const std = @import("std");

pub const Network = @import("../channel/network.zig").Network;
pub const port_of = Network.port_of;

test "network transport re-exports the channel implementation" {
    try std.testing.expect(@as(u16, Network.port_of("alpha")) > 0);
}