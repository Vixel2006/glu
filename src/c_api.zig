const std = @import("std");
const glu = @import("glu");

pub const GLU_OK = 0;
pub const GLU_ERR_OUT_OF_MEM = -1;
pub const GLU_ERR_SHM_OPEN = -2;
pub const GLU_ERR_MMAP = -3;
pub const GLU_ERR_SOCKET = -4;
pub const GLU_ERR_BIND = -5;
pub const GLU_ERR_LISTEN = -6;
pub const GLU_ERR_ACCEPT = -7;
pub const GLU_ERR_CONNECT = -8;
pub const GLU_ERR_SEND = -9;
pub const GLU_ERR_RECV = -10;
pub const GLU_ERR_ADDR_RESOLVE = -11;
pub const GLU_ERR_WOULD_BLOCK = -12;
pub const GLU_ERR_CONN_RESET = -13;
pub const GLU_ERR_INTERRUPTED = -14;
pub const GLU_ERR_SETSOCKOPT = -15;
pub const GLU_ERR_MESSAGE_TOO_LARGE = -16;
pub const GLU_ERR_NO_SPACE = -17;
pub const GLU_ERR_MULTICAST = -18;
pub const GLU_ERR_NOT_CONNECTED = -19;

comptime {
    std.debug.assert(GLU_ERR_NOT_CONNECTED == -19);
}

const alloc = std.heap.c_allocator;

pub const GluUdpEndpoint = extern struct {
    host: [46]u8,
    host_len: usize,
    port: u16,
};

fn mapErr(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => GLU_ERR_OUT_OF_MEM,
        error.ShmOpenFailed => GLU_ERR_SHM_OPEN,
        error.MmapFailed => GLU_ERR_MMAP,
        error.AddressInUse => GLU_ERR_BIND,
        error.AddressUnavailable => GLU_ERR_BIND,
        error.AccessDenied => GLU_ERR_SOCKET,
        error.AddressFamilyUnsupported => GLU_ERR_SOCKET,
        error.ConnectionPending => GLU_ERR_CONNECT,
        error.ConnectionRefused => GLU_ERR_CONNECT,
        error.ConnectionResetByPeer => GLU_ERR_CONN_RESET,
        error.HostUnreachable => GLU_ERR_CONNECT,
        error.NetworkUnreachable => GLU_ERR_SEND,
        error.AlreadyConnected => GLU_ERR_CONNECT,
        error.AlreadyInProgress => GLU_ERR_CONNECT,
        error.SocketUnconnected => GLU_ERR_NOT_CONNECTED,
        error.DestinationAddressRequired => GLU_ERR_NOT_CONNECTED,
        error.MessageTooLarge => GLU_ERR_MESSAGE_TOO_LARGE,
        error.BadAddress => GLU_ERR_SOCKET,
        error.AddressNotAvailable => GLU_ERR_BIND,
        error.ProcessFdQuotaExceeded => GLU_ERR_NO_SPACE,
        error.SystemFdQuotaExceeded => GLU_ERR_NO_SPACE,
        error.SystemResources => GLU_ERR_NO_SPACE,
        error.OperationNotSupported => GLU_ERR_SOCKET,
        error.BadFileDescriptor => GLU_ERR_SOCKET,
        error.Interrupted => GLU_ERR_INTERRUPTED,
        error.WouldBlock => GLU_ERR_WOULD_BLOCK,
        error.ConnectionAborted => GLU_ERR_CONN_RESET,
        error.ConnectionTimedOut => GLU_ERR_CONNECT,
        error.PermissionDenied => GLU_ERR_SOCKET,
        error.BrokenPipe => GLU_ERR_SEND,
        error.Unexpected => GLU_ERR_SOCKET,
        else => |e| {
            std.debug.print("[glu] unhandled error: {}\n", .{e});
            return GLU_ERR_SOCKET;
        },
    };
}

