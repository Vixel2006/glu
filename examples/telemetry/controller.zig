const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const subscriber_id = 0;
const timeout_ms = 2_000;

// -- helpers -----------------------------------------------------------------
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

// -- main --------------------------------------------------------------------
pub fn main() void {
    const allocator = std.heap.page_allocator;

    var subscriber = glu.Subscriber.init(
        allocator,
        subscriber_id,
        topic,
        @sizeOf(msgs.Telemetry),
        capacity,
    ) catch |e| {
        std.debug.print("[controller] subscriber init failed: {}\n", .{e});
        return;
    };
    defer subscriber.deinit();

    std.debug.print("[controller] waiting for messages on '{s}'…\n", .{topic});

    var count: u32 = 0;
    var sum_temp: f64 = 0;
    var sum_pressure: f64 = 0;
    var min_alt: f32 = std.math.floatMax(f32);
    var max_alt: f32 = -std.math.floatMax(f32);
    var first_seq: ?u32 = null;
    var last_seq: ?u32 = null;
    var last_received = milliTimestamp();
    const start = milliTimestamp();

    // Consume messages until a timeout elapses with no new data.
    while (true) {
        if (subscriber.receive(msgs.Telemetry)) |msg| {
            if (first_seq == null) first_seq = msg.seq;
            last_seq = msg.seq;
            sum_temp += msg.temperature;
            sum_pressure += msg.pressure;
            min_alt = @min(min_alt, msg.altitude);
            max_alt = @max(max_alt, msg.altitude);
            count += 1;
            last_received = milliTimestamp();
        } else {
            if (milliTimestamp() - last_received > timeout_ms) break;
            sleepMs(1);
        }
    }

    const elapsed = milliTimestamp() - start;
    const avg_temp: f32 = @floatCast(
        if (count > 0) sum_temp / @as(f64, @floatFromInt(count)) else 0,
    );
    const avg_pressure: f32 = @floatCast(
        if (count > 0) sum_pressure / @as(f64, @floatFromInt(count)) else 0,
    );

    std.debug.print("\n[controller] ── telemetry summary ─────────────────\n", .{});
    std.debug.print("[controller]   received   : {d} messages in {d} ms\n", .{ count, elapsed });
    if (first_seq) |fs| std.debug.print("[controller]   first seq  : {d}\n", .{fs});
    if (last_seq) |ls| std.debug.print("[controller]   last seq   : {d}\n", .{ls});
    std.debug.print("[controller]   avg temp   : {d:.2} °C\n", .{avg_temp});
    std.debug.print("[controller]   avg pressure: {d:.2} hPa\n", .{avg_pressure});
    std.debug.print("[controller]   altitude   : {d:.1} – {d:.1} m\n", .{ min_alt, max_alt });
    std.debug.print("[controller] ─────────────────────────────────────────\n", .{});
}
