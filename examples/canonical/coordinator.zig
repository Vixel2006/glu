// coordinator — fusion, command handling, and best-effort logging.
//
// The busiest node. It subscribes to raw joints, health, and operator
// commands, then publishes a fused state. It also shows off two things the
// other nodes don't:
//
//   1. best-effort QoS: it opens the low-level `glu.Channel` for the logs
//      topic with `ToS.best_effort` and writes with the raw `glu.write` free
//      function. Best-effort channels never back-pressure the writer, so a
//      slow (or missing) logger can never stall the control loop.
//
//   2. UDP multicast: it joins a multicast group and receives one-way state
//      broadcasts from the operator (udp.receive_from + udp.join_multicast),
//      instead of only sending like the sensor does.
//
// The loop is paced with an io_uring `timeout` rather than nanosleep.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");
const util = @import("util.zig");

const IO = glu.IO;
const LogEntry = msgs.LogEntry;

const topic_joints = "/robot/joint_states";
const topic_health = "/robot/health";
const topic_command = "/robot/command";
const topic_fused = "/robot/fused";
const topic_logs = "/robot/logs";

const capacity = 4096;
const log_capacity = 256;
const rate_hz = 100;
const node_name = "coordinator";

// Operator broadcasts on this multicast group; we listen to it.
const multicast_group = "224.0.0.1";
const multicast_port: u16 = 9997;

const Node = struct {
    io: *IO,
    joints: glu.Subscriber,
    health: glu.Subscriber,
    command: glu.Subscriber,
    fused: glu.Publisher,
    logs: glu.Channel,
    seq: u32 = 0,
    log_seq: u32 = 0,
    command_seq: u32 = 0,
    avg_effort: f32 = 0.0,
    energy: f32 = 0.0,
    fault_level: u32 = 0,
    target_torque: f32 = 2.0,

    fn log(self: *Node, source: []const u8, level: msgs.LogLevel, msg: []const u8) void {
        var entry = LogEntry{
            .seq = self.log_seq,
            .timestamp = util.milli_timestamp(),
            .level = @intFromEnum(level),
            .source = std.mem.zeroes([16]u8),
            .msg = std.mem.zeroes([64]u8),
        };
        self.log_seq += 1;
        msgs.set_str(&entry.source, source);
        msgs.set_str(&entry.msg, msg);
        // NOTE: best-effort write — never blocks even if the logger is slow.
        glu.write(&self.logs, @ptrCast(&entry));
    }
};

pub fn main() void {
    var io = IO.init(64, 0) catch |e| {
        std.debug.print("[coord] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var node = Node{
        .io = &io,
        .joints = glu.Subscriber.init(topic_joints, @sizeOf(msgs.JointState), capacity) catch |e| {
            std.debug.print("[coord] joints subscriber init failed: {}\n", .{e});
            return;
        },
        .health = glu.Subscriber.init(topic_health, @sizeOf(msgs.Health), 128) catch |e| {
            std.debug.print("[coord] health subscriber init failed: {}\n", .{e});
            return;
        },
        .command = glu.Subscriber.init(topic_command, @sizeOf(msgs.RobotCommand), 128) catch |e| {
            std.debug.print("[coord] command subscriber init failed: {}\n", .{e});
            return;
        },
        .fused = glu.Publisher.init(topic_fused, @sizeOf(msgs.FusedState), capacity, .reliable) catch |e| {
            std.debug.print("[coord] fused publisher init failed: {}\n", .{e});
            return;
        },
        .logs = glu.Channel.open(topic_logs, @sizeOf(LogEntry), log_capacity, .best_effort) catch |e| {
            std.debug.print("[coord] raw best-effort channel open failed: {}\n", .{e});
            return;
        },
    };
    defer node.joints.deinit();
    defer node.health.deinit();
    defer node.command.deinit();
    defer node.fused.deinit();
    defer node.logs.close();

    glu.registry.register(node_name) catch |e| {
        std.debug.print("[coord] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister(node_name);

    var udp_sock = glu.udp.bind(&io, multicast_port, .{}) catch |e| {
        std.debug.print("[coord] multicast UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock);
    glu.udp.join_multicast(udp_sock, multicast_group);

    node.log("coordinator", .info, "node online, joined multicast group");

    std.debug.print(
        "[coord] fusion + command node (glu)\n" ++
            "[coord]   {s} ← joints, {s} ← health, {s} ← commands\n" ++
            "[coord]   {s} → fused\n" ++
            "[coord]   {s} → best-effort logs (raw glu.write)\n" ++
            "[coord]   UDP multicast {s}:{d} joined\n" ++
            "[coord]   Ctrl-C to stop\n",
        .{ topic_joints, topic_health, topic_command, topic_fused, topic_logs, multicast_group, multicast_port },
    );

    var recv_buf: [256]u8 = undefined;
    var recv_future: IO.Future = undefined;
    var recv_active = false;

    const dt: f32 = 1.0 / @as(f32, @floatFromInt(rate_hz));
    var last_effort_sum: f32 = 0.0;
    var sample_count: u32 = 0;

    while (true) {
        while (node.joints.peek()) |raw| {
            const msg: *msgs.JointState = @ptrCast(@alignCast(raw));
            last_effort_sum += msg.effort;
            sample_count += 1;
            node.joints.ack();
        }

        while (node.health.peek()) |raw| {
            const msg: *msgs.Health = @ptrCast(@alignCast(raw));
            if (msg.error_count > 0) {
                node.log("sensor_arm", .warn, "health errors reported");
            }
            node.health.ack();
        }

        while (node.command.peek()) |raw| {
            const msg: *msgs.RobotCommand = @ptrCast(@alignCast(raw));
            node.command_seq += 1;
            switch (@as(msgs.CommandKind, @enumFromInt(msg.kind))) {
                .home => {
                    node.target_torque = 2.0;
                    node.log("operator", .info, "homing sequence started");
                },
                .torque, .velocity => {
                    node.target_torque = msg.value;
                    node.log("operator", .info, "target updated");
                },
                .stop => {
                    node.target_torque = 0.0;
                    node.log("operator", .warn, "EMERGENCY STOP");
                },
            }
            node.command.ack();
        }

        if (sample_count > 0) {
            node.avg_effort = last_effort_sum / @as(f32, @floatFromInt(sample_count));
        }
        node.energy += node.avg_effort * dt;
        if (node.avg_effort > 4.5 * node.target_torque) {
            node.fault_level = 1;
        }

        const slot: *msgs.FusedState = @ptrCast(@alignCast(node.fused.reserve()));
        slot.* = msgs.FusedState{
            .seq = node.seq,
            .timestamp = util.milli_timestamp(),
            .joint_count = sample_count,
            .avg_effort = node.avg_effort,
            .energy = node.energy,
            .fault_level = node.fault_level,
        };
        node.fused.commit();
        node.seq += 1;
        last_effort_sum = 0.0;
        sample_count = 0;

        if (recv_future.done) {
            if (recv_future.err) |_| {
                node.log("coordinator", .fatal, "multicast recv failed");
            } else {
                const n: usize = @intCast(recv_future.value);
                if (n > 0) node.log("operator", .info, recv_buf[0..n]);
            }
            recv_active = false;
        }
        if (!recv_active) {
            recv_future = undefined;
            glu.udp.receive_from(&io, &recv_future, udp_sock, &recv_buf) catch {
                node.log("coordinator", .fatal, "multicast recv arm failed");
            };
            recv_active = true;
        }

        io.run(0) catch |e| {
            std.debug.print("[coord] IO run error: {}\n", .{e});
        };
        util.timer_sleep(&io, 1000 / rate_hz);
    }
}
