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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *IO.Completion,
            result: IO.WriteError!usize,
        ) void,
        completion: *IO.Completion,
        buf: []const u8,
    ) !void {
        try io.write(Context, context, callback, completion, self.handle, buf, 0);
    }

    pub fn read(
        self: *Stream,
        io: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *IO.Completion,
            result: IO.ReadError!usize,
        ) void,
        completion: *IO.Completion,
        buf: []u8,
    ) !void {
        try io.read(Context, context, callback, completion, self.handle, buf, 0);
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
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.AcceptError!Stream,
    ) void,
    completion: *IO.Completion,
    server: *Server,
    comptime config: Config,
) !void {
    const wrapper = struct {
        fn call(ctx: Context, compl: *IO.Completion, res: IO.AcceptError!posix.socket_t) void {
            const stream_res: IO.AcceptError!Stream = blk: {
                if (res) |sock| {
                    apply_socket_opts(sock, config);
                    break :blk Stream{ .socket = sock, .handle = sock };
                } else |err| {
                    break :blk err;
                }
            };
            callback(ctx, compl, stream_res);
        }
    }.call;
    try io.accept(Context, context, wrapper, completion, server.socket);
}

pub fn connect(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.ConnectError!Stream,
    ) void,
    completion: *IO.Completion,
    host: []const u8,
    port: u16,
    comptime config: Config,
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

    const wrapper = struct {
        fn call(ctx: Context, compl: *IO.Completion, res: IO.ConnectError!void) void {
            const stream_res: IO.ConnectError!Stream = blk: {
                if (res) |_| {
                    const sock = compl.operation.connect.socket;
                    apply_socket_opts(sock, config);
                    break :blk Stream{ .socket = sock, .handle = sock };
                } else |err| {
                    break :blk err;
                }
            };
            callback(ctx, compl, stream_res);
        }
    }.call;

    try io.connect(Context, context, wrapper, completion, socket, addr);
}

pub fn send(io: *IO, stream: *Stream, data: []const u8) !void {
    assert(data.len <= std.math.maxInt(u32));
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    mem.writeInt(u32, &len_buf, len, .little);

    const SyncState = struct {
        done: bool = false,
        result: IO.WriteError!usize = undefined,
    };

    const cb = struct {
        fn call(ctx: *SyncState, compl: *IO.Completion, res: IO.WriteError!usize) void {
            _ = compl;
            ctx.result = res;
            ctx.done = true;
        }
    }.call;

    {
        var compl: IO.Completion = undefined;
        var state = SyncState{};
        try stream.write(io, *SyncState, &state, cb, &compl, &len_buf);
        while (!state.done) {
            try io.submit(1);
            try io.complete(1);
            try io.run_callback();
        }
        _ = try state.result;
    }

    {
        var compl: IO.Completion = undefined;
        var state = SyncState{};
        try stream.write(io, *SyncState, &state, cb, &compl, data);
        while (!state.done) {
            try io.submit(1);
            try io.complete(1);
            try io.run_callback();
        }
        _ = try state.result;
    }
}

pub fn receive(io: *IO, stream: *Stream, buffer: []u8) !usize {
    assert(buffer.len > 0);
    var len_buf: [4]u8 = undefined;

    const SyncState = struct {
        done: bool = false,
        result: IO.ReadError!usize = undefined,
    };

    const cb = struct {
        fn call(ctx: *SyncState, compl: *IO.Completion, res: IO.ReadError!usize) void {
            _ = compl;
            ctx.result = res;
            ctx.done = true;
        }
    }.call;

    var len_read: usize = 0;
    while (len_read < 4) {
        var compl: IO.Completion = undefined;
        var state = SyncState{};
        try stream.read(io, *SyncState, &state, cb, &compl, len_buf[len_read..]);
        while (!state.done) {
            try io.submit(1);
            try io.complete(1);
            try io.run_callback();
        }
        const n = try state.result;
        if (n == 0) return error.ConnectionResetByPeer;
        len_read += n;
    }

    const msg_len = mem.readInt(u32, &len_buf, .little);
    if (msg_len == 0) return 0;
    if (msg_len > buffer.len) {
        var discard: [4096]u8 = undefined;
        var remaining = msg_len;
        while (remaining > 0) {
            const chunk = @min(remaining, @as(u32, @intCast(discard.len)));
            var chunk_read: usize = 0;
            while (chunk_read < chunk) {
                var compl: IO.Completion = undefined;
                var state = SyncState{};
                try stream.read(io, *SyncState, &state, cb, &compl, discard[chunk_read..chunk]);
                while (!state.done) {
                    try io.submit(1);
                    try io.complete(1);
                    try io.run_callback();
                }
                const n = try state.result;
                if (n == 0) return error.ConnectionResetByPeer;
                chunk_read += n;
            }
            remaining -= @as(u32, @intCast(chunk_read));
        }
        return error.MessageTooLarge;
    }

    var data_read: usize = 0;
    while (data_read < msg_len) {
        var compl: IO.Completion = undefined;
        var state = SyncState{};
        try stream.read(io, *SyncState, &state, cb, &compl, buffer[data_read..msg_len]);
        while (!state.done) {
            try io.submit(1);
            try io.complete(1);
            try io.run_callback();
        }
        const n = try state.result;
        if (n == 0) return error.ConnectionResetByPeer;
        data_read += n;
    }
    return msg_len;
}