fn allocWrap(comptime T: type, result: !T, out: *?*T) c_int {
    const val = result catch |err| return mapErr(err);
    const ptr = alloc.create(T) catch return GLU_ERR_OUT_OF_MEM;
    ptr.* = val;
    out.* = ptr;
    return GLU_OK;
}

// ─────────────────────────────────────────────
//  Shared-memory Channel
// ─────────────────────────────────────────────

export fn glu_channel_create(path: [*:0]const u8, size: u32, tos: u8) c_int {
    return glu.Channel.create(std.mem.sliceTo(path, 0), size, @enumFromInt(tos)) catch |err| mapErr(err);
}

export fn glu_channel_open(path: [*:0]const u8, out: *?*glu.Channel) c_int {
    return allocWrap(glu.Channel, glu.Channel.open(std.mem.sliceTo(path, 0)), out);
}

export fn glu_channel_close(ch: *glu.Channel) void {
    ch.close();
}

export fn glu_channel_reserve(ch: *glu.Channel, out: *?*anyopaque) c_int {
    const ptr = ch.reserve() orelse return GLU_ERR_NO_SPACE;
    out.* = @ptrCast(ptr);
    return GLU_OK;
}

export fn glu_channel_commit(ch: *glu.Channel) void {
    ch.commit();
}

export fn glu_channel_write(ch: *glu.Channel, data: *const anyopaque, len: u32) c_int {
    ch.write(@ptrCast(@alignCast(data))[0..len]) catch |err| return mapErr(err);
    return GLU_OK;
}

export fn glu_channel_read(ch: *glu.Channel, out: *?*const anyopaque) c_int {
    const ptr = ch.read() orelse return GLU_ERR_NO_SPACE;
    out.* = @ptrCast(ptr);
    return GLU_OK;
}

export fn glu_channel_release(ch: *glu.Channel) void {
    ch.release();
}

// ─────────────────────────────────────────────
//  Publisher
// ─────────────────────────────────────────────

export fn glu_publisher_init(allocator: std.mem.Allocator, topic: [*:0]const u8, msg_size: u32, capacity: u32, tos: u8, out: *?*glu.Publisher) c_int {
    return allocWrap(glu.Publisher, glu.Publisher.init(allocator, std.mem.sliceTo(topic, 0), msg_size, capacity, @enumFromInt(tos)), out);
}

export fn glu_publisher_deinit(pub: *glu.Publisher) void {
    pub.deinit();
}

export fn glu_publisher_reserve(pub: *glu.Publisher, out: *?*anyopaque) c_int {
    const ptr = pub.reserve() orelse return GLU_ERR_NO_SPACE;
    out.* = @ptrCast(ptr);
    return GLU_OK;
}

export fn glu_publisher_commit(pub: *glu.Publisher) void {
    pub.commit();
}

export fn glu_publisher_publish(pub: *glu.Publisher, data: *const anyopaque) void {
    pub.publish(@ptrCast(@alignCast(data)));
}

// ─────────────────────────────────────────────
//  Subscriber
// ─────────────────────────────────────────────

export fn glu_subscriber_init(allocator: std.mem.Allocator, topic: [*:0]const u8, msg_size: u32, capacity: u32, out: *?*glu.Subscriber) c_int {
    return allocWrap(glu.Subscriber, glu.Subscriber.init(allocator, std.mem.sliceTo(topic, 0), msg_size, capacity), out);
}

export fn glu_subscriber_deinit(sub: *glu.Subscriber) void {
    sub.deinit();
}

export fn glu_subscriber_receive(sub: *glu.Subscriber, out: *?*const anyopaque) c_int {
    const ptr = sub.receive() orelse return GLU_ERR_NO_SPACE;
    out.* = @ptrCast(ptr);
    return GLU_OK;
}

// ─────────────────────────────────────────────
//  Registry
// ─────────────────────────────────────────────

