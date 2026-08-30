const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const hash = @import("../hash.zig");
const udp = @import("../transport/udp.zig");
const IO = @import("../io.zig").IO;
const ConnectAddress = @import("../io.zig").ConnectAddress;
const time = @import("../time.zig");
const ToS = @import("shm.zig").ToS;
const constants = @import("../constants.zig");

/// Fixed-size header at the start of every datagram. A data frame is the
/// header followed by the message payload
pub const Frame = extern struct {
    magic: u32,
    seq: u32,
    frag: u32 = 1,
    total: u32 = 1,
    name: [constants.MAX_NAME_LEN + 1]u8,
};

pub const HEADER_SIZE = @sizeOf(Frame);

/// Maximum payload carried in a single frame's datagram.
pub const FRAG_PAYLOAD: usize = constants.NET_PAYLOAD_MAX - HEADER_SIZE;

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

    /// Pool of futures for in-flight send datagrams. A fragmented send
    /// enqueues one future per fragment and returns a slice into this pool.
    send_futures: [constants.NET_CAP_MAX]IO.Future = undefined,

    /// Pool of futures for in-flight recv datagrams, one per fragment.
    recv_futures: [constants.NET_CAP_MAX]IO.Future = undefined,

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
    }

    pub const deinit = close;

    pub fn send(self: *Session, data: []const u8) ![]IO.Future {
        defer self.seq += 1;

        const parsed = try std.Io.net.IpAddress.parseIp4(constants.MULTICAST_HOST, self.port);
        const addr = ConnectAddress{ .inet = .{
            .addr = @bitCast(parsed.ip4.bytes),
            .port = @byteSwap(parsed.ip4.port),
            .family = std.c.AF.INET,
        } };

        assert(data.len > 0);
        const n = @divFloor(data.len + FRAG_PAYLOAD - 1, FRAG_PAYLOAD);
        assert(n <= constants.NET_CAP_MAX);

        const futures = self.send_futures[0..n];
        for (0..n) |i| {
            const s = (self.next_send + i) % constants.NET_CAP_MAX;
            const frag_start = i * FRAG_PAYLOAD;
            const frag_len = @min(FRAG_PAYLOAD, data.len - frag_start);

            const frame: *align(1) Frame = @ptrCast(&self.send_buf[s]);
            frame.magic = constants.NET_MAGIC;
            frame.seq = self.seq;
            frame.frag = @intCast(i + 1);
            frame.total = @intCast(n);
            frame.name = self.name;

            @memcpy(
                self.send_buf[s][HEADER_SIZE .. HEADER_SIZE + frag_len],
                data[frag_start .. frag_start + frag_len],
            );
            try self.io.send_to(&futures[i], self.socket, self.send_buf[s][0 .. HEADER_SIZE + frag_len], addr);
        }

        self.next_send = (self.next_send + @as(u32, @intCast(n))) % constants.NET_CAP_MAX;
        return futures;
    }

    pub fn recv(self: *Session) ![]IO.Future {
        while (true) {
            try self.io.recv_from(&self.recv_futures[0], self.socket, &self.recv_buf[self.next_recv]);
            _ = self.io.wait(&self.recv_futures[0], usize) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            break;
        }

        const frame: *align(1) const Frame = @ptrCast(&self.recv_buf[self.next_recv]);
        if (frame.magic != constants.NET_MAGIC) return error.InvalidFrame;
        const total = frame.total;
        if (total == 0 or total > constants.NET_CAP_MAX) return error.InvalidFrame;

        const futures = self.recv_futures[0..total];
        for (1..total) |i| {
            const slot = (self.next_recv + i) % constants.NET_CAP_MAX;
            try self.io.recv_from(&futures[i], self.socket, &self.recv_buf[slot]);
        }
        return futures;
    }

    pub fn wait(self: *Session, futures: []IO.Future) !usize {
        var total: usize = 0;
        for (futures) |*fut| {
            total += try self.io.wait(fut, usize);
        }
        return total;
    }

    pub fn gather(self: *Session, futures: []IO.Future, out: []u8) !usize {
        for (futures) |*fut| {
            _ = try self.io.wait(fut, usize);
        }
        return self.assemble(futures, out);
    }

    fn assemble(self: *Session, futures: []IO.Future, out: []u8) !usize {
        const total = futures.len;
        if (total == 0 or total > constants.NET_CAP_MAX) return error.InvalidFrame;

        var seen: u32 = 0;
        var payload_len: usize = 0;
        for (0..total) |i| {
            const slot = (self.next_recv + i) % constants.NET_CAP_MAX;
            const frame: *align(1) const Frame = @ptrCast(&self.recv_buf[slot]);
            if (frame.magic != constants.NET_MAGIC) return error.InvalidFrame;
            if (frame.frag == 0 or frame.frag > total) return error.InvalidFrame;

            const mask: u32 = @as(u32, 1) << @intCast(frame.frag - 1);
            if (seen & mask != 0) return error.InvalidFrame;
            seen |= mask;

            const frag_start = (frame.frag - 1) * FRAG_PAYLOAD;
            if (frag_start >= out.len) return error.InvalidFrame;
            const frag_len = @min(FRAG_PAYLOAD, out.len - frag_start);
            @memcpy(out[frag_start .. frag_start + frag_len], self.recv_buf[slot][HEADER_SIZE .. HEADER_SIZE + frag_len]);
            payload_len += frag_len;
        }

        self.next_recv = (self.next_recv + @as(u32, @intCast(total))) % constants.NET_CAP_MAX;
        return payload_len;
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

test "send small payload as a single unfragmented frame" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "single_frame", 1024, 4, .best_effort);
    defer net.close() catch {};

    const msg = "hello network channel";

    const futures = try net.send(msg);
    try std.testing.expectEqual(@as(usize, 1), futures.len);

    const sent = try net.wait(futures);
    try std.testing.expectEqual(@as(usize, msg.len + HEADER_SIZE), sent);

    const frame: Frame = std.mem.bytesToValue(Frame, net.send_buf[0][0..HEADER_SIZE]);
    try std.testing.expectEqual(constants.NET_MAGIC, frame.magic);
    try std.testing.expectEqual(@as(u32, 0), frame.seq);
    try std.testing.expectEqual(@as(u32, 1), frame.frag);
    try std.testing.expectEqual(@as(u32, 1), frame.total);
    try std.testing.expect(std.mem.eql(u8, msg, net.send_buf[0][HEADER_SIZE .. HEADER_SIZE + msg.len]));
    try std.testing.expectEqual(@as(u32, 1), net.next_send);
}

