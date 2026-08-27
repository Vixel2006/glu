const std = @import("std");
const os = std.os.linux;
const c = std.c;
const constants = @import("../constants.zig");
const NodeConfig = @import("../launch/toml.zig").NodeConfig;
const protocol = @import("protocol.zig");

pub const ClientErr = error{
    DaemonNotRunning,
    ConnectionFailed,
    WriteFailed,
    ReadFailed,
    BadMagic,
    CommandFailed,
    PayloadTooLarge,
};

pub const Client = struct {
    sock_fd: i32,

    pub fn connect() ClientErr!Client {
        const sock_path = constants.DAEMON_SOCK;
        const fd = c.socket(os.AF.UNIX, os.SOCK.STREAM, 0);
        if (fd == -1) return ClientErr.ConnectionFailed;

        var addr: os.sockaddr.un = undefined;
        addr.family = os.AF.UNIX;
        @memcpy(addr.path[0..sock_path.len], sock_path);
        addr.path[sock_path.len] = 0;

        const addr_len: u32 = @intCast(@sizeOf(u16) + sock_path.len + 1);
        if (c.connect(fd, @ptrCast(&addr), addr_len) != 0) {
            _ = os.close(fd);
            return ClientErr.DaemonNotRunning;
        }

        return .{ .sock_fd = fd };
    }

    pub fn deinit(self: *Client) void {
        if (self.sock_fd != -1) {
            _ = os.close(self.sock_fd);
            self.sock_fd = -1;
        }
    }

    pub fn ensure_daemon_running(io: std.Io) !Client {
        if (connect()) |client| {
            return client;
        } else |_| {
            // Spawn glud binary in detached mode
            const child = std.process.spawn(io, .{
                .argv = &[_][]const u8{"glud"},
                .stdout = .ignore,
                .stdin = .ignore,
                .stderr = .ignore,
            }) catch |err| {
                std.log.err("Failed to auto-spawn glud daemon: {}", .{err});
                return ClientErr.DaemonNotRunning;
            };
            _ = child;

            // Retry connecting with brief timeout
            var attempts: usize = 0;
            while (attempts < 50) : (attempts += 1) {
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake);
                if (connect()) |client| {
                    return client;
                } else |_| {}
            }
            return ClientErr.DaemonNotRunning;
        }
    }

    fn write_exact(self: *Client, buf: []const u8) ClientErr!void {
        var written: usize = 0;
        while (written < buf.len) {
            const rc = c.write(self.sock_fd, buf[written..].ptr, buf.len - written);
            if (rc <= 0) return ClientErr.WriteFailed;
            written += @intCast(rc);
        }
    }

    fn read_exact(self: *Client, buf: []u8) ClientErr!void {
        var read_bytes: usize = 0;
        while (read_bytes < buf.len) {
            const rc = c.read(self.sock_fd, buf[read_bytes..].ptr, buf.len - read_bytes);
            if (rc <= 0) return ClientErr.ReadFailed;
            read_bytes += @intCast(rc);
        }
    }

    pub fn ping(self: *Client) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.ping),
            .payload_len = 0,
        };
        try self.write_exact(std.mem.asBytes(&req));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
        if (resp.magic != protocol.GLUD_MAGIC) return ClientErr.BadMagic;
        if (resp.status != 0) return ClientErr.CommandFailed;
    }

    pub fn launch(self: *Client, cfgs: []const NodeConfig) ClientErr!u32 {
        var payload_buf: [8192]u8 = undefined;
        var off: usize = 0;

        std.mem.writeInt(u32, payload_buf[off..][0..4], @intCast(cfgs.len), .little);
        off += 4;

        for (cfgs) |cfg| {
            var argv_storage: [32][]const u8 = undefined;
            var argc: usize = 0;

            if (cfg.bin.len > 0) {
                argv_storage[0] = cfg.bin;
                argc = 1;
                for (cfg.extra_cfg[0..cfg.extra_cfg_len]) |arg| {
                    argv_storage[argc] = arg;
                    argc += 1;
                }
            } else {
                argv_storage[0] = "zig";
                argv_storage[1] = "run";
                argv_storage[2] = cfg.path;
                argv_storage[3] = "--";
                argc = 4;
                for (cfg.extra_cfg[0..cfg.extra_cfg_len]) |arg| {
                    argv_storage[argc] = arg;
                    argc += 1;
                }
            }

            const argv = argv_storage[0..argc];

            std.mem.writeInt(u32, payload_buf[off..][0..4], @intCast(cfg.name.len), .little);
            off += 4;
            @memcpy(payload_buf[off .. off + cfg.name.len], cfg.name);
            off += cfg.name.len;

            std.mem.writeInt(u32, payload_buf[off..][0..4], @intCast(argv.len), .little);
            off += 4;
            for (argv) |arg| {
                std.mem.writeInt(u32, payload_buf[off..][0..4], @intCast(arg.len), .little);
                off += 4;
                @memcpy(payload_buf[off .. off + arg.len], arg);
                off += arg.len;
            }
        }

        const payload = payload_buf[0..off];
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.launch),
            .payload_len = @intCast(payload.len),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(payload);

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
        if (resp.magic != protocol.GLUD_MAGIC) return ClientErr.BadMagic;

        var spawned_count: u32 = 0;
        try self.read_exact(std.mem.asBytes(&spawned_count));
        return spawned_count;
    }

    pub fn stop_node(self: *Client, name: []const u8) ClientErr!bool {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.stop_node),
            .payload_len = @intCast(name.len),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(name);

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
        return resp.status == 0;
    }

    pub fn start_node(self: *Client, name: []const u8) ClientErr!bool {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.start_node),
            .payload_len = @intCast(name.len),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(name);

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
        return resp.status == 0;
    }

    pub fn shutdown(self: *Client) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.shutdown),
            .payload_len = 0,
        };
        try self.write_exact(std.mem.asBytes(&req));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
    }

    pub fn register_shm(self: *Client, entry: protocol.WireShmTopic) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.register_shm),
            .payload_len = @sizeOf(protocol.WireShmTopic),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(std.mem.asBytes(&entry));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
    }

    pub fn unregister_shm(self: *Client, name: []const u8) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.unregister_shm),
            .payload_len = @intCast(name.len),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(name);

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
    }

    pub fn register_net(self: *Client, entry: protocol.WireNetChannel) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.register_net),
            .payload_len = @sizeOf(protocol.WireNetChannel),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(std.mem.asBytes(&entry));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
    }

    pub fn unregister_net(self: *Client, name: []const u8) ClientErr!void {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.unregister_net),
            .payload_len = @intCast(name.len),
        };
        try self.write_exact(std.mem.asBytes(&req));
        try self.write_exact(name);

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));
    }

    pub fn list_nodes(self: *Client, nodes_out: []protocol.WireNode) ClientErr!usize {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.list_nodes),
            .payload_len = 0,
        };
        try self.write_exact(std.mem.asBytes(&req));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));

        const count = resp.payload_len / @sizeOf(protocol.WireNode);
        const to_read = @min(count, nodes_out.len);
        for (nodes_out[0..to_read]) |*n| {
            try self.read_exact(std.mem.asBytes(n));
        }
        return to_read;
    }

    pub fn list_topics(self: *Client, topics_out: []protocol.WireShmTopic) ClientErr!usize {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.list_topics),
            .payload_len = 0,
        };
        try self.write_exact(std.mem.asBytes(&req));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));

        const count = resp.payload_len / @sizeOf(protocol.WireShmTopic);
        const to_read = @min(count, topics_out.len);
        for (topics_out[0..to_read]) |*t| {
            try self.read_exact(std.mem.asBytes(t));
        }
        return to_read;
    }

    pub fn list_net(self: *Client, net_out: []protocol.WireNetChannel) ClientErr!usize {
        const req = protocol.Header{
            .magic = protocol.GLUD_MAGIC,
            .cmd = @intFromEnum(protocol.Cmd.list_net),
            .payload_len = 0,
        };
        try self.write_exact(std.mem.asBytes(&req));

        var resp: protocol.Header = undefined;
        try self.read_exact(std.mem.asBytes(&resp));

        const count = resp.payload_len / @sizeOf(protocol.WireNetChannel);
        const to_read = @min(count, net_out.len);
        for (net_out[0..to_read]) |*n| {
            try self.read_exact(std.mem.asBytes(n));
        }
        return to_read;
    }
};
