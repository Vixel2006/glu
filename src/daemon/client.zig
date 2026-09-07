const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");

/// How many connect attempts a best-effort daemon notification makes before
/// giving up. Each failed attempt costs roughly a millisecond.
const CONNECT_ATTEMPTS: u32 = 3;

/// Size of the largest request payload (`protocol.Node`).
const MAX_REQUEST = @sizeOf(protocol.Node);

pub const ClientErr = error{
    DaemonNotRunning,
    ConnectionFailed,
    ConnectionClosed,
};

pub const Client = struct {
    io: *IO.IO,
    socket: posix.socket_t,

    pub fn init(io: *IO.IO) !Client {
        const fd: posix.socket_t =
            try io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);
        errdefer _ = linux.close(fd);

        return .{ .io = io, .socket = fd };
    }

    pub fn deinit(self: *Client) void {
        _ = linux.close(self.socket);
    }

    pub fn connect(self: *Client, max_attempts: u32) !void {
        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);
        const addr: IO.ConnectAddress = .{
            .unix = .{
                .family = posix.AF.UNIX,
                .path = path_buf,
            },
        };

        var ts: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };

        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            var fut: IO.IO.Future = undefined;
            try self.io.connect(&fut, self.socket, addr);
            if (self.io.wait(&fut, void)) |_| {
                return;
            } else |_| {
                var t: IO.IO.Future = undefined;
                self.io.timeout(&t, &ts, 0) catch {};
                self.io.wait(&t, void) catch {};
            }
        }

        return error.ConnectionFailed;
    }

    pub fn send(self: *Client, fut: *IO.IO.Future, buf: []const u8) !void {
        try self.io.send(fut, self.socket, buf);
    }

    pub fn recv(self: *Client, fut: *IO.IO.Future, buf: []u8) !void {
        try self.io.recv(fut, self.socket, buf);
    }

    pub fn daemon_running() bool {
        return std.c.access(constants.DAEMON_SOCK.ptr, std.c.F_OK) == 0;
    }

    pub fn ensure_running(io: *IO.IO) ClientErr!Client {
        if (!daemon_running()) return error.ConnectionFailed;

        var client = Client.init(io) catch return error.ConnectionFailed;
        errdefer client.deinit();
        client.connect(CONNECT_ATTEMPTS) catch return error.ConnectionFailed;
        return client;
    }

    pub fn notify(io: *IO.IO, comptime cmd: protocol.CMD, payload: []const u8) !void {
        if (!daemon_running()) return;
        var client = try Client.init(io);
        defer client.deinit();
        client.connect(CONNECT_ATTEMPTS) catch return;
        try client.request(cmd, payload);
    }

    fn recv_full(self: *Client, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            var fut: IO.IO.Future = undefined;
            try self.io.recv(&fut, self.socket, dest[off..]);
            const n = try self.io.wait(&fut, usize);
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    pub fn request(self: *Client, comptime cmd: protocol.CMD, payload: []const u8) !void {
        assert(payload.len <= MAX_REQUEST);
        var buf: [1 + MAX_REQUEST]u8 = undefined;
        buf[0] = @intFromEnum(cmd);
        @memcpy(buf[1..][0..payload.len], payload);

        var fut: IO.IO.Future = undefined;
        try self.send(&fut, buf[0 .. 1 + payload.len]);
        _ = try self.io.wait(&fut, usize);
    }

    pub fn exchange(self: *Client, comptime cmd: protocol.CMD, req: []const u8, resp: []u8) !usize {
        try self.request(cmd, req);

        var hdr: [4]u8 = undefined;
        try self.recv_full(&hdr);
        const len = std.mem.bytesAsValue(u32, &hdr).*;
        const take = @min(@as(usize, len), resp.len);
        if (take > 0) try self.recv_full(resp[0..take]);
        return take;
    }

    pub fn ping(self: *Client) !void {
        _ = try self.exchange(.PING, "", &.{});
    }

    fn action(self: *Client, comptime cmd: protocol.CMD, name: []const u8) !bool {
        var name_buf: protocol.NODE_NAME = std.mem.zeroes(protocol.NODE_NAME);
        const len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..len], name[0..len]);
        var resp: [1]u8 = undefined;
        const n = try self.exchange(cmd, &name_buf, &resp);
        return n == 1 and resp[0] != 0;
    }

    pub fn start_node(self: *Client, name: []const u8) !bool {
        return self.action(.START_NODE, name);
    }

    pub fn stop_node(self: *Client, name: []const u8) !bool {
        return self.action(.STOP_NODE, name);
    }

    pub fn restart_node(self: *Client, name: []const u8) !bool {
        return self.action(.RESTART_NODE, name);
    }

    pub fn launch(self: *Client, nodes: []const protocol.Node) !void {
        for (nodes) |*n| {
            var resp: [1]u8 = undefined;
            _ = try self.exchange(.SPAWN_NODE, std.mem.asBytes(n), &resp);
        }
    }

    pub fn list_nodes(self: *Client, out: []protocol.Node) !usize {
        const n = try self.exchange(.LIST_NODES, "", std.mem.sliceAsBytes(out));
        return n / @sizeOf(protocol.Node);
    }

    pub fn list_topics(self: *Client, out: []protocol.SHM_CHAN) !usize {
        const n = try self.exchange(.LIST_TOPICS, "", std.mem.sliceAsBytes(out));
        return n / @sizeOf(protocol.SHM_CHAN);
    }

    pub fn list_net(self: *Client, out: []protocol.NET_CHAN) !usize {
        const n = try self.exchange(.LIST_NET, "", std.mem.sliceAsBytes(out));
        return n / @sizeOf(protocol.NET_CHAN);
    }

    pub fn register_shm(self: *Client, req: *const protocol.SHM_CHAN) !void {
        try self.request(.REG_SHM, std.mem.asBytes(req));
    }

    pub fn unregister_shm(self: *Client, name: *const protocol.SHM_NAME) !void {
        try self.request(.UNREG_SHM, std.mem.asBytes(name));
    }

    pub fn register_net(self: *Client, req: *const protocol.NET_CHAN) !void {
        try self.request(.REG_NET, std.mem.asBytes(req));
    }

    pub fn unregister_net(self: *Client, name: *const protocol.NET_NAME) !void {
        try self.request(.UNREG_NET, std.mem.asBytes(name));
    }
};

