const std = @import("std");
const utils = @import("utils.zig");
const launch = @import("../launch/launcher.zig").launch;
const toml = @import("../launch/toml.zig");

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

    const launched = launch(init.io, init.gpa, config.nodes) catch |err| {
        std.debug.print("error launching nodes: {}\n", .{err});
        return err;
    };
    defer init.gpa.free(launched);

    for (launched) |*n| {
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
}
