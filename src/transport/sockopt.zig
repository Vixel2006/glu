const std = @import("std");
const c = std.c;

pub const SockErr = error{
    SetSockOptFailed,
};

const IPPROTO_TCP: u32 = 6;
const TCP_NODELAY: u32 = 1;
const TCP_QUICKACK: u32 = 12;
const TCP_KEEPIDLE: u32 = 4;
const TCP_KEEPINTVL: u32 = 5;
const TCP_KEEPCNT: u32 = 6;
const TCP_DEFER_ACCEPT: u32 = 9;

pub const TcpOptions = struct {
    nodelay: bool = true,
    quickack: bool = true,
    keepalive: bool = false,
    keepalive_idle: u32 = 7200,
    keepalive_interval: u32 = 75,
    keepalive_count: u32 = 9,
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    defer_accept: bool = false,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

pub const UdpOptions = struct {
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    broadcast: bool = false,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

fn setInt(fd: i32, level: c_int, opt: u32, val: c_int) SockErr!void {
    if (c.setsockopt(fd, level, opt, &val, @sizeOf(c_int)) == -1)
        return SockErr.SetSockOptFailed;
}

fn setTimeval(fd: i32, level: c_int, opt: u32, ms: u32) SockErr!void {
    const tv = std.c.timeval{
        .sec = @as(c_int, @intCast(ms / 1000)),
        .usec = @as(c_int, @intCast((ms % 1000) * 1000)),
    };
    if (c.setsockopt(fd, level, opt, &tv, @sizeOf(std.c.timeval)) == -1)
        return SockErr.SetSockOptFailed;
}

pub fn applyTcp(fd: i32, opts: TcpOptions) SockErr!void {
    if (opts.nodelay)
        try setInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);

    if (opts.quickack)
        try setInt(fd, IPPROTO_TCP, TCP_QUICKACK, 1);

    try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.KEEPALIVE)), @as(c_int, @intFromBool(opts.keepalive)));
    if (opts.keepalive) {
        try setInt(fd, IPPROTO_TCP, TCP_KEEPIDLE, @as(c_int, @intCast(opts.keepalive_idle)));
        try setInt(fd, IPPROTO_TCP, TCP_KEEPINTVL, @as(c_int, @intCast(opts.keepalive_interval)));
        try setInt(fd, IPPROTO_TCP, TCP_KEEPCNT, @as(c_int, @intCast(opts.keepalive_count)));
    }

    if (opts.recv_buf) |buf| try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (opts.send_buf) |buf| try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);

    if (opts.defer_accept)
        try setInt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT, 1);

    if (opts.recv_timeout_ms) |ms| try setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (opts.send_timeout_ms) |ms| try setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

pub fn applyUdp(fd: i32, opts: UdpOptions) SockErr!void {
    if (opts.recv_buf) |buf| try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVBUF)), buf);
    if (opts.send_buf) |buf| try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDBUF)), buf);

    try setInt(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.BROADCAST)), @as(c_int, @intFromBool(opts.broadcast)));

    if (opts.recv_timeout_ms) |ms| try setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.RCVTIMEO)), ms);
    if (opts.send_timeout_ms) |ms| try setTimeval(fd, c.SOL.SOCKET, @as(u32, @intCast(c.SO.SNDTIMEO)), ms);
}

test "TcpOptions apply on a real socket" {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    defer _ = c.close(fd);
    try applyTcp(fd, .{});
}

test "UdpOptions apply on a real socket" {
    const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
    defer _ = c.close(fd);
    try applyUdp(fd, .{});
}
