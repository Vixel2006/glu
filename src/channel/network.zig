const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const hash = @import("../hash.zig");
const udp = @import("../transport/udp.zig");
const IO = @import("../io.zig").IO;
const time = @import("../time.zig");
const ToS = @import("shm.zig").ToS;
const constants = @import("../constants.zig");

/// Fixed-size header at the start of every datagram. A data frame is the
/// header followed by the message payload
const Frame = extern struct {
    magic: u32,
    seq: u32,
    frag: u32 = 1,
    total: u32 = 1,
    name: [constants.MAX_NAME_LEN + 1]u8,
};

pub const HEADER_SIZE = @sizeOf(Frame);

var alive_networks: [256][]const u8 = std.mem.zeroes([256][]const u8);
var dead_networks: [256][]const u8 = std.mem.zeroes([256][]const u8);

fn set_nonblocking(fd: i32) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

pub const Session = struct {
    io: *IO,
    socket: udp.Socket,
    port: u16,
    name: [constants.MAX_NAME_LEN + 1]u8,
    name_len: u32,
    msg_size: u32,
    cap: u32,
    tos: ToS,
    seq: u32 = 0,

    send_buf: [constants.NET_CAP_MAX][constants.NET_PAYLOAD_MAX]u8 = std.mem.zeroes([constants.NET_CAP_MAX][constants.NET_PAYLOAD_MAX]u8),
    next_send: u32 = 0,

    recv_buf: [constants.NET_CAP_MAX][constants.NET_PAYLOAD_MAX]u8 = std.mem.zeroes([constants.NET_CAP_MAX][constants.NET_PAYLOAD_MAX]u8),
    next_recv: u32 = 0,

    pub fn open(io: *IO, name: []const u8, msg_size: u32, capacity: u32, tos: ToS) anyerror!Session {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(capacity <= constants.NET_CAP_MAX);
        assert(name.len > 0 and name.len <= constants.MAX_NAME_LEN);

        const port = @as(u16, @intCast(constants.PORT_BASE + hash.fvn1a(name, constants.PORT_SLOTS)));
        var socket = try udp.bind(io, .{ .host = constants.MULTICAST_HOST, .port = port }, .{ .reuse_addr = true });
        errdefer udp.close(&socket);

        set_nonblocking(socket);
        udp.join_multicast(socket, constants.MULTICAST_HOST, port, "");

        // NOTE: Remove the multicast loop in production so the sender doesn't recieve its messages back
        // we leave the multicast loop enabled in debug mode for unit testing
        if (comptime builtin.mode != .Debug) udp.set_multicast_loop(socket, false);

        _ = try hash.put(name, &alive_networks);

        var self: Session = .{
            .io = io,
            .socket = socket,
            .port = port,
            .name = std.mem.zeroes([constants.MAX_NAME_LEN + 1]u8),
            .name_len = @intCast(name.len),
            .msg_size = msg_size,
            .cap = capacity,
            .tos = tos,
        };
        @memcpy(self.name[0..name.len], name);

        return self;
    }

    pub fn close(self: *Session) !void {
        udp.leave_multicast(self.socket, constants.MULTICAST_HOST);
        try hash.delete(&self.name, &alive_networks);
        _ = try hash.put(&self.name, &dead_networks);
    }

    pub const deinit = close;

    pub fn send(self: *Session, future: *IO.Future, data: []const u8) !void {
        defer self.seq += 1;

        const parsed = try std.Io.net.IpAddress.parseIp4(constants.MULTICAST_HOST, self.port);
        const addr: posix.sockaddr.in = .{
            .addr = @bitCast(parsed.ip4.bytes),
            .port = @byteSwap(parsed.ip4.port),
            .family = std.c.AF.INET,
        };

        const frag_payload = constants.NET_PAYLOAD_MAX - HEADER_SIZE;
        const n = @divFloor(data.len + frag_payload - 1, frag_payload);

        for (0..n) |i| {
            const s = (self.next_send + i) % constants.NET_CAP_MAX;
            const frame: Frame = .{
                .magic = constants.NET_MAGIC,
                .seq = self.seq,
                .frag = @intCast(i + 1),
                .total = @intCast(n),
                .name = self.name,
            };
            @memcpy(self.send_buf[s][0..HEADER_SIZE], std.mem.asBytes(&frame));
            @memcpy(self.send_buf[s][HEADER_SIZE .. HEADER_SIZE + data.len], data);

            if (i == n - 1) {
                try self.io.send_to(future, self.socket, self.send_buf[self.next_send][0 .. HEADER_SIZE + data.len], addr);
            }
        }
    }

    pub fn recv(self: *Session, future: *IO.Future) !void {
        try self.io.recv_from(future, self.socket, &self.recv_buf[self.next_recv]);
    }
};

