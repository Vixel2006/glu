const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const mem = std.mem;
const posix = std.posix;

pub const Endpoint = struct {
    host: [46]u8,
    host_len: usize,
    port: u16,
};

pub fn address_to_endpoint(addr: posix.sockaddr.in) Endpoint {
    var ep = Endpoint{ .host = undefined, .host_len = 0, .port = 0 };
    ep.port = @byteSwap(addr.port);
    const bytes: *const [4]u8 = @ptrCast(&addr.addr);
    ep.host_len = (std.fmt.bufPrint(&ep.host, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch unreachable).len;
    return ep;
}

test "address_to_endpoint from IPv4" {
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(@as(u16, 8080)),
        .addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 })),
    };
    const ep = address_to_endpoint(addr);
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
    try std.testing.expectEqualStrings("127.0.0.1", ep.host[0..ep.host_len]);
}
