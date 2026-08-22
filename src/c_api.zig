const std = @import("std");
const c = std.c;
const posix = std.posix;

const std_heap = std.heap.c_allocator;

const IO = @import("io.zig").IO;
const shm = @import("channel/shm.zig");
const ToS = shm.ToS;
const Publisher = @import("api/publisher.zig").Publisher;
const Subscriber = @import("api/subscriber.zig").Subscriber;
const Peer = @import("api/peer.zig").Peer;
const Session = @import("channel/network.zig").Session;
const tcp = @import("transport/tcp.zig");
const udp = @import("transport/udp.zig");
const net = @import("transport/net.zig");

const log = std.debug;

/// Per-thread error string (consumers can read with `glu_last_error`).
/// Stored in a fixed buffer to avoid any allocation on the error path.
threadlocal var last_error: [256]u8 = .{0} ** 256;

fn setError(comptime prefix: []const u8, err: anyerror) void {
    const buf = std.fmt.bufPrint(&last_error, "{s}: {s}", .{ prefix, @errorName(err) }) catch {
        const err_str = "glu: error (truncated)";
        const n = @min(last_error.len - 1, err_str.len);
        @memcpy(last_error[0..n], err_str[0..n]);
        last_error[n] = 0;
        return;
    };
    last_error[buf.len] = 0;
}

fn setErrorMsg(msg: []const u8) void {
    const n = @min(last_error.len - 1, msg.len);
    @memcpy(last_error[0..n], msg[0..n]);
    last_error[n] = 0;
}

fn clearError() void {
    last_error[0] = 'O';
    last_error[1] = 'K';
    last_error[2] = 0;
}

/// Returns a static string describing the most recent error on this thread.
pub export fn glu_last_error() *const u8 {
    // The buffer is always null-terminated; return as C-compatible string pointer.
    return @as(*const u8, &last_error[0]);
}

// Types of Service
pub const GluTos = enum(c_int) {
    reliable = @intFromEnum(ToS.reliable),
    best_effort = @intFromEnum(ToS.best_effort),
};

// Handle types. For pub/sub these are the actual Zig structs.
// For TCP/UDP/peer we use box structs that carry the io_uring ring.
// All are exported as opaque pointers in the C header.
pub const GluPublisher = Publisher;
pub const GluSubscriber = Subscriber;
pub const GluPeer = Peer;

pub const TcpServerBox = struct { io: *IO, server: tcp.Server };
pub const TcpStreamBox = struct { io: *IO, stream: tcp.Stream };
pub const UdpSocketBox = struct { io: *IO, fd: c_int };

// Opaque handle types for C (all map to the Zig types above)
pub const GluTcpServer = TcpServerBox;
pub const GluTcpStream = TcpStreamBox;
pub const GluUdpSocket = UdpSocketBox;

// ---------------------------------------------------------------------------
// C-representable structs (mirrors of the transport Zig structs).
// ---------------------------------------------------------------------------

/// Sender address result returned by `glu_udp_receive_from`.
pub const GluEndpoint = extern struct {
    host: [46]u8,
    host_len: u32,
    port: u16,
    _pad: u16 = 0,
};

/// Mirrors `transport/tcp.zig::Config`; optionals use -1 as "unset".
pub const GluTcpConfig = extern struct {
    nodelay: bool = true,
    quickack: bool = true,
    keepalive: bool = false,
    keepalive_idle: u32 = 7200,
    keepalive_interval: u32 = 75,
    keepalive_count: u32 = 9,
    recv_buf: i32 = -1,
    send_buf: i32 = -1,
    defer_accept: bool = false,
    connect_timeout_ms: u32 = 5000,
    recv_timeout_ms: i32 = -1,
    send_timeout_ms: i32 = -1,
};

/// Mirrors `transport/udp.zig::SocketConfig`; optionals use -1 as "unset".
pub const GluUdpSocketConfig = extern struct {
    recv_buf: i32 = -1,
    send_buf: i32 = -1,
    broadcast: bool = false,
    reuse_addr: bool = false,
    recv_timeout_ms: i32 = -1,
    send_timeout_ms: i32 = -1,
};

