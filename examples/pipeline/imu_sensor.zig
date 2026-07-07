/// imu_sensor.zig — IMU (gyroscope) sensor publisher node
///
/// Simulates a 3-axis gyroscope and publishes raw measurements on /imu/raw at
/// 200 Hz using the zero-copy reserve/commit pattern.
///
/// Signal model:
///   x-axis  — roll rate,  0.7 Hz sine
///   y-axis  — pitch rate, 1.3 Hz sine
///   z-axis  — yaw rate,   0.4 Hz sine
/// All axes have additive white Gaussian noise.
///
/// Part of the pipeline example:
///   imu_sensor → filter → actuator
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/imu_raw";
const capacity = 4096;
const publish_rate_hz = 200;
const pi: f32 = 3.14159265358979;

// Gyroscope signal parameters (rad/s amplitudes)
const amp_x: f32 = 1.5;
const amp_y: f32 = 0.8;
const amp_z: f32 = 0.6;
const freq_x: f32 = 0.7;
const freq_y: f32 = 1.3;
const freq_z: f32 = 0.4;
const noise_std: f32 = 0.05; // rad/s Gaussian noise std-dev

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

fn lcgNext(state: *u64) f32 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    const top: u32 = @intCast(state.* >> 33);
    return @as(f32, @floatFromInt(top)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Box-Muller gaussian noise generator.
fn gaussianNoise(state: *u64, std_dev: f32) f32 {
    const r1 = lcgNext(state);
    const r2 = lcgNext(state);
    const safe_r1 = if (r1 < 1e-7) 1e-7 else r1;
    const mag = std_dev * std.math.sqrt(-2.0 * std.math.log(f32, std.math.e, safe_r1));
    return mag * std.math.cos(2.0 * pi * r2);
}

// -- main --------------------------------------------------------------------
pub fn main() void {
    const allocator = std.heap.page_allocator;

    var publisher = glu.Publisher.init(
        allocator,
        topic,
        @sizeOf(msgs.RawSensor),
        capacity,
    ) catch |e| {
        std.debug.print("[imu_sensor] publisher init failed: {}\n", .{e});
        return;
    };
    defer publisher.deinit();

    std.debug.print(
        "[imu_sensor] publishing on '{s}' at {d} Hz (zero-copy, Ctrl-C to stop)\n",
        .{ topic, publish_rate_hz },
    );

    const interval_ms: u64 = 1000 / publish_rate_hz;
    var seq: u32 = 0;
    var rng: u64 = 0xABCD1234FEDC5678;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(publish_rate_hz));

    while (true) : (seq += 1) {
        const t: f32 = @as(f32, @floatFromInt(seq)) * dt;
        const noise = gaussianNoise(&rng, noise_std);

        const slot: *msgs.RawSensor = @ptrCast(@alignCast(publisher.reserve()));
        slot.* = msgs.RawSensor{
            .seq = seq,
            .timestamp = milliTimestamp(),
            .raw_x = amp_x * std.math.sin(2.0 * pi * freq_x * t) + gaussianNoise(&rng, noise_std),
            .raw_y = amp_y * std.math.sin(2.0 * pi * freq_y * t) + gaussianNoise(&rng, noise_std),
            .raw_z = amp_z * std.math.sin(2.0 * pi * freq_z * t) + noise,
            .noise = noise,
        };
        publisher.commit();

        // Print status every ~1 second (200 messages).
        if (seq > 0 and seq % 200 == 0) {
            std.debug.print(
                "[imu_sensor] seq={d}  t={d:.2}s  x={d:.3}  y={d:.3}  z={d:.3}\n",
                .{ seq, t, slot.raw_x, slot.raw_y, slot.raw_z },
            );
        }

        sleepMs(interval_ms);
    }
}
