const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");
const Inventory = @import("inventory.zig").Inventory;

const Server = struct {
    io: *IO.IO,
    socket: posix.socket_t = -1,
    inventory: Inventory,
    allocator: std.mem.Allocator,
    payloads: std.ArrayList([]align(8) u8),

    pub fn init(io: *IO.IO, allocator: std.mem.Allocator) !Server {
        return .{
            .io = io,
            .allocator = allocator,
            .inventory = Inventory.init(allocator),
            .payloads = .empty,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.payloads.items) |blob| self.allocator.free(blob);
        self.payloads.deinit(self.allocator);
        self.inventory.deinit();
        if (self.socket != -1) _ = linux.close(self.socket);
    }

    pub fn listen(self: *Server, backlog: u32) !void {
        const fd: posix.socket_t =
            try self.io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);
        errdefer _ = linux.close(fd);
        self.socket = fd;

        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);

        const addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = path_buf,
        };

        try self.io.bind(fd, IO.ConnectAddress{ .unix = addr });
        try self.io.listen(fd, backlog);

        //while (true) {
        var fut: IO.IO.Future = undefined;
        try self.io.accept(&fut, self.socket);
        const client_fd = try self.io.wait(&fut, posix.socket_t);
        defer _ = linux.close(client_fd);

        try self.handle_request(client_fd);
        //}
    }

    /// Copy the payload into daemon-owned storage so name keys used by the
    /// inventory stay valid after the request buffer is gone.
    fn persist(self: *Server, comptime T: type, bytes: []const u8) !*T {
        const blob = try self.allocator.alignedAlloc(u8, std.mem.Alignment.of(protocol.Node), @sizeOf(T));
        @memcpy(blob, bytes);
        errdefer self.allocator.free(blob);
        try self.payloads.append(self.allocator, blob);
        return @ptrCast(blob.ptr);
    }

    pub fn handle_request(self: *Server, client_fd: posix.socket_t) !void {
        var fut: IO.IO.Future = undefined;
        var buf: [1024]u8 = undefined;

        try self.io.recv(&fut, client_fd, &buf);
        const len = try self.io.wait(&fut, usize);
        const data = buf[0..len];

        fut = undefined;
        const cmd = std.mem.bytesAsValue(protocol.CMD, data[0..@sizeOf(protocol.CMD)]);
        switch (cmd.*) {
            .PING => {
                try self.io.send(&fut, client_fd, "");
                _ = try self.io.wait(&fut, usize);
            },
            .START_NODE => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.Node)) return error.ShortMessage;
                const node = try self.persist(protocol.Node, data[off .. off + @sizeOf(protocol.Node)]);
                self.inventory.start_node(node) catch |e| log.err("start node: {s}", .{@errorName(e)});
            },
            .STOP_NODE => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.NODE_NAME)) return error.ShortMessage;
                var name = std.mem.bytesToValue(protocol.NODE_NAME, data[off .. off + @sizeOf(protocol.NODE_NAME)]);
                self.inventory.stop_node(std.mem.sliceTo(name[0..], 0));
            },
            .RESTART_NODE => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.NODE_NAME)) return error.ShortMessage;
                var name = std.mem.bytesToValue(protocol.NODE_NAME, data[off .. off + @sizeOf(protocol.NODE_NAME)]);
                self.inventory.restart_node(std.mem.sliceTo(name[0..], 0));
            },
            .REG_SHM => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.SHM_CHAN)) return error.ShortMessage;
                const req = try self.persist(protocol.SHM_CHAN, data[off .. off + @sizeOf(protocol.SHM_CHAN)]);
                self.inventory.register_shm(req);
            },
            .UNREG_SHM => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.SHM_NAME)) return error.ShortMessage;
                var name = std.mem.bytesToValue(protocol.SHM_NAME, data[off .. off + @sizeOf(protocol.SHM_NAME)]);
                self.inventory.unregister_shm(&name);
            },
            .REG_NET => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.NET_CHAN)) return error.ShortMessage;
                const req = try self.persist(protocol.NET_CHAN, data[off .. off + @sizeOf(protocol.NET_CHAN)]);
                self.inventory.register_net(req);
            },
            .UNREG_NET => {
                const off = @sizeOf(protocol.CMD);
                if (data.len < off + @sizeOf(protocol.NET_NAME)) return error.ShortMessage;
                var name = std.mem.bytesToValue(protocol.NET_NAME, data[off .. off + @sizeOf(protocol.NET_NAME)]);
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

fn send_request(io: *IO.IO, server: *Server, payload: []const u8) !void {
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
}

test "daemon handles PING and replies" {
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
    try send_request(&io, &server, &payload);

    const entry = server.inventory.alive_shm.get(name) orelse return error.NotRegistered;
    try std.testing.expectEqual(@as(u32, 2048), entry.msg_size);
    try std.testing.expectEqual(@as(u32, 16), entry.capacity);

    var unreg: protocol.SHM_NAME = std.mem.zeroes(protocol.SHM_NAME);
    @memcpy(unreg[0..name.len], name);
    const unreg_payload = cmd_buffer(.UNREG_SHM, unreg);
    try send_request(&io, &server, &unreg_payload);

    try std.testing.expect(server.inventory.alive_shm.get(name) == null);
    try std.testing.expect(server.inventory.dead_shm.get(name) != null);
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
    try send_request(&io, &server, &payload);

    const entry = server.inventory.alive_shm.get(name) orelse return error.NotRegistered;
    try std.testing.expectEqual(@as(u32, 2048), entry.msg_size);
    try std.testing.expectEqual(@as(u32, 16), entry.capacity);

    var unreg: protocol.SHM_NAME = std.mem.zeroes(protocol.SHM_NAME);
    @memcpy(unreg[0..name.len], name);
    const unreg_payload = cmd_buffer(.UNREG_SHM, unreg);
    try send_request(&io, &server, &unreg_payload);

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

    const payload = cmd_buffer(.REG_NET, reg);
    try send_request(&io, &server, &payload);

    const entry = server.inventory.alive_net.get(name) orelse return error.NotRegistered;
    try std.testing.expectEqual(@as(u32, 512), entry.msg_size);
    try std.testing.expectEqual(@as(u16, 49152), entry.port);

    var unreg: protocol.NET_NAME = std.mem.zeroes(protocol.NET_NAME);
    @memcpy(unreg[0..name.len], name);
    const unreg_payload = cmd_buffer(.UNREG_NET, unreg);
    try send_request(&io, &server, &unreg_payload);

    try std.testing.expect(server.inventory.alive_net.get(name) == null);
    try std.testing.expect(server.inventory.dead_net.get(name) != null);
}

test "daemon handles START_NODE, STOP_NODE and RESTART_NODE" {
    var io: IO.IO = try IO.IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.testing.allocator);
    defer server.deinit();

    const name = "node_alpha";

    const node = protocol.Node{
        .name = name,
        .path = "",
        .bin = "/bin/true",
        .extra_cfg = .{""} ** constants.MAX_ARGS,
        .pid = null,
        .uptime = null,
    };
    const start_payload = cmd_buffer(.START_NODE, node);
    try send_request(&io, &server, &start_payload);

    const entry = server.inventory.alive_nodes.get(name) orelse return error.NotStarted;
    try std.testing.expect(entry.pid != null);

    var stop_name: protocol.NODE_NAME = std.mem.zeroes(protocol.NODE_NAME);
    @memcpy(stop_name[0..name.len], name);
    const stop_payload = cmd_buffer(.STOP_NODE, stop_name);
    try send_request(&io, &server, &stop_payload);

    try std.testing.expect(server.inventory.alive_nodes.get(name) == null);
    try std.testing.expect(server.inventory.dead_nodes.get(name) != null);

    const restart_payload = cmd_buffer(.RESTART_NODE, stop_name);
    try send_request(&io, &server, &restart_payload);

    const restarted = server.inventory.alive_nodes.get(name) orelse return error.NotRestarted;
    try std.testing.expect(restarted.pid != null);
}