test "connect a client to daemon server and send a message" {
    const c = std.c;
    var io: IO.IO = try IO.IO.init(64, 0);

    const cwd_io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(cwd_io, "/tmp/glu");

    const fd: posix.socket_t =
        try io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);

    const DAEMON_SOCK = "/tmp/glu/glud.sock";
    var path_buf: [108]u8 = [_]u8{0} ** 108;
    @memcpy(path_buf[0..DAEMON_SOCK.len], DAEMON_SOCK);

    const addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = path_buf,
    };

    const conn_addr: IO.ConnectAddress = .{
        .unix = addr,
    };

    cwd.deleteFile(cwd_io, DAEMON_SOCK) catch {};
    defer cwd.deleteFile(cwd_io, DAEMON_SOCK) catch {};
    try io.bind(fd, conn_addr);
    defer _ = linux.close(fd);
    errdefer _ = linux.close(fd);

    try io.listen(fd, 0);

    const pid = c.fork();
    if (pid == 0) {
        // --- child: server (accept + recv) ---
        var child_io: IO.IO = try IO.IO.init(64, 0);
        defer child_io.deinit();

        var accept_fut: IO.IO.Future = undefined;
        _ = try child_io.accept(&accept_fut, fd);
        const client_fd = try child_io.wait(&accept_fut, posix.socket_t);

        var read_buf: [256]u8 = undefined;
        var recv_fut: IO.IO.Future = undefined;
        try child_io.recv(&recv_fut, client_fd, &read_buf);
        const len = try child_io.wait(&recv_fut, usize);

        const send_buf = "Hello, World!";
        try std.testing.expect(std.mem.eql(u8, send_buf, read_buf[0..len]));

        _ = linux.close(client_fd);
        c.exit(0);
    }

    // --- parent: client (connect + send) ---
    var parent_io: IO.IO = try IO.IO.init(64, 0);
    defer parent_io.deinit();

    var client: Client = try Client.init(&parent_io);
    defer client.deinit();

    try client.connect(100);

    const send_buf = "Hello, World!";
    var send_fut: IO.IO.Future = undefined;
    try client.send(&send_fut, send_buf);
    _ = try parent_io.wait(&send_fut, usize);

    var status: c_int = undefined;
    _ = c.waitpid(pid, &status, 0);
    _ = linux.close(fd);
}