test "send fragments a large payload and returns one future per fragment" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "fragmented_send", 8192, 8, .best_effort);
    defer net.close() catch {};

    const frag_payload: usize = constants.NET_PAYLOAD_MAX - HEADER_SIZE;
    var payload: [2 * frag_payload + 123]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);

    const futures = try net.send(&payload);
    const n: usize = 3;
    try std.testing.expectEqual(n, futures.len);

    const sent = try net.wait(futures);
    try std.testing.expectEqual(@as(usize, n * HEADER_SIZE + payload.len), sent);

    // next_send advanced by the number of fragments.
    try std.testing.expectEqual(@as(u32, @intCast(n)), net.next_send);

    // Each ring slot carries one fragment with the correct frame and slice.
    for (0..n) |i| {
        const frag_start = i * frag_payload;
        const frag_len = @min(frag_payload, payload.len - frag_start);

        const frame: Frame = std.mem.bytesToValue(Frame, net.send_buf[i][0..HEADER_SIZE]);
        try std.testing.expectEqual(constants.NET_MAGIC, frame.magic);
        try std.testing.expectEqual(@as(u32, 0), frame.seq);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), frame.frag);
        try std.testing.expectEqual(@as(u32, @intCast(n)), frame.total);
        try std.testing.expect(std.mem.eql(
            u8,
            payload[frag_start .. frag_start + frag_len],
            net.send_buf[i][HEADER_SIZE .. HEADER_SIZE + frag_len],
        ));
    }
}

test "send and recv round-trip over multicast loopback" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "roundtrip_channel", 1024, 4, .best_effort);
    defer net.close() catch {};

    const msg = "hello network channel";

    const send_futures = try net.send(msg);
    const sent = try net.wait(send_futures);
    try std.testing.expectEqual(@as(usize, msg.len + HEADER_SIZE), sent);

    const recv_futures = try net.recv();
    try std.testing.expectEqual(@as(usize, 1), recv_futures.len);

    var out: [msg.len]u8 = undefined;
    const gathered = try net.gather(recv_futures, &out);
    try std.testing.expectEqual(@as(usize, msg.len), gathered);
    try std.testing.expect(std.mem.eql(u8, msg, &out));
    try std.testing.expectEqual(@as(u32, 1), net.next_recv);
}

