const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const status = @import("status.zig");
const launch = @import("launch.zig");
const nodes_list = @import("nodes/list.zig");
const nodes_action = @import("nodes/action.zig");
const nodes_logs = @import("nodes/logs.zig");
const nodes_down = @import("nodes/down.zig");
const topics_list = @import("topics/list.zig");
const topics_info = @import("topics/info.zig");
const net_cmd = @import("net.zig");
const constants = @import("../constants.zig");

const RunFn = *const fn (init: std.process.Init, args: *parser.Args) anyerror!void;

/// A runnable command, addressed by its tree path (`nodes list`, `status`).
/// `alias`/`alias2` are the legacy flat names that still work.
const Leaf = struct {
    path: []const u8,
    usage: []const u8,
    summary: []const u8,
    run: RunFn,
    alias: []const u8 = "",
    alias2: []const u8 = "",
};

const leaves = [_]Leaf{
    .{ .path = "status", .usage = "glu status", .summary = "Overview of nodes and topics", .run = &status.cmd_status },
    .{ .path = "launch", .usage = "glu launch -f <file.toml> [-d]", .summary = "Launch nodes from a TOML config file", .run = &launch.cmd_launch },
    .{ .path = "nodes list", .usage = "glu nodes list", .summary = "List registered nodes", .run = &nodes_list.cmd_list, .alias = "ps" },
    .{ .path = "nodes start", .usage = "glu nodes start <node> [node...]", .summary = "Start named nodes from their manifest", .run = &nodes_action.cmd_start, .alias = "start" },
    .{ .path = "nodes stop", .usage = "glu nodes stop <node> [node...]", .summary = "Stop named nodes", .run = &nodes_down.cmd_stop, .alias = "stop" },
    .{ .path = "nodes restart", .usage = "glu nodes restart <node> [node...]", .summary = "Restart named nodes", .run = &nodes_action.cmd_restart, .alias = "restart" },
    .{ .path = "nodes logs", .usage = "glu nodes logs [--tail <n>] [--head <n>] [-f] <node>", .summary = "Print or follow a node's log", .run = &nodes_logs.cmd_logs, .alias = "logs" },
    .{ .path = "nodes down", .usage = "glu nodes down [node...]", .summary = "Stop all nodes, or the named ones", .run = &nodes_down.cmd_down, .alias = "down" },
    .{ .path = "topics list", .usage = "glu topics list", .summary = "List active topics in shared memory", .run = &topics_list.cmd_list, .alias = "list", .alias2 = "ls" },
    .{ .path = "topics info", .usage = "glu topics info <topic>", .summary = "Show detailed info about a topic", .run = &topics_info.cmd_info, .alias = "info" },
    .{ .path = "net list", .usage = "glu net list", .summary = "List active network channels", .run = &net_cmd.cmd_list },
    .{ .path = "net info", .usage = "glu net info <channel>", .summary = "Show detailed info about a network channel", .run = &net_cmd.cmd_info },
    .{ .path = "net sniff", .usage = "glu net sniff <channel> [-v]", .summary = "Sniff live traffic on a network channel", .run = &net_cmd.cmd_sniff, .alias = "sniff" },
};

const Group = struct {
    name: []const u8,
    summary: []const u8,
    members: []const u8,
};

const groups = [_]Group{
    .{ .name = "nodes", .summary = "Manage node processes", .members = "list, start, stop, restart, logs, down" },
    .{ .name = "topics", .summary = "Inspect shared-memory topics", .members = "list, info" },
    .{ .name = "net", .summary = "Discover and inspect network channels", .members = "list, info, sniff" },
};

fn is_group(name: []const u8) bool {
    for (groups) |g| {
        if (std.mem.eql(u8, g.name, name)) return true;
    }
    return false;
}

fn find_path(path: []const u8) ?*const Leaf {
    for (&leaves) |*leaf| {
        if (std.mem.eql(u8, leaf.path, path)) return leaf;
    }
    return null;
}

fn find_alias(name: []const u8) ?*const Leaf {
    for (&leaves) |*leaf| {
        if (leaf.alias.len > 0 and std.mem.eql(u8, leaf.alias, name)) return leaf;
        if (leaf.alias2.len > 0 and std.mem.eql(u8, leaf.alias2, name)) return leaf;
    }
    return null;
}

/// Resolve `glu <group> <sub>` to its leaf, e.g. `("nodes", "stop")`.
fn find_group(group: []const u8, sub: []const u8) ?*const Leaf {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s} {s}", .{ group, sub }) catch return null;
    return find_path(path);
}

/// A leaf whose path begins with `group + " "`, i.e. a group member.
fn in_group(leaf: *const Leaf, group: []const u8) bool {
    if (leaf.path.len <= group.len + 1) return false;
    if (!std.mem.eql(u8, leaf.path[0..group.len], group)) return false;
    return leaf.path[group.len] == ' ';
}

/// A top-level leaf has no group prefix (`status`, `launch`).
fn top_level(leaf: *const Leaf) bool {
    return std.mem.indexOfScalar(u8, leaf.path, ' ') == null;
}

