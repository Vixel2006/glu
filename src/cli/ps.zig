const std = @import("std");
const utils = @import("utils.zig");
const Registry = @import("../registry.zig");

pub fn cmdPs(init: std.process.Init) void {
    cmdPs_(init) catch |err| utils.logErr("ps", err);
}

fn cmdPs_(init: std.process.Init) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const entries = Registry.listAlive(init.gpa) catch |err| {
        try w.print("error: cannot list nodes: {}\n", .{err});
        return;
    };
    defer {
        for (entries) |e| init.gpa.free(e.name);
        init.gpa.free(entries);
    }

    if (entries.len == 0) {
        try w.writeAll("no registered nodes\n");
        return;
    }

    try w.writeAll(" Node                     PID       Status\n");
    try w.writeAll(" ──────────────────────── ───────── ──────\n");
    for (entries) |e| {
        const status = if (e.alive) "alive" else "dead";
        try w.print(" {s:<24} {d:>9} {s:>6}\n", .{ e.name, e.pid, status });
    }
}
