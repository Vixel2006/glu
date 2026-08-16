const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const hash = @import("../hash.zig");
const udp = @import("../transport/udp.zig");
const IO = @import("../io.zig").IO;
const time = @import("../time.zig");
const ToS = @import("shm.zig").ToS;

/// IPv4 multicast group everything publishes to. Every channel is carried
/// over this one group; traffic is demultiplexed by (port, name).
const MULTICAST_HOST = "239.255.43.1";

/// Base UDP port for network channels. The port for a channel with `name` is
/// `PORT_BASE + fvn1a(name, 256)`, so two processes derive the same port from
/// the name alone (no shared state). Colliding names share a port and are
/// demultiplexed by name inside each frame.
const PORT_BASE: u16 = 49152;
const PORT_SLOTS: u32 = 256;

const MAX_NAME_LEN = 63;

/// Maximum payload per message and maximum number of in-flight messages per
/// channel (the ring depth / flow-control window).
const NET_MSG_MAX = 4096; // TODO: We maybe want to make this bigger for large payloads in the future
const NET_CAP_MAX = 32;

/// Magic identifying a glu network frame (`"GLNW"`).
const NET_MAGIC = 0x474C4E57;

/// Kinds of frames exchanged on a network channel.
const Kind = enum(u32) {
    data = 0,
    ack = 1,
    nack = 2,
    join = 3,
};

/// Fixed-size header at the start of every datagram. A data frame is the
/// header followed by the message payload; control frames (ack/nack/join)
/// are just the header.
const Frame = extern struct {
    magic: u32,
    kind: Kind,
    name: [MAX_NAME_LEN + 1]u8,
    seq: u32,
    /// Subscriber slot this frame addresses (ack/nack/join) or carries for.
    sub: u32,
};

const HEADER_SIZE = @sizeOf(Frame);
const NET_FRAME = HEADER_SIZE + NET_MSG_MAX;

comptime {
    assert(@sizeOf(Frame) == 80);
}

var alive_networks: [256][]const u8 = std.mem.zeroes([256][]const u8);
var dead_networks: [256][]const u8 = std.mem.zeroes([256][]const u8);

fn set_nonblocking(fd: i32) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

pub const Network = struct {
    io: *IO,
    socket: udp.Socket,
    port: u16,
    name: [MAX_NAME_LEN + 1]u8,
    name_len: u32,
    msg_size: u32,
    cap: u32,
    tos: ToS,

    /// Publisher state.
    /// Ring of full frames (header + payload), indexed by `seq % cap`.
    send_ring: [NET_CAP_MAX * NET_FRAME]u8,
    /// Sequence number of the next message to publish.
    send_seq: u32,

    /// Subscriber state (single local lane, `sub_id`).
    recv_ring: [NET_CAP_MAX * NET_FRAME]u8,
    present: [NET_CAP_MAX]bool,
    /// Next sequence number the local subscriber expects.
    recv_next: u32,
    sub_id: u32,

    recv_buf: [NET_FRAME]u8,
    fut: IO.Future,

    pub fn open(io: *IO, name: []const u8, msg_size: u32, capacity: u32, tos: ToS) anyerror!Network {
        assert(msg_size > 0);
        assert(msg_size <= NET_MSG_MAX);
        assert(capacity > 0);
        assert(capacity <= NET_CAP_MAX);
        assert(name.len > 0);
        assert(name.len <= MAX_NAME_LEN);

        const port = port_of(name);
        var socket = try udp.bind(io, port, .{ .reuse_addr = true });
        errdefer udp.close(&socket);

        set_nonblocking(socket);
        udp.join_multicast(socket, MULTICAST_HOST, port, "");

        try hash.put(name, &alive_networks);

        var self: Network = .{
            .io = io,
            .socket = socket,
            .port = port,
            .name = std.mem.zeroes([MAX_NAME_LEN + 1]u8),
            .name_len = @intCast(name.len),
            .msg_size = msg_size,
            .cap = capacity,
            .tos = tos,
            .send_ring = undefined,
            .send_seq = 0,
            .recv_ring = undefined,
            .present = std.mem.zeroes([NET_CAP_MAX]bool),
            .recv_next = 0,
            .sub_id = 0,
            .recv_buf = undefined,
            .fut = undefined,
        };
        @memcpy(self.name[0..name.len], name);

        @memset(&self.send_ring, 0);
        @memset(&self.recv_ring, 0);

        // Announce our subscriber lane to any publisher on this port.
        self.send_ctrl(.join, self.send_seq);

        return self;
    }

    pub fn close(self: *Network) void {
        _ = self;
    }

    pub const deinit = close;

    /// Port a channel with `name` binds, stable across processes.
    pub fn port_of(name: []const u8) u16 {
        return @intCast(PORT_BASE + hash.fvn1a(name, PORT_SLOTS));
    }

    fn name_slice(self: *const Network) []const u8 {
        return self.name[0..self.name_len];
    }

    fn writes_in_flight(self: *const Network) u32 {
        return self.send_seq -% self.slowest_reader();
    }
};
