// sensor_arm — telemetry producer node.
//
// Publishes joint states over a shared-memory topic at 100 Hz using the
// zero-copy `reserve`/`commit` pair, and battery/health telemetry once a
// second using the one-shot `publish` convenience. Also advertises itself
// to the operator over UDP (send_to). Registers itself in the node
// registry so `glu ps` and the operator's node table can see it.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");
const util = @import("util.zig");

const IO = glu.IO;

const topic_joints = "/robot/joint_states";
const topic_health = "/robot/health";
const capacity = 4096;
const rate_hz = 100;
const node_name = "sensor_arm";

// Operator listens for node heartbeats on this port.
const discovery_port: u16 = 9996;

pub fn main() void {
    var io = IO.init(32, 0) catch |e| {
        std.debug.print("[sensor] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var joints_pub = glu.Publisher.init(topic_joints, @sizeOf(msgs.JointState), capacity, .reliable) catch |e| {
        std.debug.print("[sensor] joints publisher init failed: {}\n", .{e});
        return;
    };
    defer joints_pub.deinit();

    var health_pub = glu.Publisher.init(topic_health, @sizeOf(msgs.Health), 128, .reliable) catch |e| {
        std.debug.print("[sensor] health publisher init failed: {}\n", .{e});
        return;
    };
    defer health_pub.deinit();

    glu.registry.register(node_name) catch |e| {
        std.debug.print("[sensor] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister(node_name);

    var udp_sock = glu.udp.bind(&io, 0, .{}) catch |e| {
        std.debug.print("[sensor] UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock);

    std.debug.print(
        "[sensor] arm telemetry node (glu)\n" ++
            "[sensor]   {s} @ {d} Hz (zero-copy reserve/commit)\n" ++
            "[sensor]   {s} @  1 Hz (publish copy)\n" ++
            "[sensor]   UDP heartbeat → :{d}\n" ++
            "[sensor]   Ctrl-C to stop\n",
        .{ topic_joints, rate_hz, topic_health, discovery_port },
    );

    const dt: f32 = 1.0 / @as(f32, @floatFromInt(rate_hz));
    var seq: u32 = 0;
    var health_seq: u32 = 0;
    var uptime: u32 = 0;

    var heartbeat: IO.Future = undefined;
    var heartbeat_active = false;

    while (true) : (seq += 1) {
        const t: f32 = @as(f32, @floatFromInt(seq)) * dt;

        const slot: *msgs.JointState = @ptrCast(@alignCast(joints_pub.reserve()));
        slot.* = msgs.JointState{
            .seq = seq,
            .timestamp = util.milli_timestamp(),
            .index = 0,
            .position = 0.5 * @sin(t * 1.0),
            .velocity = 0.5 * @cos(t * 1.0),
            .effort = 2.0 + @sin(t * 2.0) * 1.0,
        };
        joints_pub.commit();

        if (seq % rate_hz == 0) {
            uptime += 1;
            const health = msgs.Health{
                .seq = health_seq,
                .timestamp = util.milli_timestamp(),
                .uptime_sec = uptime,
                .battery_voltage = @max(10.0, 12.5 - @as(f32, @floatFromInt(uptime)) * 0.001),
                .temperature = 40.0 + @as(f32, @floatFromInt(uptime % 10)) * 0.5,
                .error_count = 0,
            };
            health_pub.publish(@ptrCast(&health));
            health_seq += 1;

            if (heartbeat.done) {
                _ = heartbeat.result.send_to catch |e| {
                    std.debug.print("[sensor] warning: heartbeat send error: {}\n", .{e});
                };
                heartbeat_active = false;
            }
            if (!heartbeat_active) {
                heartbeat = undefined;
                glu.udp.send_to(&io, &heartbeat, udp_sock, "127.0.0.1", discovery_port, "sensor_arm:alive") catch |e| {
                    std.debug.print("[sensor] warning: failed to send UDP heartbeat: {}\n", .{e});
                    heartbeat_active = true;
                };
                heartbeat_active = true;
            }
        }

        io.run(0) catch |e| {
            std.debug.print("[sensor] IO run error: {}\n", .{e});
        };
        util.timer_sleep(&io, 1000 / rate_hz);
    }
}