export fn glu_registry_register(name: [*:0]const u8) c_int {
    glu.registry.register(std.mem.sliceTo(name, 0)) catch |err| return mapErr(err);
    return GLU_OK;
}

export fn glu_registry_unregister(name: [*:0]const u8) void {
    glu.registry.unregister(std.mem.sliceTo(name, 0));
}

export fn glu_registry_list_alive(allocator: std.mem.Allocator, out: *?*glu.registry.Entry, out_len: *usize) c_int {
    const entries = glu.registry.listAlive(allocator) catch |err| return mapErr(err);
    const slice = alloc.alloc(glu.registry.Entry, entries.len) catch return GLU_ERR_OUT_OF_MEM;
    @memcpy(slice, entries);
    allocator.free(entries);
    out.* = slice.ptr;
    out_len.* = slice.len;
    return GLU_OK;
}

export fn glu_registry_entry_deinit(allocator: std.mem.Allocator, entry: *glu.registry.Entry) void {
    allocator.free(entry.name);
}

// ─────────────────────────────────────────────
//  TCP
// ─────────────────────────────────────────────

export fn glu_tcp_listen(port: u16, out: *?*glu.tcp.Server) c_int {
    return allocWrap(glu.tcp.Server, glu.tcp.listen(port, .{}), out);
}

export fn glu_tcp_listener_deinit(listener: *glu.tcp.Server) void {
    glu.tcp.closeServer(listener);
    alloc.destroy(listener);
}

export fn glu_tcp_listener_port(listener: *const glu.tcp.Server) u16 {
    var sockname: std.posix.sockaddr.in = undefined;
    var namelen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.c.getsockname(listener.socket.handle, @ptrCast(&sockname), &namelen) == 0)
        return std.mem.bigToNative(u16, sockname.port);
    return 0;
}

export fn glu_tcp_accept(listener: *glu.tcp.Server, out: *?*glu.tcp.Stream) c_int {
    return allocWrap(glu.tcp.Stream, glu.tcp.accept(listener, .{}), out);
}

export fn glu_tcp_connect(host: [*:0]const u8, port: u16, out: *?*glu.tcp.Stream) c_int {
    return allocWrap(glu.tcp.Stream, glu.tcp.connect(std.mem.sliceTo(host, 0), port, .{}), out);
}

export fn glu_tcp_send(stream: *glu.tcp.Stream, data: [*]const u8, len: u32) c_int {
    glu.tcp.send(stream, data[0..len]) catch |err| return mapErr(err);
    return GLU_OK;
}

export fn glu_tcp_receive(stream: *glu.tcp.Stream, buffer: [*]u8, len: u32, out_bytes: *u32) c_int {
    const bytes = glu.tcp.receive(stream, buffer[0..len]) catch |err| return mapErr(err);
    out_bytes.* = @intCast(bytes);
    return GLU_OK;
}

export fn glu_tcp_close(stream: *glu.tcp.Stream) void {
    glu.tcp.close(stream);
    alloc.destroy(stream);
}

export fn glu_tcp_listen_with_config(port: u16, nodelay: bool, quickack: bool, keepalive: bool, keepalive_idle: u32, keepalive_interval: u32, keepalive_count: u32, recv_buf: i32, send_buf: i32, defer_accept: bool, connect_timeout_ms: u32, recv_timeout_ms: u32, send_timeout_ms: u32, out: *?*glu.tcp.Server) c_int {
    return allocWrap(glu.tcp.Server, glu.tcp.listen(port, .{
        .nodelay = nodelay,
        .quickack = quickack,
        .keepalive = keepalive,
        .keepalive_idle = keepalive_idle,
        .keepalive_interval = keepalive_interval,
        .keepalive_count = keepalive_count,
        .recv_buf = if (recv_buf >= 0) @as(?i32, recv_buf) else null,
        .send_buf = if (send_buf >= 0) @as(?i32, send_buf) else null,
        .defer_accept = defer_accept,
        .connect_timeout_ms = connect_timeout_ms,
        .recv_timeout_ms = if (recv_timeout_ms > 0) @as(?u32, recv_timeout_ms) else null,
        .send_timeout_ms = if (send_timeout_ms > 0) @as(?u32, send_timeout_ms) else null,
    }), out);
}

