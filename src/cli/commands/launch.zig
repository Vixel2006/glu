const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;
const launch_cfg = @import("../../launch/config.zig");

pub fn cmd_launch(init: std.process.Init, args: *parser.Args) !void {
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f")) {
            config_path = args.next();
            continue;
        }
        if (std.mem.eql(u8, arg, "-d")) {
            continue;
        }
    }

    const path = config_path orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu launch -f <file.json>\n") catch {};
        return error.MissingArgument;
    };

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const data = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(data);
    _ = try file.readAll(data);

    const cfg = try launch_cfg.parse(data);

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var n: u32 = 0;
    for (cfg.nodes) |node| {
        var np: protocol.Node = std.mem.zeroes(protocol.Node);
        fill_node(&np, &node);
        const ok = try client.launch_node(&np);
        if (ok) n += 1;
    }

    var fw = utils.writer(init);
    fw.interface.print("launched {d} node(s) from {s}\n", .{ n, path }) catch {};
}

fn fill_node(dst: *protocol.Node, src: *launch_cfg.Node) void {
    const name_len = @min(src.name.len, constants.MAX_NAME_LEN);
    @memcpy(dst.name[0..name_len], src.name[0..name_len]);
    dst.name[name_len] = 0;
    dst.name_len = @intCast(name_len);

    const bin_len = @min(src.executable.len, constants.MAX_PATH_LEN);
    @memcpy(dst.bin[0..bin_len], src.executable[0..bin_len]);
    dst.bin[bin_len] = 0;
    dst.bin_len = @intCast(bin_len);

    const cwd_len = @min(src.cwd.len, constants.MAX_PATH_LEN);
    @memcpy(dst.cwd[0..cwd_len], src.cwd[0..cwd_len]);
    dst.cwd[cwd_len] = 0;
    dst.cwd_len = @intCast(cwd_len);

    const out_len = @min(src.log_output.len, constants.MAX_PATH_LEN);
    @memcpy(dst.out[0..out_len], src.log_output[0..out_len]);
    dst.out[out_len] = 0;
    dst.out_len = @intCast(out_len);

    const err_len = @min(src.log_error.len, constants.MAX_PATH_LEN);
    @memcpy(dst.err[0..err_len], src.log_error[0..err_len]);
    dst.err[err_len] = 0;
    dst.err_len = @intCast(err_len);

    dst.num_args = 0;
    for (src.args, 0..) |a, i| {
        if (i >= constants.MAX_ARGS) break;
        const l = @min(a.len, constants.MAX_ARG_LEN);
        @memcpy(dst.args[i][0..l], a[0..l]);
        dst.args[i][l] = 0;
        dst.args_len[i] = @intCast(l);
        dst.num_args += 1;
    }
    dst.autostart = src.autostart;
}
