const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const topic_filtered = "/filtered_temp";
const topic_status = "/sensor_status";
const node_name = "temperature_dashboard";
const capacity = 4096;
const tcp_port: u16 = 9999;
const alert_port: u16 = 9998;
const tick_rate_hz = 200;

fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn runDisplay(allocator: std.mem.Allocator) void {
    var rt = glu.Runtime.init(allocator, .{}) catch |e| {
        std.debug.print("[dashboard/tx] Runtime init failed: {}\n", .{e});
        return;
    };
    defer rt.deinit();

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

    var udp_sock = glu.udp.bind(0, .{}) catch |e| {
        std.debug.print("[dashboard/tx] UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock);

    std.debug.print(
        "[dashboard/tx] display + registry monitor (zio)\n" ++
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

            if (glu.registry.listAlive(allocator)) |entries| {
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

            _ = glu.udp.sendTo(&udp_sock, "127.0.0.1", 9997, "dashboard_alive") catch {};
        }

        rt.sleep(glu.Duration.fromMilliseconds(1000 / tick_rate_hz)) catch {};
    }
}

fn runTcpServer() void {
    const allocator = std.heap.page_allocator;

    var rt = glu.Runtime.init(allocator, .{}) catch |e| {
        std.debug.print("[dashboard/tcp] Runtime init failed: {}\n", .{e});
        return;
    };
    defer rt.deinit();

    var sub = glu.Subscriber.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tcp] subscriber init failed: {}\n", .{e});
        return;
    };
    defer sub.deinit();

    var server = glu.tcp.listen(tcp_port, .{}) catch |e| {
        std.debug.print("[dashboard/tcp] listen on {d} failed: {}\n", .{ tcp_port, e });
        return;
    };
    defer glu.tcp.closeServer(&server);

    std.debug.print(
        "[dashboard/tcp] listening on :{d} (zio)\n",
        .{tcp_port},
    );

    while (true) {
        var stream = glu.tcp.accept(&server, .{}) catch |e| {
            std.debug.print("[dashboard/tcp] accept error: {}\n", .{e});
            rt.sleep(glu.Duration.fromMilliseconds(100)) catch {};
            continue;
        };
        defer glu.tcp.close(&stream);

        std.debug.print("[dashboard/tcp] client connected\n", .{});

        var latest: ?msgs.FilteredTemperature = null;
        while (true) {
            while (sub.receive()) |raw| {
                const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
                latest = msg.*;
            }

            if (latest) |data| {
                const bytes = std.mem.asBytes(&data);
                glu.tcp.send(&stream, bytes) catch break;
            }

            rt.sleep(glu.Duration.fromMilliseconds(1000 / tick_rate_hz)) catch {};
        }
    }
}

pub fn main() void {
    const allocator = std.heap.page_allocator;

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
        runDisplay(allocator);
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[dashboard] fork failed\n", .{});
    }
}
