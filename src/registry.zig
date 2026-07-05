const std = @import("std");
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
    name: []const u8,
    pid: u32,
    alive: bool,
};

/// Register a node by name with an explicit PID.
///
/// Writes a `.pid` file under `/tmp/glu/nodes/` so other processes can
/// discover the node via `listAlive`.
pub fn registerPid(name: []const u8, pid: u32) RegistryErr!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, REGISTRY_DIR) catch {};

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
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, REGISTRY_DIR) catch {};

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
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pid", .{ REGISTRY_DIR, name }) catch return;
    cwd.deleteFile(io, path) catch {};
}

/// Register the current process using its executable name (from `/proc/self/exe`).
///
/// This is a convenience for nodes that want to self-register without
/// having to know their own name.
pub fn registerOwnExe() void {
    var exe_buf: [1024]u8 = undefined;
    const len = std.os.linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (len > 0 and len <= exe_buf.len) {
        const path = exe_buf[0..len];
        const exe_name = std.fs.path.basename(path);
        register(exe_name) catch {};
    }
}

pub fn unregisterOwnExe() void {
    var exe_buf: [1024]u8 = undefined;
    const len = std.os.linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (len > 0 and len <= exe_buf.len) {
        const path = exe_buf[0..len];
        const exe_name = std.fs.path.basename(path);
        unregister(exe_name);
    }
}

/// List all registered nodes and their health status.
///
/// Scans `/tmp/glu/nodes/*.pid` files, reads each PID, and checks
/// `/proc/<pid>/status` to determine if the process is still alive.
/// Returns an owned slice allocated with `allocator`.
pub fn listAlive(allocator: std.mem.Allocator) RegistryErr![]NodeEntry {
    var entries = std.ArrayList(NodeEntry).empty;

    const dirp = c.opendir(REGISTRY_DIR) orelse return entries.toOwnedSlice(allocator);
    defer _ = c.closedir(dirp);

    while (true) {
        const entry = c.readdir(dirp) orelse break;
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len <= 4) continue;
        if (!std.mem.eql(u8, name[name.len - 4 ..], ".pid")) continue;

        const node_name = name[0 .. name.len - 4];

        var path_buf: [256]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ REGISTRY_DIR, name }) catch continue;

        const fd = c.open(path_z.ptr, os.O{ .ACCMODE = .RDONLY });
        if (fd == -1) continue;
        defer _ = c.close(fd);

        var buf: [32]u8 = undefined;
        const nread = c.read(fd, &buf, buf.len);
        if (nread <= 0) continue;

        const content = buf[0..@as(usize, @intCast(nread))];
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n\r"), 10) catch continue;

        var proc_buf: [256]u8 = undefined;
        const proc_z = std.fmt.bufPrintZ(&proc_buf, "/proc/{d}/status", .{pid}) catch continue;
        const alive = c.access(proc_z.ptr, 0) == 0; // F_OK == 0

        const name_copy = try allocator.dupe(u8, node_name);
        try entries.append(allocator, .{ .name = name_copy, .pid = pid, .alive = alive });
    }

    return entries.toOwnedSlice(allocator);
}

test "register and listAlive" {
    const allocator = std.testing.allocator;

    const name = "glu-test-register-alive";
    defer unregister(name);

    try register(name);

    const entries = try listAlive(allocator);
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    var found = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            found = true;
            try std.testing.expectEqual(@as(u32, @intCast(os.getpid())), e.pid);
            try std.testing.expect(e.alive);
        }
    }
    try std.testing.expect(found);
}

test "registerPid with explicit PID" {
    const allocator = std.testing.allocator;

    const name = "glu-test-register-pid";
    defer unregister(name);

    try registerPid(name, 42);

    const entries = try listAlive(allocator);
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    var found = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            found = true;
            try std.testing.expectEqual(@as(u32, 42), e.pid);
        }
    }
    try std.testing.expect(found);
}

test "unregister removes entry" {
    const allocator = std.testing.allocator;

    const name = "glu-test-unregister";
    try register(name);

    // Verify it exists
    {
        const entries = try listAlive(allocator);
        defer {
            for (entries) |e| allocator.free(e.name);
            allocator.free(entries);
        }
        var found = false;
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                found = true;
            }
        }
        try std.testing.expect(found);
    }

    unregister(name);

    // Verify it's gone
    {
        const entries = try listAlive(allocator);
        defer {
            for (entries) |e| allocator.free(e.name);
            allocator.free(entries);
        }
        for (entries) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, name));
        }
    }
}

test "unregister nonexistent name does not crash" {
    unregister("glu-test-nonexistent-this-should-not-exist");
}

test "listAlive empty when no matching nodes" {
    const allocator = std.testing.allocator;

    const name = "glu-test-list-empty";
    defer unregister(name);

    const entries = try listAlive(allocator);
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    for (entries) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, name));
    }
}