pub fn close(stream: *Stream) void {
    _ = c.close(stream.handle);
}

pub fn close_server(server: *Server) void {
    _ = c.close(server.handle);
}

fn getPort(fd: i32) u16 {
    var sockname: std.posix.sockaddr.in = undefined;
    var namelen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
        return mem.bigToNative(u16, sockname.port);
    return 0;
}

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

    const TestContext = struct {
        connect_done: bool = false,
        accept_done: bool = false,
        connect_result: ?IO.ConnectError!Stream = null,
        accept_result: ?IO.AcceptError!Stream = null,
    };

    var ctx = TestContext{};

    const connect_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.ConnectError!Stream) void {
            _ = compl;
            c_ctx.connect_result = res;
            c_ctx.connect_done = true;
        }
    }.call;

    const accept_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.AcceptError!Stream) void {
            _ = compl;
            c_ctx.accept_result = res;
            c_ctx.accept_done = true;
        }
    }.call;

    var compl_connect: IO.Completion = undefined;
    var compl_accept: IO.Completion = undefined;

    try connect(&io, *TestContext, &ctx, connect_cb, &compl_connect, "127.0.0.1", port, .{});
    try accept(&io, *TestContext, &ctx, accept_cb, &compl_accept, &server, .{});

    while (!ctx.connect_done or !ctx.accept_done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }

    var stream = try ctx.connect_result.?;
    defer close(&stream);

    var accepted = try ctx.accept_result.?;
    defer close(&accepted);
}

test "send and receive data" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try listen(&io, 0, .{});
    defer close_server(&server);

    const port = getPort(server.handle);

    const msg = "hello glu!";

    const TestContext = struct {
        connect_done: bool = false,
        accept_done: bool = false,
        connect_result: ?IO.ConnectError!Stream = null,
        accept_result: ?IO.AcceptError!Stream = null,
    };

    var ctx = TestContext{};

    const connect_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.ConnectError!Stream) void {
            _ = compl;
            c_ctx.connect_result = res;
            c_ctx.connect_done = true;
        }
    }.call;

    const accept_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.AcceptError!Stream) void {
            _ = compl;
            c_ctx.accept_result = res;
            c_ctx.accept_done = true;
        }
    }.call;

    var compl_connect: IO.Completion = undefined;
    var compl_accept: IO.Completion = undefined;

    try connect(&io, *TestContext, &ctx, connect_cb, &compl_connect, "127.0.0.1", port, .{});
    try accept(&io, *TestContext, &ctx, accept_cb, &compl_accept, &server, .{});

    while (!ctx.connect_done or !ctx.accept_done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }

    var stream = try ctx.connect_result.?;
    defer close(&stream);

    var accepted = try ctx.accept_result.?;
    defer close(&accepted);

    try send(&io, &stream, msg);

    var buf: [64]u8 = undefined;
    const n = try receive(&io, &accepted, &buf);
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..n]));
}

test "empty message round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try listen(&io, 0, .{});
    defer close_server(&server);

    const port = getPort(server.handle);

    const TestContext = struct {
        connect_done: bool = false,
        accept_done: bool = false,
        connect_result: ?IO.ConnectError!Stream = null,
        accept_result: ?IO.AcceptError!Stream = null,
    };

    var ctx = TestContext{};

    const connect_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.ConnectError!Stream) void {
            _ = compl;
            c_ctx.connect_result = res;
            c_ctx.connect_done = true;
        }
    }.call;

    const accept_cb = struct {
        fn call(c_ctx: *TestContext, compl: *IO.Completion, res: IO.AcceptError!Stream) void {
            _ = compl;
            c_ctx.accept_result = res;
            c_ctx.accept_done = true;
        }
    }.call;

    var compl_connect: IO.Completion = undefined;
    var compl_accept: IO.Completion = undefined;

    try connect(&io, *TestContext, &ctx, connect_cb, &compl_connect, "127.0.0.1", port, .{});
    try accept(&io, *TestContext, &ctx, accept_cb, &compl_accept, &server, .{});

    while (!ctx.connect_done or !ctx.accept_done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }

    var stream = try ctx.connect_result.?;
    defer close(&stream);

    var accepted = try ctx.accept_result.?;
    defer close(&accepted);

    try send(&io, &stream, "");

    var buf: [1]u8 = undefined;
    const n = try receive(&io, &accepted, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "socket options apply on a real socket" {
    var io = try IO.init(32, 0);
    defer io.deinit();
    var server = try listen(&io, 0, .{});
    defer close_server(&server);
}