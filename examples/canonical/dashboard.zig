const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const IO = glu.IO;

const topic_filtered = "/filtered_temp";
const topic_status = "/sensor_status";
const node_name = "temperature_dashboard";
const capacity = 4096;
const tcp_port: u16 = 9999;
const tick_rate_hz = 200;

fn sendToSync(io: *IO, socket: glu.udp.Socket, host: []const u8, port: u16, data: []const u8) !void {
    const SyncState = struct {
        done: bool = false,
        result: IO.SendToError!usize = undefined,
    };
    const cb = struct {
        fn call(ctx: *SyncState, _: *IO.Completion, res: IO.SendToError!usize) void {
            ctx.result = res;
            ctx.done = true;
        }
    }.call;
    var compl: IO.Completion = undefined;
    var state = SyncState{};
    try glu.udp.send_to(io, *SyncState, &state, cb, &compl, socket, host, port, data);
    while (!state.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    _ = try state.result;
}

fn acceptSync(io: *IO, server: *glu.tcp.Server) !glu.tcp.Stream {
    const SyncState = struct {
        done: bool = false,
        result: IO.AcceptError!glu.tcp.Stream = undefined,
    };
    const cb = struct {
        fn call(ctx: *SyncState, _: *IO.Completion, res: IO.AcceptError!glu.tcp.Stream) void {
            ctx.result = res;
            ctx.done = true;
        }
    }.call;
    var compl: IO.Completion = undefined;
    var state = SyncState{};
    try glu.tcp.accept(io, *SyncState, &state, cb, &compl, server, .{});
    while (!state.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    return state.result;
}

fn sleep(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn runDisplay(allocator: std.mem.Allocator) void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[dashboard/tx] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var filtered_sub = glu.Subscriber.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tx] subscriber init failed: {}\n", .{e});
        return;
    };
    defer filtered_sub.deinit();

    var status_sub = glu.Subscriber.init(allocator, topic_status, @sizeOf(msgs.SensorStatus), 128) catch |e| {
        std.debug.print("[dashboard/tx] status subscriber init failed: {}\n", .{e});
        return;
    };
    defer status_sub.deinit();

    var udp_sock = glu.udp.bind(&io, 0, .{}) catch |e| {
        std.debug.print("[dashboard/tx] UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock);

    std.debug.print(
        "[dashboard/tx] display + registry monitor (glu)\n" ++
            "[dashboard/tx]   Ctrl-C to stop\n",
        .{},
    );

    var latest_filtered: ?msgs.FilteredTemperature = null;
    var tick: u32 = 0;

    while (true) {
        while (filtered_sub.receive()) |raw| {
            const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
            latest_filtered = msg.*;
        }

        while (status_sub.receive()) |raw| {
            const msg: *msgs.SensorStatus = @ptrCast(@alignCast(raw));
            _ = msg;
        }

        tick += 1;
        if (tick >= tick_rate_hz * 2) {
            tick = 0;

            if (latest_filtered) |data| {
                std.debug.print(
                    "[dashboard] seq={d}  raw={d:.2}°C  filtered={d:.2}°C  hum={d:.1}%  samples={d}\n",
                    .{ data.seq, data.raw_temp, data.filtered_temp, data.humidity, data.sample_count },
                );
            }

            if (glu.registry.list_alive(allocator)) |entries| {
                if (entries.len > 0) {
                    std.debug.print("[dashboard] nodes:", .{});
                    for (entries) |entry| {
                        const s = if (entry.alive) "\x1b[32malive\x1b[0m" else "\x1b[31mdead\x1b[0m";
                        std.debug.print("  {s}(pid={d},{s})", .{ entry.name, entry.pid, s });
                        allocator.free(entry.name);
                    }
                    std.debug.print("\n", .{});
                }
                allocator.free(entries);
            } else |_| {}

            sendToSync(&io, udp_sock, "127.0.0.1", 9997, "dashboard_alive") catch {};
        }

        io.run(0) catch {};
        sleep(1000 / tick_rate_hz);
    }
}

fn runTcpServer() void {
    const allocator = std.heap.page_allocator;

    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[dashboard/tcp] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var sub = glu.Subscriber.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tcp] subscriber init failed: {}\n", .{e});
        return;
    };
    defer sub.deinit();

    var server = glu.tcp.listen(&io, tcp_port, .{}) catch |e| {
        std.debug.print("[dashboard/tcp] listen on {d} failed: {}\n", .{ tcp_port, e });
        return;
    };
    defer glu.tcp.close_server(&server);

    std.debug.print("[dashboard/tcp] listening on :{d} (glu)\n", .{tcp_port});

    while (true) {
        var stream = acceptSync(&io, &server) catch |e| {
            std.debug.print("[dashboard/tcp] accept error: {}\n", .{e});
            sleep(100);
            continue;
        };

        std.debug.print("[dashboard/tcp] client connected\n", .{});

        var latest: ?msgs.FilteredTemperature = null;
        while (true) {
            while (sub.receive()) |raw| {
                const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
                latest = msg.*;
            }

            if (latest) |data| {
                glu.tcp.send(&io, &stream, std.mem.asBytes(&data)) catch break;
            }

            io.run(0) catch {};
            sleep(1000 / tick_rate_hz);
        }
        glu.tcp.close(&stream);
    }
}

pub fn main() void {
    glu.registry.register(node_name) catch {};
    defer glu.registry.unregister(node_name);

    std.debug.print(
        "[dashboard] temperature monitor\n" ++
            "[dashboard]   {s} ← filtered data\n" ++
            "[dashboard]   {s} ← sensor status\n" ++
            "[dashboard]   TCP :{d}  (connect with companion python client)\n" ++
            "[dashboard]   Ctrl-C to stop\n",
        .{ topic_filtered, topic_status, tcp_port },
    );

    const pid = std.c.fork();

    if (pid == 0) {
        runTcpServer();
        std.c.exit(0);
    } else if (pid > 0) {
        const allocator = std.heap.page_allocator;
        runDisplay(allocator);
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[dashboard] fork failed\n", .{});
    }
}
