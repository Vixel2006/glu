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

fn sleep(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn run_display() void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[dashboard/tx] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var filtered_sub = glu.Subscriber.init(topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tx] subscriber init failed: {}\n", .{e});
        return;
    };
    defer filtered_sub.deinit();

    var status_sub = glu.Subscriber.init(topic_status, @sizeOf(msgs.SensorStatus), 128) catch |e| {
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

    var compl_heartbeat: IO.Future = undefined;
    var heartbeat_active = false;

    while (true) {
        while (filtered_sub.peek()) |raw| {
            const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
            latest_filtered = msg.*;
            filtered_sub.ack();
        }

        while (status_sub.peek()) |raw| {
            const msg: *msgs.SensorStatus = @ptrCast(@alignCast(raw));
            _ = msg;
            status_sub.ack();
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

            var entry_buf: [128]glu.registry.NodeEntry = undefined;
            if (glu.registry.list_alive(&entry_buf)) |count| {
                if (count > 0) {
                    std.debug.print("[dashboard] nodes:", .{});
                    for (entry_buf[0..count]) |entry| {
                        const s = if (entry.alive) "\x1b[32malive\x1b[0m" else "\x1b[31mdead\x1b[0m";
                        std.debug.print("  {s}(pid={d},{s})", .{ entry.name[0..entry.name_len], entry.pid, s });
                    }
                    std.debug.print("\n", .{});
                }
            } else |_| {}

            if (!heartbeat_active or compl_heartbeat.done) {
                glu.udp.send_to(&io, &compl_heartbeat, udp_sock, "127.0.0.1", 9997, "dashboard_alive") catch |e| {
                    std.debug.print("[dashboard/tx] warning: failed to send UDP heartbeat: {}\n", .{e});
                };
                heartbeat_active = true;
            }
        }

        io.run(0) catch |e| {
            std.debug.print("[dashboard/tx] IO run error: {}\n", .{e});
        };
        sleep(1000 / tick_rate_hz);
    }
}

fn run_tcp_server() void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[dashboard/tcp] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var sub = glu.Subscriber.init(topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
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
        var compl_accept: IO.Future = undefined;
        glu.tcp.accept(&io, &compl_accept, &server) catch |e| {
            std.debug.print("[dashboard/tcp] accept queue error: {}\n", .{e});
            sleep(100);
            continue;
        };
        const sock = io.wait(&compl_accept, std.posix.socket_t) catch |e| {
            std.debug.print("[dashboard/tcp] accept wait error: {}\n", .{e});
            sleep(100);
            continue;
        };
        glu.tcp.apply_socket_opts(sock, .{});
        var stream = glu.tcp.Stream{ .socket = sock, .handle = sock };
        defer glu.tcp.close(&stream);

        std.debug.print("[dashboard/tcp] client connected\n", .{});

        var latest: ?msgs.FilteredTemperature = null;
        var compl_send: IO.Future = undefined;
        var send_pending = false;

        while (true) {
            while (sub.peek()) |raw| {
                const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
                latest = msg.*;
                sub.ack();
            }

            if (send_pending and compl_send.done) {
                _ = compl_send.result.send catch |e| {
                    std.debug.print("[dashboard/tcp] send error: {}\n", .{e});
                    break;
                };
                send_pending = false;
            }

            if (latest) |data| {
                if (!send_pending) {
                    glu.tcp.send(&io, &compl_send, &stream, std.mem.asBytes(&data)) catch break;
                    send_pending = true;
                    latest = null;
                }
            }

            io.run(0) catch |e| {
                std.debug.print("[dashboard/tcp] IO run error: {}\n", .{e});
            };
            sleep(1000 / tick_rate_hz);
        }
    }
}

pub fn main() void {
    glu.registry.register(node_name) catch |e| {
        std.debug.print("[dashboard] warning: failed to register node: {}\n", .{e});
    };
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
        run_tcp_server();
        std.c.exit(0);
    } else if (pid > 0) {
        run_display();
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[dashboard] fork failed\n", .{});
    }
}
