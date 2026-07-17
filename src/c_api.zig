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
        error.NetworkDown => GLU_ERR_SOCKET,
        error.OptionUnsupported => GLU_ERR_SETSOCKOPT,
        error.ProcessFdQuotaExceeded => GLU_ERR_SOCKET,
        error.SystemFdQuotaExceeded => GLU_ERR_SOCKET,
        error.ProtocolUnsupportedBySystem => GLU_ERR_SOCKET,
        error.ProtocolUnsupportedByAddressFamily => GLU_ERR_SOCKET,
        error.SocketModeUnsupported => GLU_ERR_SOCKET,
        error.WouldBlock => GLU_ERR_WOULD_BLOCK,
        error.SystemResources => GLU_ERR_SOCKET,
        error.SocketUnconnected => GLU_ERR_NOT_CONNECTED,
        error.MessageOversize => GLU_ERR_SEND,
        error.MessageTooLarge => GLU_ERR_MESSAGE_TOO_LARGE,
        error.PortUnreachable => GLU_ERR_SEND,
        error.Timeout => GLU_ERR_CONNECT,
        error.Canceled => GLU_ERR_INTERRUPTED,
        error.Unexpected => GLU_ERR_SOCKET,
        else => GLU_ERR_OUT_OF_MEM,
    };
}

fn allocWrap(comptime T: type, val: anytype, out: *?*T) c_int {
    const ptr = alloc.create(T) catch return GLU_ERR_OUT_OF_MEM;
    ptr.* = val catch |err| {
        alloc.destroy(ptr);
        return mapErr(err);
    };
    out.* = ptr;
    return GLU_OK;
}

fn destroy(ptr: anytype) void {
    ptr.deinit();
    alloc.destroy(ptr);
}

// ─────────────────────────────────────────────
//  Channel
// ─────────────────────────────────────────────

export fn glu_channel_open(name: [*:0]const u8, msg_size: u32, capacity: u32, tos: u32, out: *?*glu.Channel) c_int {
    return allocWrap(glu.Channel, glu.Channel.open(alloc, std.mem.sliceTo(name, 0), msg_size, capacity, @as(glu.ToS, @enumFromInt(tos))), out);
}

export fn glu_channel_close(chan: *glu.Channel) void {
    destroy(chan);
}

export fn glu_channel_write(chan: *glu.Channel, msg: *const anyopaque) void {
    glu.write(chan, msg);
}

export fn glu_channel_read(chan: *glu.Channel, sub_id: u32) *anyopaque {
    return glu.read(chan, sub_id);
}

export fn glu_channel_msg_size(chan: *const glu.Channel) u32 {
    return chan.header.msg_size;
}

export fn glu_channel_capacity(chan: *const glu.Channel) u32 {
    return chan.header.capacity;
}

export fn glu_channel_write_cursor(chan: *const glu.Channel) u32 {
    return chan.header.write;
}

// ─────────────────────────────────────────────
//  Publisher
// ─────────────────────────────────────────────

export fn glu_publisher_init(name: [*:0]const u8, msg_size: u32, capacity: u32, tos: u32, out: *?*glu.Publisher) c_int {
    return allocWrap(glu.Publisher, glu.Publisher.init(alloc, std.mem.sliceTo(name, 0), msg_size, capacity, @as(glu.ToS, @enumFromInt(tos))), out);
}

export fn glu_publisher_deinit(p: *glu.Publisher) void {
    destroy(p);
}

export fn glu_publisher_reserve(p: *glu.Publisher) *anyopaque {
    return p.reserve();
}

export fn glu_publisher_commit(p: *glu.Publisher) void {
    p.commit();
}

export fn glu_publisher_publish(p: *glu.Publisher, msg: *const anyopaque) void {
    p.publish(msg);
}

// ─────────────────────────────────────────────
//  Subscriber
// ─────────────────────────────────────────────

export fn glu_subscriber_init(name: [*:0]const u8, msg_size: u32, capacity: u32, out: *?*glu.Subscriber) c_int {
    return allocWrap(glu.Subscriber, glu.Subscriber.init(alloc, std.mem.sliceTo(name, 0), msg_size, capacity), out);
}

export fn glu_subscriber_deinit(sub: *glu.Subscriber) void {
    destroy(sub);
}

export fn glu_subscriber_receive(sub: *glu.Subscriber) ?*anyopaque {
    return sub.receive();
}

// ─────────────────────────────────────────────
//  TCP
// ─────────────────────────────────────────────

export fn glu_tcp_listen(port: u16, out: *?*glu.tcp.Server) c_int {
    const io = glu.io();
    return allocWrap(glu.tcp.Server, glu.tcp.listen(io, port, .{}), out);
}

