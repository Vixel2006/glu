/// cmd_publisher.zig — command velocity publisher (joystick simulator)
///
/// Simulates a joystick driving the robot in a figure-8 trajectory and
/// publishes velocity commands on /cmd_vel at 50 Hz.
///
/// Also publishes BatteryStatus on /battery at 1 Hz, simulating a battery
/// that decays from 100% to 80% over ~20 minutes (about 3.5 hours to empty).
///
/// Demonstrates:
///   • Zero-copy reserve/commit for high-rate Twist messages
///   • Regular publish() for lower-rate BatteryStatus messages
///   • Publishing on two topics from a single node
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const cmd_topic = "/cmd_vel";
const bat_topic = "/battery";
const capacity = 4096;
const cmd_rate_hz = 50;
const bat_rate_hz = 1;
const pi: f32 = 3.14159265358979;

// Figure-8 trajectory parameters
const linear_x: f32 = 0.5; // m/s — constant forward speed
const angular_freq: f32 = 0.3; // rad/s oscillation frequency

// Battery simulation
const bat_start_pct: f32 = 100.0;
const bat_discharge_rate: f32 = 0.0008; // %/s — reaches 80% in ~25 000 s
const bat_voltage_full: f32 = 25.2; // V (6S LiPo)
const bat_current_draw: f32 = 8.5; // A nominal

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

    // Twist publisher (high rate — use zero-copy)
    var cmd_pub = glu.Publisher.init(
        allocator,
        cmd_topic,
        @sizeOf(msgs.Twist),
        capacity,
    ) catch |e| {
        std.debug.print("[cmd_pub] cmd publisher init failed: {}\n", .{e});
        return;
    };
    defer cmd_pub.deinit();

    // Battery publisher (low rate — regular publish is fine)
    var bat_pub = glu.Publisher.init(
        allocator,
        bat_topic,
        @sizeOf(msgs.BatteryStatus),
        capacity,
    ) catch |e| {
        std.debug.print("[cmd_pub] battery publisher init failed: {}\n", .{e});
        return;
    };
    defer bat_pub.deinit();

    std.debug.print(
        "[cmd_pub] figure-8 joystick sim\n" ++
            "[cmd_pub]   {s} @ {d} Hz  (zero-copy)\n" ++
            "[cmd_pub]   {s} @ {d} Hz  (publish)\n" ++
            "[cmd_pub]   Ctrl-C to stop\n",
        .{ cmd_topic, cmd_rate_hz, bat_topic, bat_rate_hz },
    );

    const interval_ms: u64 = 1000 / cmd_rate_hz;
    const bat_interval_ticks: u32 = cmd_rate_hz / bat_rate_hz; // publish bat every N ticks

    var seq_cmd: u32 = 0;
    var seq_bat: u32 = 0;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(cmd_rate_hz));
    var bat_pct: f32 = bat_start_pct;

    while (true) : (seq_cmd += 1) {
        const t: f32 = @as(f32, @floatFromInt(seq_cmd)) * dt;

        // Figure-8: constant forward + sinusoidal angular velocity.
        const angular_z = std.math.sin(angular_freq * t);

        // Zero-copy Twist publish.
        const slot = cmd_pub.reserve(msgs.Twist);
        slot.* = msgs.Twist{
            .seq = seq_cmd,
            .timestamp = milliTimestamp(),
            .linear_x = linear_x,
            .linear_y = 0.0,
            .angular_z = angular_z,
        };
        cmd_pub.commit();

        // Battery status at 1 Hz.
        if (seq_cmd % bat_interval_ticks == 0) {
            bat_pct = @max(0.0, bat_pct - bat_discharge_rate * @as(f32, @floatFromInt(bat_interval_ticks)) * dt);
            // Voltage sags slightly under load proportional to discharge level.
            const voltage = bat_voltage_full * (0.85 + 0.15 * (bat_pct / 100.0));

            const bat_msg = msgs.BatteryStatus{
                .seq = seq_bat,
                .timestamp = milliTimestamp(),
                .voltage = voltage,
                .current = bat_current_draw,
                .percentage = bat_pct,
            };
            bat_pub.publish(msgs.BatteryStatus, &bat_msg);
            seq_bat += 1;
        }

        // Status every ~1 second.
        if (seq_cmd > 0 and seq_cmd % cmd_rate_hz == 0) {
            std.debug.print(
                "[cmd_pub] seq={d}  t={d:.1}s  lin={d:.2}  ang={d:.3}  bat={d:.1}%\n",
                .{ seq_cmd, t, linear_x, angular_z, bat_pct },
            );
        }

        sleepMs(interval_ms);
    }
}
