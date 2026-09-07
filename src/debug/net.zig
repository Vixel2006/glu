const std = @import("std");
const posix = std.posix;
const c = std.c;
const constants = @import("../constants.zig");
const Frame = @import("../channel/network.zig").Frame;
const HEADER_SIZE = @import("../channel/network.zig").HEADER_SIZE;

pub const SniffEvent = struct {
    seq: u32,
    frag: u32,
    total: u32,
    payload_len: usize,
    channel_name: []const u8,
    dropped: u32,
};

pub const NetSniffer = struct {
    sockfd: posix.socket_t,
    port: u16,
    has_prev: bool = false,
    last_seq: u32 = 0,
    total_frames: u64 = 0,
    total_bytes: u64 = 0,
    total_drops: u64 = 0,

    pub fn init(channel_name: []const u8) !NetSniffer {
        const port = @as(u16, @intCast(constants.PORT_BASE + @as(u32, @intCast(std.hash.Fnv1a_64.hash(channel_name) % constants.PORT_SLOTS))));

        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        errdefer _ = c.close(fd);

        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
        _ = c.setsockopt(fd, c.SOL.SOCKET, 15, &one, @sizeOf(c_int)); // SO_REUSEPORT

        const parsed = try std.Io.net.IpAddress.parseIp4(constants.MULTICAST_HOST, port);
        const addr: posix.sockaddr.in = .{
            .family = @as(u16, @intCast(c.AF.INET)),
            .port = @byteSwap(parsed.ip4.port),
            .addr = @bitCast(parsed.ip4.bytes),
        };

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) < 0) {
            return error.BindFailed;
        }

        const mreq: extern struct {
            imr_multiaddr: u32,
            imr_interface: u32,
        } = .{
            .imr_multiaddr = @bitCast(parsed.ip4.bytes),
            .imr_interface = 0,
        };
        _ = c.setsockopt(fd, 0, 35, &mreq, @sizeOf(@TypeOf(mreq))); // IP_ADD_MEMBERSHIP

        return .{
            .sockfd = fd,
            .port = port,
        };
    }

    pub fn deinit(self: *NetSniffer) void {
        if (self.sockfd >= 0) {
            _ = c.close(self.sockfd);
            self.sockfd = -1;
        }
    }

    pub fn poll(self: *NetSniffer, buf: []u8, timeout_ms: i32) !?SniffEvent {
        var pfd: [1]posix.pollfd = .{.{
            .fd = self.sockfd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const ready = c.poll(@ptrCast(&pfd), 1, timeout_ms);
        if (ready <= 0) return null;

        const n = c.recv(self.sockfd, buf.ptr, buf.len, 0);
        if (n < @as(isize, @intCast(HEADER_SIZE))) return null;

        const un: usize = @intCast(n);
        const frame: *align(1) const Frame = @ptrCast(buf.ptr);
        if (frame.magic != constants.NET_MAGIC) return null;

        var dropped: u32 = 0;
        if (self.has_prev) {
            if (frame.seq > self.last_seq + 1) {
                dropped = frame.seq - (self.last_seq + 1);
            }
        }
        self.has_prev = true;
        self.last_seq = frame.seq;
        self.total_frames += 1;
        self.total_bytes += un;
        self.total_drops += dropped;

        const name_slice = std.mem.sliceTo(&frame.name, 0);
        return SniffEvent{
            .seq = frame.seq,
            .frag = frame.frag,
            .total = frame.total,
            .payload_len = un - HEADER_SIZE,
            .channel_name = name_slice,
            .dropped = dropped,
        };
    }
};