test "open and close a network channel" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "test_channel", 1024, 8, .best_effort);
    defer net.close() catch {};

    try std.testing.expectEqual(constants.PORT_BASE + hash.fvn1a("test_channel", constants.PORT_SLOTS), @as(u32, net.port));
    try std.testing.expectEqual(@as(u32, 1024), net.msg_size);
    try std.testing.expectEqual(@as(u32, 8), net.cap);
    try std.testing.expectEqual(@as(u32, "test_channel".len), net.name_len);
    try std.testing.expect(std.mem.eql(u8, "test_channel", net.name[0..net.name_len]));
}

test "network channel port is deterministic from name" {
    const name = "deterministic_port";
    var io = try IO.init(32, 0);
    defer io.deinit();

    var a = try Session.open(&io, name, 256, 4, .best_effort);
    defer a.close() catch {};
    var b = try Session.open(&io, name, 256, 4, .best_effort);
    defer b.close() catch {};

    try std.testing.expectEqual(a.port, b.port);
}

test "send and recv round-trip over multicast loopback" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "roundtrip_channel", 1024, 4, .best_effort);
    defer net.close() catch {};

    const msg = "hello network channel";

    var send_future: IO.Future = undefined;
    try net.send(&send_future, msg);
    const sent = try io.wait(&send_future, usize);
    try std.testing.expectEqual(@as(usize, msg.len), sent - HEADER_SIZE);

    var recv_future: IO.Future = undefined;
    try net.recv(&recv_future);
    const recv_len = try io.wait(&recv_future, usize);

    const buf = net.recv_buf[net.next_recv];
    try std.testing.expectEqual(@as(usize, msg.len), recv_len - HEADER_SIZE);

    const frame: Frame = std.mem.bytesToValue(Frame, buf[0..HEADER_SIZE]);
    try std.testing.expectEqual(constants.NET_MAGIC, frame.magic);
    try std.testing.expect(std.mem.eql(u8, "roundtrip_channel", frame.name[0..net.name_len]));
    try std.testing.expectEqual(net.next_send * @as(u32, @intCast(msg.len)), frame.seq);
    try std.testing.expect(std.mem.eql(u8, msg, buf[HEADER_SIZE .. HEADER_SIZE + msg.len]));
}

test "large payload round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "large_payload_channel", 8192, 4, .best_effort);
    defer net.close() catch {};

    var payload: [8192]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);

    var send_future: IO.Future = undefined;
    try net.send(&send_future, &payload);
    const sent = try io.wait(&send_future, usize);
    try std.testing.expectEqual(@as(usize, payload.len) + HEADER_SIZE, sent);

    var recv_future: IO.Future = undefined;
    try net.recv(&recv_future);
    const recv_len = try io.wait(&recv_future, usize);

    const buf = net.recv_buf[net.next_recv];
    try std.testing.expectEqual(@as(usize, HEADER_SIZE + payload.len), recv_len);
    try std.testing.expectEqual(constants.NET_MAGIC, std.mem.bytesToValue(Frame, buf[0..HEADER_SIZE]).magic);
    try std.testing.expect(std.mem.eql(u8, &payload, buf[HEADER_SIZE .. HEADER_SIZE + payload.len]));
}
