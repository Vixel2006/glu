const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;
const net = @import("net.zig");
const sockopt = @import("sockopt.zig");

pub const UdpErr = error{
    SocketFailed,
    BindFailed,
    SendFailed,
    RecvFailed,
    AddressResolveFailed,
    WouldBlock,
    Interrupted,
    SetSockOptFailed,
    MulticastFailed,
    NotConnected,
};

fn mapErr(errno_val: i32) UdpErr {
    return switch (@as(linux.E, @enumFromInt(errno_val))) {
        .AGAIN => UdpErr.WouldBlock,
        .INTR => UdpErr.Interrupted,
        .NOTCONN => UdpErr.NotConnected,
        else => UdpErr.SocketFailed,
    };
}

const IPPROTO_IP = 0;
const IP_ADD_MEMBERSHIP = 35;
const IP_DROP_MEMBERSHIP = 36;

const IpMreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};

comptime {
    std.debug.assert(@sizeOf(IpMreq) == 8);
}

pub const SocketConfig = struct {
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    broadcast: bool = false,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

pub const ReceiveResult = struct {
    data: []u8,
    sender: net.Endpoint,
};

pub fn bind(port: u16, config: SocketConfig) UdpErr!struct { fd: c_int, port: u16 } {
    const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) return mapErr(c._errno().*);

    const addr = posix.sockaddr.in{
        .family = c.AF.INET,
        .port = mem.nativeToBig(u16, port),
        .addr = 0,
    };

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) == -1)
        return UdpErr.BindFailed;

    sockopt.applyUdp(fd, .{
        .recv_buf = config.recv_buf,
        .send_buf = config.send_buf,
        .broadcast = config.broadcast,
        .recv_timeout_ms = config.recv_timeout_ms,
        .send_timeout_ms = config.send_timeout_ms,
    }) catch |e| {
        _ = c.close(fd);
        return e;
    };

    const actual_port: u16 = blk: {
        if (port != 0) break :blk port;
        var sockname: posix.sockaddr.in = undefined;
        var socklen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.getsockname(fd, @ptrCast(&sockname), &socklen) == 0)
            break :blk mem.bigToNative(u16, sockname.port)
        else
            break :blk port;
    };

    return .{ .fd = fd, .port = actual_port };
}

pub fn sendTo(fd: c_int, host: []const u8, port: u16, data: []const u8) UdpErr!usize {
    assert(fd >= 0);
    assert(host.len > 0);
    const dest = try net.resolve(host, port, c.SOCK.DGRAM);
    const rc = c.sendto(fd, data.ptr, data.len, 0, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));
    if (rc == -1) return mapErr(c._errno().*);
    return @as(usize, @intCast(rc));
}

pub fn receiveFrom(fd: c_int, buffer: []u8) UdpErr!ReceiveResult {
    assert(fd >= 0);
    var sender_addr: posix.sockaddr.in = undefined;
    var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const rc = c.recvfrom(fd, buffer.ptr, buffer.len, 0, @ptrCast(&sender_addr), &addrlen);
    if (rc == -1) return mapErr(c._errno().*);
    return ReceiveResult{
        .data = buffer[0..@as(usize, @intCast(rc))],
        .sender = net.sockaddrToEndpoint(sender_addr),
    };
}

pub fn joinMulticast(fd: c_int, group: []const u8) UdpErr!void {
    assert(fd >= 0);
    const group_addr = try net.resolve(group, 0, c.SOCK.DGRAM);
    const mreq = IpMreq{
        .imr_multiaddr = group_addr.addr,
        .imr_interface = 0,
    };
    if (c.setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, @sizeOf(IpMreq)) == -1)
        return UdpErr.MulticastFailed;
}

pub fn leaveMulticast(fd: c_int, group: []const u8) UdpErr!void {
    assert(fd >= 0);
    const group_addr = try net.resolve(group, 0, c.SOCK.DGRAM);
    const mreq = IpMreq{
        .imr_multiaddr = group_addr.addr,
        .imr_interface = 0,
    };
    if (c.setsockopt(fd, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, @sizeOf(IpMreq)) == -1)
        return UdpErr.MulticastFailed;
}

