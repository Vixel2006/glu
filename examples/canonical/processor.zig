const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const IO = glu.IO;

const topic_raw = "/temperature";
const topic_filtered = "/filtered_temp";
const node_name = "temperature_processor";
const capacity = 4096;
const rate_hz = 50;
const window_size = 10;
const alert_threshold: f32 = 50.0;
const alert_port: u16 = 9998;

fn send_tcp_alert(io: *IO, temp: f32, seq_in: u32) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ALERT seq={d} temp={d:.1}°C\n", .{ seq_in, temp }) catch return;

    var compl_connect: IO.Future = undefined;
    glu.tcp.connect(io, &compl_connect, "127.0.0.1", alert_port) catch return;
    io.wait(&compl_connect, void) catch return;
    const sock = compl_connect.operation.connect.socket;
    glu.tcp.apply_socket_opts(sock, .{});
    var stream = glu.tcp.Stream{ .socket = sock, .handle = sock };
    defer glu.tcp.close(&stream);

    var compl_send: IO.Future = undefined;
    glu.tcp.send(io, &compl_send, &stream, msg) catch return;
    _ = io.wait(&compl_send, usize) catch |e| {
        std.debug.print("[processor] warning: failed to send TCP alert: {}\n", .{e});
    };
}

fn milli_timestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleep(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub fn main() void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[processor] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var raw_sub = glu.Subscriber.init(topic_raw, @sizeOf(msgs.TemperatureReading), capacity) catch |e| {
        std.debug.print("[processor] subscriber init failed: {}\n", .{e});
        return;
    };
    defer raw_sub.deinit();

    var filtered_pub = glu.Publisher.init(topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity, .reliable) catch |e| {
        std.debug.print("[processor] publisher init failed: {}\n", .{e});
        return;
    };
    defer filtered_pub.deinit();

    glu.registry.register(node_name) catch |e| {
        std.debug.print("[processor] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister(node_name);

    std.debug.print(
        "[processor] temperature filter node (glu alerts)\n" ++
            "[processor]   {s} → (moving avg {d}) → {s}\n" ++
            "[processor]   Ctrl-C to stop\n",
        .{ topic_raw, window_size, topic_filtered },
    );

    var window = std.mem.zeroes([window_size]f32);
    var window_idx: usize = 0;
    var window_count: usize = 0;
    var seq: u32 = 0;
    var alert_cooldown: u32 = 0;

    while (true) {
        while (raw_sub.peek()) |raw| {
            const msg: *msgs.TemperatureReading = @ptrCast(@alignCast(raw));

            window[window_idx] = msg.temperature;
            window_idx = (window_idx + 1) % window_size;
            if (window_count < window_size) window_count += 1;

            var sum: f32 = 0;
            for (window[0..window_count]) |val| sum += val;
            const filtered = sum / @as(f32, @floatFromInt(window_count));

            const slot: *msgs.FilteredTemperature = @ptrCast(@alignCast(filtered_pub.reserve()));
            slot.* = msgs.FilteredTemperature{
                .seq = seq,
                .timestamp = milli_timestamp(),
                .raw_temp = msg.temperature,
                .filtered_temp = filtered,
                .humidity = msg.humidity,
                .sample_count = @intCast(window_count),
            };
            filtered_pub.commit();
            seq += 1;

            if (msg.temperature > alert_threshold and alert_cooldown == 0) {
                std.debug.print(
                    "\x1b[31m[processor] ALERT  {d:.1}°C exceeds {d:.0}°C threshold\x1b[0m\n",
                    .{ msg.temperature, alert_threshold },
                );
                send_tcp_alert(&io, msg.temperature, msg.seq);
                alert_cooldown = rate_hz * 10;
            }

            if (seq % (rate_hz * 5) == 0) {
                std.debug.print(
                    "[processor] seq={d}  raw={d:.2}  filtered={d:.2}  window={d}\n",
                    .{ seq, msg.temperature, filtered, window_count },
                );
            }

            raw_sub.ack();
        }

        if (alert_cooldown > 0) alert_cooldown -= 1;

        io.run(0) catch |e| {
            std.debug.print("[processor] IO run error: {}\n", .{e});
        };
        sleep(1000 / rate_hz);
    }
}
