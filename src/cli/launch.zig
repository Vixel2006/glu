const std = @import("std");
const utils = @import("utils.zig");
const launch_mod = @import("../launch/launcher.zig");
const toml = @import("../launch/toml.zig");
const launch = launch_mod.launch;

var launched_children: []launch_mod.LaunchedNode = &.{};
var launch_io: std.Io = undefined;

fn handleSigint(_: std.os.linux.SIG) callconv(.c) void {
    for (launched_children) |*n| {
        n.child.kill(launch_io);
    }
    std.process.exit(1);
}

pub fn cmdLaunch(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdLaunch_(init, args) catch |err| utils.logErr("launch", err);
}

fn cmdLaunch_(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const file = utils.parseFlag(args, "-f") orelse {
        std.debug.print("usage: glu launch -f <file.toml>\n", .{});
        return error.MissingArgument;
    };

    var config = toml.parse(init.io, init.gpa, file) catch |err| {
        std.debug.print("error parsing launch config '{s}': {}\n", .{ file, err });
        return err;
    };
    defer config.deinit(init.gpa);

    launched_children = try launch(init.io, init.gpa, config.nodes);
    launch_io = init.io;

    var sa: std.os.linux.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);

    std.debug.print("launched {d} node(s)\n", .{launched_children.len});

    for (launched_children) |*n| {
        const term = n.child.wait(init.io) catch |err| {
            std.debug.print("error waiting for node '{s}': {}\n", .{ n.name, err });
            continue;
        };
        switch (term) {
            .exited => |code| std.debug.print("node '{s}' exited with code {d}\n", .{ n.name, code }),
            .signal => |sig| std.debug.print("node '{s}' killed by signal {}\n", .{ n.name, sig }),
            else => std.debug.print("node '{s}' terminated unexpectedly\n", .{ n.name }),
        }
    }

    init.gpa.free(launched_children);
    launched_children = &.{};
}
