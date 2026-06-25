const std = @import("std");
const list = @import("cli/list.zig");
const info = @import("cli/info.zig");
const ps = @import("cli/ps.zig");
const launch = @import("cli/launch.zig");
const logs = @import("cli/logs.zig");
const codegen = @import("cli/codegen.zig");
const down = @import("cli/down.zig");

fn printUsage() void {
    std.debug.print(
        \\usage: glu <command> [args]
        \\
        \\commands:
        \\  launch   Launch nodes from a TOML config file
        \\           glu launch -f <file.toml> [-d]
        \\
        \\  codegen  Generate Zig structs from a .glu message definition
        \\           glu codegen -f <file.glu> -o <path/to/gen>
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
        launch.cmdLaunch(init, &args_iter);
    } else if (std.mem.eql(u8, cmd, "codegen")) {
        codegen.cmdCodegen(init, &args_iter);
    } else if (std.mem.eql(u8, cmd, "logs")) {
        logs.cmdLogs(init, &args_iter);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        list.cmdList(init);
    } else if (std.mem.eql(u8, cmd, "info")) {
        info.cmdInfo(init, &args_iter);
    } else if (std.mem.eql(u8, cmd, "ps")) {
        ps.cmdPs(init);
    } else if (std.mem.eql(u8, cmd, "down")) {
        down.cmdDown(init);
    } else {
        printUsage();
    }
}
