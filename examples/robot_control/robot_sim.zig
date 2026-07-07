/// robot_sim.zig — differential drive robot simulator
///
/// Subscribes to /cmd_vel and integrates kinematic equations to simulate
/// the robot's pose (x, y, theta) over time.  Publishes Odometry on /odom
/// at 100 Hz using zero-copy.
///
/// Kinematics (first-order Euler integration at 100 Hz):
///   theta  += angular_z * dt
///   x      += linear_x * cos(theta) * dt
///   y      += linear_x * sin(theta) * dt
///
/// Also monitors /battery (subscriber_id=0) and prints warnings if charge
/// drops below 85%.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const cmd_topic = "/cmd_vel";
const odom_topic = "/odom";
const bat_topic = "/battery";
const capacity = 4096;
const cmd_sub_id = 0;
const bat_sub_id = 0;
const odom_rate_hz = 100;
const bat_warn_pct: f32 = 85.0;

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

    // Command velocity subscriber.
    var cmd_sub = glu.Subscriber.init(
        allocator,
        cmd_sub_id,
        cmd_topic,
        @sizeOf(msgs.Twist),
        capacity,
    ) catch |e| {
        std.debug.print("[robot_sim] cmd subscriber init failed: {}\n", .{e});
        return;
    };
    defer cmd_sub.deinit();

    // Battery subscriber (different topic — subscriber_id is per-topic).
    var bat_sub = glu.Subscriber.init(
        allocator,
        bat_sub_id,
        bat_topic,
        @sizeOf(msgs.BatteryStatus),
        capacity,
    ) catch |e| {
        std.debug.print("[robot_sim] battery subscriber init failed: {}\n", .{e});
        return;
    };
    defer bat_sub.deinit();

    // Odometry publisher (zero-copy).
    var odom_pub = glu.Publisher.init(
        allocator,
        odom_topic,
        @sizeOf(msgs.Odometry),
        capacity,
    ) catch |e| {
        std.debug.print("[robot_sim] odom publisher init failed: {}\n", .{e});
        return;
    };
    defer odom_pub.deinit();

    std.debug.print(
        "[robot_sim] differential drive simulator\n" ++
            "[robot_sim]   cmd_vel : {s}  odom : {s}\n" ++
            "[robot_sim]   rate    : {d} Hz  Ctrl-C to stop\n",
        .{ cmd_topic, odom_topic, odom_rate_hz },
    );

    const interval_ms: u64 = 1000 / odom_rate_hz;
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(odom_rate_hz));

    // Robot state.
    var x: f32 = 0;
    var y: f32 = 0;
    var theta: f32 = 0;
    var linear_vel: f32 = 0;
    var angular_vel: f32 = 0;
    var seq: u32 = 0;

    while (true) : (seq += 1) {
        // Consume the latest command velocity (non-blocking).
        // We process every available message to stay up to date.
        while (cmd_sub.receive()) |raw| {
            const cmd: *msgs.Twist = @ptrCast(@alignCast(raw));
            linear_vel = cmd.linear_x;
            angular_vel = cmd.angular_z;
        }

        // Integrate kinematics.
        theta += angular_vel * dt;
        x += linear_vel * std.math.cos(theta) * dt;
        y += linear_vel * std.math.sin(theta) * dt;

        // Publish odometry (zero-copy).
        const slot: *msgs.Odometry = @ptrCast(@alignCast(odom_pub.reserve()));
        slot.* = msgs.Odometry{
            .seq = seq,
            .timestamp = milliTimestamp(),
            .x = x,
            .y = y,
            .theta = theta,
            .linear_vel = linear_vel,
            .angular_vel = angular_vel,
        };
        odom_pub.commit();

        // Check battery (non-blocking — only prints when a new message arrives).
        while (bat_sub.receive()) |raw| {
            const bat: *msgs.BatteryStatus = @ptrCast(@alignCast(raw));
            if (bat.percentage < bat_warn_pct) {
                std.debug.print(
                    "\x1b[33m[robot_sim] BATTERY LOW  {d:.1}%  {d:.2}V\x1b[0m\n",
                    .{ bat.percentage, bat.voltage },
                );
            }
        }

        // Print odometry every ~1 second.
        if (seq % odom_rate_hz == 0) {
            std.debug.print(
                "[robot_sim] seq={d}  x={d:.3}m  y={d:.3}m  θ={d:.3}rad  v={d:.2}m/s  ω={d:.3}rad/s\n",
                .{ seq, x, y, theta, linear_vel, angular_vel },
            );
        }

        sleepMs(interval_ms);
    }
}
