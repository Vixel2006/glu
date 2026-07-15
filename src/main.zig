const std = @import("std");
const utils = @import("cli/utils.zig");
const list = @import("cli/list.zig");
const info = @import("cli/info.zig");
const ps = @import("cli/ps.zig");
const launch = @import("cli/launch.zig");
const logs = @import("cli/logs.zig");
const down = @import("cli/down.zig");

fn printUsage(init: std.process.Init) void {
    var fw = utils.writer(init);
    const w = &fw.interface;
    w.print(
        \\usage: glu <command> [args]
        \\
        \\commands:
        \\  launch   Launch nodes from a TOML config file
        \\           glu launch -f <file.toml> [-d]
        \\
        \\  list     List active topics in shared memory
        \\           glu list
        \\
        \\  info     Show detailed info about a topic
        \\           glu info <topic>
        \\
        \\  ps       List registered nodes
        \\           glu ps
        \\
        \\  logs     Print out all the logs for a specific node when launching with -d flag
        \\           glu logs <node>
        \\
        \\  down     Stop all running nodes
        \\           glu down
        \\
    , .{}) catch {};
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();


    var evented: std.Io.Evented = undefined;
    var evented_active = false;

    if (comptime std.Io.Evented != void) {
        try evented.init(init.gpa, .{
            .argv0 = .init(.{ .vector = init.minimal.args.vector }),
            .environ = .{ .block = init.minimal.environ.block },
        });
        evented_active = true;
    }
    defer if(evented_active) evented.deinit();


    var m_init = init;

    if (evented_active) m_init.io = evented.io();

    const cmd = args_iter.next() orelse {
        printUsage(init);
        return;
    };

    if (std.mem.eql(u8, cmd, "launch")) {
        launch.cmdLaunch(m_init, &args_iter) catch |err| utils.logErr("launch", err);
    } else if (std.mem.eql(u8, cmd, "logs")) {
        logs.cmdLogs(m_init, &args_iter, "/tmp/glu/logs") catch |err| utils.logErr("logs", err);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        list.cmdList(m_init) catch |err| utils.logErr("list", err);
    } else if (std.mem.eql(u8, cmd, "info")) {
        info.cmdInfo(m_init, &args_iter) catch |err| utils.logErr("info", err);
    } else if (std.mem.eql(u8, cmd, "ps")) {
        ps.cmdPs(m_init) catch |err| utils.logErr("ps", err);
    } else if (std.mem.eql(u8, cmd, "down")) {
        down.cmdDown(m_init) catch |err| utils.logErr("down", err);
    } else {
        printUsage(m_init);
    }
}