fn tcpConfigOf(host: []const u8, c_cfg: *const GluTcpConfig) tcp.Config {
    return tcp.Config{
        .host = host,
        .nodelay = c_cfg.nodelay,
        .quickack = c_cfg.quickack,
        .keepalive = c_cfg.keepalive,
        .keepalive_idle = c_cfg.keepalive_idle,
        .keepalive_interval = c_cfg.keepalive_interval,
        .keepalive_count = c_cfg.keepalive_count,
        .recv_buf = if (c_cfg.recv_buf < 0) null else @intCast(c_cfg.recv_buf),
        .send_buf = if (c_cfg.send_buf < 0) null else @intCast(c_cfg.send_buf),
        .defer_accept = c_cfg.defer_accept,
        .connect_timeout_ms = c_cfg.connect_timeout_ms,
        .recv_timeout_ms = if (c_cfg.recv_timeout_ms < 0) null else @intCast(c_cfg.recv_timeout_ms),
        .send_timeout_ms = if (c_cfg.send_timeout_ms < 0) null else @intCast(c_cfg.send_timeout_ms),
    };
}

fn udpSocketConfigOf(c_cfg: *const GluUdpSocketConfig) udp.SocketConfig {
    return udp.SocketConfig{
        .recv_buf = if (c_cfg.recv_buf < 0) null else @intCast(c_cfg.recv_buf),
        .send_buf = if (c_cfg.send_buf < 0) null else @intCast(c_cfg.send_buf),
        .broadcast = c_cfg.broadcast,
        .reuse_addr = c_cfg.reuse_addr,
        .recv_timeout_ms = if (c_cfg.recv_timeout_ms < 0) null else @intCast(c_cfg.recv_timeout_ms),
        .send_timeout_ms = if (c_cfg.send_timeout_ms < 0) null else @intCast(c_cfg.send_timeout_ms),
    };
}

fn sockaddrIn4(host: []const u8, port: u16) !posix.sockaddr.in {
    const parsed = try std.Io.net.IpAddress.parseIp4(host, port);
    return .{
        .port = @byteSwap(parsed.ip4.port),
        .addr = @bitCast(parsed.ip4.bytes),
        .family = @intCast(c.AF.INET),
    };
}

fn applyUdpSocketOpts(fd: c_int, cfg: *const GluUdpSocketConfig) void {
    if (cfg.recv_buf >= 0) net.set_int(fd, c.SOL.SOCKET, @intCast(c.SO.RCVBUF), cfg.recv_buf);
    if (cfg.send_buf >= 0) net.set_int(fd, c.SOL.SOCKET, @intCast(c.SO.SNDBUF), cfg.send_buf);
    net.set_int(fd, c.SOL.SOCKET, @intCast(c.SO.BROADCAST), @intFromBool(cfg.broadcast));
    if (cfg.recv_timeout_ms >= 0) net.set_timeval(fd, c.SOL.SOCKET, @intCast(c.SO.RCVTIMEO), @intCast(cfg.recv_timeout_ms));
    if (cfg.send_timeout_ms >= 0) net.set_timeval(fd, c.SOL.SOCKET, @intCast(c.SO.SNDTIMEO), @intCast(cfg.send_timeout_ms));
}

fn newIo(alloc: std.mem.Allocator) !*IO {
    const io = try alloc.create(IO);
    errdefer alloc.destroy(io);
    io.* = try IO.init(32, 0);
    return io;
}

fn dropIo(alloc: std.mem.Allocator, io: *IO) void {
    io.deinit();
    alloc.destroy(io);
}

// ===========================================================================
// Publisher (src/api/publisher.zig)
// ===========================================================================

pub export fn glu_publisher_new(
    name: [*:0]const u8,
    msg_size: u32,
    capacity: u32,
    tos: GluTos,
) ?*GluPublisher {
    const p = Publisher.init(std.mem.span(name), msg_size, capacity, @enumFromInt(@intFromEnum(tos))) catch |e| {
        setError("glu_publisher_new", e);
        return null;
    };
    const boxed = std_heap.create(Publisher) catch {
        setErrorMsg("glu_publisher_new: out of memory");
        return null;
    };
    boxed.* = p;
    clearError();
    return @ptrCast(boxed);
}

pub export fn glu_publisher_free(p: ?*GluPublisher) void {
    if (p) |handle| {
        const pub_ = @as(*Publisher, handle);
        pub_.deinit();
        std_heap.destroy(pub_);
    }
    clearError();
}

pub export fn glu_publisher_reserve(p: ?*GluPublisher) ?*anyopaque {
    if (p == null) {
        setErrorMsg("glu_publisher_reserve: null publisher");
        return null;
    }
    const pub_ = @as(*Publisher, p.?);
    clearError();
    return pub_.reserve();
}

