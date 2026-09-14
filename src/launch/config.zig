const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const constants = @import("../constants.zig");

pub const NodeConfig = struct {
    name: []const u8 = "",
    path: []const u8 = "",
    bin: []const u8 = "",
    extra_cfg: []const []const u8 = &.{},
    extra_cfg_len: usize = 0,
};

pub const LaunchConfig = struct {
    node: []const NodeConfig,
};

pub fn parse(
    allocator: Allocator,
    io: std.Io,
    file_path: []const u8,
    nodes: []NodeConfig,
    arena: *std.heap.ArenaAllocator,
) !usize {
    assert(file_path.len > 0);

    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    const size: usize = @intCast(file.length(io) catch return error.FileSystem);
    const buf = try a.alloc(u8, size);
    const got = file.readPositionalAll(io, buf, 0) catch return error.FileSystem;

    const parsed = try std.json.parseFromSlice(
        LaunchConfig,
        a,
        buf[0..got],
        .{ .ignore_unknown_fields = true },
    );

    var num_nodes: usize = 0;
    for (parsed.value.node, 0..) |n, i| {
        if (i >= nodes.len) break;
        const len_cfg = @min(n.extra_cfg.len, constants.MAX_ARGS);
        nodes[i] = .{
            .name = n.name,
            .path = n.path,
            .bin = n.bin,
            .extra_cfg = n.extra_cfg,
            .extra_cfg_len = len_cfg,
        };
        num_nodes += 1;
    }

    return num_nodes;
}
