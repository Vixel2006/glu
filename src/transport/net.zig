const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const mem = std.mem;
const zio = @import("zio");

pub const Endpoint = struct {
    host: [46]u8,
    host_len: usize,
    port: u16,
};

pub fn addressToEndpoint(addr: zio.net.Address) Endpoint {
    var ep = Endpoint{ .host = undefined, .host_len = 0, .port = 0 };
    if (addr.any.family == std.os.linux.AF.INET) {
        ep.port = addr.ip.getPort();
        const bytes: *const [4]u8 = @ptrCast(&addr.ip.in.addr);
        ep.host_len = (std.fmt.bufPrint(&ep.host, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch unreachable).len;
    }
    return ep;
}

test "addressToEndpoint from IPv4" {
    const ip = zio.net.IpAddress.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const addr = zio.net.Address{ .ip = ip };
    const ep = addressToEndpoint(addr);
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
    try std.testing.expectEqualStrings("127.0.0.1", ep.host[0..ep.host_len]);
}
