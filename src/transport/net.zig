const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const mem = std.mem;

pub const Endpoint = struct {
    host: [46]u8,
    host_len: usize,
    port: u16,
};

pub const AddrErr = error{
    AddressResolveFailed,
};

pub fn resolve(host: []const u8, port: u16, socktype: c_int) AddrErr!posix.sockaddr.in {
    assert(host.len > 0);
    var hints = mem.zeroes(c.addrinfo);
    hints.family = c.AF.UNSPEC;
    hints.socktype = socktype;

    var host_buf: [256]u8 align(1) = undefined;
    if (host.len > host_buf.len - 1) return AddrErr.AddressResolveFailed;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    const host_z: [*:0]u8 = @ptrCast(&host_buf);

    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch
        return AddrErr.AddressResolveFailed;

    var result: ?*c.addrinfo = null;
    if (@intFromEnum(c.getaddrinfo(host_z, port_str.ptr, &hints, &result)) != 0)
        return AddrErr.AddressResolveFailed;
    defer if (result) |res| c.freeaddrinfo(res);

    var info = result;
    while (info) |inf| : (info = inf.next) {
        const addr = inf.addr orelse continue;
        if (inf.family == c.AF.INET) {
            return @as(*posix.sockaddr.in, @ptrCast(@alignCast(addr))).*;
        }
    }
    return AddrErr.AddressResolveFailed;
}

pub fn setBlocking(fd: i32, blocking: bool) void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags == -1) return;
    const nonblock: c_int = @bitCast(std.os.linux.O{ .NONBLOCK = true });
    const new_flags = if (blocking) flags & ~nonblock else flags | nonblock;
    _ = c.fcntl(fd, c.F.SETFL, new_flags);
}

pub fn sockaddrToEndpoint(addr: posix.sockaddr.in) Endpoint {
    const host_bytes = @as(*const [4]u8, @ptrCast(&addr.addr));
    var endpoint = Endpoint{
        .host = undefined,
        .host_len = 0,
        .port = mem.bigToNative(u16, addr.port),
    };
    endpoint.host_len = @intCast(
        (std.fmt.bufPrint(&endpoint.host, "{d}.{d}.{d}.{d}", .{
            host_bytes[0], host_bytes[1], host_bytes[2], host_bytes[3],
        }) catch unreachable).len,
    );
    return endpoint;
}

test "resolve succeeds for localhost" {
    const addr = try resolve("127.0.0.1", 0, c.SOCK.DGRAM);
    try std.testing.expectEqual(c.AF.INET, addr.family);
}

test "resolve fails for invalid host" {
    const result = resolve("nonexistent.invalid.example.com", 12345, c.SOCK.STREAM);
    try std.testing.expectError(error.AddressResolveFailed, result);
}

test "sockaddrToEndpoint produces correct string" {
    const addr = posix.sockaddr.in{
        .family = c.AF.INET,
        .port = mem.nativeToBig(u16, 8080),
        .addr = mem.nativeToBig(u32, 0x7F_00_00_01),
    };
    const ep = sockaddrToEndpoint(addr);
    try std.testing.expectEqual(@as(usize, 9), ep.host_len);
    try std.testing.expect(mem.eql(u8, "127.0.0.1", ep.host[0..ep.host_len]));
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
}
