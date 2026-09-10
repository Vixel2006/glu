const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");
const Inventory = @import("inventory.zig").Inventory;

pub const Server = struct {
    io: *IO.IO,
    socket: posix.socket_t = -1,
    inventory: Inventory,

    pub fn init(io: *IO.IO, allocator: std.mem.Allocator) !Server {
        return .{
            .io = io,
            .inventory = Inventory.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.inventory.deinit();
        if (self.socket != -1) _ = linux.close(self.socket);
    }

    pub fn listen(self: *Server, backlog: u32) !void {
        const fd: posix.socket_t =
            try self.io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);
        errdefer _ = linux.close(fd);
        self.socket = fd;

        // A previous crash may have left a stale socket file behind.
        _ = linux.unlink(constants.DAEMON_SOCK.ptr);

        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);

        const addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = path_buf,
        };

        try self.io.bind(fd, IO.ConnectAddress{ .unix = addr });
        try self.io.listen(fd, backlog);

        while (true) {
            var fut: IO.IO.Future = undefined;
            try self.io.accept(&fut, self.socket);
            const client_fd = try self.io.wait(&fut, posix.socket_t);

            // Serve every request until the client hangs up. Session clients
            // like `launch` issue many requests over one connection.
            while (true) {
                self.handle_request(client_fd) catch |err| {
                    if (err != error.ConnectionClosed)
                        log.err("closing client after failed request: {s}", .{@errorName(err)});
                    break;
                };
            }
            _ = linux.close(client_fd);
        }
    }

    fn read_full(self: *Server, client_fd: posix.socket_t, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            var fut: IO.IO.Future = undefined;
            try self.io.recv(&fut, client_fd, dest[off..]);
            const n = try self.io.wait(&fut, usize);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    fn reply(self: *Server, client_fd: posix.socket_t, payload: []const u8) !void {
        var hdr: [4]u8 = undefined;
        @memcpy(&hdr, std.mem.asBytes(&@as(u32, @intCast(payload.len))));
        var fut: IO.IO.Future = undefined;
        try self.io.send(&fut, client_fd, &hdr);
        _ = try self.io.wait(&fut, usize);
        if (payload.len > 0) {
            fut = undefined;
            try self.io.send(&fut, client_fd, payload);
            _ = try self.io.wait(&fut, usize);
        }
    }

    fn payload_len(cmd: protocol.CMD) usize {
        return switch (cmd) {
            .PING, .LIST_NODES, .LIST_TOPICS, .LIST_NET => 0,
            .SPAWN_NODE => @sizeOf(protocol.Node),
            .START_NODE, .STOP_NODE, .RESTART_NODE => @sizeOf(protocol.NODE_NAME),
            .REG_SHM => @sizeOf(protocol.SHM_CHAN),
            .UNREG_SHM => @sizeOf(protocol.SHM_NAME),
            .REG_NET => @sizeOf(protocol.NET_CHAN),
            .UNREG_NET => @sizeOf(protocol.NET_NAME),
        };
    }

    fn name_action(self: *Server, client_fd: posix.socket_t, data: []const u8, op: *const fn (*Inventory, []const u8) bool) !void {
        var name = std.mem.bytesToValue(protocol.NODE_NAME, data);
        try self.reply(client_fd, &[_]u8{@intFromBool(op(&self.inventory, std.mem.sliceTo(name[0..], 0)))});
    }

    pub fn handle_request(self: *Server, client_fd: posix.socket_t) !void {
        var buf: [4096]u8 = undefined;

        var cmd_buf: [1]u8 = undefined;
        try self.read_full(client_fd, &cmd_buf);
        const cmd: protocol.CMD = @enumFromInt(cmd_buf[0]);
        const rest_len = payload_len(cmd);
        if (rest_len > 0) try self.read_full(client_fd, buf[0..rest_len]);
        const data = buf[0..rest_len];

        switch (cmd) {
            .PING => try self.reply(client_fd, ""),
            .SPAWN_NODE => {
                var node: protocol.Node = undefined;
                @memcpy(std.mem.asBytes(&node), data);
                self.inventory.spawn_node(&node) catch |e| {
                    log.err("start node: {s}", .{@errorName(e)});
                    try self.reply(client_fd, &[_]u8{@intFromBool(false)});
                    return;
                };
                try self.reply(client_fd, &[_]u8{@intFromBool(true)});
            },
            .START_NODE => try self.name_action(client_fd, data, &Inventory.start_node),
            .STOP_NODE => try self.name_action(client_fd, data, &Inventory.stop_node),
            .RESTART_NODE => try self.name_action(client_fd, data, &Inventory.restart_node),
            .LIST_NODES => {
                var entries: [constants.MAX_ENTRIES]protocol.Node = undefined;
                const count = self.inventory.list_nodes(&entries);
                try self.reply(client_fd, std.mem.sliceAsBytes(entries[0..count]));
            },
            .LIST_TOPICS => {
                var entries: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
                const count = self.inventory.list_shm(&entries);
                try self.reply(client_fd, std.mem.sliceAsBytes(entries[0..count]));
            },
            .LIST_NET => {
                var entries: [constants.MAX_ENTRIES]protocol.NET_CHAN = undefined;
                const count = self.inventory.list_net(&entries);
                try self.reply(client_fd, std.mem.sliceAsBytes(entries[0..count]));
            },
            .REG_SHM => {
                var req: protocol.SHM_CHAN = undefined;
                @memcpy(std.mem.asBytes(&req), data);
                self.inventory.register_shm(&req);
            },
            .UNREG_SHM => {
                var name = std.mem.bytesToValue(protocol.SHM_NAME, data);
                self.inventory.unregister_shm(&name);
            },
            .REG_NET => {
                var req: protocol.NET_CHAN = undefined;
                @memcpy(std.mem.asBytes(&req), data);
                self.inventory.register_net(&req);
            },
            .UNREG_NET => {
                var name = std.mem.bytesToValue(protocol.NET_NAME, data);
                self.inventory.unregister_net(&name);
            },
        }
    }
};

