const std = @import("std");
const c = std.c;
const os = std.os.linux;
const utils = @import("utils.zig");
const launch_mod = @import("../launch/launcher.zig");
const toml = @import("../launch/toml.zig");
const Registry = @import("../registry.zig");

var launched_children: []launch_mod.LaunchedNode = &.{};
var launch_io: std.Io = undefined;

fn cleanupShm() void {
    const Header = @import("../channel.zig").Header;
    const GLU_MAGIC = @import("../channel.zig").GLU_MAGIC;

    const dirp = c.opendir("/dev/shm") orelse return;
    defer _ = c.closedir(dirp);

    while (true) {
        const entry = c.readdir(dirp) orelse break;
        if (entry.type != 8) continue;
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, "sem.")) continue;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name_z = std.fmt.bufPrintZ(&shm_name_buf, "/{s}", .{name}) catch continue;

        const fd = c.shm_open(shm_name_z.ptr, 0, 0);
        if (fd == -1) continue;
        defer _ = c.close(fd);

        const mapped = os.mmap(null, @sizeOf(Header), os.PROT{ .READ = true }, os.MAP{ .TYPE = .SHARED }, fd, 0);
        if (mapped == ~@as(usize, 0)) continue;

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *align(1) Header = @ptrCast(ptr);
        const is_glu = hdr.magic == GLU_MAGIC;
        _ = os.munmap(@ptrFromInt(mapped), @sizeOf(Header));

        if (is_glu) _ = c.shm_unlink(shm_name_z.ptr);
    }
}

fn handleSigint(_: os.SIG) callconv(.c) void {
    for (launched_children) |*n| {
        n.child.kill(launch_io);
        Registry.unregister(n.name);
    }
    cleanupShm();
    std.process.exit(1);
}

pub fn cmdLaunch(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdLaunch_(init, args) catch |err| utils.logErr("launch", err);
}

fn cmdLaunch_(init: std.process.Init, args: *std.process.Args.Iterator) !void {
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
        std.debug.print("usage: glu launch -f <file.toml> [-d]\n", .{});
        return error.MissingArgument;
    };

    var config = toml.parse(init.io, init.gpa, file_path) catch |err| {
        std.debug.print("error parsing launch config '{s}': {}\n", .{ file_path, err });
        return err;
    };
    defer config.deinit(init.gpa);

    if (detach) {
        launch_mod.launchDetached(init.io, init.gpa, config.nodes);
        std.debug.print("launched {d} node(s) in background\n", .{config.nodes.len});
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
