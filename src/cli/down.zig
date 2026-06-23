const std = @import("std");
const c = std.c;
const utils = @import("utils.zig");
const Registry = @import("../registry.zig");

pub fn cmdDown(init: std.process.Init) void {
    cmdDown_(init) catch |err| utils.logErr("down", err);
}

fn cmdDown_(init: std.process.Init) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const entries = Registry.listAlive(init.gpa) catch {
        try w.writeAll("no running nodes\n");
        return;
    };
    defer {
        for (entries) |e| init.gpa.free(e.name);
        init.gpa.free(entries);
    }

    if (entries.len == 0) {
        try w.writeAll("no running nodes\n");
        return;
    }

    var stopped: usize = 0;
    for (entries) |e| {
        if (e.alive) {
            _ = c.kill(@as(i32, @intCast(e.pid)), std.os.linux.SIG.TERM);
            stopped += 1;
        }
        Registry.unregister(e.name);
    }

    try w.print("stopped {d} node(s)\n", .{stopped});
}
