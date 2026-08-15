const std = @import("std");
const assert = std.debug.assert;
const udp = @import("../transport/udp.zig");
const IO = @import("../io.zig").IO;

/// Errors reported while opening/using a UDP network channel.
///
/// TODO: populate as the multicast transport lands (reachability, port
/// collision, framing violations, out-of-sequence datagrams, ...).
pub const UdpErr = error{
    NotImplemented,
};

/// Default multicast group used for UDP channels (topic -> group).
pub const DEFAULT_GROUP = "239.255.43.1";

/// A network channel carried over UDP multicast.
///
/// Each topic maps to a multicast group: the publisher sends one datagram
/// per message to the group, and every subscriber that joined the group
/// receives a copy. Delivery semantics (`.reliable` via sequence numbers +
/// acks, `.best_effort` as fire-and-forget) are mirror images of the shm
/// channel's `ToS`.
pub const Udp = struct {
    io: *IO,
    socket: udp.Socket,
    /// Topic -> group address, NUL-terminated for the socket helpers.
    group: [16]u8,
    group_len: usize,
    port: u16,
    msg_size: u32,
    cap: u32,
    /// Monotonic sequence for reliable ordering.
    seq: u32,

    /// Open (or join) a UDP channel for topic `group` on `port`.
    pub fn open(io: *IO, group: []const u8, port: u16, msg_size: u32, capacity: u32) UdpErr!Udp {
        assert(group.len > 0);
        assert(port > 0);
        assert(msg_size > 0);
        assert(capacity > 0);
        _ = io;
        return error.NotImplemented;
    }

    /// Leave the multicast group and close the socket.
    pub fn close(self: *Udp) void {
        _ = self;
    }

    pub const deinit = close;

    /// Send one message to the multicast group.
    ///
    /// TODO: encode a frame (seq + topic + payload), enqueue an io_uring
    /// `send_to` on `self.io`, and wait for its completion.
    pub fn write(self: *Udp, msg: *const anyopaque) void {
        _ = self;
        _ = msg;
        std.debug.panic("channel/udp.write: not implemented yet", .{});
    }

    /// Return the next unread message for `sub_id`, if any.
    ///
    /// TODO: demux datagrams by `sub_id` (per-subscriber sequence tracking).
    pub fn peek(self: *Udp, sub_id: u32) *anyopaque {
        _ = self;
        _ = sub_id;
        std.debug.panic("channel/udp.peek: not implemented yet", .{});
    }

    /// Acknowledge the message returned by `peek` so `sub_id` may advance.
    ///
    /// TODO: send the ack datagram back to the publisher (only relevant for
    /// `.reliable` delivery).
    pub fn ack(self: *Udp, sub_id: u32) void {
        _ = self;
        _ = sub_id;
        std.debug.panic("channel/udp.ack: not implemented yet", .{});
    }
};

test "Udp skeleton: struct layout is well-formed" {
    try std.testing.expect(@sizeOf(Udp) > 0);
    try std.testing.expect(@sizeOf(Udp) < 1 << 16);
}
