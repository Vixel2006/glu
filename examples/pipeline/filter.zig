/// filter.zig — low-pass filter node
///
/// Subscribes to /imu/raw and applies an exponential moving average (EMA)
/// to each axis independently, then publishes the smoothed signal on
/// /imu/filtered.
///
/// EMA update: y[n] = alpha * x[n] + (1 - alpha) * y[n-1]
/// With alpha = 0.1, the cutoff is approximately at 1/20 of the sample rate.
///
/// Also computes vector magnitude = sqrt(x² + y² + z²) for downstream nodes.
///
/// Part of the pipeline example:
///   imu_sensor → filter → actuator
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const raw_topic = "/imu_raw";
const filtered_topic = "/imu_filtered";
const capacity = 4096;
const alpha: f32 = 0.1; // EMA smoothing factor (0=no update, 1=no smoothing)

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

    var sub = glu.Subscriber.init(
        allocator,
        raw_topic,
        @sizeOf(msgs.RawSensor),
        capacity,
    ) catch |e| {
        std.debug.print("[filter] subscriber init failed: {}\n", .{e});
        return;
    };
    defer sub.deinit();

    var pub_ = glu.Publisher.init(
        allocator,
        filtered_topic,
        @sizeOf(msgs.Filtered),
        capacity,
    ) catch |e| {
        std.debug.print("[filter] publisher init failed: {}\n", .{e});
        return;
    };
    defer pub_.deinit();

    std.debug.print(
        "[filter] EMA filter  alpha={d:.2}  {s} → {s}  (Ctrl-C to stop)\n",
        .{ alpha, raw_topic, filtered_topic },
    );

    // EMA state — initialised to 0 until first message arrives.
    var ema_x: f32 = 0;
    var ema_y: f32 = 0;
    var ema_z: f32 = 0;
    var initialised = false;

    var count: u64 = 0;
    var total_noise: f64 = 0;

    while (true) {
        if (sub.receive()) |r| {
            const raw: *msgs.RawSensor = @ptrCast(@alignCast(r));
            count += 1;
            total_noise += raw.noise;

            if (!initialised) {
                // Seed the EMA with the first sample for a bumpless start.
                ema_x = raw.raw_x;
                ema_y = raw.raw_y;
                ema_z = raw.raw_z;
                initialised = true;
            } else {
                ema_x = alpha * raw.raw_x + (1.0 - alpha) * ema_x;
                ema_y = alpha * raw.raw_y + (1.0 - alpha) * ema_y;
                ema_z = alpha * raw.raw_z + (1.0 - alpha) * ema_z;
            }

            const magnitude = std.math.sqrt(ema_x * ema_x + ema_y * ema_y + ema_z * ema_z);

            // Zero-copy publish of the filtered message.
            const slot: *msgs.Filtered = @ptrCast(@alignCast(pub_.reserve()));
            slot.* = msgs.Filtered{
                .seq = raw.seq,
                .timestamp = milliTimestamp(),
                .x = ema_x,
                .y = ema_y,
                .z = ema_z,
                .magnitude = magnitude,
            };
            pub_.commit();

            // Print filter stats every ~1 second (200 messages at 200 Hz).
            if (count % 200 == 0) {
                const avg_noise: f32 = @floatCast(total_noise / @as(f64, @floatFromInt(count)));
                std.debug.print(
                    "[filter] n={d}  ema=({d:.3},{d:.3},{d:.3})  |v|={d:.3}  avg_noise={d:.4}\n",
                    .{ count, ema_x, ema_y, ema_z, magnitude, avg_noise },
                );
            }
        } else {
            sleepMs(1);
        }
    }
}
