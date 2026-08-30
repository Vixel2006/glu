const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

const IO = @import("../io.zig");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");

const Server = struct {
    io: *IO.IO,
    socket: posix.socket_t,

    pub fn init(io: *IO.IO) Server {
        const fd: posix.socket_t =
            io.socket(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.DGRAM), 0) catch |err| {
                log.err("Daemon Server: can't init a unix socket: {s}", .{@errorName(err)});
            };

        const addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = constants.DAEMON_SOCK,
        };

        io.bind(fd, addr) catch |err| {
            log.err("Daemon Server: can't bind daemon server socket: {s}", .{@errorName(err)});
        };
        errdefer linux.close(fd);

        return .{ .io = io, .socket = fd };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
    }

    pub fn handle_request(self: *Server) void {
        var fut: IO.Future = undefined;
        var buf: [1024]u8 = undefined;

        try self.io.recv(&fut, self.socket, &buf);
        _ = try self.io.wait(&fut, usize);

        const cmd = std.mem.bytesAsValue(protocol.CMD, buf[0..@sizeOf(protocol.CMD)]);
        switch (cmd) {
            .PING => {
                // TODO: here we should do the ping
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
