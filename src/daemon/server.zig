const std = @import("std");
const os = std.os.linux;
const c = std.c;

const protocol = @import("protocol.zig");
const supervisor = @import("supervisor.zig");
const constants = @import("../constants.zig");

const state = @import("state.zig");

pub const Server = struct {
    sock_fd: i32,
    state: *state.DaemonState,
    running: std.atomic.Value(bool),
    io: std.Io,

    pub fn init(io: std.Io, dstate: *state.DaemonState) !Server {
        const sock_path = constants.DAEMON_SOCK;

        // Ensure directory exists
        const cwd = std.Io.Dir.cwd();
        _ = cwd.createDirPathStatus(io, "/tmp/glu", std.Io.File.Permissions.fromMode(0o700)) catch {};

        // Remove stale socket if present
        _ = c.unlink(sock_path.ptr);

        const fd = c.socket(os.AF.UNIX, os.SOCK.STREAM, 0);
        if (fd == -1) return error.SocketCreationFailed;

        var addr: os.sockaddr.un = undefined;
        addr.family = os.AF.UNIX;
        @memcpy(addr.path[0..sock_path.len], sock_path);
        addr.path[sock_path.len] = 0;

        const addr_len: u32 = @intCast(@sizeOf(u16) + sock_path.len + 1);
        if (c.bind(fd, @ptrCast(&addr), addr_len) != 0) {
            _ = os.close(fd);
            return error.SocketBindFailed;
        }

        if (c.listen(fd, 16) != 0) {
            _ = os.close(fd);
            return error.SocketListenFailed;
        }

        return .{
            .sock_fd = fd,
            .state = dstate,
            .running = std.atomic.Value(bool).init(true),
            .io = io,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.sock_fd != -1) {
            _ = os.close(self.sock_fd);
            self.sock_fd = -1;
        }
        _ = c.unlink(constants.DAEMON_SOCK.ptr);
    }

    pub fn run(self: *Server) void {
        while (self.running.load(.acquire)) {
            var client_addr: os.sockaddr.un = undefined;
            var addr_len: socklen_t = @sizeOf(os.sockaddr.un);

            const client_fd = c.accept(self.sock_fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd == -1) {
                if (!self.running.load(.acquire)) break;
                continue;
            }

            self.handle_client(client_fd) catch |err| {
                std.log.debug("Client handler error: {}", .{err});
            };
            _ = os.close(client_fd);
        }
    }

    fn handle_client(self: *Server, fd: i32) !void {
        var hdr: protocol.Header = undefined;
        const hdr_slice = std.mem.asBytes(&hdr);
        try read_exact(fd, hdr_slice);

        if (hdr.magic != protocol.GLUD_MAGIC) return error.BadMagic;

        var payload_buf: [8192]u8 = undefined;
        if (hdr.payload_len > payload_buf.len) return error.PayloadTooLarge;
        const payload = payload_buf[0..hdr.payload_len];
        if (hdr.payload_len > 0) {
            try read_exact(fd, payload);
        }

        const cmd: protocol.Cmd = @enumFromInt(hdr.cmd);
        switch (cmd) {
            .ping => {
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .status => {
                self.state.sweep_dead();

                const snap_hdr = protocol.StatusSnapshotHeader{
                    .node_count = @intCast(self.state.node_count),
                    .topic_count = @intCast(self.state.shm_count),
                };

                const total_payload_len = @sizeOf(protocol.StatusSnapshotHeader) +
                    self.state.node_count * @sizeOf(protocol.WireNode) +
                    self.state.shm_count * @sizeOf(protocol.WireShmTopic) +
                    self.state.net_count * @sizeOf(protocol.WireNetChannel);

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = @intCast(total_payload_len),
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
                try write_exact(fd, std.mem.asBytes(&snap_hdr));

                for (self.state.nodes[0..self.state.node_count]) |n| {
                    const wn = protocol.WireNode{
                        .name = n.name,
                        .name_len = n.name_len,
                        .pid = n.pid,
                        .status = @intFromEnum(n.status),
                        .start_time = n.start_time,
                        .restart_count = n.restart_count,
                        .argv_len = @intCast(n.argv_len),
                    };
                    try write_exact(fd, std.mem.asBytes(&wn));
                }

                for (self.state.shm_topics[0..self.state.shm_count]) |t| {
                    const wt = protocol.WireShmTopic{
                        .name = t.name,
                        .name_len = t.name_len,
                        .owner_pid = t.owner_pid,
                        .msg_size = t.msg_size,
                        .capacity = t.capacity,
                        .tos = t.tos,
                    };
                    try write_exact(fd, std.mem.asBytes(&wt));
                }

                for (self.state.net_channels[0..self.state.net_count]) |net| {
                    const wn = protocol.WireNetChannel{
                        .name = net.name,
                        .name_len = net.name_len,
                        .owner_pid = net.owner_pid,
                        .port = net.port,
                        .msg_size = net.msg_size,
                        .capacity = net.capacity,
                        .tos = net.tos,
                    };
                    try write_exact(fd, std.mem.asBytes(&wn));
                }
            },
            .list_nodes => {
                self.state.sweep_dead();

                const payload_len = self.state.node_count * @sizeOf(protocol.WireNode);
                const resp_hdr: protocol.Header = .{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = @intCast(payload_len),
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));

                for (self.state.nodes[0..self.state.node_count]) |n| {
                    const wn = protocol.WireNode{
                        .name = n.name,
                        .name_len = n.name_len,
                        .pid = n.pid,
                        .status = @intFromEnum(n.status),
                        .start_time = n.start_time,
                        .restart_count = n.restart_count,
                        .argv_len = @intCast(n.argv_len),
                    };
                    try write_exact(fd, std.mem.asBytes(&wn));
                }
            },
            .list_topics => {
                self.state.sweep_dead();

                const payload_len = self.state.shm_count * @sizeOf(protocol.WireShmTopic);
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = @intCast(payload_len),
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));

                for (self.state.shm_topics[0..self.state.shm_count]) |t| {
                    const wt = protocol.WireShmTopic{
                        .name = t.name,
                        .name_len = t.name_len,
                        .owner_pid = t.owner_pid,
                        .msg_size = t.msg_size,
                        .capacity = t.capacity,
                        .tos = t.tos,
                    };
                    try write_exact(fd, std.mem.asBytes(&wt));
                }
            },
            .list_net => {
                self.state.sweep_dead();

                const payload_len = self.state.net_count * @sizeOf(protocol.WireNetChannel);
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = @intCast(payload_len),
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));

                for (self.state.net_channels[0..self.state.net_count]) |net| {
                    const wn = protocol.WireNetChannel{
                        .name = net.name,
                        .name_len = net.name_len,
                        .owner_pid = net.owner_pid,
                        .port = net.port,
                        .msg_size = net.msg_size,
                        .capacity = net.capacity,
                        .tos = net.tos,
                    };
                    try write_exact(fd, std.mem.asBytes(&wn));
                }
            },
            .launch => {
                var off: usize = 0;
                if (payload.len < 4) return error.InvalidPayload;
                const node_count = std.mem.readInt(u32, payload[off..][0..4], .little);
                off += 4;

                var spawned_count: u32 = 0;
                var idx: u32 = 0;
                while (idx < node_count) : (idx += 1) {
                    if (off + 4 > payload.len) break;
                    const name_len = std.mem.readInt(u32, payload[off..][0..4], .little);
                    off += 4;
                    if (off + name_len > payload.len or name_len > 63) break;
                    const name = payload[off .. off + name_len];
                    off += name_len;

                    if (off + 4 > payload.len) break;
                    const argc = std.mem.readInt(u32, payload[off..][0..4], .little);
                    off += 4;

                    var argv_ptrs: [32][]const u8 = undefined;
                    var arg_i: u32 = 0;
                    var valid = true;
                    while (arg_i < argc) : (arg_i += 1) {
                        if (off + 4 > payload.len) {
                            valid = false;
                            break;
                        }
                        const arg_len = std.mem.readInt(u32, payload[off..][0..4], .little);
                        off += 4;
                        if (off + arg_len > payload.len or arg_i >= argv_ptrs.len) {
                            valid = false;
                            break;
                        }
                        argv_ptrs[arg_i] = payload[off .. off + arg_len];
                        off += arg_len;
                    }
                    if (!valid) break;

                    _ = supervisor.spawn_node(self.io, self.state, name, argv_ptrs[0..argc], constants.LOGS_DIR) catch |err| {
                        std.log.err("Failed to spawn node '{s}': {}", .{ name, err });
                        continue;
                    };
                    spawned_count += 1;
                }

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = if (spawned_count == node_count) 0 else 1,
                    .payload_len = 4,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
                try write_exact(fd, std.mem.asBytes(&spawned_count));
            },
            .stop_node => {
                const name = std.mem.trim(u8, payload, "\x00");
                const ok = supervisor.stop_node(self.io, self.state, name) catch false;

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = if (ok) 0 else 1,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .start_node => {
                const name = std.mem.trim(u8, payload, "\x00");
                const node_opt = self.state.find_node(name);

                var ok = false;
                if (node_opt) |n| {
                    var args_buf: [constants.MAX_ARGV][]const u8 = undefined;
                    var argc: usize = 0;
                    var it = std.mem.splitScalar(u8, n.argv_buf[0..n.argv_len], 0);
                    while (it.next()) |arg| {
                        if (arg.len == 0) continue;
                        if (argc >= args_buf.len) break;
                        args_buf[argc] = arg;
                        argc += 1;
                    }

                    if (argc > 0) {
                        _ = supervisor.spawn_node(self.io, self.state, name, args_buf[0..argc], constants.LOGS_DIR) catch false;
                        ok = true;
                    }
                }

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = if (ok) 0 else 1,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .register_shm => {
                if (payload.len >= @sizeOf(protocol.WireShmTopic)) {
                    const wt: *const protocol.WireShmTopic = @ptrCast(@alignCast(payload.ptr));
                    var entry = state.ShmTopic{
                        .name_len = wt.name_len,
                        .owner_pid = wt.owner_pid,
                        .msg_size = wt.msg_size,
                        .capacity = wt.capacity,
                        .tos = wt.tos,
                    };
                    const name_slice = wt.name[0..@min(wt.name_len, 63)];
                    state.set_name(state.ShmTopic, &entry, name_slice);

                    self.state.register_shm(entry);
                }
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .unregister_shm => {
                const name = std.mem.trim(u8, payload, "\x00");
                self.state.unregister_shm(name);

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .register_net => {
                if (payload.len >= @sizeOf(protocol.WireNetChannel)) {
                    const wn: *const protocol.WireNetChannel = @ptrCast(@alignCast(payload.ptr));
                    var entry = state.NetChannel{
                        .name_len = wn.name_len,
                        .owner_pid = wn.owner_pid,
                        .port = wn.port,
                        .msg_size = wn.msg_size,
                        .capacity = wn.capacity,
                        .tos = wn.tos,
                    };
                    const name_slice = wn.name[0..@min(wn.name_len, 63)];
                    state.set_name(state.NetChannel, &entry, name_slice);

                    self.state.register_net(entry);
                }
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .unregister_net => {
                const name = std.mem.trim(u8, payload, "\x00");
                self.state.unregister_net(name);

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            .shutdown => {
                supervisor.stop_all(self.io, self.state);
                self.running.store(false, .release);

                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 0,
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
            else => {
                const resp_hdr = protocol.Header{
                    .magic = protocol.GLUD_MAGIC,
                    .cmd = @intFromEnum(protocol.Cmd.response),
                    .status = 2, // unknown cmd
                    .payload_len = 0,
                };
                try write_exact(fd, std.mem.asBytes(&resp_hdr));
            },
        }
    }

    fn read_exact(fd: i32, buf: []u8) !void {
        var read_bytes: usize = 0;
        while (read_bytes < buf.len) {
            const rc = c.read(fd, buf[read_bytes..].ptr, buf.len - read_bytes);
            if (rc <= 0) return error.ConnectionClosed;
            read_bytes += @intCast(rc);
        }
    }

    fn write_exact(fd: i32, buf: []const u8) !void {
        var written: usize = 0;
        while (written < buf.len) {
            const rc = c.write(fd, buf[written..].ptr, buf.len - written);
            if (rc <= 0) return error.WriteFailed;
            written += @intCast(rc);
        }
    }
};

const socklen_t = u32;
