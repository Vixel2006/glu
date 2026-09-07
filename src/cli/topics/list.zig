const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

/// List all active glu topics in shared memory (`glu topics list`, aliases `glu list`/`glu ls`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var entry_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    const count = client.list_topics(&entry_buf) catch {
        try w.writeAll("error: cannot reach daemon\n");
        return;
    };

    if (count == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "Topic", "Size", "Cap", "TOS", "Owner" });
    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "------------------------", "--------", "--------", "------", "--------" });

    var owner_name_buf: [64]u8 = undefined;
    for (entry_buf[0..count]) |e| {
        const owner = if (e.writer_pid == 0)
            "-"
        else if (e.writer_pid > 0)
            std.fmt.bufPrint(&owner_name_buf, "{d}", .{e.writer_pid}) catch "-"
        else
            "-";
        const tos = if (e.tos == 0) "reliable" else "best_effort";
        try w.print("{s:<24} {d:>8} {d:>8} {s:>6} {s:>8}\n", .{
            e.name[0..@min(e.name_len, e.name.len)],
            e.msg_size,
            e.capacity,
            tos,
            owner,
        });
    }
}