export fn glu_tcp_connect_with_timeout(host: [*:0]const u8, port: u16, connect_timeout_ms: u32, out: *?*glu.tcp.Stream) c_int {
    return allocWrap(glu.tcp.Stream, glu.tcp.connect(std.mem.sliceTo(host, 0), port, .{
        .connect_timeout_ms = connect_timeout_ms,
    }), out);
}

// ─────────────────────────────────────────────
//  UDP
// ─────────────────────────────────────────────

export fn glu_udp_bind(port: u16, out: *?*glu.udp.Socket) c_int {
    return allocWrap(glu.udp.Socket, glu.udp.bind(port, .{}), out);
}

export fn glu_udp_close(sock: *glu.udp.Socket) void {
    glu.udp.close(sock);
    alloc.destroy(sock);
}

export fn glu_udp_send_to(sock: *glu.udp.Socket, host: [*:0]const u8, port: u16, data: [*]const u8, len: u32) c_int {
    const n = glu.udp.sendTo(sock, std.mem.sliceTo(host, 0), port, data[0..len]) catch |err| return mapErr(err);
    _ = n;
    return GLU_OK;
}

export fn glu_udp_connect(sock: *glu.udp.Socket, host: [*:0]const u8, port: u16) void {
    glu.udp.connect(sock, std.mem.sliceTo(host, 0), port);
}

export fn glu_udp_send(sock: *glu.udp.Socket, data: [*]const u8, len: u32) c_int {
    const n = glu.udp.send(sock, data[0..len]) catch |err| return mapErr(err);
    _ = n;
    return GLU_OK;
}

export fn glu_udp_receive(sock: *glu.udp.Socket, buffer: [*]u8, len: u32) c_int {
    const bytes = glu.udp.receive(sock, buffer[0..len]) catch |err| return mapErr(err);
    return @intCast(bytes);
}

export fn glu_udp_receive_from(sock: *glu.udp.Socket, buffer: [*]u8, len: u32, out_bytes: *u32, out_endpoint: *GluUdpEndpoint) c_int {
    const result = glu.udp.receiveFrom(sock, buffer[0..len]) catch |err| return mapErr(err);
    out_bytes.* = @intCast(result.data.len);
    out_endpoint.* = GluUdpEndpoint{
        .host = result.sender.host,
        .host_len = result.sender.host_len,
        .port = result.sender.port,
    };
    return GLU_OK;
}

// ── UDP extended API ──

export fn glu_udp_bind_with_config(port: u16, recv_buf: i32, send_buf: i32, broadcast: bool, recv_timeout_ms: u32, send_timeout_ms: u32, out: *?*glu.udp.Socket) c_int {
    return allocWrap(glu.udp.Socket, glu.udp.bind(port, .{
        .recv_buf = if (recv_buf >= 0) @as(?i32, recv_buf) else null,
        .send_buf = if (send_buf >= 0) @as(?i32, send_buf) else null,
        .broadcast = broadcast,
        .recv_timeout_ms = if (recv_timeout_ms > 0) @as(?u32, recv_timeout_ms) else null,
        .send_timeout_ms = if (send_timeout_ms > 0) @as(?u32, send_timeout_ms) else null,
    }), out);
}

export fn glu_udp_join_multicast(sock: *glu.udp.Socket, group: [*:0]const u8) c_int {
    glu.udp.joinMulticast(sock, std.mem.sliceTo(group, 0));
    return GLU_OK;
}

export fn glu_udp_leave_multicast(sock: *glu.udp.Socket, group: [*:0]const u8) c_int {
    glu.udp.leaveMulticast(sock, std.mem.sliceTo(group, 0));
    return GLU_OK;
}
