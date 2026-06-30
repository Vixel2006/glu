/// sensor.zig — telemetry sensor publisher node
///
/// Simulates a realistic environmental sensor suite and publishes readings
/// to the /telemetry topic using the zero-copy reserve/commit pattern.
///
/// Runs indefinitely at 100 Hz. Combine with controller and monitor nodes
/// via `glu launch -f examples/telemetry/launch.toml`.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const publish_rate_hz = 100;

// Sensor simulation parameters
const base_temp: f32 = 22.0; // °C — indoor baseline
const temp_amplitude: f32 = 8.0; // ±8 °C sine wave
const base_pressure: f32 = 1013.25; // hPa — sea-level standard
const pressure_amplitude: f32 = 2.5; // ±2.5 hPa
const base_humidity: f32 = 55.0; // % RH
const humidity_noise: f32 = 5.0; // gaussian-ish noise range
const base_altitude: f32 = 120.0; // m — starting altitude
const pi: f32 = 3.14159265358979;

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

/// Cheap pseudo-random float in [0, 1) using a linear congruential generator.
/// Good enough for sensor noise simulation.
fn lcgNext(state: *u64) f32 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    const top: u32 = @intCast(state.* >> 33);
    return @as(f32, @floatFromInt(top)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Box-Muller transform: produces one gaussian-distributed sample from two
/// uniform samples. Scaled by `std_dev` and centred on 0.
fn gaussianNoise(state: *u64, std_dev: f32) f32 {
    const r1 = lcgNext(state);
    const r2 = lcgNext(state);
    // Clamp r1 away from 0 to avoid log(0).
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
        @sizeOf(msgs.Telemetry),
        capacity,
    ) catch |e| {
        std.debug.print("[sensor] publisher init failed: {}\n", .{e});
        return;
    };
    defer publisher.deinit();

    std.debug.print(
        \\[sensor] ── telemetry sensor ──────────────────────────
        \\[sensor]   topic    : {s}
        \\[sensor]   rate     : {d} Hz
        \\[sensor]   mode     : zero-copy (reserve/commit)
        \\[sensor]   Ctrl-C to stop
        \\[sensor] ──────────────────────────────────────────────
        \\
    , .{ topic, publish_rate_hz });

    const interval_ms: u64 = 1000 / publish_rate_hz;
    var seq: u32 = 0;
    var rng_state: u64 = 0xDEADBEEFCAFE1234;

    while (true) : (seq += 1) {
        // Time drives all the sine waves.
        const t: f32 = @as(f32, @floatFromInt(seq)) / @as(f32, @floatFromInt(publish_rate_hz));

        // Temperature: slow 0.05 Hz sine + gaussian noise (~0.3 °C std-dev).
        const temperature = base_temp +
            temp_amplitude * std.math.sin(2.0 * pi * 0.05 * t) +
            gaussianNoise(&rng_state, 0.3);

        // Pressure: medium 0.02 Hz sine (weather front) + tiny noise.
        const pressure = base_pressure +
            pressure_amplitude * std.math.sin(2.0 * pi * 0.02 * t) +
            gaussianNoise(&rng_state, 0.1);

        // Humidity: 0.03 Hz sine with larger gaussian noise.
        const humidity = base_humidity +
            humidity_noise * std.math.sin(2.0 * pi * 0.03 * t) +
            gaussianNoise(&rng_state, 1.5);

        // Altitude: very slow climb (ascending sensor platform) + pressure noise.
        const altitude = base_altitude +
            5.0 * std.math.sin(2.0 * pi * 0.008 * t) +
            gaussianNoise(&rng_state, 0.05);

        // Zero-copy publish: reserve a slot, fill it in-place, then commit.
        const slot = publisher.reserve(msgs.Telemetry);
        slot.* = msgs.Telemetry{
            .seq = seq,
            .timestamp = milliTimestamp(),
            .temperature = temperature,
            .pressure = pressure,
            .humidity = humidity,
            .altitude = altitude,
        };
        publisher.commit();

        // Periodic status every 500 messages (~5 seconds at 100 Hz).
        if (seq > 0 and seq % 500 == 0) {
            std.debug.print(
                "[sensor] seq={d}  temp={d:.1}°C  pres={d:.1}hPa  hum={d:.1}%  alt={d:.1}m\n",
                .{ seq, temperature, pressure, humidity, altitude },
            );
        }

        sleepMs(interval_ms);
    }
}
