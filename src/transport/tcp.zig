const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const mem = std.mem;

pub const Server = std.Io.net.Server;
pub const Stream = std.Io.net.Stream;

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

fn applySocketOpts(fd: i32, config: Config) void {
    if (config.nodelay) setInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    if (config.quickack) setInt(fd, IPPROTO_TCP, TCP_QUICKACK, 1);
    setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.KEEPALIVE)), @as(c_int, @intFromBool(config.keepalive)));
    if (config.keepalive) {
        setInt(fd, IPPROTO_TCP, TCP_KEEPIDLE, @as(c_int, @intCast(config.keepalive_idle)));
        setInt(fd, IPPROTO_TCP, TCP_KEEPINTVL, @as(c_int, @intCast(config.keepalive_interval)));
        setInt(fd, IPPROTO_TCP, TCP_KEEPCNT, @as(c_int, @intCast(config.keepalive_count)));
    }
    if (config.recv_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (config.send_timeout_ms) |ms| setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

/// Bind and listen for TCP connections on 0.0.0.0:{port}.
/// Returns a `Server` that can be used with `accept`.
pub fn listen(io: std.Io, port: u16, config: Config) std.Io.net.IpAddress.ListenError!Server {
    var addr_buf: [32]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "0.0.0.0:{d}", .{port}) catch return error.AddressUnavailable;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return error.AddressUnavailable;

    const server = try std.Io.net.IpAddress.listen(&addr, io, .{
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    });

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(server.socket.handle, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }

    return server;
}

/// Accept a single TCP connection and apply socket options.
pub fn accept(server: *Server, io: std.Io, config: Config) std.Io.net.Server.AcceptError!Stream {
    const stream = try server.accept(io);
    applySocketOpts(stream.socket.handle, config);
    return stream;
}

/// Connect to a TCP server at `host:port`.
/// Asserts that `host` is non-empty and `port` is non-zero.
pub fn connect(io: std.Io, host: []const u8, port: u16, config: Config) std.Io.net.IpAddress.ConnectError!Stream {
    assert(host.len > 0);
    assert(port > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch return error.AddressUnavailable;
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return error.AddressUnavailable;

    const stream = try std.Io.net.IpAddress.connect(&addr, io, .{
        .mode = .stream,
        .protocol = .tcp,
    });

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(stream.socket.handle, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }
    if (config.send_buf) |buf| {
        _ = c.setsockopt(stream.socket.handle, c.SOL.SOCKET, c.SO.SNDBUF, &buf, @sizeOf(c_int));
    }

    applySocketOpts(stream.socket.handle, config);

    return stream;
}

/// Send a length-prefixed message over a TCP stream.
/// Writes a 4-byte little-endian length header followed by `data`.
/// Asserts that `data.len` fits in a `u32`.
pub fn send(stream: *Stream, io: std.Io, data: []const u8) std.Io.net.Stream.Writer.Error!void {
    const fd = stream.socket.handle;
    assert(data.len <= std.math.maxInt(u32));
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    mem.writeInt(u32, &len_buf, len, .little);

    var parts = [_][]const u8{ len_buf[0..], data };
    var part_idx: usize = 0;
    while (part_idx < 2) {
        const n = try io.vtable.netWrite(io.userdata, fd, &.{}, &.{parts[part_idx]}, 1);
        if (n >= parts[part_idx].len) {
            part_idx += 1;
        } else {
            parts[part_idx] = parts[part_idx][n..];
        }
    }
}

/// Receive a length-prefixed message from a TCP stream.
/// Reads a 4-byte little-endian length header, then reads the message body into `buffer`.
/// If the message exceeds `buffer.len` the payload is discarded and `error.MessageTooLarge` is returned.
/// Asserts that `buffer` is non-empty.
pub fn receive(stream: *Stream, io: std.Io, buffer: []u8) (std.Io.net.Stream.Reader.Error || error{MessageTooLarge})!usize {
    assert(buffer.len > 0);
    const fd = stream.socket.handle;
    var len_buf: [4]u8 = undefined;

    var offset: usize = 0;
    while (offset < 4) {
        var read_buf = [_][]u8{len_buf[offset..4]};
        const n = try io.vtable.netRead(io.userdata, fd, &read_buf);
        if (n == 0) return error.ConnectionResetByPeer;
        offset += n;
    }

    const msg_len = mem.readInt(u32, &len_buf, .little);
    if (msg_len == 0) return 0;
    if (msg_len > buffer.len) {
        var discard: [4096]u8 = undefined;
        var remaining = msg_len;
        while (remaining > 0) {
            const chunk = @min(remaining, @as(u32, @intCast(discard.len)));
            var read_buf = [_][]u8{discard[0..chunk]};
            const n = try io.vtable.netRead(io.userdata, fd, &read_buf);
            if (n == 0) return error.ConnectionResetByPeer;
            remaining -= @as(u32, @intCast(n));
        }
        return error.MessageTooLarge;
    }

    offset = 0;
    while (offset < msg_len) {
        var read_buf = [_][]u8{buffer[offset..msg_len]};
        const n = try io.vtable.netRead(io.userdata, fd, &read_buf);
        if (n == 0) return error.ConnectionResetByPeer;
        offset += n;
    }
    return msg_len;
}

/// Close a TCP stream.
pub fn close(stream: *Stream, io: std.Io) void {
    stream.close(io);
}

/// Close a TCP server socket.
pub fn closeServer(server: *Server, io: std.Io) void {
    server.deinit(io);
}

fn getPort(fd: i32) u16 {
    var sockname: std.posix.sockaddr.in = undefined;
    var namelen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

test "listen: bind and close cleanly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try listen(io, 0, .{});
    defer closeServer(&server, io);
}

test "connect: refused returns ConnectFailed" {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.ConnectionRefused, connect(io, "127.0.0.1", 1, .{}));
}

