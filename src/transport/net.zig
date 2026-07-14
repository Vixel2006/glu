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

/// Convert a POSIX sockaddr_in to an `Endpoint`.
/// Only handles IPv4 (`posix.sockaddr.in`); asserts the address family is `AF_INET`.
pub fn sockaddrToEndpoint(addr: posix.sockaddr.in) Endpoint {
    assert(addr.family == c.AF.INET);
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

/// Convert an `std.Io.net.IpAddress` (IPv4 or IPv6) to an `Endpoint`.
pub fn ipAddressToEndpoint(addr: std.Io.net.IpAddress) Endpoint {
    return switch (addr) {
        .ip4 => |ip4| {
            var ep = Endpoint{
                .host = undefined,
                .host_len = 0,
                .port = ip4.port,
            };
            ep.host_len = @intCast(
                (std.fmt.bufPrint(&ep.host, "{d}.{d}.{d}.{d}", .{
                    ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3],
                }) catch unreachable).len,
            );
            return ep;
        },
        .ip6 => |ip6| {
            var ep = Endpoint{
                .host = undefined,
                .host_len = 0,
                .port = ip6.port,
            };
            ep.host_len = @intCast(
                (std.fmt.bufPrint(&ep.host, "{}", .{ip6}) catch unreachable).len,
            );
            return ep;
        },
    };
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

test "ipAddressToEndpoint from Ip4Address" {
    const addr = std.Io.net.Ip4Address{ .bytes = .{ 127, 0, 0, 1 }, .port = 8080 };
    const ep = ipAddressToEndpoint(.{ .ip4 = addr });
    try std.testing.expectEqual(@as(usize, 9), ep.host_len);
    try std.testing.expect(mem.eql(u8, "127.0.0.1", ep.host[0..ep.host_len]));
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
}
