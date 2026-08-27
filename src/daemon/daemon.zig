const std = @import("std");
const os = std.os.linux;
const c = std.c;
const state = @import("state.zig");
const server = @import("server.zig");
const supervisor = @import("supervisor.zig");

var global_server: ?*server.Server = null;

fn handle_signal(sig: os.SIG) callconv(.c) void {
    _ = sig;
    if (global_server) |srv| {
        srv.running.store(false, .release);
        if (srv.sock_fd != -1) {
            _ = os.close(srv.sock_fd);
            srv.sock_fd = -1;
        }
    }
}

pub fn daemon_main(init: std.process.Init) !void {
    var stated = state.DaemonState.init();
    var serverd = try state.Server.init(init.io, &state);
    defer server.deinit();

    global_server = &serverd;

    var sa: os.Sigaction = .{
        .handler = .{ .handler = handle_signal },
        .mask = os.sigemptyset(),
        .flags = 0,
    };
    _ = os.sigaction(os.SIG.INT, &sa, null);
    _ = os.sigaction(os.SIG.TERM, &sa, null);

    std.log.info("glud daemon started, listening on /tmp/glu/glud.sock", .{});
    server.run();

    supervisor.stop_all(init.io, &stated);
    std.log.info("glud daemon stopped", .{});
}