pub fn connect(fd: c_int, host: []const u8, port: u16) UdpErr!void {
    assert(fd >= 0);
    assert(host.len > 0);
    const addr = try net.resolve(host, port, c.SOCK.DGRAM);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) == -1)
        return mapErr(c._errno().*);
}

pub fn send(fd: c_int, data: []const u8) UdpErr!usize {
    assert(fd >= 0);
    const rc = c.send(fd, data.ptr, data.len, 0);
    if (rc == -1) return mapErr(c._errno().*);
    return @as(usize, @intCast(rc));
}

pub fn receive(fd: c_int, buffer: []u8) UdpErr!usize {
    assert(fd >= 0);
    const rc = c.recv(fd, buffer.ptr, buffer.len, 0);
    if (rc == -1) return mapErr(c._errno().*);
    return @as(usize, @intCast(rc));
}

pub fn close(fd: c_int) void {
    assert(fd >= 0);
    _ = c.close(fd);
}

test "bind and close cleanly" {
    const r = try bind(0, .{});
    defer close(r.fd);
    try std.testing.expect(r.fd >= 0);
}

test "sendTo invalid host returns AddressResolveFailed" {
    const r = try bind(0, .{});
    defer close(r.fd);
    const result = sendTo(r.fd, "nonexistent.invalid.example.com", 12345, "hello");
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "sendTo and receiveFrom exchange data" {
    const receiver = try bind(0, .{});
    defer close(receiver.fd);

    const sender = try bind(0, .{});
    defer close(sender.fd);

    const msg = "hello udp!";
    const sent = try sendTo(sender.fd, "127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(receiver.fd, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
    try std.testing.expect(mem.eql(u8, msg, result.data));
}

test "receiveFrom returns correct sender endpoint" {
    const receiver = try bind(0, .{});
    defer close(receiver.fd);

    const sender = try bind(0, .{});
    defer close(sender.fd);

    const msg = "whoami";
    _ = try sendTo(sender.fd, "127.0.0.1", receiver.port, msg);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(receiver.fd, &buf);
    try std.testing.expect(mem.eql(u8, msg, result.data));
    try std.testing.expect(mem.eql(u8, "127.0.0.1", result.sender.host[0..result.sender.host_len]));
    try std.testing.expectEqual(sender.port, result.sender.port);
}

test "bind fails with BindFailed on port conflict" {
    const sock1 = try bind(0, .{});
    defer close(sock1.fd);
    const result = bind(sock1.port, .{});
    try std.testing.expectError(error.BindFailed, result);
}

test "non-blocking receive yields WouldBlock" {
    const r = try bind(0, .{});
    defer close(r.fd);
    net.setBlocking(r.fd, false);
    var buf: [1]u8 = undefined;
    const result = receiveFrom(r.fd, &buf);
    try std.testing.expectError(error.WouldBlock, result);
}

test "sendTo and receiveFrom return correct byte count" {
    const receiver = try bind(0, .{});
    defer close(receiver.fd);

    const sender = try bind(0, .{});
    defer close(sender.fd);

    const msg = "hello";
    const sent = try sendTo(sender.fd, "127.0.0.1", receiver.port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [16]u8 = undefined;
    const result = try receiveFrom(receiver.fd, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
}

test "joinMulticast accepts loopback address" {
    const r = try bind(0, .{});
    defer close(r.fd);

    joinMulticast(r.fd, "224.0.0.1") catch {};
    leaveMulticast(r.fd, "224.0.0.1") catch {};
}

test "connected send and receive" {
    const receiver = try bind(0, .{});
    defer close(receiver.fd);

    const sender = try bind(0, .{});
    defer close(sender.fd);

    connect(sender.fd, "127.0.0.1", receiver.port) catch unreachable;
    connect(receiver.fd, "127.0.0.1", sender.port) catch unreachable;

    const msg = "hello connected!";
    const sent = try send(sender.fd, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const n = try receive(receiver.fd, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(mem.eql(u8, msg, buf[0..n]));
}
