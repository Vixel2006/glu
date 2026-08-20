const std = @import("std");
const assert = std.debug.assert;
const c = @import("std").c;
const os = std.os.linux;
const constants = @import("constants.zig");

const RegistryErr = error{
    OutOfMemory,
    NoSpaceLeft,
    FileSystem,
    /// A node name was rejected because it could escape the registry
    /// directory (path traversal) or is otherwise invalid.
    InvalidName,
    /// The registry directory is not owned by the current user. In a
    /// sticky-bit /tmp, another user may have pre-created it to redirect
    /// our writes.
    DirNotOwned,
    NotFound,
};

/// Validate a node name before it becomes part of a path.
///
/// Names are interpolated into `"{dir}/{name}.pid"` and similar, so a name
/// containing `/`, `..`, or path separators could escape the registry
/// directory (either writing outside `/tmp/glu` or, on a shared host,
/// following an attacker's pre-created symlink). Accept only a conservative
/// charset and length.
pub fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (name[0] == '.') return false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-' or ch == '.';
        if (!ok) return false;
    }
    return true;
}

/// Ensure the registry directory exists with the right permissions and is
/// owned by us, returning it as an open handle for subsequent operations.
///
/// `/tmp` is normally a sticky world-writable directory, so another user can
/// pre-create `/tmp/glu/nodes`. We must refuse to operate on a directory we
/// don't own rather than follow whatever symlinks are planted there.
fn registry_dir(io: std.Io) RegistryErr!std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    _ = cwd.createDirPathStatus(io, constants.REGISTRY_DIR, std.Io.File.Permissions.fromMode(constants.REGISTRY_MODE)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return RegistryErr.FileSystem,
    };

    const dir = cwd.openDir(io, constants.REGISTRY_DIR, .{ .follow_symlinks = false, .iterate = true }) catch return RegistryErr.FileSystem;
    errdefer dir.close(io);

    // Verify ownership of the directory, not just that it exists.
    var st: os.Statx = undefined;
    // statx on an open fd with empty path.
    const rc = os.statx(dir.handle, "", os.AT.EMPTY_PATH, os.STATX.BASIC_STATS, &st);
    if (rc != 0) return RegistryErr.FileSystem;
    if (st.uid != os.geteuid()) return RegistryErr.DirNotOwned;

    return dir;
}

/// Open registry file `basename` for reading, never following symlinks.
///
/// Resolution is anchored to the opened (ownership-verified) registry
/// directory handle, so a planted parent symlink isn't followed.
fn open_registry_file(io: std.Io, name: []const u8, suffix: []const u8) RegistryErr!std.Io.File {
    if (!valid_name(name)) return RegistryErr.InvalidName;
    var sub_path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}{s}", .{ name, suffix }) catch return RegistryErr.FileSystem;

    var dir = try registry_dir(io);
    defer dir.close(io);
    return dir.openFile(io, sub_path, .{ .follow_symlinks = false, .resolve_beneath = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return RegistryErr.FileSystem,
    };
}

/// A discovered node with its PID and health status.
pub const NodeEntry = struct {
    name: [64]u8,
    name_len: u32,
    pid: u32,
    alive: bool,
};

/// Create-or-overwrite a registry entry securely.
///
/// `exclusive` creation ensures the first write never follows a symlink or
/// truncates an attacker's planted file; if the entry already exists we
/// reopen it with `O_NOFOLLOW` (destroying nothing we don't own) and
/// truncate it before writing. Either way a symlink at that path fails.
fn write_registry_file(io: std.Io, name: []const u8, suffix: []const u8, content: []const u8) RegistryErr!void {
    if (!valid_name(name)) return RegistryErr.InvalidName;

    var sub_path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}{s}", .{ name, suffix }) catch return RegistryErr.FileSystem;

    var dir = try registry_dir(io);
    defer dir.close(io);

    var file: std.Io.File = dir.createFile(io, sub_path, .{ .exclusive = true, .permissions = .fromMode(constants.FILE_MODE) }) catch |err| switch (err) {
        // Entry already exists: reopen without following symlinks.
        error.PathAlreadyExists => dir.openFile(io, sub_path, .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true }) catch return RegistryErr.FileSystem,
        else => return RegistryErr.FileSystem,
    };
    defer file.close(io);

    file.setLength(io, 0) catch return RegistryErr.FileSystem;
    file.writePositionalAll(io, content, 0) catch return RegistryErr.FileSystem;
}

