const std = @import("std");
const utils = @import("utils.zig");
const node = @import("../node/mod.zig");
const debug = @import("../debug/mod.zig");

/// Stop all registered nodes (`glu down`).
pub fn cmdDown(init: std.process.Init) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const stopped = node.stopAllNodes(init.gpa) catch 0;
    if (stopped == 0) {
        try w.writeAll("no running nodes\n");
        return;
    }

    try w.print("stopped {d} node(s)\n", .{stopped});

    debug.cleanupLogs(init.io);
}
