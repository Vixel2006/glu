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
    /// Allow multiple sockets to bind the same address/port. Required by
    /// multicast discovery, where every node shares one discovery port.
    reuse_addr: bool = false,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

pub const ReceiveResult = struct {
    data: []u8,
    sender: net.Endpoint,
};

const IPPROTO_IP = 0;
const IP_MULTICAST_IF = 32;
const IP_MULTICAST_TTL = 33;
const IP_MULTICAST_LOOP = 34;
const IP_ADD_MEMBERSHIP = 35;
const IP_DROP_MEMBERSHIP = 36;

const IpMcreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};

comptime {
    assert(@sizeOf(IpMcreq) == 8);
}

fn apply_socket_opts(fd: i32, config: SocketConfig) void {
    if (config.recv_buf) |buf| net.set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (config.send_buf) |buf| net.set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);
    net.set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.BROADCAST)), @as(c_int, @intFromBool(config.broadcast)));
    if (config.recv_timeout_ms) |ms| net.set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| net.set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

const BindConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16,
};

pub fn bind(io: *IO, bind_config: BindConfig, socket_config: SocketConfig) !Socket {
    const socket = try io.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);

    // Multiple nodes share the same discovery port, so a second bind to the
    // same address/port would fail with EADDRINUSE. SO_REUSEADDR must be set
    // before bind() to take effect on UDP sockets.
    if (socket_config.reuse_addr) {
        net.set_int(socket, c.SOL.SOCKET, @as(u32, @intCast(c.SO.REUSEADDR)), 1);
    }

    const parsed = try std.Io.net.IpAddress.parseIp4(bind_config.host, bind_config.port);
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(parsed.ip4.port),
        .addr = @bitCast(parsed.ip4.bytes),
    };

    try io.bind(socket, addr);

    apply_socket_opts(socket, socket_config);

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

pub fn join_multicast(socket: Socket, group: []const u8, port: u16, interface: []const u8) void {
    assert(group.len > 0);
    const parsed_group = (std.Io.net.IpAddress.parseIp4(group, port) catch return).ip4;
    const imr_interface: u32 = if (std.mem.eql(u8, interface, ""))
        0
    else blk: {
        const parsed_iface = (std.Io.net.IpAddress.parseIp4(interface, 0) catch return).ip4;
        break :blk @bitCast(parsed_iface.bytes);
    };

    const mcreq = IpMcreq{
        .imr_multiaddr = @bitCast(parsed_group.bytes),
        .imr_interface = imr_interface,
    };
    _ = c.setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mcreq, @sizeOf(IpMcreq));
}

pub fn leave_multicast(socket: Socket, group: []const u8) void {
    assert(group.len > 0);
    const parsed = (std.Io.net.IpAddress.parseIp4(group, 0) catch return).ip4;

    const mcreq = IpMcreq{
        .imr_multiaddr = @bitCast(parsed.bytes),
        .imr_interface = 0,
    };
    _ = c.setsockopt(socket, IPPROTO_IP, IP_DROP_MEMBERSHIP, &mcreq, @sizeOf(IpMcreq));
}

/// Set the interface outgoing multicast datagrams are transmitted on.
pub fn set_multicast_if(socket: Socket, interface: []const u8) void {
    assert(interface.len > 0);
    const parsed = (std.Io.net.IpAddress.parseIp4(interface, 0) catch return).ip4;
    const addr: u32 = @bitCast(parsed.bytes);
    _ = c.setsockopt(socket, IPPROTO_IP, IP_MULTICAST_IF, &addr, @sizeOf(u32));
}

/// Enable/disable a socket receiving its own multicast datagrams.
pub fn set_multicast_loop(socket: Socket, on: bool) void {
    const enabled: u8 = @intFromBool(on);
    _ = c.setsockopt(socket, IPPROTO_IP, IP_MULTICAST_LOOP, &enabled, @sizeOf(u8));
}

test "bind UDP socket" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const socket = try bind(&io, .{ .port = 0 }, .{});
    defer _ = c.close(socket);
}

test "send_to and receive_from round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const socket1 = try bind(&io, .{ .port = 0 }, .{});
    defer _ = c.close(socket1);

    const socket2 = try bind(&io, .{ .port = 0 }, .{});
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
