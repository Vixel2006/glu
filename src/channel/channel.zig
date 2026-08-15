const std = @import("std");

const Shm = @import("shm.zig").Shm;
const Udp = @import("udp.zig").Udp;

/// The transport protocols a glu channel can be built on.
pub const Protocol = enum {
    /// Local, zero-copy shared-memory ring buffer.
    shm,
    /// Networked multicast channel.
    udp,
};

/// Select the channel type for a protocol at comptime.
///
/// Every transport exposes the same method surface: `open`, `close`
/// (`deinit`), `write`, `peek`, `ack`.
pub fn Channel(comptime protocol: Protocol) type {
    return switch (protocol) {
        .shm => Shm,
        .udp => Udp,
    };
}
