const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protoocl = @import("protocol.zig");

const Client = struct {
    io: *IO.IO,
    socket: posix.socket_t,

    pub fn init(io: *IO.IO, path: []const u8) !Client {
        const fd: posix.socket_t =
            try io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);

        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..path.len], path);

        const un_addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = path_buf,
        };
        errdefer _ = linux.close(fd);

        const addr: IO.ConnectAddress = .{ .unix = un_addr };

        io.bind(fd, addr) catch |err| {
            log.err("Daemon client can't bind socket: {s}", .{@errorName(err)});
        };

        return .{ .io = io, .socket = fd };
    }

    pub fn deinit(self: *Client) void {
        _ = linux.close(self.socket);
    }

    pub fn connect(self: *Client, fut: *IO.IO.Future) !void {
        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);
        const addr: IO.ConnectAddress = .{
            .unix = .{
                .family = posix.AF.UNIX,
                .path = path_buf,
            },
        };
        self.io.connect(fut, self.socket, addr) catch |err| {
            log.err("can't connect to daemon server: {s}", .{@errorName(err)});
        };
    }

    pub fn send(self: *Client, fut: *IO.IO.Future, buf: []const u8) void {
        self.io.send(fut, self.socket, buf) catch |err| {
            log.err("client can't send message to daemon server: {s}", .{@errorName(err)});
        };
    }

    pub fn recv(self: *Client, fut: *IO.IO.Future, buf: []u8) void {
        self.io.recv(fut, self.socket, buf) catch |err| {
            log.err("client can't recieve message from daemon server: {s}", .{@errorName(err)});
        };
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

    cwd.deleteFile(cwd_io, "/tmp/glu/test.sock") catch {};
    var client: Client = try Client.init(&parent_io, "/tmp/glu/test.sock");
    defer client.deinit();

    var conn_fut: IO.IO.Future = undefined;
    try client.connect(&conn_fut);

    const send_buf = "Hello, World!";
    var send_fut: IO.IO.Future = undefined;
    client.send(&send_fut, send_buf);
    _ = try parent_io.wait(&send_fut, usize);

    var status: c_int = undefined;
    _ = c.waitpid(pid, &status, 0);
    _ = linux.close(fd);
}
