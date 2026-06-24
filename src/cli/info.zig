const std = @import("std");
const utils = @import("utils.zig");
const slowestReader = @import("../channel.zig").slowestReader;
const MAX_READERS = @import("../channel.zig").MAX_READERS;

pub fn cmdInfo(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdInfo_(init, args) catch |err| utils.logErr("info", err);
}

fn cmdInfo_(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const topic_name = args.next() orelse {
        try w.writeAll("usage: glu info <topic>\n");
        return;
    };

    var topic = utils.Topic.open(init.gpa, topic_name) catch |err| {
        const msg = switch (err) {
            error.TopicNotFound => "not found",
            error.InvalidTopic => "is not a valid glu topic",
            error.MmapFailed => "mmap failed",
            error.BadMagic => "is not a glu topic (bad magic)",
            error.OutOfMemory => "out of memory",
        };
        try w.print("error: topic '{s}' {s}\n", .{ topic_name, msg });
        return;
    };
    defer topic.close();

    const hdr = topic.header;

    const name_slice = hdr.name[0..hdr.name_len];
    const data_size = hdr.msg_size * hdr.capacity;
    var read_vals: [MAX_READERS]u32 = undefined;
    @memcpy(&read_vals, &hdr.read);
    const slowest = slowestReader(&read_vals, hdr.write);
    const depth = hdr.write -% slowest;
    const pct = if (hdr.capacity > 0) @as(f64, @floatFromInt(depth)) / @as(f64, @floatFromInt(hdr.capacity)) * 100.0 else 0.0;

    try w.print("Topic:       {s}\n", .{name_slice});
    try w.print("Msg Size:    {d} bytes\n", .{hdr.msg_size});
    try w.print("Capacity:    {d} messages\n", .{hdr.capacity});
    try w.print("Data Size:   {d} bytes\n", .{data_size});
    try w.print("Header:      {d} bytes (v1)\n", .{@sizeOf(utils.Header)});
    try w.print("Total Size:  {d} bytes\n", .{topic.file_size});
    try w.print("Connections: {d}\n", .{hdr.conns});
    try w.print("Write Pos:   {d}\n", .{hdr.write % hdr.capacity});
    try w.print("Queued:      {d} ({d:.1}% full)\n", .{ depth, pct });
    try w.print("Readers:\n", .{});
    for (&read_vals, 0..) |r, i| {
        if (r == std.math.maxInt(u32)) {
            try w.print("  [{d}] inactive\n", .{i});
        } else {
            const behind = hdr.write -% r;
            try w.print("  [{d}] {d} ({d} behind)\n", .{ i, r % hdr.capacity, behind });
        }
    }
}