pub export fn glu_publisher_commit(p: ?*GluPublisher) void {
    if (p) |handle| {
        const pub_ = @as(*Publisher, handle);
        pub_.commit();
        clearError();
    }
}

pub export fn glu_publisher_publish(p: ?*GluPublisher, msg: ?*const anyopaque) c_int {
    if (p == null or msg == null) {
        setErrorMsg("glu_publisher_publish: null argument");
        return -1;
    }
    const pub_ = @as(*Publisher, p.?);
    pub_.publish(msg.?);
    clearError();
    return 0;
}

// ===========================================================================
// Subscriber (src/api/subscriber.zig)
// ===========================================================================

pub export fn glu_subscriber_new(
    name: [*:0]const u8,
    msg_size: u32,
    capacity: u32,
) ?*GluSubscriber {
    const s = Subscriber.init(std.mem.span(name), msg_size, capacity) catch |e| {
        setError("glu_subscriber_new", e);
        return null;
    };
    const boxed = std_heap.create(Subscriber) catch {
        setErrorMsg("glu_subscriber_new: out of memory");
        return null;
    };
    boxed.* = s;
    clearError();
    return @ptrCast(boxed);
}

pub export fn glu_subscriber_free(s: ?*GluSubscriber) void {
    if (s) |handle| {
        const sub = @as(*Subscriber, handle);
        sub.deinit();
        std_heap.destroy(sub);
    }
    clearError();
}

pub export fn glu_subscriber_peek(s: ?*GluSubscriber) ?*anyopaque {
    if (s == null) {
        setErrorMsg("glu_subscriber_peek: null subscriber");
        return null;
    }
    const sub = @as(*Subscriber, s.?);
    clearError();
    return sub.peek();
}

pub export fn glu_subscriber_ack(s: ?*GluSubscriber) void {
    if (s) |handle| {
        const sub = @as(*Subscriber, handle);
        sub.ack();
        clearError();
    }
}

// ===========================================================================
// Peer (src/api/peer.zig) — wraps the multicast network Session.
// ===========================================================================

pub export fn glu_peer_new(
    name: [*:0]const u8,
    msg_size: u32,
    capacity: u32,
    tos: GluTos,
) ?*GluPeer {
    const alloc = std_heap;
    const io = newIo(alloc) catch return null;
    errdefer dropIo(alloc, io);

    const sess = Session.open(io, std.mem.span(name), msg_size, capacity, @enumFromInt(@intFromEnum(tos))) catch |e| {
        setError("glu_peer_new", e);
        return null;
    };
    const sess_box = alloc.create(Session) catch {
        setErrorMsg("glu_peer_new: out of memory");
        return null;
    };
    errdefer sess_box.close() catch {};
    sess_box.* = sess;

    const peer = alloc.create(Peer) catch {
        setErrorMsg("glu_peer_new: out of memory");
        return null;
    };
    peer.* = Peer.init(sess_box);
    clearError();
    return @ptrCast(peer);
}

pub export fn glu_peer_free(p: ?*GluPeer) void {
    if (p) |handle| {
        const peer = @as(*Peer, handle);
        const alloc = std_heap;
        peer.network.close() catch {};
        dropIo(alloc, peer.network.io);
        alloc.destroy(peer.network);
        alloc.destroy(peer);
    }
    clearError();
}

pub export fn glu_peer_send(p: ?*GluPeer, data: ?*const u8, len: usize) c_int {
    if (p == null or data == null or len == 0) {
        setErrorMsg("glu_peer_send: invalid argument");
        return -1;
    }
    const peer = @as(*Peer, p.?);
    const sess = peer.network;
    const futures = sess.send(@as([*]const u8, @ptrCast(data.?))[0..len]) catch |e| {
        setError("glu_peer_send", e);
        return -1;
    };
    for (futures) |*f| {
        _ = sess.io.wait(f, usize) catch |e| {
            setError("glu_peer_send", e);
            return -1;
        };
    }
    clearError();
    return 0;
}

pub export fn glu_peer_recv(p: ?*GluPeer, out: ?*u8, cap: usize, out_len: ?*usize) c_int {
    if (p == null or out == null or out_len == null or cap == 0) {
        setErrorMsg("glu_peer_recv: invalid argument");
        return -1;
    }
    const peer = @as(*Peer, p.?);
    const sess = peer.network;
    const futures = sess.recv() catch |e| {
        setError("glu_peer_recv", e);
        return -1;
    };
    const n = sess.gather(futures, @as([*]u8, @ptrCast(out.?))[0..cap]) catch |e| {
        setError("glu_peer_recv", e);
        return -1;
    };
    out_len.?.* = n;
    clearError();
    return 0;
}

