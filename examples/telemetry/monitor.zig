/// monitor.zig — live telemetry monitor node
///
/// Subscribes to /telemetry and prints a rolling summary every second.
/// Demonstrates running a third, independent node alongside sensor and
/// controller via `glu launch`.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const subscriber_id = 1; // slot 1 — sensor=publisher, controller=slot 0
const report_interval_ms = 1_000;
const idle_timeout_ms = 5_000;

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
        std.debug.print("[monitor] subscriber init failed: {}\n", .{e});
        return;
    };
    defer subscriber.deinit();

    std.debug.print("[monitor] live telemetry on '{s}' (Ctrl-C to stop)\n\n", .{topic});

    var window_count: u32 = 0;
    var window_temp: f64 = 0;
    var window_pressure: f64 = 0;
    var window_min_alt: f32 = std.math.floatMax(f32);
    var window_max_alt: f32 = -std.math.floatMax(f32);
    var last_report = milliTimestamp();
    var last_data = milliTimestamp();
    var total: u64 = 0;

    while (true) {
        if (subscriber.receive(msgs.Telemetry)) |msg| {
            window_count += 1;
            total += 1;
            window_temp += msg.temperature;
            window_pressure += msg.pressure;
            window_min_alt = @min(window_min_alt, msg.altitude);
            window_max_alt = @max(window_max_alt, msg.altitude);
            last_data = milliTimestamp();
        }

        const now = milliTimestamp();

        // Idle timeout — exit if no data has arrived for a while.
        if (now - last_data > idle_timeout_ms and total > 0) {
            std.debug.print("[monitor] stream ended — exiting\n", .{});
            break;
        }

        // Print a periodic report every report_interval_ms.
        if (now - last_report >= report_interval_ms) {
            if (window_count > 0) {
                const avg_temp: f32 = @floatCast(window_temp / @as(f64, @floatFromInt(window_count)));
                const avg_pres: f32 = @floatCast(window_pressure / @as(f64, @floatFromInt(window_count)));
                std.debug.print(
                    "[monitor] msgs/s={d:>5}  temp={d:.1}°C  pres={d:.1}hPa  alt=[{d:.0},{d:.0}]m  total={d}\n",
                    .{ window_count, avg_temp, avg_pres, window_min_alt, window_max_alt, total },
                );
            } else {
                std.debug.print("[monitor] waiting for data on '{s}'…\n", .{topic});
            }

            // Reset window accumulators.
            window_count = 0;
            window_temp = 0;
            window_pressure = 0;
            window_min_alt = std.math.floatMax(f32);
            window_max_alt = -std.math.floatMax(f32);
            last_report = now;
        }

        sleepMs(1);
    }
}
