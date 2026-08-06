// logger — best-effort topic consumer + async persistence.
//
// This node never uses the high-level Publisher/Subscriber wrappers.
// Instead it opens the low-level `glu.Channel` for the best-effort logs
// topic, claims a raw reader slot, and consumes with the `glu.peek` /
// `glu.ack` free functions. Each log line is then appended to
// telemetry.log with io_uring file I/O (io.openat → io.write → periodic
// io.fsync), so disk writes never block the coordinator that produces them.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");
const util = @import("util.zig");

const IO = glu.IO;

const topic_logs = "/robot/logs";
const log_capacity = 256;
const node_name = "logger";
const log_file = "telemetry.log";
const tick_rate_hz = 200;

pub fn main() void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[logger] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var chan = glu.Channel.open(topic_logs, @sizeOf(msgs.LogEntry), log_capacity, .best_effort) catch |e| {
        std.debug.print("[logger] raw channel open failed: {}\n", .{e});
        return;
    };
    defer chan.close();

    glu.registry.register(node_name) catch |e| {
        std.debug.print("[logger] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister(node_name);

    // Claim raw reader slot 0 on the shared channel: pack our PID with the
    // current write cursor so the publisher's sweep can't kill a live reader.
    const my_pid: u32 = @intCast(std.os.linux.getpid());
    @atomicStore(u64, &chan.header.readers[0], (@as(u64, my_pid) << 32) | chan.header.write, .release);

    var path_buf: [256:0]u8 = undefined;
    @memcpy(path_buf[0..log_file.len], log_file);
    path_buf[log_file.len] = 0;

    var compl: IO.Future = undefined;
    io.openat(
        &compl,
        std.posix.AT.FDCWD,
        path_buf[0..log_file.len :0],
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch |e| {
        std.debug.print("[logger] open {s} failed: {}\n", .{ log_file, e });
        return;
    };
    const fd = io.wait(&compl, std.posix.fd_t) catch |e| {
        std.debug.print("[logger] open {s} wait failed: {}\n", .{ log_file, e });
        return;
    };
    defer {
        var c: IO.Future = undefined;
        io.close(&c, fd) catch {};
        io.wait(&c, void) catch {};
    }

    std.debug.print(
        "[logger] best-effort log consumer (raw glu.peek/ack)\n" ++
            "[logger]   {s} ← raw best-effort channel\n" ++
            "[logger]   async io_uring write → {s}\n" ++
            "[logger]   Ctrl-C to stop\n",
        .{ topic_logs, log_file },
    );

    var pending: u32 = 0;

    while (true) {
        const w = @atomicLoad(u32, &chan.header.write, .acquire);
        var r: u32 = @truncate(@atomicLoad(u64, &chan.header.readers[0], .acquire));
        while (r < w) {
            const raw = glu.peek(&chan, 0);
            const entry: *const msgs.LogEntry = @ptrCast(@alignCast(raw));

            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "{d} lv={d} src={s} {s}\n",
                .{
                    entry.seq,
                    entry.level,
                    std.mem.sliceTo(entry.source[0..], 0),
                    std.mem.sliceTo(entry.msg[0..], 0),
                },
            ) catch break;
            io.write(&compl, fd, line, 0) catch break;
            _ = io.wait(&compl, usize) catch break;
            pending += 1;

            glu.ack(&chan, 0);
            r = @truncate(@atomicLoad(u64, &chan.header.readers[0], .acquire));
        }

        if (pending >= 32) {
            io.fsync(&compl, fd) catch {};
            _ = io.wait(&compl, void) catch {};
            pending = 0;
        }

        io.run(0) catch |e| {
            std.debug.print("[logger] IO run error: {}\n", .{e});
        };
        util.timer_sleep(&io, 1000 / tick_rate_hz);
    }
}