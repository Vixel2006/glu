const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const IO = glu.IO;

const topic_temp = "/temperature";
const topic_status = "/sensor_status";
const capacity = 4096;
const rate_hz = 50;
const node_name = "temperature_sensor";

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

fn milliTimestamp() i64 {
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
    const allocator = std.heap.page_allocator;

    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[sensor] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var temp_pub = glu.Publisher.init(allocator, topic_temp, @sizeOf(msgs.TemperatureReading), capacity, .reliable) catch |e| {
        std.debug.print("[sensor] publisher init failed: {}\n", .{e});
        return;
    };
    defer temp_pub.deinit();

    var status_pub = glu.Publisher.init(allocator, topic_status, @sizeOf(msgs.SensorStatus), 128, .reliable) catch |e| {
        std.debug.print("[sensor] status publisher init failed: {}\n", .{e});
        return;
    };
    defer status_pub.deinit();

    glu.registry.register(node_name) catch {};
    defer glu.registry.unregister(node_name);

    var udp_sock = glu.udp.bind(&io, 0, .{}) catch |e| {
        std.debug.print("[sensor] UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock);

    std.debug.print(
        "[sensor] temperature sensor node (glu)\n" ++
            "[sensor]   {s} @ {d} Hz  (zero-copy)\n" ++
            "[sensor]   {s} @  1 Hz  (publish)\n" ++
            "[sensor]   Ctrl-C to stop\n",
        .{ topic_temp, rate_hz, topic_status },
    );

    const interval_ms: u64 = 1000 / rate_hz;
    const status_interval: u32 = rate_hz;

    var seq_temp: u32 = 0;
    var seq_status: u32 = 0;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(rate_hz));
    var base_temp: f32 = 23.0;
    var humidity: f32 = 45.0;
    var uptime: u32 = 0;

    while (true) : (seq_temp += 1) {
        const t: f32 = @as(f32, @floatFromInt(seq_temp)) * dt;

        base_temp = 23.0 + 5.0 * @sin(t * 0.2);
        const drift: f32 = @as(f32, @floatFromInt(seq_temp)) * 0.0005;
        const noise: f32 = (@as(f32, @floatFromInt(seq_temp % 100)) - 50.0) / 50.0 * 1.5;
        const temperature = base_temp + drift + noise;

        humidity = 45.0 + 10.0 * @sin(t * 0.1 + 1.0);

        const slot: *msgs.TemperatureReading = @ptrCast(@alignCast(temp_pub.reserve()));
        slot.* = msgs.TemperatureReading{
            .seq = seq_temp,
            .timestamp = milliTimestamp(),
            .temperature = temperature,
            .humidity = humidity,
            .sensor_id = 1,
        };
        temp_pub.commit();

        if (seq_temp % status_interval == 0) {
            uptime += 1;
            const voltage = 12.5 - @as(f32, @floatFromInt(uptime)) * 0.001;
            const status = msgs.SensorStatus{
                .seq = seq_status,
                .timestamp = milliTimestamp(),
                .uptime_sec = uptime,
                .battery_voltage = @max(10.0, voltage),
                .error_count = 0,
            };
            status_pub.publish(@ptrCast(&status));
            seq_status += 1;

            sendToSync(&io, udp_sock, "127.0.0.1", 9997, "sensor_alive") catch {};
        }

        if (seq_temp > 0 and seq_temp % (rate_hz * 5) == 0) {
            std.debug.print(
                "[sensor] seq={d}  temp={d:.2}°C  hum={d:.1}%  bat={d:.2}V\n",
                .{ seq_temp, temperature, humidity, 12.5 - @as(f32, @floatFromInt(uptime)) * 0.001 },
            );
        }

        io.run(0) catch {};
        sleep(interval_ms);
    }
}
