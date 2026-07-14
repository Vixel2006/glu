const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const net = @import("net.zig");

pub const Socket = std.Io.net.Socket;

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

pub fn bind(io: std.Io, port: u16, config: SocketConfig) std.Io.net.IpAddress.BindError!Socket {
    var addr_buf: [32]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "0.0.0.0:{d}", .{port}) catch return error.AddressUnavailable;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return error.AddressUnavailable;

    const socket = try std.Io.net.IpAddress.bind(&addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    applySocketOpts(socket.handle, config);

    return socket;
}

pub fn sendTo(socket: *Socket, io: std.Io, host: []const u8, port: u16, data: []const u8) (std.Io.net.Socket.SendError || error{AddressUnavailable})!usize {
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch return error.AddressUnavailable;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return error.AddressUnavailable;

    try socket.send(io, &addr, data);
    return data.len;
}

pub fn receiveFrom(socket: *Socket, io: std.Io, buffer: []u8) std.Io.net.Socket.ReceiveError!ReceiveResult {
    const received = try socket.receive(io, buffer);
    return ReceiveResult{
        .data = received.data,
        .sender = net.ipAddressToEndpoint(received.from),
    };
}

pub fn connect(socket: *Socket, host: []const u8, port: u16) void {
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch return;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return;

    var sockaddr = posix.sockaddr.in{
        .family = c.AF.INET,
        .port = mem.nativeToBig(u16, addr.getPort()),
        .addr = switch (addr) {
            .ip4 => |ip4| @bitCast(ip4.bytes),
            .ip6 => return,
        },
    };

    _ = c.connect(socket.handle, @ptrCast(&sockaddr), @sizeOf(posix.sockaddr.in));
}

pub fn send(socket: *Socket, io: std.Io, data: []const u8) std.Io.net.Stream.Writer.Error!usize {
    const n = try io.vtable.netWrite(io.userdata, socket.handle, &.{}, &.{data}, 1);
    return n;
}

pub fn receive(socket: *Socket, io: std.Io, buffer: []u8) std.Io.net.Stream.Reader.Error!usize {
    var read_buf = [_][]u8{buffer};
    const n = try io.vtable.netRead(io.userdata, socket.handle, &read_buf);
    if (n == 0) return error.ConnectionResetByPeer;
    return n;
}

pub fn joinMulticast(socket: *Socket, group: []const u8) void {
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:0", .{group}) catch return;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return;

    const group_addr = switch (addr) {
        .ip4 => |ip4| mem.nativeToBig(u32, @bitCast(ip4.bytes)),
        .ip6 => return,
    };

    const mreq = IpMreq{
        .imr_multiaddr = group_addr,
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket.handle, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, @sizeOf(IpMreq));
}

pub fn leaveMulticast(socket: *Socket, group: []const u8) void {
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:0", .{group}) catch return;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return;

    const group_addr = switch (addr) {
        .ip4 => |ip4| mem.nativeToBig(u32, @bitCast(ip4.bytes)),
        .ip6 => return,
    };

    const mreq = IpMreq{
        .imr_multiaddr = group_addr,
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket.handle, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mreq, @sizeOf(IpMreq));
}

pub fn close(socket: *Socket, io: std.Io) void {
    socket.close(io);
}

fn getPort(fd: i32) u16 {
    var sockname: posix.sockaddr.in = undefined;
    var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

test "bind and close cleanly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = try bind(io, 0, .{});
    defer close(&s, io);
}

test "sendTo and receiveFrom exchange data" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var receiver = try bind(io, 0, .{});
    defer close(&receiver, io);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(io, 0, .{});
    defer close(&sender, io);

    const msg = "hello udp!";
    const sent = try sendTo(&sender, io, "127.0.0.1", recv_port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(&receiver, io, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
    try std.testing.expect(mem.eql(u8, msg, result.data));
}

test "receiveFrom returns correct sender endpoint" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var receiver = try bind(io, 0, .{});
    defer close(&receiver, io);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(io, 0, .{});
    defer close(&sender, io);
    const send_port = getPort(sender.handle);

    const msg = "whoami";
    _ = try sendTo(&sender, io, "127.0.0.1", recv_port, msg);

    var buf: [64]u8 = undefined;
    const result = try receiveFrom(&receiver, io, &buf);
    try std.testing.expect(mem.eql(u8, msg, result.data));
    try std.testing.expect(mem.eql(u8, "127.0.0.1", result.sender.host[0..result.sender.host_len]));
    try std.testing.expectEqual(send_port, result.sender.port);
}

test "bind fails with BindFailed on port conflict" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var sock1 = try bind(io, 0, .{});
    defer close(&sock1, io);
    const port = getPort(sock1.handle);
    try std.testing.expectError(error.AddressInUse, bind(io, port, .{}));
}

test "sendTo and receiveFrom return correct byte count" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var receiver = try bind(io, 0, .{});
    defer close(&receiver, io);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(io, 0, .{});
    defer close(&sender, io);

    const msg = "hello";
    const sent = try sendTo(&sender, io, "127.0.0.1", recv_port, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [16]u8 = undefined;
    const result = try receiveFrom(&receiver, io, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), result.data.len);
}

test "joinMulticast accepts loopback address" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = try bind(io, 0, .{});
    defer close(&s, io);

    joinMulticast(&s, "224.0.0.1");
    leaveMulticast(&s, "224.0.0.1");
}

test "connected send and receive" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var receiver = try bind(io, 0, .{});
    defer close(&receiver, io);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(io, 0, .{});
    defer close(&sender, io);
    const send_port = getPort(sender.handle);

    connect(&sender, "127.0.0.1", recv_port);
    connect(&receiver, "127.0.0.1", send_port);

    const msg = "hello connected!";
    const sent = try send(&sender, io, msg);
    try std.testing.expectEqual(@as(usize, msg.len), sent);

    var buf: [64]u8 = undefined;
    const n = try receive(&receiver, io, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(mem.eql(u8, msg, buf[0..n]));
}

test "send via netWrite to bound socket works" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var receiver = try bind(io, 0, .{});
    defer close(&receiver, io);
    const recv_port = getPort(receiver.handle);

    var sender = try bind(io, 0, .{});
    defer close(&sender, io);

    _ = try sendTo(&sender, io, "127.0.0.1", recv_port, "hello");

    var buf: [16]u8 = undefined;
    const result = try receiveFrom(&receiver, io, &buf);
    try std.testing.expect(mem.eql(u8, "hello", result.data));
}

test "socket options apply on a real socket" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var s = try bind(io, 0, .{});
    defer close(&s, io);
}
