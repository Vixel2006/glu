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

/// Maximum UDP payload over IPv4 (65535 - 20 IP header - 8 UDP header).
/// One datagram carries a full frame (header + payload); no fragmentation.
const NET_PAYLOAD_MAX = 65507;
const NET_CAP_MAX = 32;

/// Magic identifying a glu network frame (`"GLNW"`).
const NET_MAGIC = 0x474C4E57;

/// Fixed-size header at the start of every datagram. A data frame is the
/// header followed by the message payload
const Frame = extern struct {
    magic: u32,
    seq: u32,
    name: [MAX_NAME_LEN + 1]u8,
};

const HEADER_SIZE = @sizeOf(Frame);

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

    send_buf: [NET_CAP_MAX][NET_PAYLOAD_MAX]u8 = std.mem.zeroes([NET_CAP_MAX][NET_PAYLOAD_MAX]u8),
    next_send: u32 = 0,

    recv_buf: [NET_CAP_MAX][NET_PAYLOAD_MAX]u8 = std.mem.zeroes([NET_CAP_MAX][NET_PAYLOAD_MAX]u8),
    next_recv: u32 = 0,

    pub fn open(io: *IO, name: []const u8, msg_size: u32, capacity: u32, tos: ToS) anyerror!Network {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(capacity <= NET_CAP_MAX);
        assert(name.len > 0 and name.len <= MAX_NAME_LEN);

        const port = @as(u16, @intCast(PORT_BASE + hash.fvn1a(name, PORT_SLOTS)));
        var socket = try udp.bind(io, .{ .host = MULTICAST_HOST, .port = port }, .{ .reuse_addr = true });
        errdefer udp.close(&socket);

        set_nonblocking(socket);
        udp.join_multicast(socket, MULTICAST_HOST, port, "");

        _ = try hash.put(name, &alive_networks);

        var self: Network = .{
            .io = io,
            .socket = socket,
            .port = port,
            .name = std.mem.zeroes([MAX_NAME_LEN + 1]u8),
            .name_len = @intCast(name.len),
            .msg_size = msg_size,
            .cap = capacity,
            .tos = tos,
        };
        @memcpy(self.name[0..name.len], name);

        return self;
    }

    pub fn close(self: *Network) !void {
        udp.leave_multicast(self.socket, MULTICAST_HOST);
        try hash.delete(&self.name, &alive_networks);
        _ = try hash.put(&self.name, &dead_networks);
    }

    pub const deinit = close;

    pub fn send(self: *Network, future: *IO.Future, data: []const u8) !void {
        assert(data.len + HEADER_SIZE <= NET_PAYLOAD_MAX);

        const frame: Frame = .{
            .magic = NET_MAGIC,
            .seq = self.next_send * @as(u32, @intCast(data.len)),
            .name = self.name,
        };
        @memcpy(self.send_buf[self.next_send][0..HEADER_SIZE], std.mem.asBytes(&frame));
        @memcpy(self.send_buf[self.next_send][HEADER_SIZE .. HEADER_SIZE + data.len], data);

        const parsed = try std.Io.net.IpAddress.parseIp4(MULTICAST_HOST, self.port);
        const addr: posix.sockaddr.in = .{
            .addr = @bitCast(parsed.ip4.bytes),
            .port = @byteSwap(parsed.ip4.port),
            .family = std.c.AF.INET,
        };

        try self.io.send_to(future, self.socket, self.send_buf[self.next_send][0 .. HEADER_SIZE + data.len], addr);
        // TODO: When the future returns we should do the increament if the future is returning with the data.

    }

    pub fn recv(self: *Network, future: *IO.Future) !void {
        try self.io.recv_from(future, self.socket, &self.recv_buf[self.next_recv]);
        // TODO: When the future returns we should do the increament if the future is returning with the data.
    }
};

test "open and close a network channel" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Network.open(&io, "test_channel", 1024, 8, .best_effort);
    defer net.close() catch {};

    try std.testing.expectEqual(PORT_BASE + hash.fvn1a("test_channel", PORT_SLOTS), @as(u32, net.port));
    try std.testing.expectEqual(@as(u32, 1024), net.msg_size);
    try std.testing.expectEqual(@as(u32, 8), net.cap);
    try std.testing.expectEqual(@as(u32, "test_channel".len), net.name_len);
    try std.testing.expect(std.mem.eql(u8, "test_channel", net.name[0..net.name_len]));
}

test "network channel port is deterministic from name" {
    const name = "deterministic_port";
    var io = try IO.init(32, 0);
    defer io.deinit();

    var a = try Network.open(&io, name, 256, 4, .best_effort);
    defer a.close() catch {};
    var b = try Network.open(&io, name, 256, 4, .best_effort);
    defer b.close() catch {};

    try std.testing.expectEqual(a.port, b.port);
}

test "send and recv round-trip over multicast loopback" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Network.open(&io, "roundtrip_channel", 1024, 4, .best_effort);
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
    try std.testing.expectEqual(NET_MAGIC, frame.magic);
    try std.testing.expect(std.mem.eql(u8, "roundtrip_channel", frame.name[0..net.name_len]));
    try std.testing.expectEqual(net.next_send * @as(u32, @intCast(msg.len)), frame.seq);
    try std.testing.expect(std.mem.eql(u8, msg, buf[HEADER_SIZE .. HEADER_SIZE + msg.len]));
}

test "large payload round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Network.open(&io, "large_payload_channel", 8192, 4, .best_effort);
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
    try std.testing.expectEqual(NET_MAGIC, std.mem.bytesToValue(Frame, buf[0..HEADER_SIZE]).magic);
    try std.testing.expect(std.mem.eql(u8, &payload, buf[HEADER_SIZE .. HEADER_SIZE + payload.len]));
}
