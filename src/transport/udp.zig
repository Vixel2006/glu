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

/// A UDPSock bound to a port, sending and receiving datagrams.
const UDPSock = struct {
    fd: c_int,
    port: u16,

    /// Bind socket to `port`.
    /// If `port` is 0, the OS assigns an available port (query
    /// `.port` to discover the actual port).
    pub fn init(port: u16) UdpErr!UDPSock {
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

        return UDPSock{ .fd = fd, .port = actual_port };
    }

    /// Send `data` to `host:port`. Returns the number of bytes sent.
    pub fn send(self: *UDPSock, host: []const u8, port: u16, data: []const u8) UdpErr!usize {
        const dest = try resolveAddr(host, port);
        const rc = c.sendto(self.fd, data.ptr, data.len, 0, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));
        if (rc == -1) return mapErr(c._errno().*);
        return @as(usize, @intCast(rc));
    }

    /// Receive up to `buffer.len` bytes. Returns the number of bytes received.
    pub fn receive(self: *UDPSock, buffer: []u8) UdpErr!usize {
        const rc = c.recvfrom(self.fd, buffer.ptr, buffer.len, 0, null, null);
        if (rc == -1) return mapErr(c._errno().*);
        return @as(usize, @intCast(rc));
    }

    /// Switch between blocking and non-blocking I/O mode.
    pub fn setBlocking(self: *UDPSock, blocking: bool) UdpErr!void {
        const flags = c.fcntl(self.fd, c.F.GETFL);
        if (flags == -1) return mapErr(c._errno().*);
        const nonblock: c_int = @bitCast(linux.O{ .NONBLOCK = true });
        const new_flags = if (blocking) flags & ~nonblock else flags | nonblock;
        if (c.fcntl(self.fd, c.F.SETFL, new_flags) == -1)
            return mapErr(c._errno().*);
    }

    pub fn deinit(self: *UDPSock) void {
        _ = c.close(self.fd);
    }
};

test "UDPSock: bind and deinit cleanly" {
    var sock = try UDPSock.init(0);
    defer sock.deinit();
    try std.testing.expect(sock.fd >= 0);
}

test "UDPSock: resolveAddr succeeds for localhost" {
    const addr = try resolveAddr("127.0.0.1", 0);
    try std.testing.expectEqual(c.AF.INET, addr.family);
}

test "UDPSock: resolveAddr fails for invalid host" {
    const result = resolveAddr("nonexistent.invalid.example.com", 12345);
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "UDPSock: send to invalid host returns AddressResolveFailed" {
    var sock = try UDPSock.init(0);
    defer sock.deinit();
    const result = sock.send("nonexistent.invalid.example.com", 12345, "hello");
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "UDPSock: send and receive data" {
    var receiver = try UDPSock.init(0);
    defer receiver.deinit();

    var sender = try UDPSock.init(0);
    defer sender.deinit();

    const msg = "hello udp!";
    const sent = try sender.send("127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const n = try receiver.receive(&buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(mem.eql(u8, msg, buf[0..n]));
}

test "UDPSock: init fails with BindFailed on port conflict" {
    var sock1 = try UDPSock.init(0);
    defer sock1.deinit();
    const result = UDPSock.init(sock1.port);
    try std.testing.expectError(error.BindFailed, result);
}

test "UDPSock: setBlocking enables WouldBlock on empty receive" {
    var sock = try UDPSock.init(0);
    defer sock.deinit();
    try sock.setBlocking(false);
    var buf: [1]u8 = undefined;
    const result = sock.receive(&buf);
    try std.testing.expectError(error.WouldBlock, result);
}

test "UDPSock: send returns correct byte count" {
    var receiver = try UDPSock.init(0);
    defer receiver.deinit();

    var sender = try UDPSock.init(0);
    defer sender.deinit();

    const msg = "hello";
    const sent = try sender.send("127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [16]u8 = undefined;
    const n = try receiver.receive(&buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
}
