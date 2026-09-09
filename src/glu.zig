const std = @import("std");
const posix = std.posix;

threadlocal var running_flag: bool = true;

fn signalHandler(_: posix.SIG) callconv(.c) void {
    running_flag = false;
}

pub const Glu = struct {
    pub fn init() Glu {
        running_flag = true;
        var action: posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };

        posix.sigaction(.INT, &action, null);
        posix.sigaction(.TERM, &action, null);

        return .{};
    }

    pub fn running() bool {
        return running_flag;
    }

    pub fn stop() void {
        running_flag = false;
    }
};
