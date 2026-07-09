/// actuator.zig — motor actuator node
///
/// Subscribes to /imu/filtered and computes differential-drive motor commands:
///
///   left_pwm  = clamp(50.0 + z * 20.0,  -100, 100)
///   right_pwm = clamp(50.0 - z * 20.0,  -100, 100)
///   enabled   = 1 if magnitude > 0.1, else 0
///
/// Publishes MotorCmd on /motors/cmd using zero-copy.
///
/// Part of the pipeline example:
///   imu_sensor → filter → actuator
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const input_topic = "/imu_filtered";
const output_topic = "/motors_cmd";
const capacity = 4096;

// Motor mix parameters
const base_pwm: f32 = 50.0; // % duty cycle at rest
const yaw_gain: f32 = 20.0; // PWM gain from yaw rate
const motion_threshold: f32 = 0.1; // |v| threshold to enable motors

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

/// Saturate a value to [-limit, +limit].
fn clamp(v: f32, limit: f32) f32 {
    return @max(-limit, @min(limit, v));
}

// -- main --------------------------------------------------------------------
pub fn main() void {
    const allocator = std.heap.page_allocator;

    var sub = glu.Subscriber.init(
        allocator,
        input_topic,
        @sizeOf(msgs.Filtered),
        capacity,
    ) catch |e| {
        std.debug.print("[actuator] subscriber init failed: {}\n", .{e});
        return;
    };
    defer sub.deinit();

    var pub_ = glu.Publisher.init(
        allocator,
        output_topic,
        @sizeOf(msgs.MotorCmd),
        capacity,
    ) catch |e| {
        std.debug.print("[actuator] publisher init failed: {}\n", .{e});
        return;
    };
    defer pub_.deinit();

    std.debug.print(
        "[actuator] differential drive  {s} → {s}  (Ctrl-C to stop)\n",
        .{ input_topic, output_topic },
    );

    var count: u64 = 0;

    while (true) {
        if (sub.receive()) |raw| {
            const filtered: *msgs.Filtered = @ptrCast(@alignCast(raw));
            count += 1;

            // Differential drive mixing.
            const left_pwm = clamp(base_pwm + filtered.z * yaw_gain, 100.0);
            const right_pwm = clamp(base_pwm - filtered.z * yaw_gain, 100.0);
            const enabled: u8 = if (filtered.magnitude > motion_threshold) 1 else 0;

            // Zero-copy publish of motor command.
            const slot: *msgs.MotorCmd = @ptrCast(@alignCast(pub_.reserve()));
            slot.* = msgs.MotorCmd{
                .seq = filtered.seq,
                .timestamp = milliTimestamp(),
                .left_pwm = left_pwm,
                .right_pwm = right_pwm,
                .enabled = enabled,
            };
            pub_.commit();

            // Print motor commands every 100 messages.
            if (count % 100 == 0) {
                const state: []const u8 = if (enabled == 1) "RUNNING" else "IDLE   ";
                std.debug.print(
                    "[actuator] {s}  L={d:>7.2}%  R={d:>7.2}%  |v|={d:.3}  seq={d}\n",
                    .{ state, left_pwm, right_pwm, filtered.magnitude, filtered.seq },
                );
            }
        } else {
            sleepMs(1);
        }
    }
}