fn cmd_buffer(comptime cmd: protocol.CMD, payload: anytype) [@sizeOf(protocol.CMD) + @sizeOf(@TypeOf(payload))]u8 {
    var buf: [@sizeOf(protocol.CMD) + @sizeOf(@TypeOf(payload))]u8 = undefined;
    buf[0] = @intFromEnum(cmd);
    @memcpy(buf[@sizeOf(protocol.CMD)..], std.mem.asBytes(&payload));
    return buf;
}

fn recv_full(io: *IO.IO, fd: posix.socket_t, dest: []u8) !void {
    var off: usize = 0;
    while (off < dest.len) {
        var fut: IO.IO.Future = undefined;
        try io.recv(&fut, fd, dest[off..]);
        const n = try io.wait(&fut, usize);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

/// Send a frame to an in-process server and optionally read its reply.
/// Commands that never reply (REG_*/UNREG_*) must pass `resp = null`.
fn send_request(io: *IO.IO, server: *Server, payload: []const u8, resp: ?[]u8) !usize {
    var fds: [2]posix.socket_t = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    var fut: IO.IO.Future = undefined;
    try io.send(&fut, fds[1], payload);
    _ = try io.wait(&fut, usize);

    try server.handle_request(fds[0]);

    if (resp) |rb| {
        var hdr: [4]u8 = undefined;
        try recv_full(io, fds[1], &hdr);
        const resp_len = std.mem.bytesAsValue(u32, &hdr).*;
        const take = @min(@as(usize, resp_len), rb.len);
        if (take > 0) try recv_full(io, fds[1], rb[0..take]);
        return take;
    }
    return 0;
}

fn test_node(comptime name: []const u8) protocol.Node {
    var node = std.mem.zeroes(protocol.Node);
    @memcpy(node.name[0..name.len], name);
    node.name_len = @intCast(name.len);
    @memcpy(node.bin[0.."/bin/true".len], "/bin/true");
    node.bin_len = "/bin/true".len;
    return node;
}

test "daemon handles REG_SHM and UNREG_SHM" {
    var io: IO.IO = try IO.IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.testing.allocator);
    defer server.deinit();

    const name = "shm_chan";

    var reg: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(reg.name[0..name.len], name);
    reg.name_len = @intCast(name.len);
    reg.writer_pid = 42;
    reg.msg_size = 2048;
    reg.capacity = 16;

    const payload = cmd_buffer(.REG_SHM, reg);
    _ = try send_request(&io, &server, &payload, null);

    const entry = server.inventory.alive_shm.get(name) orelse return error.NotRegistered;
    try std.testing.expectEqual(@as(u32, 2048), entry.msg_size);
    try std.testing.expectEqual(@as(u32, 16), entry.capacity);

    var unreg: protocol.SHM_NAME = std.mem.zeroes(protocol.SHM_NAME);
    @memcpy(unreg[0..name.len], name);
    _ = try send_request(&io, &server, &cmd_buffer(.UNREG_SHM, unreg), null);

    try std.testing.expect(server.inventory.alive_shm.get(name) == null);
    try std.testing.expect(server.inventory.dead_shm.get(name) != null);
}

test "daemon handles REG_NET and UNREG_NET" {
    var io: IO.IO = try IO.IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.testing.allocator);
    defer server.deinit();

    const name = "net_chan";

    var reg: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(reg.name[0..name.len], name);
    reg.name_len = @intCast(name.len);
    reg.msg_size = 512;
    reg.capacity = 4;
    reg.num_reg = 1;
    reg.port = 49152;
    reg.writer_pid = 7;
    reg.tos = 1;

    _ = try send_request(&io, &server, &cmd_buffer(.REG_NET, reg), null);

    const entry = server.inventory.alive_net.get(name) orelse return error.NotRegistered;
    try std.testing.expectEqual(@as(u32, 512), entry.msg_size);
    try std.testing.expectEqual(@as(u16, 49152), entry.port);
    try std.testing.expectEqual(@as(u32, 7), entry.writer_pid);
    try std.testing.expectEqual(@as(u32, 1), entry.tos);

    var unreg: protocol.NET_NAME = std.mem.zeroes(protocol.NET_NAME);
    @memcpy(unreg[0..name.len], name);
    _ = try send_request(&io, &server, &cmd_buffer(.UNREG_NET, unreg), null);

    try std.testing.expect(server.inventory.alive_net.get(name) == null);
    try std.testing.expect(server.inventory.dead_net.get(name) != null);
}

