const std = @import("std");

const Shm = @import("shm.zig").Shm;
const Session = @import("network.zig").Session;

pub const Protocol = enum {
    shm,
    net,
};

pub fn Channel(comptime protocol: Protocol) type {
    return switch (protocol) {
        .shm => Shm,
        .net => Session,
    };
}
