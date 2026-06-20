const std = @import("std");
const c = @import("std").c;
const utils = @import("utils.zig");

const Entry = struct {
    name: []const u8,
    msg_size: u32,
    capacity: u32,
    conns: u32,
    write_pos: u32,
    read_pos: u32,
};

pub fn cmdList(init: std.process.Init) void {
    cmdList_(init) catch |err| utils.logErr("list", err);
}

fn cmdList_(init: std.process.Init) !void {
    const allocator = init.gpa;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var entries = std.ArrayList(Entry).empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    const dirp = c.opendir("/dev/shm") orelse {
        try w.writeAll("error: /dev/shm not accessible\n");
        return;
    };
    defer _ = c.closedir(dirp);

    while (true) {
        const entry = c.readdir(dirp) orelse break;
        if (entry.type != 8) continue; // DT_REG
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, "sem.")) continue;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name = std.fmt.bufPrint(&shm_name_buf, "/{s}", .{name}) catch continue;

        var topic = utils.Topic.open(allocator, shm_name) catch continue;
        defer topic.close();
        const hdr = topic.header;

        const name_copy = try allocator.dupe(u8, hdr.name[0..hdr.name_len]);
        try entries.append(allocator, .{
            .name = name_copy,
            .msg_size = hdr.msg_size,
            .capacity = hdr.capacity,
            .conns = hdr.conns,
            .write_pos = hdr.write,
            .read_pos = hdr.read,
        });
    }

    if (entries.items.len == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.writeAll(" Topic                    Size    Cap  Conns  Write  Read  Depth\n");
    try w.writeAll(" ──────────────────────── ─────── ──── ────── ────── ───── ──────\n");
    for (entries.items) |e| {
        const depth = e.write_pos - e.read_pos;
        try w.print(" {s:<24} {d:>5}  {d:>4}  {d:>5}  {d:>5}  {d:>4}  {d:>5}\n", .{
            e.name,      e.msg_size, e.capacity, e.conns,
            e.write_pos, e.read_pos, depth,
        });
    }
}
