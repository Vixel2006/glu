const std = @import("std");
const list_ = @import("cli/list.zig");
const info_ = @import("cli/info.zig");
const ps_ = @import("cli/ps.zig");
const launch_ = @import("cli/launch.zig");
const codegen_ = @import("cli/codegen.zig");

fn printUsage() void {
    std.debug.print(
        \\usage: glu <command> [args]
        \\
        \\commands:
        \\  launch   Launch nodes from a TOML config file
        \\           glu launch -f <file.toml>
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
        launch_.cmdLaunch(init, &args_iter) catch {};
    } else if (std.mem.eql(u8, cmd, "codegen")) {
        codegen_.cmdCodegen(init, &args_iter) catch {};
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        list_.cmdList(init) catch {};
    } else if (std.mem.eql(u8, cmd, "info")) {
        info_.cmdInfo(init, &args_iter) catch {};
    } else if (std.mem.eql(u8, cmd, "ps")) {
        ps_.cmdPs(init) catch {};
    } else {
        printUsage();
    }
}