test "fragmented payload round-trips over multicast loopback" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "fragmented_roundtrip", 8192, 8, .best_effort);
    defer net.close() catch {};

    var payload: [2 * FRAG_PAYLOAD + 123]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);
    const n: usize = 3;

    const send_futures = try net.send(&payload);
    try std.testing.expectEqual(n, send_futures.len);
    _ = try net.wait(send_futures);

    const recv_futures = try net.recv();
    try std.testing.expectEqual(n, recv_futures.len);

    var reassembled: [payload.len]u8 = undefined;
    const gathered = try net.gather(recv_futures, &reassembled);
    try std.testing.expectEqual(@as(usize, payload.len), gathered);
    try std.testing.expect(std.mem.eql(u8, &payload, &reassembled));
    try std.testing.expectEqual(@as(u32, @intCast(n)), net.next_recv);
}

test "gather reassembles fragments delivered out of order" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "gather_reorder", 8192, 8, .best_effort);
    defer net.close() catch {};

    var payload: [2 * FRAG_PAYLOAD + 123]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);
    const n: usize = 3;

    // Simulate fragments arriving in the order 2, 1, 3 across ring slots.
    const order = [_]u8{ 2, 1, 3 };
    for (0..n) |i| {
        const frag: u32 = order[i];
        const frag_start = (frag - 1) * FRAG_PAYLOAD;
        const frag_len = @min(FRAG_PAYLOAD, payload.len - frag_start);
        const frame: Frame = .{
            .magic = constants.NET_MAGIC,
            .seq = 0,
            .frag = frag,
            .total = @intCast(n),
            .name = net.name,
        };
        @memcpy(net.recv_buf[i][0..HEADER_SIZE], std.mem.asBytes(&frame));
        @memcpy(
            net.recv_buf[i][HEADER_SIZE .. HEADER_SIZE + frag_len],
            payload[frag_start .. frag_start + frag_len],
        );
    }

    var futs: [n]IO.Future = undefined;
    var out: [payload.len]u8 = undefined;
    const gathered = try net.assemble(&futs, &out);
    try std.testing.expectEqual(@as(usize, payload.len), gathered);
    try std.testing.expect(std.mem.eql(u8, &payload, &out));
    try std.testing.expectEqual(@as(u32, @intCast(n)), net.next_recv);
}

test "gather rejects a frame with the wrong magic" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "gather_bad_magic", 8192, 8, .best_effort);
    defer net.close() catch {};

    var frame: Frame = .{
        .magic = 0xDEADBEEF,
        .seq = 0,
        .frag = 1,
        .total = 1,
        .name = net.name,
    };
    @memcpy(net.recv_buf[0][0..HEADER_SIZE], std.mem.asBytes(&frame));

    var futs: [1]IO.Future = undefined;
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidFrame, net.assemble(&futs, &out));
}

test "gather rejects duplicate fragments" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "gather_dup_frag", 8192, 8, .best_effort);
    defer net.close() catch {};

    for (0..2) |i| {
        const frame: Frame = .{
            .magic = constants.NET_MAGIC,
            .seq = 0,
            .frag = 1,
            .total = 2,
            .name = net.name,
        };
        @memcpy(net.recv_buf[i][0..HEADER_SIZE], std.mem.asBytes(&frame));
        @memset(net.recv_buf[i][HEADER_SIZE .. HEADER_SIZE + 8], 0x42);
    }

    var futs: [2]IO.Future = undefined;
    var out: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidFrame, net.assemble(&futs, &out));
}

test "send ring wraps after a fragmented payload" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var net = try Session.open(&io, "ring_wrap", 8192, 4, .best_effort);
    defer net.close() catch {};

    const frag_payload: usize = constants.NET_PAYLOAD_MAX - HEADER_SIZE;
    var big: [frag_payload + 1]u8 = undefined;
    @memset(&big, 0xAB);

    const big_futures = try net.send(&big);
    try std.testing.expectEqual(@as(usize, 2), big_futures.len);
    _ = try net.wait(big_futures);
    try std.testing.expectEqual(@as(u32, 2), net.next_send);

    const msg = "wraps";
    const small_futures = try net.send(msg);
    _ = try net.wait(small_futures);

    // The small frame lands in slot 2 and next_send wraps back to slot 0.
    try std.testing.expectEqual(@as(u32, 3), net.next_send);
    const frame: Frame = std.mem.bytesToValue(Frame, net.send_buf[2][0..HEADER_SIZE]);
    try std.testing.expectEqual(@as(u32, 1), frame.frag);
    try std.testing.expectEqual(@as(u32, 1), frame.total);
    try std.testing.expect(std.mem.eql(u8, msg, net.send_buf[2][HEADER_SIZE .. HEADER_SIZE + msg.len]));
}
