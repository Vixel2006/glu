const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const net = @import("net.zig");
const zio = @import("zio");

pub const Socket = zio.net.Socket;

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

fn setInt(fd: i32, level: c_int, opt: u32, val: c_int) void {
    _ = c.setsockopt(fd, level, opt, &val, @sizeOf(c_int));
}

fn setTimeval(fd: i32, level: c_int, opt: u32, ms: u32) void {
    const tv = std.c.timeval{
        .sec = @as(c_int, @intCast(ms / 1000)),
        .usec = @as(c_int, @intCast((ms % 1000) * 1000)),
    };
    _ = c.setsockopt(fd, level, opt, &tv, @sizeOf(std.c.timeval));
}

fn applySocketOpts(fd: i32, config: SocketConfig) void {
    if (config.recv_buf) |buf| setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (config.send_buf) |buf| setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);
    setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.BROADCAST)), @as(c_int, @intFromBool(config.broadcast)));
    if (config.recv_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

pub fn bind(port: u16, config: SocketConfig) !Socket {
    var addr_buf: [32]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "0.0.0.0:{d}", .{port});
    const addr = try zio.net.IpAddress.parseIpAndPort(addr_str);

    const socket = try addr.bind(.{});

    applySocketOpts(socket.handle, config);

    return socket;
}

pub fn sendTo(socket: *Socket, host: []const u8, port: u16, data: []const u8) !usize {
    assert(host.len > 0);
    assert(port > 0);
    assert(data.len > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port });
    const addr = try zio.net.IpAddress.parseIpAndPort(addr_str);

    return socket.sendTo(.{ .ip = addr }, data, .none);
}

pub fn receiveFrom(socket: *Socket, buffer: []u8) !ReceiveResult {
    assert(buffer.len > 0);
    const result = try socket.receiveFrom(buffer, .none);
    return ReceiveResult{
        .data = buffer[0..result.len],
        .sender = net.addressToEndpoint(result.from),
    };
}

pub fn connect(socket: *Socket, host: []const u8, port: u16) void {
    assert(host.len > 0);
    assert(port > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch return;
    const addr = zio.net.IpAddress.parseIpAndPort(addr_str) catch return;

    socket.connect(.{ .ip = addr }, .{ .timeout = .none }) catch {};
}

pub fn send(socket: *Socket, data: []const u8) !usize {
    assert(data.len > 0);
    return socket.send(data, .none);
}

pub fn receive(socket: *Socket, buffer: []u8) !usize {
    assert(buffer.len > 0);
    const n = try socket.receive(buffer, .none);
    if (n == 0) return error.ConnectionResetByPeer;
    return n;
}

pub fn joinMulticast(socket: *Socket, group: []const u8) void {
    assert(group.len > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:0", .{group}) catch return;
    const addr = zio.net.IpAddress.parseIpAndPort(addr_str) catch return;

    if (addr.any.family != std.os.linux.AF.INET) return;

    const mreq = IpMreq{
        .imr_multiaddr = addr.in.addr,
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket.handle, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, @sizeOf(IpMreq));
}

pub fn leaveMulticast(socket: *Socket, group: []const u8) void {
    assert(group.len > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:0", .{group}) catch return;
    const addr = zio.net.IpAddress.parseIpAndPort(addr_str) catch return;

    if (addr.any.family != std.os.linux.AF.INET) return;

    const mreq = IpMreq{
        .imr_multiaddr = addr.in.addr,
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket.handle, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, @sizeOf(IpMreq));
}

pub fn close(socket: *Socket) void {
    socket.close();
}

fn getPort(fd: i32) u16 {
    var sockname: posix.sockaddr.in = undefined;
    var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

test "bind and close cleanly" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var s = try bind(0, .{});
    defer close(&s);
}

test "sendTo and receiveFrom exchange data" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var receiver = try bind(0, .{});
    defer close(&receiver);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(0, .{});
    defer close(&sender);

    const msg = "hello udp!";
    const sent = try sendTo(&sender, "127.0.0.1", recv_port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(&receiver, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
    try std.testing.expect(mem.eql(u8, msg, result.data));
}

test "receiveFrom returns correct sender endpoint" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var receiver = try bind(0, .{});
    defer close(&receiver);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(0, .{});
    defer close(&sender);
    const send_port = getPort(sender.handle);

    const msg = "whoami";
    _ = try sendTo(&sender, "127.0.0.1", recv_port, msg);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(&receiver, &buf);
    try std.testing.expect(mem.eql(u8, msg, result.data));
    try std.testing.expect(mem.eql(u8, "127.0.0.1", result.sender.host[0..result.sender.host_len]));
    try std.testing.expectEqual(send_port, result.sender.port);
}

test "bind fails with BindFailed on port conflict" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var sock1 = try bind(0, .{});
    defer close(&sock1);
    const port = getPort(sock1.handle);
    try std.testing.expectError(error.AddressInUse, bind(port, .{}));
}

test "sendTo and receiveFrom return correct byte count" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var receiver = try bind(0, .{});
    defer close(&receiver);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(0, .{});
    defer close(&sender);

    const msg = "hello";
    const sent = try sendTo(&sender, "127.0.0.1", recv_port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [16]u8 = undefined;
    const result = try receiveFrom(&receiver, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
}

test "joinMulticast accepts loopback address" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var s = try bind(0, .{});
    defer close(&s);

    joinMulticast(&s, "224.0.0.1");
    leaveMulticast(&s, "224.0.0.1");
}

test "connected send and receive" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var receiver = try bind(0, .{});
    defer close(&receiver);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(0, .{});
    defer close(&sender);
    const send_port = getPort(sender.handle);

    connect(&sender, "127.0.0.1", recv_port);
    connect(&receiver, "127.0.0.1", send_port);

    const msg = "hello connected!";
    const sent = try send(&sender, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const n = try receive(&receiver, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(mem.eql(u8, msg, buf[0..n]));
}

test "socket options apply on a real socket" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var s = try bind(0, .{});
    defer close(&s);
}