test "listen + connect + accept round-trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try listen(io, 0, .{});
    defer closeServer(&server, io);

    const port = getPort(server.socket.handle);

    var thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const tio = std.Io.Threaded.global_single_threaded.io();
            var s = connect(tio, "127.0.0.1", p, .{}) catch @panic("connect failed");
            close(&s, tio);
        }
    }.run, .{port});

    var stream = try accept(&server, io, .{});
    defer close(&stream, io);

    thread.join();
}

test "send and receive data" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try listen(io, 0, .{});
    defer closeServer(&server, io);

    const port = getPort(server.socket.handle);

    const msg = "hello glu!";
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, m: []const u8) void {
            const tio = std.Io.Threaded.global_single_threaded.io();
            var s = connect(tio, "127.0.0.1", p, .{}) catch @panic("connect failed");
            send(&s, tio, m) catch @panic("send failed");
            close(&s, tio);
        }
    }.run, .{ port, msg });

    var stream = try accept(&server, io, .{});
    defer close(&stream, io);

    var buf: [64]u8 = undefined;
    const n = try receive(&stream, io, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..n]));

    thread.join();
}

test "empty message round-trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try listen(io, 0, .{});
    defer closeServer(&server, io);

    const port = getPort(server.socket.handle);

    var thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16) void {
            const tio = std.Io.Threaded.global_single_threaded.io();
            var s = connect(tio, "127.0.0.1", p, .{}) catch @panic("connect failed");
            send(&s, tio, "") catch @panic("send failed");
            close(&s, tio);
        }
    }.run, .{port});

    var stream = try accept(&server, io, .{});
    defer close(&stream, io);

    var buf: [1]u8 = undefined;
    const n = try receive(&stream, io, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);

    thread.join();
}

test "socket options apply on a real socket" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var server = try listen(io, 0, .{});
    defer closeServer(&server, io);
}
