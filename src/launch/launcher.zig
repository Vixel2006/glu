const std = @import("std");
const NodeConfig = @import("toml.zig").NodeConfig;

pub const LaunchedNode = struct {
    name: []const u8,
    child: std.process.Child,
};

pub fn launch(io: std.Io, allocator: std.mem.Allocator, cfgs: []const NodeConfig) ![]LaunchedNode {
    var launched = try std.ArrayListAligned(LaunchedNode, null).initCapacity(allocator, cfgs.len);
    errdefer {
        for (launched.items) |*n| n.child.kill(io);
        launched.deinit(allocator);
    }

    for (cfgs) |cfg| {
        const argv = try allocator.alloc([]const u8, 3 + cfg.extra_cfg.len);
        argv[0] = "zig";
        argv[1] = "run";
        argv[2] = cfg.path;
        for (cfg.extra_cfg, 0..) |arg, i| argv[3 + i] = arg;

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .inherit,
            .stdin = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            allocator.free(argv);
            return err;
        };
        allocator.free(argv);

        launched.appendAssumeCapacity(.{ .name = cfg.name, .child = child });
    }

    return launched.toOwnedSlice(allocator);
}

fn testNodePath(allocator: std.mem.Allocator, dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &dir.sub_path, name });
}

test "launch single node exits with code 0" {
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

test "launch node exits with non-zero code" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "fail.zig", .data = "pub fn main() u8 { return 42; }" });
    const path = try testNodePath(allocator, dir, "fail.zig");
    defer allocator.free(path);

    const cfgs = &[_]NodeConfig{.{ .name = "fail", .path = path }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 42 });
}

test "launch multiple nodes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn main() u8 { return 0; }" });
    try dir.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "pub fn main() u8 { return 1; }" });

    const path_a = try testNodePath(allocator, dir, "a.zig");
    defer allocator.free(path_a);
    const path_b = try testNodePath(allocator, dir, "b.zig");
    defer allocator.free(path_b);

    const cfgs = &[_]NodeConfig{
        .{ .name = "node_a", .path = path_a },
        .{ .name = "node_b", .path = path_b },
    };
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    try std.testing.expectEqual(@as(usize, 2), launched.len);
    try std.testing.expectEqualStrings("node_a", launched[0].name);
    try std.testing.expectEqualStrings("node_b", launched[1].name);

    const term_a = try launched[0].child.wait(io);
    const term_b = try launched[1].child.wait(io);
    try std.testing.expectEqual(term_a, std.process.Child.Term{ .exited = 0 });
    try std.testing.expectEqual(term_b, std.process.Child.Term{ .exited = 1 });
}

test "launch node with extra_cfg passes arguments" {
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

    const extra = &[_][]const u8{ "--", "--fps", "30" };
    const cfgs = &[_]NodeConfig{.{ .name = "args_test", .path = path, .extra_cfg = extra }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}
