const std = @import("std");
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;

const UdpErr = error{
    SocketFailed,
    BindFailed,
    SendFailed,
    RecvFailed,
    AddressResolveFailed,
    WouldBlock,
    Interrupted,
};

fn mapErr(errno_val: i32) UdpErr {
    return switch (@as(linux.E, @enumFromInt(errno_val))) {
        .AGAIN => UdpErr.WouldBlock,
        .INTR => UdpErr.Interrupted,
        else => UdpErr.SocketFailed,
    };
}

fn resolveAddr(host: []const u8, port: u16) UdpErr!posix.sockaddr.in {
    var hints = mem.zeroes(c.addrinfo);
    hints.family = c.AF.UNSPEC;
    hints.socktype = c.SOCK.DGRAM;

    var host_buf: [256]u8 align(1) = undefined;
    if (host.len > host_buf.len - 1) return UdpErr.AddressResolveFailed;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    const host_z: [*:0]u8 = @ptrCast(&host_buf);

    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch
        return UdpErr.AddressResolveFailed;

    var result: ?*c.addrinfo = null;
    if (@intFromEnum(c.getaddrinfo(host_z, port_str.ptr, &hints, &result)) != 0)
        return UdpErr.AddressResolveFailed;
    defer if (result) |res| c.freeaddrinfo(res);

    var info = result;
    while (info) |inf| : (info = inf.next) {
        const addr = inf.addr orelse continue;
        if (inf.family == c.AF.INET) {
            return @as(*posix.sockaddr.in, @ptrCast(@alignCast(addr))).*;
        }
    }
    return UdpErr.AddressResolveFailed;
}

/// The address of a peer that sent a datagram.
pub const Endpoint = struct {
    host: [46]u8,
    host_len: usize,
    port: u16,
};

/// The result of a `receiveFrom` call — the received data and who sent it.
pub const ReceiveResult = struct {
    data: []u8,
    sender: Endpoint,
};

/// A UDP socket bound to a port, capable of unicast.
pub const Socket = struct {
    fd: c_int,
    port: u16,

    /// Bind a UDP socket to `port` on all interfaces.
    /// If `port` is 0, the OS assigns an available port (query
    /// `.port` afterwards to discover the actual port).
    pub fn bind(port: u16) UdpErr!Socket {
        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (fd < 0) return mapErr(c._errno().*);

        const addr = posix.sockaddr.in{
            .family = c.AF.INET,
            .port = mem.nativeToBig(u16, port),
            .addr = 0,
        };

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) == -1)
            return UdpErr.BindFailed;

        const actual_port: u16 = blk: {
            if (port != 0) break :blk port;
            var sockname: posix.sockaddr.in = undefined;
            var socklen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            if (c.getsockname(fd, @ptrCast(&sockname), &socklen) == 0)
                break :blk mem.bigToNative(u16, sockname.port)
            else
                break :blk port;
        };

        return Socket{ .fd = fd, .port = actual_port };
    }

    /// Send `data` to `host:port`. Returns the number of bytes sent.
    pub fn sendTo(self: *Socket, host: []const u8, port: u16, data: []const u8) UdpErr!usize {
        const dest = try resolveAddr(host, port);
        const rc = c.sendto(self.fd, data.ptr, data.len, 0, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));
        if (rc == -1) return mapErr(c._errno().*);
        return @as(usize, @intCast(rc));
    }

    /// Receive a datagram and identify the sender.
    /// Returns `ReceiveResult` containing the data slice and the sender's endpoint.
    /// Blocks until data arrives (unless set to non-blocking).
    pub fn receiveFrom(self: *Socket, buffer: []u8) UdpErr!ReceiveResult {
        var sender_addr: posix.sockaddr.in = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const rc = c.recvfrom(self.fd, buffer.ptr, buffer.len, 0, @ptrCast(&sender_addr), &addrlen);
        if (rc == -1) return mapErr(c._errno().*);

        const host_bytes = @as(*const [4]u8, @ptrCast(&sender_addr.addr));
        var endpoint = Endpoint{
            .host = undefined,
            .host_len = 0,
            .port = mem.bigToNative(u16, sender_addr.port),
        };
        endpoint.host_len = @intCast(
            (std.fmt.bufPrint(&endpoint.host, "{d}.{d}.{d}.{d}", .{
                host_bytes[0], host_bytes[1], host_bytes[2], host_bytes[3],
            }) catch unreachable).len,
        );

        return ReceiveResult{
            .data = buffer[0..@as(usize, @intCast(rc))],
            .sender = endpoint,
        };
    }

    /// Switch between blocking and non-blocking I/O mode.
    pub fn setBlocking(self: *Socket, blocking: bool) UdpErr!void {
        const flags = c.fcntl(self.fd, c.F.GETFL);
        if (flags == -1) return mapErr(c._errno().*);
        const nonblock: c_int = @bitCast(linux.O{ .NONBLOCK = true });
        const new_flags = if (blocking) flags & ~nonblock else flags | nonblock;
        if (c.fcntl(self.fd, c.F.SETFL, new_flags) == -1)
            return mapErr(c._errno().*);
    }

    pub fn deinit(self: *Socket) void {
        _ = c.close(self.fd);
    }
};

