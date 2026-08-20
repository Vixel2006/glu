const std = @import("std");
const assert = std.debug.assert;
const os = std.os.linux;
const constants = @import("../constants.zig");
const is_alive = @import("../registry.zig").is_alive;
const valid_name = @import("../registry.zig").valid_name;

pub const NetChannelEntry = struct {
    name: [64]u8,
    name_len: u32,
    owner_pid: u32,
    port: u16,
    msg_size: u32,
    capacity: u32,
    tos: u32,
};

fn net_dir(io: std.Io) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    _ = cwd.createDirPathStatus(io, constants.NET_REGISTRY_DIR, std.Io.File.Permissions.fromMode(constants.REGISTRY_MODE)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.FileSystem,
    };
    const dir = cwd.openDir(io, constants.NET_REGISTRY_DIR, .{ .follow_symlinks = false, .iterate = true }) catch return error.FileSystem;
    return dir;
}

pub fn register_net_channel(name: []const u8, pid: u32, port: u16, msg_size: u32, cap: u32, tos: u32) !void {
    if (!valid_name(name)) return error.InvalidName;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try net_dir(io);
    defer dir.close(io);

    var path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&path_buf, "{s}.net", .{name}) catch return error.FileSystem;

    var file = dir.createFile(io, sub_path, .{
        .truncate = true,
        .permissions = .fromMode(constants.FILE_MODE),
    }) catch return error.FileSystem;
    defer file.close(io);

    var content_buf: [128]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "{d} {d} {d} {d} {d}\n", .{ pid, port, msg_size, cap, tos }) catch return error.FileSystem;
    file.writePositionalAll(io, content, 0) catch return error.FileSystem;
}

pub fn unregister_net_channel(name: []const u8) void {
    if (!valid_name(name)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = net_dir(io) catch return;
    defer dir.close(io);

    var path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&path_buf, "{s}.net", .{name}) catch return;
    dir.deleteFile(io, sub_path) catch {};
}

pub fn scan_net_channels(entries: []NetChannelEntry) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = net_dir(io) catch return 0;
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    var count: usize = 0;
    while (count < entries.len) {
        const entry = it.next(io) catch break orelse break;
        const fname = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (fname.len <= 4) continue;
        if (!std.mem.eql(u8, fname[fname.len - 4 ..], ".net")) continue;

        const ch_name = fname[0 .. fname.len - 4];
        if (!valid_name(ch_name)) continue;

        var file = dir.openFile(io, fname, .{ .follow_symlinks = false }) catch continue;
        defer file.close(io);

        var buf: [128]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch continue;
        if (n == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
        const pid_str = tokens.next() orelse continue;
        const port_str = tokens.next() orelse continue;
        const msg_str = tokens.next() orelse continue;
        const cap_str = tokens.next() orelse continue;
        const tos_str = tokens.next() orelse continue;

        const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;
        const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
        const msg_size = std.fmt.parseInt(u32, msg_str, 10) catch continue;
        const cap = std.fmt.parseInt(u32, cap_str, 10) catch continue;
        const tos = std.fmt.parseInt(u32, tos_str, 10) catch continue;

        var name_arr = std.mem.zeroes([64]u8);
        const name_len = @min(@as(u32, @intCast(ch_name.len)), 63);
        @memcpy(name_arr[0..name_len], ch_name[0..name_len]);

        entries[count] = .{
            .name = name_arr,
            .name_len = name_len,
            .owner_pid = pid,
            .port = port,
            .msg_size = msg_size,
            .capacity = cap,
            .tos = tos,
        };
        count += 1;
    }
    return count;
}

pub fn cleanup_net_channels() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = net_dir(io) catch return;
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (true) {
        const entry = it.next(io) catch break orelse break;
        const fname = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (fname.len <= 4 or !std.mem.eql(u8, fname[fname.len - 4 ..], ".net")) continue;

        var file = dir.openFile(io, fname, .{ .follow_symlinks = false }) catch continue;
        var buf: [32]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch {
            file.close(io);
            continue;
        };
        file.close(io);

        var tokens = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
        const pid_str = tokens.next() orelse continue;
        const pid = std.fmt.parseInt(u32, pid_str, 10) catch continue;

        if (pid == 0 or !is_alive(pid)) {
            dir.deleteFile(io, fname) catch {};
        }
    }
}

test "register and scan net channels" {
    const name = "test_net_discovery";
    defer unregister_net_channel(name);

    try register_net_channel(name, 12345, 50000, 1024, 8, 0);

    var entries: [16]NetChannelEntry = undefined;
    const count = try scan_net_channels(&entries);

    var found = false;
    for (entries[0..count]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            found = true;
            try std.testing.expectEqual(@as(u32, 12345), e.owner_pid);
            try std.testing.expectEqual(@as(u16, 50000), e.port);
            try std.testing.expectEqual(@as(u32, 1024), e.msg_size);
        }
    }
    try std.testing.expect(found);
}
