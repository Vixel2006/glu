const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const dispatch = @import("../dispatch.zig");
const daemon_client = @import("../../daemon/client.zig");
const protocol = @import("../../daemon/protocol.zig");

/// List all active glu topics in shared memory (`glu topics list`, aliases `glu list`/`glu ls`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var client = try dispatch.get_client(init);
    defer client.deinit();

    var entry_buf: [128]protocol.WireShmTopic = undefined;
    const count = client.list_topics(&entry_buf) catch |err| switch (err) {
        daemon_client.ClientErr.DaemonNotRunning => {
            try w.writeAll("error: daemon not running\n");
            return;
        },
        else => {
            try w.print("error: {}\n", .{err});
            return;
        },
    };

    if (count == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "Topic", "Size", "Cap", "TOS", "Owner" });
    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "------------------------", "--------", "--------", "------", "--------" });

    for (entry_buf[0..count]) |e| {
        try w.print("{s:<24} {d:>8} {d:>8} {d:>6} {d:>8}\n", .{
            e.name[0..@min(e.name_len, e.name.len)],
            e.msg_size,
            e.capacity,
            e.tos,
            e.owner_pid,
        });
    }
}