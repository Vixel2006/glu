const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const config = @import("../launch/config.zig");
const constants = @import("../constants.zig");
const protocol = @import("../daemon/protocol.zig");
const daemon_client = @import("../daemon/client.zig");
const IO = @import("../io.zig").IO;

fn fill_node(json_node: *const config.NodeConfig, node: *protocol.Node) void {
    node.* = std.mem.zeroes(protocol.Node);
    node.pid = null;
    node.uptime = null;

    const name = @min(json_node.name.len, protocol.Node.name_buf_len - 1);
    @memcpy(node.name[0..name], json_node.name[0..name]);
    node.name_len = @intCast(name);

    if (json_node.bin.len > 0) {
        const n = @min(json_node.bin.len, node.bin.len - 1);
        @memcpy(node.bin[0..n], json_node.bin[0..n]);
        node.bin_len = @intCast(n);
    }
    if (json_node.path.len > 0) {
        const n = @min(json_node.path.len, node.path.len - 1);
        @memcpy(node.path[0..n], json_node.path[0..n]);
        node.path_len = @intCast(n);
    }

    const nargs = @min(json_node.extra_cfg_len, constants.MAX_ARGS);
    for (json_node.extra_cfg[0..nargs]) |arg| {
        const n = @min(arg.len, protocol.Node.arg_buf_len - 1);
        const slot = &node.extra_cfg[node.extra_cfg_len];
        @memcpy(slot[0..n], arg[0..n]);
        node.extra_cfg_lens[node.extra_cfg_len] = @intCast(n);
        node.extra_cfg_len += 1;
    }
}

/// Launch nodes from a json config (`glu launch -f <file>`).
pub fn cmd_launch(init: std.process.Init, args: *parser.Args) !void {
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f")) {
            file = args.next();
        }
    }

    const file_path = file orelse {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu launch -f <file.json>\n", .{}) catch {};
        return error.MissingArgument;
    };

    var config_nodes: [constants.MAX_NODES]config.NodeConfig = undefined;
    var arena: std.heap.ArenaAllocator = undefined;
    const config_count = config.parse(
        init.gpa,
        init.io,
        file_path,
        &config_nodes,
        &arena,
    ) catch |err| {
        var ew = utils.err_writer(init);
        ew.interface.print("error parsing launch config '{s}': {}\n", .{ file_path, err }) catch {};
        return err;
    };
    defer arena.deinit();
    const json_nodes = config_nodes[0..config_count];

    if (json_nodes.len == 0) {
        var ew = utils.err_writer(init);
        ew.interface.print("no nodes found in '{s}'\n", .{file_path}) catch {};
        return error.NoNodes;
    }

    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var nodes: [constants.MAX_NODES]protocol.Node = undefined;
    for (json_nodes, 0..) |tn, i| fill_node(&tn, &nodes[i]);

    try client.launch(nodes[0..json_nodes.len]);
    w.print("launched {d} node(s)\n", .{json_nodes.len}) catch {};
}
