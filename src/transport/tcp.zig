const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const mem = std.mem;
const posix = std.posix;
const IO = @import("../io.zig").IO;
const net = @import("net.zig");

pub const Socket = posix.socket_t;

pub const Server = struct {
    socket: Socket,
    handle: posix.fd_t,
};

pub const Stream = struct {
    socket: Socket,
    handle: posix.fd_t,

    pub fn write(
        self: *Stream,
        io: *IO,
        future: *IO.Future,
        buf: []const u8,
    ) !void {
        try io.write(future, self.handle, buf, 0);
    }

    pub fn read(
        self: *Stream,
        io: *IO,
        future: *IO.Future,
        buf: []u8,
    ) !void {
        try io.read(future, self.handle, buf, 0);
    }
};

pub const Config = struct {
    nodelay: bool = true,
    quickack: bool = true,
    keepalive: bool = false,
    keepalive_idle: u32 = 7200,
    keepalive_interval: u32 = 75,
    keepalive_count: u32 = 9,
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    defer_accept: bool = false,
    connect_timeout_ms: u32 = 5000,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

const IPPROTO_TCP: u32 = 6;
const TCP_NODELAY: u32 = 1;
const TCP_QUICKACK: u32 = 12;
const TCP_KEEPIDLE: u32 = 4;
const TCP_KEEPINTVL: u32 = 5;
const TCP_KEEPCNT: u32 = 6;
const TCP_DEFER_ACCEPT: u32 = 9;

fn set_int(fd: i32, level: c_int, opt: u32, val: c_int) void {
    if (c.setsockopt(fd, level, opt, &val, @sizeOf(c_int)) == -1) {
        std.log.warn("setsockopt failed for fd {} level {} opt {}", .{ fd, level, opt });
    }
}

fn set_timeval(fd: i32, level: c_int, opt: u32, ms: u32) void {
    const tv = std.c.timeval{
        .sec = @as(c_int, @intCast(ms / 1000)),
        .usec = @as(c_int, @intCast((ms % 1000) * 1000)),
    };
    if (c.setsockopt(fd, level, opt, &tv, @sizeOf(std.c.timeval)) == -1) {
        std.log.warn("setsockopt timeval failed for fd {} level {} opt {}", .{ fd, level, opt });
    }
}

pub fn apply_socket_opts(fd: i32, config: Config) void {
    if (config.nodelay) set_int(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    if (config.quickack) set_int(fd, IPPROTO_TCP, TCP_QUICKACK, 1);
    set_int(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.KEEPALIVE)), @as(c_int, @intFromBool(config.keepalive)));
    if (config.keepalive) {
        set_int(fd, IPPROTO_TCP, TCP_KEEPIDLE, @as(c_int, @intCast(config.keepalive_idle)));
        set_int(fd, IPPROTO_TCP, TCP_KEEPINTVL, @as(c_int, @intCast(config.keepalive_interval)));
        set_int(fd, IPPROTO_TCP, TCP_KEEPCNT, @as(c_int, @intCast(config.keepalive_count)));
    }
    if (config.recv_timeout_ms) |ms| set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| set_timeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

pub fn listen(io: *IO, port: u16, config: Config) !Server {
    const socket = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);

    const reuse: i32 = 1;
    _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port),
        .addr = 0,
    };
    try io.bind(socket, addr);
    try io.listen(socket, 128);

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }

    return .{ .socket = socket, .handle = socket };
}

pub fn accept(
    io: *IO,
    future: *IO.Future,
    server: *Server,
) !void {
    try io.accept(future, server.socket);
}

pub fn connect(
    io: *IO,
    future: *IO.Future,
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

    const socket = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer _ = c.close(socket);

    try io.connect(future, socket, addr);
}

pub fn send(
    io: *IO,
    future: *IO.Future,
    stream: *Stream,
    data: []const u8,
) !void {
    assert(data.len > 0);
    try io.send(future, stream.handle, data);
}

pub fn receive(
    io: *IO,
    future: *IO.Future,
    stream: *Stream,
    buffer: []u8,
) !void {
    assert(buffer.len > 0);
    try io.recv(future, stream.handle, buffer);
}

pub fn close(stream: *Stream) void {
    _ = c.close(stream.handle);
}

pub fn close_server(server: *Server) void {
    _ = c.close(server.handle);
}

fn getPort(fd: i32) u16 {
    var sockname: std.posix.sockaddr.in = undefined;
    var poollen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &poollen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

const testing = std.testing;

test "listen: bind and close cleanly" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try listen(&io, 0, .{});
    defer close_server(&server);
}

test "listen + connect + accept round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try listen(&io, 0, .{});
    defer close_server(&server);

    const port = getPort(server.handle);

    var compl_connect: IO.Future = undefined;
    var compl_accept: IO.Future = undefined;

    try connect(&io, &compl_connect, "127.0.0.1", port);
    try accept(&io, &compl_accept, &server);

    try io.wait(&compl_connect, void);
    const client_sock = compl_connect.operation.connect.socket;
    apply_socket_opts(client_sock, .{});
    var stream = Stream{ .socket = client_sock, .handle = client_sock };
    defer close(&stream);

    const server_sock = try io.wait(&compl_accept, posix.socket_t);
    apply_socket_opts(server_sock, .{});
    var accepted = Stream{ .socket = server_sock, .handle = server_sock };
    defer close(&accepted);
}

test "send and receive data" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try listen(&io, 0, .{});
    defer close_server(&server);

    const port = getPort(server.handle);
    const msg = "hello glu!";

    var compl_connect: IO.Future = undefined;
    var compl_accept: IO.Future = undefined;

    try connect(&io, &compl_connect, "127.0.0.1", port);
    try accept(&io, &compl_accept, &server);

    try io.wait(&compl_connect, void);
    const client_sock = compl_connect.operation.connect.socket;
    apply_socket_opts(client_sock, .{});
    var stream = Stream{ .socket = client_sock, .handle = client_sock };
    defer close(&stream);

    const server_sock = try io.wait(&compl_accept, posix.socket_t);
    apply_socket_opts(server_sock, .{});
    var accepted = Stream{ .socket = server_sock, .handle = server_sock };
    defer close(&accepted);

    var compl_send: IO.Future = undefined;
    var compl_recv: IO.Future = undefined;

    try send(&io, &compl_send, &stream, msg);

    var buf: [64]u8 = undefined;
    try receive(&io, &compl_recv, &accepted, &buf);

    const sent_bytes = try io.wait(&compl_send, usize);
    try std.testing.expectEqual(msg.len, sent_bytes);

    const recv_bytes = try io.wait(&compl_recv, usize);
    try std.testing.expectEqual(msg.len, recv_bytes);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..recv_bytes]));
}

test "socket options apply on a real socket" {
    var io = try IO.init(32, 0);
    defer io.deinit();
    var server = try listen(&io, 0, .{});
    defer close_server(&server);
}
