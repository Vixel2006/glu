const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const discovery = @import("../../discovery/mod.zig");
const slowest_reader = @import("../../channel.zig").slowest_reader;
const MAX_READERS = @import("../../channel.zig").MAX_READERS;
const Header = @import("../../channel.zig").Header;

/// Show detailed info about a topic (`glu topics info <topic>`).
pub fn cmd_info(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const topic_name = args.next() orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu topics info <topic>\n") catch {};
        return error.MissingArgument;
    };

    var t = discovery.Topic.open(topic_name) catch |err| {
        const msg = switch (err) {
            error.TopicNotFound => "not found",
            error.InvalidTopic => "is not a valid glu topic",
            error.MmapFailed => "mmap failed",
            error.BadMagic => "is not a glu topic (bad magic)",
        };
        try w.print("error: topic '{s}' {s}\n", .{ topic_name, msg });
        return;
    };
    defer t.close();

    const hdr = t.header;
    std.debug.assert(hdr.name_len <= hdr.name.len);

    const name_slice = hdr.name[0..hdr.name_len];
    const data_size = @as(u64, hdr.msg_size) * @as(u64, hdr.capacity);
    var read_vals: [MAX_READERS]u64 = undefined;
    @memcpy(&read_vals, &hdr.readers);
    const slowest = slowest_reader(&read_vals, hdr.write);
    const depth = hdr.write -% slowest;
    const pct = if (hdr.capacity > 0) @as(f64, @floatFromInt(depth)) / @as(f64, @floatFromInt(hdr.capacity)) * 100.0 else 0.0;

    try w.print("Topic:       {s}\n", .{name_slice});
    try w.print("Owner:       {d}\n", .{hdr.owner_pid});
    try w.print("TOS:         {s}\n", .{if (hdr.tos == 0) "reliable" else "best_effort"});
    try w.print("Msg Size:    {d} bytes\n", .{hdr.msg_size});
    try w.print("Capacity:    {d} messages\n", .{hdr.capacity});
    try w.print("Data Size:   {d} bytes\n", .{data_size});
    try w.print("Header:      {d} bytes (v1)\n", .{@sizeOf(Header)});
    try w.print("Total Size:  {d} bytes\n", .{t.file_size});
    try w.print("Connections: {d}\n", .{hdr.conns});
    try w.print("Write Pos:   {d}\n", .{hdr.write % hdr.capacity});
    try w.print("Queued:      {d} ({d:.1}% full)\n", .{ depth, pct });
    try w.print("Readers:\n", .{});
    for (&read_vals, 0..) |entry, i| {
        if (entry == 0) {
            try w.print("  [{d}] inactive\n", .{i});
        } else {
            const r: u32 = @truncate(entry);
            const behind = hdr.write -% r;
            try w.print("  [{d}] {d} ({d} behind)\n", .{ i, r % hdr.capacity, behind });
        }
    }
}
