const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const net = @import("net.zig");
const IO = @import("../io.zig").IO;

pub const Socket = posix.socket_t;

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
    assert(@sizeOf(IpMreq) == 8);
}

fn set_int(fd: i32, level: c_int, opt: u32, val: c_int) void {
    if (c.setsockopt(fd, level, opt, &val, @sizeOf(c_int)) == -1) {
        std.log.warn("setsockopt failed for fd {} level {} opt {}", .{ fd, level, opt });
    }
}

fn set_timeval(fd: i32, level: c_int, opt: u32, ms: u32) void {
    const tv = std.c.timeval{
        .sec = @as(c_int, @intCast(ms / 1000)),
        .usec = @as(c_int, @intCast((ms % 1000) * 1_000_000)),
    };
    if (c.setsockopt(fd, level, opt, &tv, @sizeOf(std.c.timeval)) == -1) {
        std.log.warn("setsockopt timeval failed for fd {} level {} opt {}", .{ fd, level, opt });
    }
}

fn apply_socket_opts(fd: i32, config: SocketConfig) void {
    if (config.recv_buf) |buf| set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (config.send_buf) |buf| set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);
    set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.BROADCAST)), @as(c_int, @intFromBool(config.broadcast)));
    if (config.recv_timeout_ms) |ms| set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

pub fn bind(io: *IO, port: u16, config: SocketConfig) !Socket {
    const socket = try io.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);

    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port),
        .addr = 0,
    };

    try io.bind(socket, addr);

    apply_socket_opts(socket, config);

    return socket;
}

pub fn send_to(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    host: []const u8,
    port: u16,
    data: []const u8,
) !void {
    assert(host.len > 0);
    assert(port > 0);
    assert(data.len > 0);

    const parsed = try std.Io.net.IpAddress.parse(host, port);
    const addr: posix.sockaddr.in = switch (parsed) {
        .ip4 => |ip4| .{
            .port = @byteSwap(ip4.port),
            .addr = @bitCast(ip4.bytes),
        },
        .ip6 => return error.AddressFamilyNotSupported,
    };

    try io.send_to(future, socket, data, addr);
}


pub fn close(socket: *Socket) void {
    _ = c.close(socket.*);
}

pub fn receive_from(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    buffer: []u8,
) !void {
    assert(buffer.len > 0);
    try io.recv_from(future, socket, buffer);
}


pub fn connect(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    host: []const u8,
    port: u16,
) !void {
    assert(host.len > 0);
    assert(port > 0);
    const parsed = try std.Io.net.IpAddress.parse(host, port);
    const addr: posix.sockaddr.in = switch (parsed) {
        .ip4 => |ip4| .{
            .port = @byteSwap(ip4.port),
            .addr = @bitCast(ip4.bytes),
        },
        .ip6 => return error.AddressFamilyNotSupported,
    };
    try io.connect(future, socket, addr);
}


pub fn send(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    data: []const u8,
) !void {
    assert(data.len > 0);
    try io.send(future, socket, data);
}


pub fn receive(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    buffer: []u8,
) !void {
    assert(buffer.len > 0);
    try io.recv(future, socket, buffer);
}


pub fn join_multicast(socket: Socket, group: []const u8) void {
    assert(group.len > 0);
    const parsed = (std.Io.net.IpAddress.parseIp4(group, 0) catch return).ip4;

    const mreq = IpMreq{
        .imr_multiaddr = @bitCast(parsed.bytes),
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, @sizeOf(IpMreq));
}

test "bind UDP socket" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const socket = try bind(&io, 0, .{});
    defer _ = c.close(socket);
}

test "send_to and receive_from round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const socket1 = try bind(&io, 0, .{});
    defer _ = c.close(socket1);

    const socket2 = try bind(&io, 0, .{});
    defer _ = c.close(socket2);

    var addr1: std.posix.sockaddr.in = undefined;
    var len1: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    _ = c.getsockname(socket1, @ptrCast(&addr1), &len1);
    const port1 = std.mem.bigToNative(u16, addr1.port);

    var compl_send: IO.Future = undefined;
    var compl_recv: IO.Future = undefined;

    const msg = "hello udp";
    try send_to(&io, &compl_send, socket2, "127.0.0.1", port1, msg);

    var buf: [64]u8 = undefined;
    try receive_from(&io, &compl_recv, socket1, &buf);

    const sent_bytes = try io.wait(&compl_send, usize);
    try std.testing.expectEqual(msg.len, sent_bytes);

    const n = try io.wait(&compl_recv, usize);
    const recv_res = ReceiveResult{
        .data = buf[0..n],
        .sender = net.address_to_endpoint(compl_recv.operation.recv_from.address),
    };
    try std.testing.expectEqual(@as(usize, msg.len), recv_res.data.len);
    try std.testing.expect(std.mem.eql(u8, msg, recv_res.data));
}
