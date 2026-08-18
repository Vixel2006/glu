const std = @import("std");

const constants = @import("../constants.zig");
const Network = @import("../channel/network.zig").Network;

const Peer = struct {
    network: *Network,
    write_buf: [constants.NET_PAYLOAD_MAX]u8,
    read_buf: [constants.NET_PAYLOAD_MAX]u8,

    pub fn init(network: *Network) Peer {
        return .{ .network = network };
    }

    pub fn deinit(self: *Peer) void {
        _ = self;
    }

    pub fn read() void {}
    pub fn write() void {}
    pub fn send() void {}
    pub fn recieve() void {}
};
