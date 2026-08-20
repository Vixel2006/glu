const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const discovery = @import("../discovery/mod.zig");
const debug = @import("../debug/mod.zig");
const hash = @import("../hash.zig");
const constants = @import("../constants.zig");
const FRAG_PAYLOAD = @import("../channel/network.zig").FRAG_PAYLOAD;
const HEADER_SIZE = @import("../channel/network.zig").HEADER_SIZE;

/// List active network channels (`glu net list`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var entry_buf: [128]discovery.NetChannelEntry = undefined;
    const count = discovery.scan_net_channels(&entry_buf) catch |err| {
        try w.print("error: cannot read network channels: {}\n", .{err});
        return;
    };

    if (count == 0) {
        try w.writeAll("no active network channels\n");
        return;
    }

    try w.print("{s:<24} {s:>6} {s:>8} {s:>8} {s:>6} {s:<11}\n", .{ "Channel", "Port", "Owner", "Size", "Cap", "TOS" });
    try w.print("{s:<24} {s:>6} {s:>8} {s:>8} {s:>6} {s:<11}\n", .{ "------------------------", "------", "--------", "--------", "------", "-----------" });

    for (entry_buf[0..count]) |e| {
        try w.print("{s:<24} {d:>6} {d:>8} {d:>8} {d:>6} {s:<11}\n", .{
            e.name[0..e.name_len],
            e.port,
            e.owner_pid,
            e.msg_size,
            e.capacity,
            if (e.tos == 0) "reliable" else "best_effort",
        });
    }
}

/// Show detailed info about a network channel (`glu net info <channel>`).
pub fn cmd_info(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    const name = args.next() orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu net info <channel>\n") catch {};
        return error.MissingArgument;
    };

    const port = @as(u16, @intCast(constants.PORT_BASE + hash.fvn1a(name, constants.PORT_SLOTS)));

    var entry_buf: [128]discovery.NetChannelEntry = undefined;
    const count = discovery.scan_net_channels(&entry_buf) catch 0;
    var matched: ?discovery.NetChannelEntry = null;
    for (entry_buf[0..count]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            matched = e;
            break;
        }
    }

    try w.print("Channel:     {s}\n", .{name});
    try w.print("Multicast:   {s}:{d}\n", .{ constants.MULTICAST_HOST, port });
    try w.print("Header Size: {d} bytes (v1)\n", .{HEADER_SIZE});
    try w.print("Max Payload: {d} bytes/datagram\n", .{FRAG_PAYLOAD});
    try w.print("Max Slots:   {d} fragments\n", .{constants.NET_CAP_MAX});

    if (matched) |e| {
        try w.print("Owner PID:   {d}\n", .{e.owner_pid});
        try w.print("Msg Size:    {d} bytes\n", .{e.msg_size});
        try w.print("Capacity:    {d} frames\n", .{e.capacity});
        try w.print("TOS:         {s}\n", .{if (e.tos == 0) "reliable" else "best_effort"});
    } else {
        try w.print("Status:      unregistered (wire sniffing available)\n", .{});
    }
}

/// Sniff and monitor live traffic on a network channel (`glu net sniff <channel> [-v]`).
pub fn cmd_sniff(init: std.process.Init, args: *parser.Args) !void {
    var verbose = false;
    var channel_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            channel_name = arg;
        }
    }

    const name = channel_name orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu net sniff <channel> [-v]\n") catch {};
        return error.MissingArgument;
    };

    var sniffer = debug.NetSniffer.init(name) catch |err| {
        var ew = utils.err_writer(init);
        ew.interface.print("error: failed to bind sniffer on channel '{s}': {}\n", .{ name, err }) catch {};
        return err;
    };
    defer sniffer.deinit();

    var fw = utils.writer(init);
    const w = &fw.interface;

    try w.print("sniffing '{s}' on {s}:{d} (Ctrl-C to stop)...\n", .{ name, constants.MULTICAST_HOST, sniffer.port });

    var buf: [constants.NET_PAYLOAD_MAX]u8 = undefined;
    while (true) {
        const event = (try sniffer.poll(&buf, 500)) orelse continue;

        if (event.dropped > 0) {
            try w.print("[DROP] {d} frame(s) lost before seq {d}\n", .{ event.dropped, event.seq });
        }

        try w.print("seq={d:<6} frag={d}/{d} len={d}B\n", .{
            event.seq,
            event.frag,
            event.total,
            event.payload_len,
        });

        if (verbose and event.payload_len > 0) {
            const preview_len = @min(event.payload_len, 32);
            const offset: usize = HEADER_SIZE;
            const payload = buf[offset .. offset + preview_len];
            try w.print("  data: {s}\n", .{payload});
        }
    }
}
