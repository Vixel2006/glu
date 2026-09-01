const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");
const Client = @import("client.zig").Client;

const Server = struct {
    io: *IO.IO,
    socket: posix.socket_t,

    pub fn init(io: *IO.IO) !Server {
        const fd: posix.socket_t =
            try io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0);

        var path_buf: [108]u8 = [_]u8{0} ** 108;
        @memcpy(path_buf[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);

        const addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = path_buf,
        };

        try io.bind(fd, IO.ConnectAddress{ .unix = addr });
        errdefer _ = linux.close(fd);

        return .{ .io = io, .socket = fd };
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(self.socket);
    }

    pub fn listen(self: *Server, backlog: u32) !void {
        try self.io.listen(self.socket, backlog);

        //while (true) {
        var fut: IO.IO.Future = undefined;
        try self.io.accept(&fut, self.socket);
        const client_fd = try self.io.wait(&fut, posix.socket_t);
        defer _ = linux.close(client_fd);

        try self.handle_request(client_fd);
        //}
    }

    pub fn handle_request(self: *Server, client_fd: posix.socket_t) !void {
        var fut: IO.IO.Future = undefined;
        var buf: [1024]u8 = undefined;

        try self.io.recv(&fut, client_fd, &buf);
        _ = try self.io.wait(&fut, usize);

        fut = undefined;
        const cmd = std.mem.bytesAsValue(protocol.CMD, buf[0..@sizeOf(protocol.CMD)]);
        switch (cmd.*) {
            .PING => {
                try self.io.send(&fut, client_fd, "");
                _ = try self.io.wait(&fut, usize);
            },
            .START_NODE => {
                // TODO: here we should actually start a node,
            },
            .STOP_NODE => {
                // TODO: Here we will stop a node,
            },
            .RESTART_NODE => {
                // TODO: Here we restart a node,
            },
            .REG_SHM => {
                // TODO: Here we handle registering a shared memory channel
            },
            .UNREG_SHM => {
                // TODO: Here we handle un-registering a shared memory channel
            },
            .REG_NET => {
                // TODO: Here we handle registering a network channel
            },
            .UNREG_NET => {
                // TODO: Here we handle un-registering a network channel
            },
        }
    }
};

test "daemon server accepts a PING from the client and replies" {
    const c = std.c;

    var daemon_path: [constants.DAEMON_SOCK.len + 1]u8 = undefined;
    @memcpy(daemon_path[0..constants.DAEMON_SOCK.len], constants.DAEMON_SOCK);
    daemon_path[constants.DAEMON_SOCK.len] = 0;
    _ = linux.unlink(@ptrCast(&daemon_path));

    const test_path = "/tmp/glu/test.sock";
    var test_path_buf: [test_path.len + 1]u8 = undefined;
    @memcpy(test_path_buf[0..test_path.len], test_path);
    test_path_buf[test_path.len] = 0;
    _ = linux.unlink(@ptrCast(&test_path_buf));

    const pid = c.fork();
    if (pid == 0) {
        // --- child: daemon server ---
        var child_io: IO.IO = IO.IO.init(64, 0) catch linux.exit_group(1);
        defer child_io.deinit();

        var server = Server.init(&child_io) catch linux.exit_group(1);
        defer server.deinit();

        server.listen(0) catch linux.exit_group(1);
        linux.exit_group(0);
    }

    // --- parent: client ---
    var client_io: IO.IO = try IO.IO.init(64, 0);
    defer client_io.deinit();

    var client = try Client.init(&client_io, "/tmp/glu/test.sock");
    defer client.deinit();

    try client.connect(100);

    const ping: protocol.CMD = .PING;
    var send_fut: IO.IO.Future = undefined;
    try client.send(&send_fut, std.mem.asBytes(&ping));
    _ = try client_io.wait(&send_fut, usize);

    var recv_fut: IO.IO.Future = undefined;
    var buf: [1024]u8 = undefined;
    try client.recv(&recv_fut, &buf);
    const len = try client_io.wait(&recv_fut, usize);

    try std.testing.expect(len == 0);

    var status: c_int = undefined;
    _ = c.waitpid(pid, &status, 0);
}