test "daemon starts, stops and restarts nodes, replying with success" {
    var io: IO.IO = try IO.IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.testing.allocator);
    defer server.deinit();

    const name = "node_alpha";

    var resp: [1]u8 = undefined;
    const started = try send_request(&io, &server, &cmd_buffer(.SPAWN_NODE, test_node(name)), &resp);
    try std.testing.expectEqual(@as(usize, 1), started);
    try std.testing.expectEqual(@as(u8, 1), resp[0]);

    const entry = server.inventory.alive_node(name) orelse return error.NotStarted;
    try std.testing.expect(entry.pid != null);
    try std.testing.expect(entry.uptime != null);

    var stop_name: protocol.NODE_NAME = std.mem.zeroes(protocol.NODE_NAME);
    @memcpy(stop_name[0..name.len], name);
    const stopped = try send_request(&io, &server, &cmd_buffer(.STOP_NODE, stop_name), &resp);
    try std.testing.expectEqual(@as(u8, 1), resp[0]);
    try std.testing.expectEqual(@as(usize, 1), stopped);

    try std.testing.expect(server.inventory.alive_node(name) == null);
    try std.testing.expect(server.inventory.dead_node(name) != null);

    const restarted = try send_request(&io, &server, &cmd_buffer(.RESTART_NODE, stop_name), &resp);
    try std.testing.expectEqual(@as(u8, 1), resp[0]);
    try std.testing.expectEqual(@as(usize, 1), restarted);

    const alive = server.inventory.alive_node(name) orelse return error.NotRestarted;
    try std.testing.expect(alive.pid != null);
}

test "daemon answers list queries from the inventory" {
    var io: IO.IO = try IO.IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.testing.allocator);
    defer server.deinit();

    const shm_name = "shm_a";
    var shm: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(shm.name[0..shm_name.len], shm_name);
    shm.name_len = @intCast(shm_name.len);
    shm.msg_size = 128;
    shm.capacity = 4;
    _ = try send_request(&io, &server, &cmd_buffer(.REG_SHM, shm), null);

    const net_name = "net_a";
    var net_c: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(net_c.name[0..net_name.len], net_name);
    net_c.name_len = @intCast(net_name.len);
    net_c.port = 49152;
    _ = try send_request(&io, &server, &cmd_buffer(.REG_NET, net_c), null);

    var resp: [1]u8 = undefined;
    _ = try send_request(&io, &server, &cmd_buffer(.SPAWN_NODE, test_node("node_a")), &resp);

    var topics: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    const st = try send_request(&io, &server, &cmd_buffer(.LIST_TOPICS, @as(u8, 0)), std.mem.sliceAsBytes(topics[0..]));
    try std.testing.expectEqual(@as(usize, @sizeOf(protocol.SHM_CHAN)), st);
    try std.testing.expectEqualStrings(shm_name, topics[0].name[0..topics[0].name_len]);

    var nets: [constants.MAX_ENTRIES]protocol.NET_CHAN = undefined;
    const sn = try send_request(&io, &server, &cmd_buffer(.LIST_NET, @as(u8, 0)), std.mem.sliceAsBytes(nets[0..]));
    try std.testing.expectEqual(@as(usize, @sizeOf(protocol.NET_CHAN)), sn);
    try std.testing.expectEqualStrings(net_name, nets[0].name[0..nets[0].name_len]);

    var nodes: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const snn = try send_request(&io, &server, &cmd_buffer(.LIST_NODES, @as(u8, 0)), std.mem.sliceAsBytes(nodes[0..]));
    try std.testing.expectEqual(@as(usize, @sizeOf(protocol.Node)), snn);
    try std.testing.expectEqualStrings("node_a", nodes[0].name_slice());
    try std.testing.expectEqualStrings("/bin/true", nodes[0].bin_slice());
}