fn print_top(init: std.process.Init, to_stderr: bool) void {
    var fw = if (to_stderr) utils.err_writer(init) else utils.writer(init);
    const w = &fw.interface;
    w.print(
        \\usage: glu <command> [args]
        \\
        \\commands:
        \\
    , .{}) catch {};
    for (&leaves) |*leaf| {
        if (top_level(leaf)) {
            w.print("  {s:<8} {s}\n", .{ leaf.path, leaf.summary }) catch {};
        }
    }
    for (groups) |g| {
        w.print("  {s:<8} {s} ({s})\n", .{ g.name, g.summary, g.members }) catch {};
    }
    w.print(
        \\
        \\run 'glu help <command>' for usage
        \\
    , .{}) catch {};
}

fn print_group(init: std.process.Init, group: []const u8, to_stderr: bool) void {
    var fw = if (to_stderr) utils.err_writer(init) else utils.writer(init);
    const w = &fw.interface;
    w.print("usage: glu {s} <command> [args]\n\ncommands:\n", .{group}) catch {};
    for (&leaves) |*leaf| {
        if (!in_group(leaf, group)) continue;
        const sub = leaf.path[group.len + 1 ..];
        w.print("  {s:<10} {s}\n", .{ sub, leaf.summary }) catch {};
    }
    w.print("\nrun 'glu help {s} <command>' for usage\n", .{group}) catch {};
}

fn print_leaf(init: std.process.Init, leaf: *const Leaf) void {
    var fw = utils.writer(init);
    const w = &fw.interface;
    w.print("{s}\n\nusage: {s}\n", .{ leaf.summary, leaf.usage }) catch {};
}

fn run_leaf(init: std.process.Init, leaf: *const Leaf, args: *parser.Args) void {
    leaf.run(init, args) catch |err| {
        var fw = utils.err_writer(init);
        fw.interface.print("error: {s}: {s}\n", .{ leaf.path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
}

fn unknown(init: std.process.Init, cmd: []const u8, group: ?[]const u8) noreturn {
    var ew = utils.err_writer(init);
    const w = &ew.interface;
    if (group) |g| {
        w.print("glu: unknown command '{s} {s}'\n", .{ g, cmd }) catch {};
        print_group(init, g, true);
    } else {
        w.print("glu: unknown command '{s}'\n", .{cmd}) catch {};
        print_top(init, true);
    }
    std.process.exit(1);
}

fn help_cmd(init: std.process.Init, args: *parser.Args) void {
    const topic = args.next() orelse {
        print_top(init, false);
        return;
    };
    if (is_group(topic)) {
        const sub = args.next() orelse {
            print_group(init, topic, false);
            return;
        };
        const leaf = find_group(topic, sub) orelse unknown(init, sub, topic);
        print_leaf(init, leaf);
        return;
    }
    const leaf = find_path(topic) orelse find_alias(topic) orelse unknown(init, topic, null);
    print_leaf(init, leaf);
}

/// Route `glu <command> [args]` from the raw process arguments.
pub fn run(init: std.process.Init) void {
    var args = parser.Args.init(init);

    const cmd = args.next() orelse {
        print_top(init, false);
        return;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        print_top(init, false);
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        var fw = utils.writer(init);
        fw.interface.print("glu {s}\n", .{constants.VERSION}) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        help_cmd(init, &args);
        return;
    }

    if (is_group(cmd)) {
        const sub = args.next() orelse {
            print_group(init, cmd, false);
            return;
        };
        if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
            print_group(init, cmd, false);
            return;
        }
        const leaf = find_group(cmd, sub) orelse unknown(init, sub, cmd);
        run_leaf(init, leaf, &args);
        return;
    }

    const leaf = find_path(cmd) orelse find_alias(cmd) orelse unknown(init, cmd, null);
    run_leaf(init, leaf, &args);
}

test "aliases resolve to tree commands" {
    const cases = [_][2][]const u8{
        .{ "ps", "nodes list" },
        .{ "start", "nodes start" },
        .{ "stop", "nodes stop" },
        .{ "restart", "nodes restart" },
        .{ "logs", "nodes logs" },
        .{ "down", "nodes down" },
        .{ "list", "topics list" },
        .{ "ls", "topics list" },
        .{ "info", "topics info" },
        .{ "sniff", "net sniff" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], find_alias(c[0]).?.path);
    }
}

test "tree paths resolve directly" {
    try std.testing.expectEqualStrings("status", find_path("status").?.path);
    try std.testing.expectEqualStrings("launch", find_path("launch").?.path);
    try std.testing.expectEqualStrings("nodes stop", find_group("nodes", "stop").?.path);
    try std.testing.expectEqualStrings("topics info", find_group("topics", "info").?.path);
    try std.testing.expectEqualStrings("net sniff", find_group("net", "sniff").?.path);
    try std.testing.expect(find_group("nodes", "bogus") == null);
}

test "group membership" {
    try std.testing.expect(is_group("nodes"));
    try std.testing.expect(is_group("topics"));
    try std.testing.expect(is_group("net"));
    try std.testing.expect(!is_group("status"));
    try std.testing.expectEqualStrings("list, start, stop, restart, logs, down", groups[0].members);
    try std.testing.expectEqualStrings("list, info", groups[1].members);
    try std.testing.expectEqualStrings("list, info, sniff", groups[2].members);
}
