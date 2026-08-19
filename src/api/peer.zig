const std = @import("std");

const constants = @import("../constants.zig");
const IO = @import("../io.zig").IO;
const Session = @import("../channel/network.zig").Session;
const HEADER_SIZE = @import("../channel/network.zig").HEADER_SIZE;

pub const Peer = struct {
    network: *Session,

    pub fn init(network: *Session) Peer {
        return .{ .network = network };
    }

    pub fn send(self: *Peer, comptime T: type, data: *T) ![]IO.Future {
        return self.network.send(std.mem.asBytes(data));
    }

    pub fn recv(self: *Peer) ![]IO.Future {
        return self.network.recv();
    }

    pub fn read(self: *Peer, comptime T: type, futures: []IO.Future, out: *T) !usize {
        return self.network.gather(futures, std.mem.asBytes(out));
    }
};

const TestMsg = packed struct { x: u32, y: u32 };

const BigMsg = struct {
    x: u32,
    y: u32,
    data: [constants.NET_PAYLOAD_MAX + 128]u8,
};

const Frame = @import("../channel/network.zig").Frame;

test "peer init wraps a network" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_init", @sizeOf(TestMsg), 8, .best_effort);
    defer net.close() catch {};

    const peer = Peer.init(&net);
    try std.testing.expectEqual(@as(*Session, &net), peer.network);
}

test "peer send forwards payload and advances the send cursor" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_send", @sizeOf(TestMsg), 8, .best_effort);
    defer net.close() catch {};

    var peer = Peer.init(&net);
    var msg = TestMsg{ .x = 7, .y = 42 };

    const futures = try peer.send(TestMsg, &msg);
    const sent = try net.wait(futures);

    try std.testing.expectEqual(@as(usize, @sizeOf(TestMsg) + HEADER_SIZE), sent);
    try std.testing.expectEqual(@as(u32, 1), net.next_send);
}

test "peer send fragments a message larger than one frame" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_frag", @sizeOf(BigMsg), 8, .best_effort);
    defer net.close() catch {};

    var peer = Peer.init(&net);
    var msg = BigMsg{ .x = 11, .y = 22, .data = undefined };
    for (0..msg.data.len) |i| msg.data[i] = @intCast(i % 251);

    const n: usize = 2;
    const futures = try peer.send(BigMsg, &msg);
    try std.testing.expectEqual(n, futures.len);

    const sent = try net.wait(futures);
    try std.testing.expectEqual(@as(usize, n * HEADER_SIZE + @sizeOf(BigMsg)), sent);
    try std.testing.expectEqual(@as(u32, @intCast(n)), net.next_send);

    const bytes = std.mem.asBytes(&msg);
    const frag_payload: usize = constants.NET_PAYLOAD_MAX - HEADER_SIZE;
    for (0..n) |i| {
        const frag_start = i * frag_payload;
        const frag_len = @min(frag_payload, bytes.len - frag_start);

        const frame: Frame = std.mem.bytesToValue(Frame, net.send_buf[i][0..HEADER_SIZE]);
        try std.testing.expectEqual(constants.NET_MAGIC, frame.magic);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), frame.frag);
        try std.testing.expectEqual(@as(u32, @intCast(n)), frame.total);
        try std.testing.expect(std.mem.eql(
            u8,
            bytes[frag_start .. frag_start + frag_len],
            net.send_buf[i][HEADER_SIZE .. HEADER_SIZE + frag_len],
        ));
    }
}

test "peer recv and read round-trip a message" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_roundtrip", @sizeOf(TestMsg), 8, .best_effort);
    defer net.close() catch {};

    var peer = Peer.init(&net);
    var msg = TestMsg{ .x = 99, .y = 7 };

    const send_futures = try peer.send(TestMsg, &msg);
    _ = try net.wait(send_futures);

    const recv_futures = try peer.recv();
    try std.testing.expectEqual(@as(usize, 1), recv_futures.len);

    var out: TestMsg = undefined;
    const gathered = try peer.read(TestMsg, recv_futures, &out);
    try std.testing.expectEqual(@as(usize, @sizeOf(TestMsg)), gathered);
    try std.testing.expectEqual(@as(u32, 99), out.x);
    try std.testing.expectEqual(@as(u32, 7), out.y);
    try std.testing.expectEqual(@as(u32, 1), net.next_recv);
}

test "peer fragmented round-trip over multicast loopback" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_frag_roundtrip", @sizeOf(BigMsg), 8, .best_effort);
    defer net.close() catch {};

    var peer = Peer.init(&net);
    var msg = BigMsg{ .x = 5, .y = 6, .data = undefined };
    for (0..msg.data.len) |i| msg.data[i] = @intCast(i % 251);

    const send_futures = try peer.send(BigMsg, &msg);
    try std.testing.expectEqual(@as(usize, 2), send_futures.len);
    _ = try net.wait(send_futures);

    const recv_futures = try peer.recv();
    try std.testing.expectEqual(@as(usize, 2), recv_futures.len);

    var out: BigMsg = undefined;
    const gathered = try peer.read(BigMsg, recv_futures, &out);
    try std.testing.expectEqual(@as(usize, @sizeOf(BigMsg)), gathered);
    try std.testing.expectEqual(@as(u32, 5), out.x);
    try std.testing.expectEqual(@as(u32, 6), out.y);
    try std.testing.expect(std.mem.eql(u8, msg.data[0..], out.data[0..]));
    try std.testing.expectEqual(@as(u32, 2), net.next_recv);
}
