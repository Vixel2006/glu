const std = @import("std");
const assert = std.debug.assert;
const c = @import("std").c;
const os = std.os.linux;

const RegistryErr = error{
    OutOfMemory,
    NoSpaceLeft,
    FileSystem,
};

const REGISTRY_DIR = "/tmp/glu/nodes";

/// A discovered node with its PID and health status.
pub const NodeEntry = struct {
    name: [64]u8,
    name_len: u32,
    pid: u32,
    alive: bool,
};

/// Register a node by name with an explicit PID.
///
/// Writes a `.pid` file under `/tmp/glu/nodes/` so other processes can
/// discover the node via `list_alive`.
pub fn register_pid(name: []const u8, pid: u32) RegistryErr!void {
    assert(name.len > 0);
    assert(pid > 0);
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, REGISTRY_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return RegistryErr.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.pid", .{ REGISTRY_DIR, name });
    var file = cwd.createFile(io, path, .{}) catch return RegistryErr.FileSystem;
    defer file.close(io);

    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;
    w.print("{d}", .{pid}) catch return RegistryErr.FileSystem;
}

/// Register the current process under `name`.
pub fn register(name: []const u8) RegistryErr!void {
    assert(name.len > 0);
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, REGISTRY_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return RegistryErr.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.pid", .{ REGISTRY_DIR, name });
    var file = cwd.createFile(io, path, .{}) catch return RegistryErr.FileSystem;
    defer file.close(io);

    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;
    w.print("{d}", .{os.getpid()}) catch return RegistryErr.FileSystem;
}

pub fn unregister(name: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pid", .{ REGISTRY_DIR, name }) catch |err| {
        std.log.err("unregister: failed to format path for node '{s}': {}", .{ name, err });
        return;
    };
    cwd.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| std.log.err("unregister: failed to delete file '{s}': {}", .{ path, e }),
    };
}

/// Check if a process with the given PID is still alive.
///
/// Uses `access(F_OK)` on `/proc/<pid>/status`, which is a cheap
/// OS-level existence check with no privileges required.
pub fn is_alive(pid: u32) bool {
    var buf: [64]u8 = undefined;
    const path_len = (std.fmt.bufPrint(&buf, "/proc/{d}/status", .{pid}) catch return false).len;
    buf[path_len] = 0;
    return c.access(buf[0..path_len :0], 0) == 0;
}

/// List all registered nodes and their health status.
///
/// Scans `/tmp/glu/nodes/*.pid` files, reads each PID, and calls
/// `is_alive` to determine if the process is still running.
/// Writes up to `entries.len` elements into the provided slice.
/// Returns the number of nodes found and written.
pub fn list_alive(entries: []NodeEntry) RegistryErr!usize {
    const dirp = c.opendir(REGISTRY_DIR) orelse return 0;
    defer _ = c.closedir(dirp);

    var count: usize = 0;
    while (count < entries.len) {
        const entry = c.readdir(dirp) orelse break;
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len <= 4) continue;
        if (!std.mem.eql(u8, name[name.len - 4 ..], ".pid")) continue;

        const node_name = name[0 .. name.len - 4];

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ REGISTRY_DIR, name }) catch continue;
        path_buf[path.len] = 0;

        const fd = c.open(path_buf[0..path.len :0], os.O{ .ACCMODE = .RDONLY });
        if (fd == -1) continue;
        defer _ = c.close(fd);

        var buf: [32]u8 = undefined;
        const nread = c.read(fd, &buf, buf.len);
        if (nread <= 0) continue;

        const content = buf[0..@as(usize, @intCast(nread))];
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n\r"), 10) catch continue;

        var name_arr = std.mem.zeroes([64]u8);
        const name_len = @min(@as(u32, @intCast(node_name.len)), 63);
        @memcpy(name_arr[0..name_len], node_name[0..name_len]);

        entries[count] = .{
            .name = name_arr,
            .name_len = name_len,
            .pid = pid,
            .alive = is_alive(pid),
        };
        count += 1;
    }

    return count;
}

test "register and list_alive" {
    const name = "glu-test-register-alive";
    defer unregister(name);

    try register(name);

    var entries: [16]NodeEntry = undefined;
    const count = try list_alive(&entries);

    var found = false;
    for (entries[0..count]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            found = true;
            try std.testing.expectEqual(@as(u32, @intCast(os.getpid())), e.pid);
            try std.testing.expect(e.alive);
        }
    }
    try std.testing.expect(found);
}

test "register_pid with explicit PID" {
    const name = "glu-test-register-pid";
    defer unregister(name);

    try register_pid(name, 42);

    var entries: [16]NodeEntry = undefined;
    const count = try list_alive(&entries);

    var found = false;
    for (entries[0..count]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            found = true;
            try std.testing.expectEqual(@as(u32, 42), e.pid);
        }
    }
    try std.testing.expect(found);
}

test "unregister removes entry" {
    const name = "glu-test-unregister";
    try register(name);

    // Verify it exists
    {
        var entries: [16]NodeEntry = undefined;
        const count = try list_alive(&entries);
        var found = false;
        for (entries[0..count]) |e| {
            if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
                found = true;
            }
        }
        try std.testing.expect(found);
    }

    unregister(name);

    // Verify it's gone
    {
        var entries: [16]NodeEntry = undefined;
        const count = try list_alive(&entries);
        for (entries[0..count]) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name[0..e.name_len], name));
        }
    }
}

test "unregister nonexistent name does not crash" {
    unregister("glu-test-nonexistent-this-should-not-exist");
}

test "list_alive empty when no matching nodes" {
    const name = "glu-test-list-empty";
    defer unregister(name);

    var entries: [16]NodeEntry = undefined;
    const count = try list_alive(&entries);

    for (entries[0..count]) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name[0..e.name_len], name));
    }
}
