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

    pub fn send(self: *Peer, future: *IO.Future, comptime T: type, data: *T) !void {
        try self.network.send(future, std.mem.asBytes(data));
        self.network.next_send += 1;
    }

    pub fn recv(self: *Peer, future: *IO.Future) !void {
        try self.network.recv(future);
    }

    pub fn read(self: *Peer, comptime T: type) *align(1) T {
        defer self.network.next_recv += 1;
        const buf = self.network.recv_buf[self.network.next_recv][HEADER_SIZE .. HEADER_SIZE + @sizeOf(T)];
        return @ptrCast(buf.ptr);
    }
};

const TestMsg = packed struct { x: u32, y: u32 };

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

    var future: IO.Future = undefined;
    try peer.send(&future, TestMsg, &msg);
    const sent = try io.wait(&future, usize);

    try std.testing.expectEqual(@as(usize, @sizeOf(TestMsg) + HEADER_SIZE), sent);
    try std.testing.expectEqual(@as(u32, 1), net.next_send);
}

test "peer recv and read round-trip a message" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "peer_roundtrip", @sizeOf(TestMsg), 8, .best_effort);
    defer net.close() catch {};

    var peer = Peer.init(&net);
    var msg = TestMsg{ .x = 99, .y = 7 };

    var send_future: IO.Future = undefined;
    try peer.send(&send_future, TestMsg, &msg);
    _ = try io.wait(&send_future, usize);

    var recv_future: IO.Future = undefined;
    try peer.recv(&recv_future);
    const recv_len = try io.wait(&recv_future, usize);
    try std.testing.expectEqual(@as(usize, @sizeOf(TestMsg) + HEADER_SIZE), recv_len);
    try std.testing.expectEqual(@as(u32, 0), net.next_recv);

    const got: *align(1) TestMsg = peer.read(TestMsg);
    try std.testing.expectEqual(@as(u32, 99), got.x);
    try std.testing.expectEqual(@as(u32, 7), got.y);
    try std.testing.expectEqual(@as(u32, 1), net.next_recv);
}
