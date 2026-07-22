const std = @import("std");
const os = std.os.linux;
const utils = @import("utils.zig");
const topic = @import("../topic/mod.zig");
const debug = @import("../debug/mod.zig");
const launch_mod = @import("../launch/launcher.zig");
const toml = @import("../launch/toml.zig");
const Registry = @import("../registry.zig");

var launched_children: []launch_mod.LaunchedNode = &.{};
var launch_io: std.Io = undefined;

fn handleSigint(_: os.SIG) callconv(.c) void {
    for (launched_children) |*n| {
        n.child.kill(launch_io);
        Registry.unregister(n.name);
    }
    topic.cleanupTopics();
    debug.cleanupLogs(launch_io);
    std.process.exit(1);
}

/// Launch nodes from a TOML config (`glu launch -f <file> [-d]`).
pub fn cmdLaunch(init: std.process.Init, args: *std.process.Args.Iterator) !void {
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
        var ew = utils.errWriter(init);
        ew.interface.print("usage: glu launch -f <file.toml> [-d]\n", .{}) catch {};
        return error.MissingArgument;
    };

    var config = toml.parse(init.io, init.gpa, file_path) catch |err| {
        var ew = utils.errWriter(init);
        ew.interface.print("error parsing launch config '{s}': {}\n", .{ file_path, err }) catch {};
        return err;
    };
    defer config.deinit(init.gpa);

    if (detach) {
        try launch_mod.launchDetached(init.io, init.gpa, config.nodes, "/tmp/glu/logs");
        var fw = utils.writer(init);
        fw.interface.print("launched {d} node(s) in background\n", .{config.nodes.len}) catch {};
        return;
    }

    launched_children = try launch_mod.launch(init.io, init.gpa, config.nodes);
    launch_io = init.io;

    var sa: os.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = os.sigemptyset(),
        .flags = 0,
    };
    _ = os.sigaction(os.SIG.INT, &sa, null);

    {
        var fw = utils.writer(init);
        fw.interface.print("launched {d} node(s)\n", .{launched_children.len}) catch {};
    }

    for (launched_children) |*n| {
        const term = n.child.wait(init.io) catch |err| {
            var fw = utils.writer(init);
            fw.interface.print("error waiting for node '{s}': {}\n", .{ n.name, err }) catch {};
            continue;
        };
        var fw = utils.writer(init);
        switch (term) {
            .exited => |code| fw.interface.print("node '{s}' exited with code {d}\n", .{ n.name, code }) catch {},
            .signal => |sig| fw.interface.print("node '{s}' killed by signal {}\n", .{ n.name, sig }) catch {},
            else => fw.interface.print("node '{s}' terminated unexpectedly\n", .{n.name}) catch {},
        }
    }

    debug.cleanupLogs(init.io);

    init.gpa.free(launched_children);
    launched_children = &.{};
}