// ===========================================================================
// TCP transport (src/transport/tcp.zig)
// ===========================================================================

pub export fn glu_tcp_listen(
    port: u16,
    host: [*:0]const u8,
    cfg: ?*const GluTcpConfig,
) ?*GluTcpServer {
    const alloc = std_heap;
    const tc = if (cfg) |cfg_| tcpConfigOf(std.mem.span(host), cfg_) else tcp.Config{ .host = std.mem.span(host) };
    const io = newIo(alloc) catch return null;
    errdefer dropIo(alloc, io);

    const server = tcp.listen(io, port, tc) catch |e| {
        setError("glu_tcp_listen", e);
        return null;
    };
    const wrap = alloc.create(TcpServerBox) catch {
        tcp.close_server(@constCast(&server));
        setErrorMsg("glu_tcp_listen: out of memory");
        return null;
    };
    wrap.* = .{ .io = io, .server = server };
    clearError();
    return @ptrCast(wrap);
}

pub export fn glu_tcp_listen_default(port: u16) ?*GluTcpServer {
    return glu_tcp_listen(port, "0.0.0.0", null);
}

pub export fn glu_tcp_accept(s: ?*GluTcpServer, out_stream: ?**GluTcpStream) c_int {
    if (s == null or out_stream == null) {
        setErrorMsg("glu_tcp_accept: null argument");
        return -1;
    }
    const wrap = @as(*TcpServerBox, s.?);
    const alloc = std_heap;

    var fut: IO.Future = undefined;
    tcp.accept(wrap.io, &fut, &wrap.server) catch |e| {
        setError("glu_tcp_accept", e);
        return -1;
    };
    const fd = wrap.io.wait(&fut, posix.socket_t) catch |e| {
        setError("glu_tcp_accept", e);
        return -1;
    };
    tcp.apply_socket_opts(@intCast(fd), .{});

    const sio = newIo(alloc) catch return -1;
    const sw = alloc.create(TcpStreamBox) catch |e| {
        dropIo(alloc, sio);
        _ = c.close(@intCast(fd));
        setError("glu_tcp_accept", e);
        return -1;
    };
    sw.* = .{ .io = sio, .stream = tcp.Stream{ .socket = @intCast(fd), .handle = @intCast(fd) } };
    const out = out_stream.?;
    out.* = @as(*GluTcpStream, sw);
    clearError();
    return 0;
}

pub export fn glu_tcp_connect(host: [*:0]const u8, port: u16) ?*GluTcpStream {
    const alloc = std_heap;
    const io = newIo(alloc) catch return null;
    errdefer dropIo(alloc, io);

    var fut: IO.Future = undefined;
    tcp.connect(io, &fut, std.mem.span(host), port) catch |e| {
        setError("glu_tcp_connect", e);
        return null;
    };
    _ = io.wait(&fut, void) catch |e| {
        setError("glu_tcp_connect", e);
        return null;
    };
    const fd: c_int = @intCast(fut.operation.connect.socket);
    tcp.apply_socket_opts(fd, .{});

    const sw = alloc.create(TcpStreamBox) catch {
        _ = c.close(fd);
        setErrorMsg("glu_tcp_connect: out of memory");
        return null;
    };
    sw.* = .{ .io = io, .stream = tcp.Stream{ .socket = fd, .handle = fd } };
    clearError();
    return @ptrCast(sw);
}

