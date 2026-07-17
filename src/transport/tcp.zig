const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const mem = std.mem;
const zio = @import("zio");

pub const Server = zio.net.Server;
pub const Stream = zio.net.Stream;

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

pub fn applySocketOpts(fd: i32, config: Config) void {
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

pub fn listen(port: u16, config: Config) !Server {
    var addr_buf: [32]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "0.0.0.0:{d}", .{port});
    const addr = try zio.net.IpAddress.parseIpAndPort(addr_str);

    const server = try addr.listen(.{
        .reuse_address = true,
    });

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(server.socket.handle, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }

    return server;
}

pub fn accept(server: *Server, config: Config) !Stream {
    const stream = try server.accept(.{ .timeout = .none });
    applySocketOpts(stream.socket.handle, config);
    return stream;
}

pub fn connect(host: []const u8, port: u16, config: Config) !Stream {
    assert(host.len > 0);
    assert(port > 0);
    var addr_buf: [256]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port });
    const addr = try zio.net.IpAddress.parseIpAndPort(addr_str);

    const stream = try addr.connect(.{
        .timeout = if (config.connect_timeout_ms > 0) zio.Timeout.fromMilliseconds(config.connect_timeout_ms) else .none,
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

pub fn send(stream: *Stream, data: []const u8) !void {
    assert(data.len <= std.math.maxInt(u32));
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    mem.writeInt(u32, &len_buf, len, .little);

    var buf: []const u8 = &len_buf;
    while (buf.len > 0) {
        const n = try stream.write(buf, .none);
        buf = buf[n..];
    }

    buf = data;
    while (buf.len > 0) {
        const n = try stream.write(buf, .none);
        buf = buf[n..];
    }
}

pub fn receive(stream: *Stream, buffer: []u8) !usize {
    assert(buffer.len > 0);
    var len_buf: [4]u8 = undefined;

    var buf: []u8 = &len_buf;
    while (buf.len > 0) {
        const n = try stream.read(buf, .none);
        if (n == 0) return error.ConnectionResetByPeer;
        buf = buf[n..];
    }

    const msg_len = mem.readInt(u32, &len_buf, .little);
    if (msg_len == 0) return 0;
    if (msg_len > buffer.len) {
        var discard: [4096]u8 = undefined;
        var remaining = msg_len;
        while (remaining > 0) {
            const chunk = @min(remaining, @as(u32, @intCast(discard.len)));
            const n = try stream.read(discard[0..chunk], .none);
            if (n == 0) return error.ConnectionResetByPeer;
            remaining -= @as(u32, @intCast(n));
        }
        return error.MessageTooLarge;
    }

    buf = buffer[0..msg_len];
    while (buf.len > 0) {
        const n = try stream.read(buf, .none);
        if (n == 0) return error.ConnectionResetByPeer;
        buf = buf[n..];
    }
    return msg_len;
}

pub fn close(stream: *Stream) void {
    stream.close();
}

pub fn closeServer(server: *Server) void {
    server.close();
}

fn getPort(fd: i32) u16 {
    var sockname: std.posix.sockaddr.in = undefined;
    var namelen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

test "listen: bind and close cleanly" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var server = try listen(0, .{});
    defer closeServer(&server);
}

test "listen + connect + accept round-trip" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var server = try listen(0, .{});
    defer closeServer(&server);

    const port = getPort(server.socket.handle);

    var handle = try rt.spawn(struct {
        fn run(p: u16) void {
            var s = connect("127.0.0.1", p, .{}) catch @panic("connect failed");
            close(&s);
        }
    }.run, .{port});

    var stream = try accept(&server, .{});
    defer close(&stream);

    handle.join();
}

test "send and receive data" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var server = try listen(0, .{});
    defer closeServer(&server);

    const port = getPort(server.socket.handle);

    const msg = "hello glu!";
    var handle = try rt.spawn(struct {
        fn run(p: u16, m: []const u8) void {
            var s = connect("127.0.0.1", p, .{}) catch @panic("connect failed");
            send(&s, m) catch @panic("send failed");
            close(&s);
        }
    }.run, .{ port, msg });

    var stream = try accept(&server, .{});
    defer close(&stream);

    var buf: [64]u8 = undefined;
    const n = try receive(&stream, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..n]));

    handle.join();
}

test "empty message round-trip" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var server = try listen(0, .{});
    defer closeServer(&server);

    const port = getPort(server.socket.handle);

    var handle = try rt.spawn(struct {
        fn run(p: u16) void {
            var s = connect("127.0.0.1", p, .{}) catch @panic("connect failed");
            send(&s, "") catch @panic("send failed");
            close(&s);
        }
    }.run, .{port});

    var stream = try accept(&server, .{});
    defer close(&stream);

    var buf: [1]u8 = undefined;
    const n = try receive(&stream, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);

    handle.join();
}

test "socket options apply on a real socket" {
    var rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    var server = try listen(0, .{});
    defer closeServer(&server);
}