/// Register a node by name with an explicit PID.
///
/// Writes a `.pid` file under `/tmp/glu/nodes/` so other processes can
/// discover the node via `list_alive`.
pub fn register_pid(name: []const u8, pid: u32) RegistryErr!void {
    assert(pid > 0);
    var buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return RegistryErr.FileSystem;
    try write_registry_file(std.Io.Threaded.global_single_threaded.io(), name, ".pid", content);
}

/// Persist the spawn vector for a node so it can be re-spawned later
/// without re-parsing the original TOML.
///
/// Writes `<name>.argv` under `/tmp/glu/nodes/` as NUL-separated args.
pub fn register_argv(name: []const u8, argv: []const []const u8) RegistryErr!void {
    if (!valid_name(name)) return RegistryErr.InvalidName;

    var data: [constants.MAX_ARGV_LEN]u8 = undefined;
    var len: usize = 0;
    for (argv) |arg| {
        if (arg.len > constants.MAX_ARGV_LEN or len + arg.len + 1 > data.len) return RegistryErr.FileSystem;
        @memcpy(data[len .. len + arg.len], arg);
        len += arg.len;
        data[len] = 0;
        len += 1;
    }

    try write_registry_file(std.Io.Threaded.global_single_threaded.io(), name, ".argv", data[0..len]);
}

/// Read a node's persisted spawn vector into `args` (slices into `data`).
///
/// Returns the number of arguments written, or 0 when no manifest exists.
pub fn read_argv(args: [][]const u8, data: []u8, name: []const u8) RegistryErr!usize {
    const io = std.Io.Threaded.global_single_threaded.io();

    const file = open_registry_file(io, name, ".argv") catch |err| switch (err) {
        error.NotFound => return 0,
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

    const file = open_registry_file(io, name, ".pid") catch |err| switch (err) {
        error.NotFound => return null,
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
    return register_pid(name, @intCast(os.getpid()));
}

pub fn unregister(name: []const u8) void {
    if (!valid_name(name)) {
        std.log.warn("unregister: refusing unsafe node name", .{});
        return;
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = registry_dir(io) catch return;
    defer dir.close(io);

    var path_buf: [128]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&path_buf, "{s}.pid", .{name}) catch return;
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| std.log.err("unregister: failed to delete file '{s}': {}", .{ sub_path, e }),
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try registry_dir(io);
    defer dir.close(io);

    // Iterate over the opened, ownership-verified directory handle and read
    // each entry with O_NOFOLLOW so a planted symlink is never followed.
    var it = dir.iterateAssumeFirstIteration();
    var count: usize = 0;
    while (count < entries.len) {
        const entry = it.next(io) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return RegistryErr.FileSystem,
            else => return RegistryErr.FileSystem,
        } orelse break;
        const fname = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (fname.len <= 4) continue;
        if (!std.mem.eql(u8, fname[fname.len - 4 ..], ".pid")) continue;

        const node_name = fname[0 .. fname.len - 4];
        if (!valid_name(node_name)) continue;

        const fd = c.openat(dir.handle, @ptrCast(fname.ptr), os.O{ .ACCMODE = .RDONLY, .NOFOLLOW = true });
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

    var args: [constants.MAX_ARGV][]const u8 = undefined;
    var data: [constants.MAX_ARGV_LEN]u8 = undefined;
    const argc = try read_argv(&args, &data, name);
    try std.testing.expectEqual(@as(usize, 3), argc);
    try std.testing.expectEqualStrings("/bin/echo", args[0]);
    try std.testing.expectEqualStrings("--flag", args[2]);
}

test "read_argv for unknown name returns zero" {
    var args: [constants.MAX_ARGV][]const u8 = undefined;
    var data: [constants.MAX_ARGV_LEN]u8 = undefined;
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
