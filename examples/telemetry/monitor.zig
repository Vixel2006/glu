/// monitor.zig — live telemetry dashboard node
///
/// Subscribes to /telemetry and renders an in-place updating dashboard every
/// second. Uses carriage-return (\r) tricks to overwrite the previous line,
/// giving a "live ticker" feel without scrolling the terminal.
///
/// Shows:
///   • msgs/sec with trend indicator (↑ / ↓ / →)
///   • Min / max / average for temperature, pressure, humidity, altitude
///
/// Runs indefinitely (Ctrl-C to stop).  Uses subscriber_id = 1 so it can
/// co-exist with controller (subscriber_id = 0) on the same topic.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const subscriber_id = 1; // slot 1 — controller occupies slot 0
const report_interval_ms = 1_000;

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

/// Running stats for one field — updated each message.
const FieldStats = struct {
    sum: f64 = 0,
    min: f32 = std.math.floatMax(f32),
    max: f32 = -std.math.floatMax(f32),
    count: u64 = 0,

    fn update(self: *FieldStats, v: f32) void {
        self.sum += v;
        self.min = @min(self.min, v);
        self.max = @max(self.max, v);
        self.count += 1;
    }

    fn avg(self: FieldStats) f32 {
        if (self.count == 0) return 0;
        return @floatCast(self.sum / @as(f64, @floatFromInt(self.count)));
    }
};

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
        std.debug.print("[monitor] subscriber init failed: {}\n", .{e});
        return;
    };
    defer subscriber.deinit();

    // Print the static header once.
    std.debug.print(
        "\x1b[1m\x1b[36m" ++
            "[monitor] ── live telemetry dashboard ───────────────────\n" ++
            "[monitor]   topic : {s}  (sub_id={d})\n" ++
            "[monitor]   Ctrl-C to stop\n" ++
            "[monitor] ──────────────────────────────────────────────\x1b[0m\n",
        .{ topic, subscriber_id },
    );

    // Per-field running stats (all-time, never reset).
    var temp_stats = FieldStats{};
    var pres_stats = FieldStats{};
    var hum_stats = FieldStats{};
    var alt_stats = FieldStats{};

    // Window accumulators for msgs/sec.
    var window_count: u32 = 0;
    var prev_window_count: u32 = 0;
    var last_report = milliTimestamp();
    var first_report = true;

    while (true) {
        // Drain all available messages before sleeping.
        while (subscriber.receive(msgs.Telemetry)) |msg| {
            window_count += 1;
            temp_stats.update(msg.temperature);
            pres_stats.update(msg.pressure);
            hum_stats.update(msg.humidity);
            alt_stats.update(msg.altitude);
        }

        // Print dashboard once per report interval.
        const now = milliTimestamp();
        if (now - last_report >= report_interval_ms) {
            const mps = window_count; // msgs received in the last second
            const trend: []const u8 = if (mps > prev_window_count)
                "\x1b[32m↑\x1b[0m"
            else if (mps < prev_window_count)
                "\x1b[31m↓\x1b[0m"
            else
                "\x1b[33m→\x1b[0m";

            if (temp_stats.count > 0) {
                // Move cursor up 6 lines to overwrite previous dashboard block
                // (skip on the very first report — nothing to overwrite yet).
                if (!first_report) {
                    std.debug.print("\x1b[6A", .{}); // move up 6 lines
                }
                first_report = false;

                std.debug.print(
                    "[monitor] msgs/sec : {d:>5} {s}  (total: {d})\n",
                    .{ mps, trend, temp_stats.count },
                );
                std.debug.print(
                    "[monitor] temp (°C): avg={d:>7.2}  min={d:>7.2}  max={d:>7.2}\n",
                    .{ temp_stats.avg(), temp_stats.min, temp_stats.max },
                );
                std.debug.print(
                    "[monitor] pres(hPa): avg={d:>7.2}  min={d:>7.2}  max={d:>7.2}\n",
                    .{ pres_stats.avg(), pres_stats.min, pres_stats.max },
                );
                std.debug.print(
                    "[monitor] hum  (%) : avg={d:>7.2}  min={d:>7.2}  max={d:>7.2}\n",
                    .{ hum_stats.avg(), hum_stats.min, hum_stats.max },
                );
                std.debug.print(
                    "[monitor] alt   (m): avg={d:>7.2}  min={d:>7.2}  max={d:>7.2}\n",
                    .{ alt_stats.avg(), alt_stats.min, alt_stats.max },
                );
                std.debug.print(
                    "[monitor] ──────────────────────────────────────────────\n",
                    .{},
                );
            } else {
                // No data yet — print a waiting line that gets overwritten next tick.
                std.debug.print("[monitor] waiting for data on '{s}'…\n", .{topic});
            }

            prev_window_count = window_count;
            window_count = 0;
            last_report = now;
        }

        sleepMs(1);
    }
}
