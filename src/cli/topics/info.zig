const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const slowest_reader = @import("../../channel/shm.zig").slowest_reader;
const Header = @import("../../channel/shm.zig").Header;
const Shm = @import("../../channel/shm.zig").Shm;
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

/// Show detailed info about a topic (`glu topics info <topic>`).
pub fn cmd_info(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const topic_name = args.next() orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu topics info <topic>\n") catch {};
        return error.MissingArgument;
    };

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    // Locate the topic and its geometry through the daemon, then attach
    // directly to the shared segment for the live ring-buffer state.
    var entry_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    const count = client.list_topics(&entry_buf) catch |err| {
        try w.print("error: cannot list topics: {}\n", .{err});
        return;
    };

    var geometry: ?protocol.SHM_CHAN = null;
    for (entry_buf[0..count]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], topic_name)) {
            geometry = e;
            break;
        }
    }

    if (geometry == null) {
        try w.print("error: topic '{s}' not found\n", .{topic_name});
        return;
    }
    const g = geometry.?;

    var t = Shm.open(topic_name, g.msg_size, g.capacity, @enumFromInt(g.tos)) catch |err| {
        try w.print("error: cannot open topic '{s}': {s}\n", .{ topic_name, @errorName(err) });
        return;
    };
    defer t.close();

    const hdr = t.header;
    const name_slice = hdr.name[0..@min(hdr.name_len, hdr.name.len)];
    const data_size = @as(u64, hdr.msg_size) * @as(u64, hdr.capacity);
    const slowest = slowest_reader(&hdr.readers, hdr.write);
    const depth = hdr.write -% slowest;
    const pct = if (hdr.capacity > 0) @as(f64, @floatFromInt(depth)) / @as(f64, @floatFromInt(hdr.capacity)) * 100.0 else 0.0;

    try w.print("Topic:       {s}\n", .{name_slice});
    try w.print("Owner:       {d}\n", .{hdr.writer_pid});
    try w.print("TOS:         {s}\n", .{if (hdr.tos == 0) "reliable" else "best_effort"});
    try w.print("Msg Size:    {d} bytes\n", .{hdr.msg_size});
    try w.print("Capacity:    {d} messages\n", .{hdr.capacity});
    try w.print("Data Size:   {d} bytes\n", .{data_size});
    try w.print("Header:      {d} bytes (v1)\n", .{@sizeOf(Header)});
    try w.print("Total Size:  {d} bytes\n", .{t.size});
    try w.print("Connections: {d}\n", .{hdr.conns - 1});
    const write_pos = if (hdr.capacity > 0) hdr.write % hdr.capacity else 0;
    try w.print("Write Pos:   {d}\n", .{write_pos});
    try w.print("Queued:      {d} ({d:.1}% full)\n", .{ depth, pct });
    try w.print("Readers:\n", .{});
    for (hdr.readers, 0..) |entry, i| {
        if (entry >> 32 == 0) {
            try w.print("  [{d}] inactive\n", .{i});
        } else {
            const r: u32 = @truncate(entry);
            const behind = hdr.write -% r;
            const read_pos = if (hdr.capacity > 0) r % hdr.capacity else 0;
            try w.print("  [{d}] {d} ({d} behind)\n", .{ i, read_pos, behind });
        }
    }
}
