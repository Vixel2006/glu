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

    /// Seconds since the process started (0 if unknown).
    uptime: u64,
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

/// Persist the spawn vector for a node so it can be re-spawned later
/// without re-parsing the original TOML.
///
/// Writes `<name>.argv` under `/tmp/glu/nodes/` as NUL-separated args.
pub fn register_argv(name: []const u8, argv: []const []const u8) RegistryErr!void {
    assert(name.len > 0);
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, REGISTRY_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return RegistryErr.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.argv", .{ REGISTRY_DIR, name });
    var file = cwd.createFile(io, path, .{}) catch return RegistryErr.FileSystem;
    defer file.close(io);

    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;
    for (argv) |arg| {
        w.writeAll(arg) catch return RegistryErr.FileSystem;
        w.writeByte(0) catch return RegistryErr.FileSystem;
    }
}

/// Maximum argv entries a persisted manifest may contain.
pub const MAX_ARGV = 32;
/// Maximum bytes of a persisted spawn vector.
pub const MAX_ARGV_LEN = 4096;

/// Read a node's persisted spawn vector into `args` (slices into `data`).
///
/// Returns the number of arguments written, or 0 when no manifest exists.
pub fn read_argv(args: [][]const u8, data: []u8, name: []const u8) RegistryErr!usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.argv", .{ REGISTRY_DIR, name });
    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return RegistryErr.FileSystem,
    };
    defer file.close(io);

    const size = @as(usize, @intCast(file.length(io) catch return RegistryErr.FileSystem));
    if (size == 0) return 0;
    if (size > data.len) return RegistryErr.FileSystem;
    const n = file.readPositionalAll(io, data[0..size], 0) catch return RegistryErr.FileSystem;

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, data[0..n], 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        if (count >= args.len) return RegistryErr.FileSystem;
        args[count] = arg;
        count += 1;
    }
    return count;
}

/// Read the PID recorded for `name`, or null when unregistered.
pub fn get_pid(name: []const u8) RegistryErr!?u32 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.pid", .{ REGISTRY_DIR, name });
    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return RegistryErr.FileSystem,
    };
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return RegistryErr.FileSystem;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], " \n\r"), 10) catch null;
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

/// Seconds since the process started, or 0 if it cannot be determined.
///
/// Computed from `/proc/<pid>/stat` (`starttime`, in clock ticks) and the
/// system boot time in `/proc/stat`, converted to wall-clock seconds.
pub fn proc_uptime(pid: u32) u64 {
    const tck: u64 = @intCast(@max(c.sysconf(2), 1)); // _SC_CLK_TCK
    const btime = boot_sec() orelse return 0;

    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return 0;
    buf[path.len] = 0;

    const fd = c.open(buf[0..path.len :0], os.O{ .ACCMODE = .RDONLY });
    if (fd == -1) return 0;
    defer _ = c.close(fd);

    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;

    // After the `comm` (which may contain spaces and parentheses) the 20th
    // whitespace-separated field is `starttime`, in clock ticks.
    var i: usize = 0;
    while (i < n and buf[i] != ')') i += 1;
    if (i >= n) return 0;
    i += 1;

    var field: usize = 0;
    var start_ticks: u64 = 0;
    while (i < n and field < 20) {
        while (i < n and buf[i] == ' ') i += 1;
        if (i >= n) break;
        field += 1;
        const j = i;
        while (i < n and buf[i] != ' ') i += 1;
        if (field == 20) {
            start_ticks = std.fmt.parseInt(u64, buf[j..i], 10) catch return 0;
            break;
        }
    }
    if (field < 20) return 0;

    var ts: os.timespec = undefined;
    if (os.clock_gettime(os.CLOCK.REALTIME, &ts) != 0) return 0;
    const now: u64 = @intCast(@max(@as(i64, ts.sec), 0));

    const started = btime + @divTrunc(start_ticks, tck);
    return if (now > started) now - started else 0;
}

/// System boot time in seconds since the Unix epoch, from `/proc/stat`.
///
/// The `btime` line sits near the end of the file, so use a buffer large
/// enough to hold the whole file.
fn boot_sec() ?u64 {
    var buf: [16384]u8 = undefined;
    const fd = c.open("/proc/stat", os.O{ .ACCMODE = .RDONLY });
    if (fd == -1) return null;
    defer _ = c.close(fd);

    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;

    var it = std.mem.tokenizeScalar(u8, buf[0..@as(usize, @intCast(n))], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "btime ")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, line[6..], " \t"), 10) catch null;
        }
    }
    return null;
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

        const alive = is_alive(pid);

        entries[count] = .{
            .name = name_arr,
            .name_len = name_len,
            .pid = pid,
            .alive = alive,
            .uptime = if (alive) proc_uptime(pid) else 0,
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

test "register_argv round-trips a manifest" {
    const name = "glu-test-argv";
    defer {
        const io = std.Io.Threaded.global_single_threaded.io();
        var pb: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "/tmp/glu/nodes/{s}.argv", .{name}) catch pb[0..0];
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }

    const argv = &[_][]const u8{ "/bin/echo", "hello", "--flag" };
    try register_argv(name, argv);

    var args: [MAX_ARGV][]const u8 = undefined;
    var data: [MAX_ARGV_LEN]u8 = undefined;
    const argc = try read_argv(&args, &data, name);
    try std.testing.expectEqual(@as(usize, 3), argc);
    try std.testing.expectEqualStrings("/bin/echo", args[0]);
    try std.testing.expectEqualStrings("--flag", args[2]);
}

test "read_argv for unknown name returns zero" {
    var args: [MAX_ARGV][]const u8 = undefined;
    var data: [MAX_ARGV_LEN]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read_argv(&args, &data, "glu-test-no-such-argv"));
}

test "get_pid returns null for unregistered node" {
    const pid = try get_pid("glu-test-no-such-node");
    try std.testing.expect(pid == null);
}

test "register_pid with explicit PID" {
    const name = "glu-test-register-pid";
    defer unregister(name);

    try register_pid(name, 42);

    const pid = try get_pid(name);
    try std.testing.expectEqual(@as(?u32, 42), pid);

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