pub export fn glu_tcp_send(s: ?*GluTcpStream, data: ?*const u8, len: usize, sent: ?*usize) c_int {
    if (s == null or data == null or len == 0 or sent == null) {
        setErrorMsg("glu_tcp_send: invalid argument");
        return -1;
    }
    const wrap = @as(*TcpStreamBox, s.?);
    const out = &wrap.stream;
    var fut: IO.Future = undefined;
    tcp.send(wrap.io, &fut, out, @as([*]const u8, @ptrCast(data.?))[0..len]) catch |e| {
        setError("glu_tcp_send", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_tcp_send", e);
        return -1;
    };
    sent.?.* = n;
    clearError();
    return 0;
}

pub export fn glu_tcp_receive(s: ?*GluTcpStream, buf: ?*u8, cap: usize, got: ?*usize) c_int {
    if (s == null or buf == null or cap == 0 or got == null) {
        setErrorMsg("glu_tcp_receive: invalid argument");
        return -1;
    }
    const wrap = @as(*TcpStreamBox, s.?);
    const out = &wrap.stream;
    var fut: IO.Future = undefined;
    tcp.receive(wrap.io, &fut, out, @as([*]u8, @ptrCast(buf.?))[0..cap]) catch |e| {
        setError("glu_tcp_receive", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_tcp_receive", e);
        return -1;
    };
    got.?.* = n;
    clearError();
    return 0;
}

pub export fn glu_tcp_apply_socket_opts(fd: c_int, cfg: ?*const GluTcpConfig) c_int {
    const defaults: GluTcpConfig = .{};
    const c_cfg = if (cfg) |cfg_| cfg_.* else defaults;
    tcp.apply_socket_opts(fd, tcpConfigOf("", &c_cfg));
    clearError();
    return 0;
}

pub export fn glu_tcp_close_stream(s: ?*GluTcpStream) void {
    if (s) |handle| {
        const wrap = @as(*TcpStreamBox, handle);
        tcp.close(&wrap.stream);
        dropIo(std_heap, wrap.io);
        std_heap.destroy(wrap);
    }
    clearError();
}

pub export fn glu_tcp_close_server(s: ?*GluTcpServer) void {
    if (s) |handle| {
        const wrap = @as(*TcpServerBox, handle);
        tcp.close_server(&wrap.server);
        dropIo(std_heap, wrap.io);
        std_heap.destroy(wrap);
    }
    clearError();
}

// ===========================================================================
// UDP transport (src/transport/udp.zig)
// ===========================================================================

pub export fn glu_udp_bind(
    port: u16,
    host: [*:0]const u8,
    cfg: ?*const GluUdpSocketConfig,
) ?*GluUdpSocket {
    const alloc = std_heap;
    const sc = if (cfg) |cfg_| udpSocketConfigOf(cfg_) else udp.SocketConfig{};
    const io = newIo(alloc) catch return null;

    const socket = io.socket(@intCast(c.AF.INET), @intCast(c.SOCK.DGRAM), 0) catch |e| {
        setError("glu_udp_bind", e);
        dropIo(alloc, io);
        return null;
    };
    if (sc.reuse_addr) net.set_int(socket, c.SOL.SOCKET, @intCast(c.SO.REUSEADDR), 1);

    const addr = sockaddrIn4(std.mem.span(host), port) catch |e| {
        _ = c.close(socket);
        dropIo(alloc, io);
        setError("glu_udp_bind", e);
        return null;
    };
    io.bind(socket, addr) catch |e| {
        _ = c.close(socket);
        dropIo(alloc, io);
        setError("glu_udp_bind", e);
        return null;
    };
    applyUdpSocketOpts(socket, &(if (cfg) |cfg_| cfg_.* else GluUdpSocketConfig{}));

    const wrap = alloc.create(UdpSocketBox) catch {
        _ = c.close(socket);
        dropIo(alloc, io);
        setErrorMsg("glu_udp_bind: out of memory");
        return null;
    };
    wrap.* = .{ .io = io, .fd = socket };
    clearError();
    return @ptrCast(wrap);
}

pub export fn glu_udp_bind_default(port: u16) ?*GluUdpSocket {
    return glu_udp_bind(port, "0.0.0.0", null);
}

pub export fn glu_udp_send_to(
    s: ?*GluUdpSocket,
    host: [*:0]const u8,
    port: u16,
    data: ?*const u8,
    len: usize,
    sent: ?*usize,
) c_int {
    if (s == null or data == null or len == 0 or sent == null) {
        setErrorMsg("glu_udp_send_to: invalid argument");
        return -1;
    }
    const wrap = @as(*UdpSocketBox, s.?);
    var fut: IO.Future = undefined;
    udp.send_to(wrap.io, &fut, @intCast(wrap.fd), std.mem.span(host), port, @as([*]const u8, @ptrCast(data.?))[0..len]) catch |e| {
        setError("glu_udp_send_to", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_udp_send_to", e);
        return -1;
    };
    sent.?.* = n;
    clearError();
    return 0;
}

pub export fn glu_udp_receive_from(
    s: ?*GluUdpSocket,
    buf: ?*u8,
    cap: usize,
    got: ?*usize,
    addr: ?*GluEndpoint,
) c_int {
    if (s == null or buf == null or cap == 0 or got == null) {
        setErrorMsg("glu_udp_receive_from: invalid argument");
        return -1;
    }
    const wrap = @as(*UdpSocketBox, s.?);
    var fut: IO.Future = undefined;
    udp.receive_from(wrap.io, &fut, @intCast(wrap.fd), @as([*]u8, @ptrCast(buf.?))[0..cap]) catch |e| {
        setError("glu_udp_receive_from", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_udp_receive_from", e);
        return -1;
    };
    got.?.* = n;
    if (addr) |ep| {
        const r = net.address_to_endpoint(fut.operation.recv_from.address);
        ep.host_len = @intCast(r.host_len);
        @memcpy(ep.host[0..r.host_len], r.host[0..r.host_len]);
        ep.port = r.port;
    }
    clearError();
    return 0;
}

pub export fn glu_udp_connect(s: ?*GluUdpSocket, host: [*:0]const u8, port: u16) c_int {
    if (s == null) {
        setErrorMsg("glu_udp_connect: null socket");
        return -1;
    }
    const wrap = @as(*UdpSocketBox, s.?);
    var fut: IO.Future = undefined;
    udp.connect(wrap.io, &fut, @intCast(wrap.fd), std.mem.span(host), port) catch |e| {
        setError("glu_udp_connect", e);
        return -1;
    };
    _ = wrap.io.wait(&fut, void) catch |e| {
        setError("glu_udp_connect", e);
        return -1;
    };
    clearError();
    return 0;
}

pub export fn glu_udp_send(
    s: ?*GluUdpSocket,
    data: ?*const u8,
    len: usize,
    sent: ?*usize,
) c_int {
    if (s == null or data == null or len == 0 or sent == null) {
        setErrorMsg("glu_udp_send: invalid argument");
        return -1;
    }
    const wrap = @as(*UdpSocketBox, s.?);
    var fut: IO.Future = undefined;
    udp.send(wrap.io, &fut, @intCast(wrap.fd), @as([*]const u8, @ptrCast(data.?))[0..len]) catch |e| {
        setError("glu_udp_send", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_udp_send", e);
        return -1;
    };
    sent.?.* = n;
    clearError();
    return 0;
}

pub export fn glu_udp_receive(
    s: ?*GluUdpSocket,
    buf: ?*u8,
    cap: usize,
    got: ?*usize,
) c_int {
    if (s == null or buf == null or cap == 0 or got == null) {
        setErrorMsg("glu_udp_receive: invalid argument");
        return -1;
    }
    const wrap = @as(*UdpSocketBox, s.?);
    var fut: IO.Future = undefined;
    udp.receive(wrap.io, &fut, @intCast(wrap.fd), @as([*]u8, @ptrCast(buf.?))[0..cap]) catch |e| {
        setError("glu_udp_receive", e);
        return -1;
    };
    const n = wrap.io.wait(&fut, usize) catch |e| {
        setError("glu_udp_receive", e);
        return -1;
    };
    got.?.* = n;
    clearError();
    return 0;
}

pub export fn glu_udp_join_multicast(s: ?*GluUdpSocket, group: [*:0]const u8, port: u16, interface: [*:0]const u8) void {
    if (s) |handle| {
        const wrap = @as(*UdpSocketBox, handle);
        udp.join_multicast(@intCast(wrap.fd), std.mem.span(group), port, std.mem.span(interface));
    }
}

pub export fn glu_udp_close(s: ?*GluUdpSocket) void {
    if (s) |handle| {
        const wrap = @as(*UdpSocketBox, handle);
        udp.close(&wrap.fd);
        dropIo(std_heap, wrap.io);
        std_heap.destroy(wrap);
    }
    clearError();
}

// ===========================================================================
// Shared-memory helper (src/channel/shm.zig::force_unlink).
// ===========================================================================

pub export fn glu_shm_unlink(name: [*:0]const u8) void {
    shm.force_unlink(std.mem.span(name));
    clearError();
}

comptime {
    // Keep the full library compiled into the shared object.
    _ = @import("api/publisher.zig");
    _ = @import("api/subscriber.zig");
    _ = @import("api/peer.zig");
    _ = @import("channel/shm.zig");
    _ = @import("channel/network.zig");
    _ = @import("registry.zig");
}
