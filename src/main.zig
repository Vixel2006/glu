const std = @import("std");
const parser = @import("codegen/parser.zig");
const generate = @import("codegen/generator.zig").generate;
const launch = @import("launch/launcher.zig").launch;
const toml = @import("launch/toml.zig");

fn parseFlag(args: *std.process.Args.Iterator, flag: []const u8) ?[]const u8 {
    const f = args.next() orelse return null;
    if (std.mem.eql(u8, f, flag)) return args.next();
    return null;
}

fn cmdLaunch(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const file = parseFlag(args, "-f") orelse {
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
            else => std.debug.print("node '{s}' terminated unexpectedly\n", .{n.name}),
        }
    }
}

fn cmdCodegen(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const file = parseFlag(args, "-f") orelse {
        std.debug.print("usage: glu codegen -f <file.glu>\n", .{});
        return error.MissingArgument;
    };

    const msgs = parser.parse(init, file) catch |err| {
        std.debug.print("error parsing '{s}': {}\n", .{ file, err });
        return err;
    };
    defer {
        for (msgs) |msg| {
            init.gpa.free(msg.name);
            for (msg.fields) |f| {
                init.gpa.free(f.name);
                init.gpa.free(f.type_);
            }
            init.gpa.free(msg.fields);
        }
        init.gpa.free(msgs);
    }

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try generate(init.gpa, init, msgs);
    try out.flush();
}

fn printUsage() void {
    std.debug.print(
        \\usage: glu <command> [args]
        \\
        \\commands:
        \\  launch   Launch nodes from a TOML config file
        \\           glu launch -f <file.toml>
        \\
        \\  codegen  Generate Zig structs from a .glu message definition
        \\           glu codegen -f <file.glu>
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();

    const cmd = args_iter.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "launch")) {
        cmdLaunch(init, &args_iter) catch {};
    } else if (std.mem.eql(u8, cmd, "codegen")) {
        cmdCodegen(init, &args_iter) catch {};
    } else {
        printUsage();
    }
}