export fn glu_tcp_listener_deinit(listener: *glu.tcp.Server) void {
    const io = glu.io();
    listener.deinit(io);
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
    const io = glu.io();
    return allocWrap(glu.tcp.Stream, glu.tcp.accept(listener, io, .{}), out);
}

export fn glu_tcp_connect(host: [*:0]const u8, port: u16, out: *?*glu.tcp.Stream) c_int {
    const io = glu.io();
    return allocWrap(glu.tcp.Stream, glu.tcp.connect(io, std.mem.sliceTo(host, 0), port, .{}), out);
}

export fn glu_tcp_send(conn: *glu.tcp.Stream, data: [*]const u8, len: u32) c_int {
    const io = glu.io();
    glu.tcp.send(conn, io, data[0..len]) catch |err| return mapErr(err);
    return GLU_OK;
}

export fn glu_tcp_receive(conn: *glu.tcp.Stream, buffer: [*]u8, len: u32) c_int {
    const io = glu.io();
    const bytes = glu.tcp.receive(conn, io, buffer[0..len]) catch |err| return mapErr(err);
    return @intCast(bytes);
}

export fn glu_tcp_connection_deinit(conn: *glu.tcp.Stream) void {
    const io = glu.io();
    conn.close(io);
    alloc.destroy(conn);
}

// ── TCP extended API ──

export fn glu_tcp_listen_with_config(port: u16, nodelay: bool, quickack: bool, keepalive: bool, keepalive_idle: u32, keepalive_interval: u32, keepalive_count: u32, recv_buf: i32, send_buf: i32, defer_accept: bool, connect_timeout_ms: u32, recv_timeout_ms: u32, send_timeout_ms: u32, out: *?*glu.tcp.Server) c_int {
    const io = glu.io();
    return allocWrap(glu.tcp.Server, glu.tcp.listen(io, port, .{
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

export fn glu_tcp_connect_with_config(host: [*:0]const u8, port: u16, connect_timeout_ms: u32, recv_timeout_ms: u32, send_timeout_ms: u32, out: *?*glu.tcp.Stream) c_int {
    const io = glu.io();
    return allocWrap(glu.tcp.Stream, glu.tcp.connect(io, std.mem.sliceTo(host, 0), port, .{
        .connect_timeout_ms = connect_timeout_ms,
        .recv_timeout_ms = if (recv_timeout_ms > 0) @as(?u32, recv_timeout_ms) else null,
        .send_timeout_ms = if (send_timeout_ms > 0) @as(?u32, send_timeout_ms) else null,
    }), out);
}

// ─────────────────────────────────────────────
//  UDP
// ─────────────────────────────────────────────

export fn glu_udp_bind(port: u16, out: *?*glu.udp.Socket) c_int {
    const io = glu.io();
    return allocWrap(glu.udp.Socket, glu.udp.bind(io, port, .{}), out);
}

export fn glu_udp_deinit(sock: *glu.udp.Socket) void {
    const io = glu.io();
    sock.close(io);
    alloc.destroy(sock);
}

export fn glu_udp_send_to(sock: *glu.udp.Socket, host: [*:0]const u8, port: u16, data: [*]const u8, len: u32) c_int {
    const io = glu.io();
    const bytes = glu.udp.sendTo(sock, io, std.mem.sliceTo(host, 0), port, data[0..len]) catch |err| return mapErr(err);
    return @intCast(bytes);
}

export fn glu_udp_socket_connect(sock: *glu.udp.Socket, host: [*:0]const u8, port: u16) c_int {
    glu.udp.connect(sock, std.mem.sliceTo(host, 0), port);
    return GLU_OK;
}

export fn glu_udp_send(sock: *glu.udp.Socket, data: [*]const u8, len: u32) c_int {
    const io = glu.io();
    const bytes = glu.udp.send(sock, io, data[0..len]) catch |err| return mapErr(err);
    return @intCast(bytes);
}

export fn glu_udp_receive(sock: *glu.udp.Socket, buffer: [*]u8, len: u32) c_int {
    const io = glu.io();
    const bytes = glu.udp.receive(sock, io, buffer[0..len]) catch |err| return mapErr(err);
    return @intCast(bytes);
}

export fn glu_udp_receive_from(sock: *glu.udp.Socket, buffer: [*]u8, len: u32, out_bytes: *u32, out_endpoint: *GluUdpEndpoint) c_int {
    const io = glu.io();
    const result = glu.udp.receiveFrom(sock, io, buffer[0..len]) catch |err| return mapErr(err);
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
    const io = glu.io();
    return allocWrap(glu.udp.Socket, glu.udp.bind(io, port, .{
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
