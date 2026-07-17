const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const topic_raw = "/temperature";
const topic_filtered = "/filtered_temp";
const node_name = "temperature_processor";
const capacity = 4096;
const rate_hz = 50;
const window_size = 10;
const alert_threshold: f32 = 50.0;

fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub fn main() void {
    const allocator = std.heap.page_allocator;

    var raw_sub = glu.Subscriber.init(allocator, topic_raw, @sizeOf(msgs.TemperatureReading), capacity) catch |e| {
        std.debug.print("[processor] subscriber init failed: {}\n", .{e});
        return;
    };
    defer raw_sub.deinit();

    var filtered_pub = glu.Publisher.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity, .reliable) catch |e| {
        std.debug.print("[processor] publisher init failed: {}\n", .{e});
        return;
    };
    defer filtered_pub.deinit();

    glu.registry.register(node_name) catch {};
    defer glu.registry.unregister(node_name);

    // Initialize AsyncIo for high-performance networking alerts
    var aio = glu.io_mod.AsyncIo.init(16) catch |e| {
        std.debug.print("[processor] AsyncIo init failed: {}\n", .{e});
        return;
    };
    defer aio.deinit();

    std.debug.print(
        "[processor] temperature filter node (async alerts)\n" ++
        "[processor]   {s} → (moving avg {d}) → {s}\n" ++
        "[processor]   Ctrl-C to stop\n",
        .{ topic_raw, window_size, topic_filtered },
    );

    var window: [window_size]f32 = undefined;
    for (&window) |*v| v.* = 0;
    var window_idx: usize = 0;
    var window_count: usize = 0;
    var seq: u32 = 0;
    var last_raw: f32 = 0;
    var last_humidity: f32 = 0;
    var alert_cooldown: u32 = 0;

    while (true) {
        while (raw_sub.receive()) |raw| {
            const msg: *msgs.TemperatureReading = @ptrCast(@alignCast(raw));

            window[window_idx] = msg.temperature;
            window_idx = (window_idx + 1) % window_size;
            if (window_count < window_size) window_count += 1;

            var sum: f32 = 0;
            for (window[0..window_count]) |val| sum += val;
            const filtered = sum / @as(f32, @floatFromInt(window_count));

            last_raw = msg.temperature;
            last_humidity = msg.humidity;

            const slot: *msgs.FilteredTemperature = @ptrCast(@alignCast(filtered_pub.reserve()));
            slot.* = msgs.FilteredTemperature{
                .seq = seq,
                .timestamp = milliTimestamp(),
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
                send_tcp_alert(&aio, msg.temperature, msg.seq);
                alert_cooldown = rate_hz * 10;
            }

            if (seq % (rate_hz * 5) == 0) {
                std.debug.print(
                    "[processor] seq={d}  raw={d:.2}  filtered={d:.2}  window={d}\n",
                    .{ seq, msg.temperature, filtered, window_count },
                );
            }
        }

        if (alert_cooldown > 0) alert_cooldown -= 1;

        sleepMs(1000 / rate_hz);
    }
}

fn send_tcp_alert(aio: *glu.io_mod.AsyncIo, temp: f32, seq: u32) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ALERT seq={d} temp={d:.1}°C\n", .{ seq, temp }) catch return;

    // Create client socket descriptor manually
    const socket_rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    if (std.os.linux.errno(socket_rc) != .SUCCESS) return;
    const fd: std.os.linux.fd_t = @intCast(socket_rc);
    defer _ = std.os.linux.close(fd);

    const dest_ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:9998") catch return;
    const dest_addr = glu.net.socketAddrFromIp(dest_ip) catch return;

    // Async TCP Connect
    var connect_fut: glu.io_mod.Future(void) = .{ .value = {} };
    _ = aio.connect(fd, dest_addr.ptr(), dest_addr.len(), &connect_fut.completion) catch return;
    _ = connect_fut.wait(aio) catch return;

    // Async TCP Send
    var send_fut: glu.io_mod.Future(usize) = .{};
    _ = aio.send(fd, msg, &send_fut.completion, 0) catch return;
    _ = send_fut.wait(aio) catch return;
}
