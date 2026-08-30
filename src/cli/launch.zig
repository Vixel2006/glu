const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const toml = @import("../launch/toml.zig");
const constants = @import("../constants.zig");
const dispatch = @import("dispatch.zig");
const debug = @import("../debug/mod.zig");

/// Launch nodes from a TOML config (`glu launch -f <file> [-d]`).
pub fn cmd_launch(init: std.process.Init, args: *parser.Args) !void {
    var file: ?[]const u8 = null;
    var detach = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f")) {
            file = args.next();
        } else if (std.mem.eql(u8, arg, "-d")) {
            detach = true;
        }
    }

    const file_path = file orelse {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu launch -f <file.toml> [-d]\n", .{}) catch {};
        return error.MissingArgument;
    };

    var config_buf: [1024]u8 = undefined;
    var config_nodes: [constants.MAX_NODES]toml.NodeConfig = undefined;
    const config_count = toml.parse(init.io, file_path, &config_buf, &config_nodes) catch |err| {
        var ew = utils.err_writer(init);
        ew.interface.print("error parsing launch config '{s}': {}\n", .{ file_path, err }) catch {};
        return err;
    };
    const nodes = config_nodes[0..config_count];

    var fw = utils.writer(init);
    const w = &fw.interface;

    var client = try dispatch.get_client(init);
    defer client.deinit();

    if (detach) {
        const spawned = try client.launch(nodes);
        w.print("launched {d} node(s) in background\n", .{spawned}) catch {};
        return;
    }

    const spawned = try client.launch(nodes);
    w.print("launched {d} node(s)\n", .{spawned}) catch {};

    debug.cleanup_logs(init.io);
}