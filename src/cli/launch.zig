const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const toml = @import("../launch/toml.zig");
const constants = @import("../constants.zig");
const protocol = @import("../daemon/protocol.zig");
const daemon_client = @import("../daemon/client.zig");
const IO = @import("../io.zig").IO;

fn fill_node(toml_node: *const toml.NodeConfig, node: *protocol.Node) void {
    node.* = std.mem.zeroes(protocol.Node);
    node.pid = null;
    node.uptime = null;

    const name = @min(toml_node.name.len, protocol.Node.name_buf_len - 1);
    @memcpy(node.name[0..name], toml_node.name[0..name]);
    node.name_len = @intCast(name);

    if (toml_node.bin.len > 0) {
        const n = @min(toml_node.bin.len, node.bin.len - 1);
        @memcpy(node.bin[0..n], toml_node.bin[0..n]);
        node.bin_len = @intCast(n);
    }
    if (toml_node.path.len > 0) {
        const n = @min(toml_node.path.len, node.path.len - 1);
        @memcpy(node.path[0..n], toml_node.path[0..n]);
        node.path_len = @intCast(n);
    }

    const nargs = @min(toml_node.extra_cfg_len, constants.MAX_ARGS);
    for (toml_node.extra_cfg[0..nargs]) |arg| {
        const n = @min(arg.len, protocol.Node.arg_buf_len - 1);
        const slot = &node.extra_cfg[node.extra_cfg_len];
        @memcpy(slot[0..n], arg[0..n]);
        node.extra_cfg_lens[node.extra_cfg_len] = @intCast(n);
        node.extra_cfg_len += 1;
    }
}

/// Launch nodes from a TOML config (`glu launch -f <file>`).
pub fn cmd_launch(init: std.process.Init, args: *parser.Args) !void {
    var file: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f")) {
            file = args.next();
        } else if (std.mem.eql(u8, arg, "-d")) {
            // Legacy flag: the daemon always launches in the background.
            continue;
        }
    }

    const file_path = file orelse {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu launch -f <file.toml>\n", .{}) catch {};
        return error.MissingArgument;
    };

    var config_buf: [1024]u8 = undefined;
    var config_nodes: [constants.MAX_NODES]toml.NodeConfig = undefined;
    const config_count = toml.parse(init.io, file_path, &config_buf, &config_nodes) catch |err| {
        var ew = utils.err_writer(init);
        ew.interface.print("error parsing launch config '{s}': {}\n", .{ file_path, err }) catch {};
        return err;
    };
    const toml_nodes = config_nodes[0..config_count];

    if (toml_nodes.len == 0) {
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
    for (toml_nodes, 0..) |tn, i| fill_node(&tn, &nodes[i]);

    try client.launch(nodes[0..toml_nodes.len]);
    w.print("launched {d} node(s)\n", .{toml_nodes.len}) catch {};
}
