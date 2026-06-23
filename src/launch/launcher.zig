const std = @import("std");
const NodeConfig = @import("toml.zig").NodeConfig;
const Registry = @import("../registry.zig");

pub const LaunchedNode = struct {
    name: []const u8,
    child: std.process.Child,
};

fn buildArgv(allocator: std.mem.Allocator, cfg: *const NodeConfig) ![]const []const u8 {
    if (cfg.bin.len > 0) {
        const args = try allocator.alloc([]const u8, 1 + cfg.extra_cfg.len);
        args[0] = cfg.bin;
        for (cfg.extra_cfg, 0..) |arg, i| args[1 + i] = arg;
        return args;
    }

    const args = try allocator.alloc([]const u8, 4 + cfg.extra_cfg.len);
    args[0] = "zig";
    args[1] = "run";
    args[2] = cfg.path;
    args[3] = "--";
    for (cfg.extra_cfg, 0..) |arg, i| args[4 + i] = arg;
    return args;
}

pub fn launch(io: std.Io, allocator: std.mem.Allocator, cfgs: []const NodeConfig) ![]LaunchedNode {
    var launched = try std.ArrayListAligned(LaunchedNode, null).initCapacity(allocator, cfgs.len);
    errdefer {
        for (launched.items) |*n| n.child.kill(io);
        launched.deinit(allocator);
    }

    for (cfgs) |cfg| {
        const argv = try buildArgv(allocator, &cfg);
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdout = .inherit,
            .stdin = .inherit,
            .stderr = .inherit,
        });
        allocator.free(argv);
        launched.appendAssumeCapacity(.{ .name = cfg.name, .child = child });
    }

    return launched.toOwnedSlice(allocator);
}

pub fn launchDetached(io: std.Io, allocator: std.mem.Allocator, cfgs: []const NodeConfig) void {
    for (cfgs) |cfg| {
        const argv = buildArgv(allocator, &cfg) catch continue;
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .ignore,
            .stdin = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            allocator.free(argv);
            std.debug.print("error spawning '{s}': {s}\n", .{ cfg.name, @errorName(err) });
            continue;
        };
        allocator.free(argv);
        if (child.id) |pid| Registry.registerPid(cfg.name, @intCast(pid)) catch {};
    }
}

fn testNodePath(allocator: std.mem.Allocator, dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &dir.sub_path, name });
}

test "launch and wait" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "ok.zig", .data = "pub fn main() u8 { return 0; }" });
    const path = try testNodePath(allocator, dir, "ok.zig");
    defer allocator.free(path);

    const cfgs = &[_]NodeConfig{.{ .name = "ok", .path = path }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    try std.testing.expectEqual(@as(usize, 1), launched.len);
    try std.testing.expectEqualStrings("ok", launched[0].name);
    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}

test "launch with extra arguments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const node_src =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init.Minimal) !void {
        \\    var iter = std.process.Args.Iterator.init(init.args);
        \\    _ = iter.next();
        \\    const first = iter.next() orelse std.process.exit(1);
        \\    const second = iter.next() orelse std.process.exit(2);
        \\    if (std.mem.eql(u8, first, "--fps") and std.mem.eql(u8, second, "30"))
        \\        std.process.exit(0)
        \\    else
        \\        std.process.exit(3);
        \\}
    ;
    try dir.dir.writeFile(io, .{ .sub_path = "args.zig", .data = node_src });
    const path = try testNodePath(allocator, dir, "args.zig");
    defer allocator.free(path);

    const extra = &[_][]const u8{ "--fps", "30" };
    const cfgs = &[_]NodeConfig{.{ .name = "args_test", .path = path, .extra_cfg = extra }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}
