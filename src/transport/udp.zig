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

fn apply_socket_opts(fd: i32, config: SocketConfig) void {
    if (config.recv_buf) |buf| setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (config.send_buf) |buf| setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);
    setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.BROADCAST)), @as(c_int, @intFromBool(config.broadcast)));
    if (config.recv_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
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
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.SendToError!usize,
    ) void,
    completion: *IO.Completion,
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

    try io.send_to(Context, context, callback, completion, socket, data, addr);
}

pub fn receive_from(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.RecvFromError!ReceiveResult,
    ) void,
    completion: *IO.Completion,
    socket: Socket,
    buffer: []u8,
) !void {
    assert(buffer.len > 0);

    const wrapper = struct {
        fn call(ctx: Context, compl: *IO.Completion, res: IO.RecvFromError!usize) void {
            const result: IO.RecvFromError!ReceiveResult = blk: {
                if (res) |n| {
                    const addr = compl.operation.recv_from.address;
                    break :blk ReceiveResult{
                        .data = compl.operation.recv_from.buffer[0..n],
                        .sender = net.address_to_endpoint(addr),
                    };
                } else |err| {
                    break :blk err;
                }
            };
            callback(ctx, compl, result);
        }
    }.call;

    try io.recv_from(Context, context, wrapper, completion, socket, buffer);
}

pub fn connect(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.ConnectError!void,
    ) void,
    completion: *IO.Completion,
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
    try io.connect(Context, context, callback, completion, socket, addr);
}

pub fn send(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.SendError!usize,
    ) void,
    completion: *IO.Completion,
    socket: Socket,
    data: []const u8,
) !void {
    assert(data.len > 0);
    try io.send(Context, context, callback, completion, socket, data);
}

pub fn receive(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.RecvError!usize,
    ) void,
    completion: *IO.Completion,
    socket: Socket,
    buffer: []u8,
) !void {
    assert(buffer.len > 0);
    try io.recv(Context, context, callback, completion, socket, buffer);
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

    const TestContext = struct {
        send_done: bool = false,
        recv_done: bool = false,
        send_result: ?IO.SendToError!usize = null,
        recv_result: ?IO.RecvFromError!ReceiveResult = null,
    };

    var ctx = TestContext{};

    const send_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.SendToError!usize) void {
            _ = compl;
            c_ctx.send_result = res;
            c_ctx.send_done = true;
        }
    }.call;

    const recv_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.RecvFromError!ReceiveResult) void {
            _ = compl;
            c_ctx.recv_result = res;
            c_ctx.recv_done = true;
        }
    }.call;

    var compl_send: IO.Completion = undefined;
    var compl_recv: IO.Completion = undefined;

    const msg = "hello udp";
    try send_to(&io, *TestContext, &ctx, send_cb, &compl_send, socket2, "127.0.0.1", port1, msg);

    var buf: [64]u8 = undefined;
    try receive_from(&io, *TestContext, &ctx, recv_cb, &compl_recv, socket1, &buf);

    while (!ctx.send_done or !ctx.recv_done) {
        try io.submit(1);
        try io.complete(1);
        try io.complete_all();
    }

    const sent_bytes = try ctx.send_result.?;
    try std.testing.expectEqual(msg.len, sent_bytes);

    const recv_res = try ctx.recv_result.?;
    try std.testing.expectEqual(@as(usize, msg.len), recv_res.data.len);
    try std.testing.expect(std.mem.eql(u8, msg, recv_res.data));
}