test "Socket: bind and deinit cleanly" {
    var sock = try Socket.bind(0);
    defer sock.deinit();
    try std.testing.expect(sock.fd >= 0);
}

test "Socket: resolveAddr succeeds for localhost" {
    const addr = try resolveAddr("127.0.0.1", 0);
    try std.testing.expectEqual(c.AF.INET, addr.family);
}

test "Socket: resolveAddr fails for invalid host" {
    const result = resolveAddr("nonexistent.invalid.example.com", 12345);
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "Socket: sendTo invalid host returns AddressResolveFailed" {
    var sock = try Socket.bind(0);
    defer sock.deinit();
    const result = sock.sendTo("nonexistent.invalid.example.com", 12345, "hello");
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "Socket: sendTo and receiveFrom exchange data" {
    var receiver = try Socket.bind(0);
    defer receiver.deinit();

    var sender = try Socket.bind(0);
    defer sender.deinit();

    const msg = "hello udp!";
    const sent = try sender.sendTo("127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const result = try receiver.receiveFrom(&buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
    try std.testing.expect(mem.eql(u8, msg, result.data));
}

test "Socket: receiveFrom returns correct sender endpoint" {
    var receiver = try Socket.bind(0);
    defer receiver.deinit();

    var sender = try Socket.bind(0);
    defer sender.deinit();

    const msg = "whoami";
    _ = try sender.sendTo("127.0.0.1", receiver.port, msg);

    var buf: [64]u8 = undefined;
    const result = try receiver.receiveFrom(&buf);
    try std.testing.expect(mem.eql(u8, msg, result.data));
    try std.testing.expect(mem.eql(u8, "127.0.0.1", result.sender.host[0..result.sender.host_len]));
    try std.testing.expectEqual(sender.port, result.sender.port);
}

test "Socket: init fails with BindFailed on port conflict" {
    var sock1 = try Socket.bind(0);
    defer sock1.deinit();
    const result = Socket.bind(sock1.port);
    try std.testing.expectError(error.BindFailed, result);
}

test "Socket: setBlocking enables WouldBlock on empty receive" {
    var sock = try Socket.bind(0);
    defer sock.deinit();
    try sock.setBlocking(false);
    var buf: [1]u8 = undefined;
    const result = sock.receiveFrom(&buf);
    try std.testing.expectError(error.WouldBlock, result);
}

test "Socket: sendTo and receiveFrom return correct byte count" {
    var receiver = try Socket.bind(0);
    defer receiver.deinit();

    var sender = try Socket.bind(0);
    defer sender.deinit();

    const msg = "hello";
    const sent = try sender.sendTo("127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [16]u8 = undefined;
    const result = try receiver.receiveFrom(&buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
}
