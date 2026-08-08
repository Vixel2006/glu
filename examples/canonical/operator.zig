// operator — the human-in-the-loop control room node.
//
// Forked into two processes that coordinate through glu topics:
//
//   parent (run_display): second subscriber on raw joints (alongside the
//     coordinator — watch the slowest-reader backpressure with
//     `glu info /robot/joint_states`), fused-state display, node registry
//     table, UDP discovery listener (udp.receive_from), and multicast
//     broadcasts to the coordinator (udp.send_to).
//
//   child (run_tcp_server): bidirectional TCP server. Reads plain-text
//     commands from a connected client (home / torque <n> / velocity <n>
//     / stop), publishes them to /robot/command, and sends back the latest
//     fused state snapshot. This is the "your own controller GUI" hook.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");
const util = @import("util.zig");

const IO = glu.IO;

const topic_joints = "/robot/joint_states";
const topic_fused = "/robot/fused";
const topic_command = "/robot/command";
const capacity = 4096;
const node_name = "operator";

const discovery_port: u16 = 9996; // sensor heartbeats land here
const multicast_group = "224.0.0.1"; // we broadcast on this group
const multicast_port: u16 = 9997;
const tcp_port: u16 = 9998; // control-room client connects here

const tick_rate_hz = 200;

fn send_command(
    command_pub: *glu.Publisher,
    seq: *u32,
    kind: msgs.CommandKind,
    target: u32,
    value: f32,
) void {
    const slot: *msgs.RobotCommand = @ptrCast(@alignCast(command_pub.reserve()));
    slot.* = msgs.RobotCommand{
        .seq = seq.*,
        .timestamp = util.milli_timestamp(),
        .kind = @intFromEnum(kind),
        .target = target,
        .value = value,
    };
    seq.* += 1;
    command_pub.commit();
}

fn run_tcp_server() void {
    // This process is forked from the operator, so it registers under its own
    // name — otherwise `glu down` would orphan it and it would hold :9998 forever.
    glu.registry.register("operator_tcp") catch |e| {
        std.debug.print("[op/tcp] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister("operator_tcp");

    var io = IO.init(64, 0) catch |e| {
        std.debug.print("[op/tcp] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var command_pub = glu.Publisher.init(topic_command, @sizeOf(msgs.RobotCommand), 128, .reliable) catch |e| {
        std.debug.print("[op/tcp] command publisher init failed: {}\n", .{e});
        return;
    };
    defer command_pub.deinit();

    var command_seq: u32 = 0;

    // Loopback only: this demo control channel is unauthenticated, so it
    // must not be reachable off the machine. See docs/SECURITY.md.
    var server = glu.tcp.listen(&io, tcp_port, .{ .host = "127.0.0.1" }) catch |e| {
        std.debug.print("[op/tcp] listen on {d} failed: {}\n", .{ tcp_port, e });
        return;
    };
    defer glu.tcp.close_server(&server);

    std.debug.print("[op/tcp] listening on :{d} — send home / torque <n> / velocity <n> / stop\n", .{tcp_port});

    while (true) {
        var compl_accept: IO.Future = undefined;
        glu.tcp.accept(&io, &compl_accept, &server) catch |e| {
            std.debug.print("[op/tcp] accept queue error: {}\n", .{e});
            util.timer_sleep(&io, 100);
            continue;
        };
        const sock = io.wait(&compl_accept, std.posix.socket_t) catch |e| {
            std.debug.print("[op/tcp] accept wait error: {}\n", .{e});
            util.timer_sleep(&io, 100);
            continue;
        };
        glu.tcp.apply_socket_opts(sock, .{});
        var stream = glu.tcp.Stream{ .socket = sock, .handle = sock };
        defer glu.tcp.close(&stream);

        std.debug.print("[op/tcp] control client connected\n", .{});

        // Only hold a fused reader slot while a client is connected. A
        // subscriber that never acknowledges is the slowest reader and would
        // otherwise block the coordinator's reliable fused publisher forever.
        var fused_sub = glu.Subscriber.init(topic_fused, @sizeOf(msgs.FusedState), capacity) catch |e| {
            std.debug.print("[op/tcp] fused subscriber init failed: {}\n", .{e});
            continue;
        };
        defer fused_sub.deinit();

        var line: [128]u8 = undefined;
        var line_len: usize = 0;
        var chunk: [128]u8 = undefined;
        var latest: ?msgs.FusedState = null;
        var compl_recv: IO.Future = undefined;
        var compl_send: IO.Future = undefined;
        var send_pending = false;
        var recv_active = false;

        while (true) {
            while (fused_sub.peek()) |raw| {
                const msg: *msgs.FusedState = @ptrCast(@alignCast(raw));
                latest = msg.*;
                fused_sub.ack();
            }

            if (send_pending and compl_send.done) {
                _ = compl_send.result.send catch |e| {
                    std.debug.print("[op/tcp] send error: {}\n", .{e});
                    break;
                };
                send_pending = false;
            }

            if (compl_recv.done) {
                const n = compl_recv.result.recv catch |e| {
                    std.debug.print("[op/tcp] recv error: {}\n", .{e});
                    break;
                };
                if (n == 0) {
                    std.debug.print("[op/tcp] client disconnected\n", .{});
                    break;
                }
                if (line_len + n <= line.len) {
                    @memcpy(line[line_len .. line_len + n], chunk[0..n]);
                    line_len += n;
                }
                while (std.mem.indexOfScalar(u8, line[0..line_len], '\n')) |nl| {
                    const cmd = std.mem.trim(u8, line[0..nl], " \n\r");
                    if (cmd.len > 0) {
                        if (std.mem.eql(u8, cmd, "home")) {
                            send_command(&command_pub, &command_seq, .home, 0, 0);
                        } else if (std.mem.startsWith(u8, cmd, "torque")) {
                            const val = std.fmt.parseFloat(f32, std.mem.trim(u8, cmd[6..], " ")) catch 0.0;
                            send_command(&command_pub, &command_seq, .torque, 0, val);
                        } else if (std.mem.startsWith(u8, cmd, "velocity")) {
                            const val = std.fmt.parseFloat(f32, std.mem.trim(u8, cmd[8..], " ")) catch 0.0;
                            send_command(&command_pub, &command_seq, .velocity, 0, val);
                        } else if (std.mem.eql(u8, cmd, "stop")) {
                            send_command(&command_pub, &command_seq, .stop, 0, 0);
                        } else {
                            std.debug.print("[op/tcp] unknown command: '{s}'\n", .{cmd});
                        }
                    }
                    line_len -= nl + 1;
                    if (line_len > 0) {
                        @memcpy(line[0..line_len], line[nl + 1 .. nl + 1 + line_len]);
                    }
                }
                recv_active = false;
            }
            if (!recv_active) {
                compl_recv = undefined;
                glu.tcp.receive(&io, &compl_recv, &stream, &chunk) catch break;
                recv_active = true;
            }

            if (latest) |data| {
                if (!send_pending) {
                    var buf: [256]u8 = undefined;
                    const rep = std.fmt.bufPrint(
                        &buf,
                        "state seq={d} joints={d} avg_effort={d:.2} energy={d:.2} fault={d}\n",
                        .{ data.seq, data.joint_count, data.avg_effort, data.energy, data.fault_level },
                    ) catch break;
                    glu.tcp.send(&io, &compl_send, &stream, rep) catch break;
                    send_pending = true;
                    latest = null;
                }
            }

            io.run(0) catch |e| {
                std.debug.print("[op/tcp] IO run error: {}\n", .{e});
            };
            util.timer_sleep(&io, 1000 / tick_rate_hz);
        }
    }
}

fn run_display() void {
    var io = IO.init(64, 0) catch |e| {
        std.debug.print("[op/display] IO init failed: {}\n", .{e});
        return;
    };
    defer io.deinit();

    var joints_sub = glu.Subscriber.init(topic_joints, @sizeOf(msgs.JointState), capacity) catch |e| {
        std.debug.print("[op/display] joints subscriber init failed: {}\n", .{e});
        return;
    };
    defer joints_sub.deinit();

    var fused_sub = glu.Subscriber.init(topic_fused, @sizeOf(msgs.FusedState), capacity) catch |e| {
        std.debug.print("[op/display] fused subscriber init failed: {}\n", .{e});
        return;
    };
    defer fused_sub.deinit();

    var discovery_sock = glu.udp.bind(&io, discovery_port, .{}) catch |e| {
        std.debug.print("[op/display] discovery UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&discovery_sock);

    var tx_sock = glu.udp.bind(&io, 0, .{}) catch |e| {
        std.debug.print("[op/display] tx UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&tx_sock);

    // Pin multicast output to loopback so the coordinator (on this host, no
    // multicast route required) receives our broadcast.group_state.
    const IP_MULTICAST_IF: u32 = 32;
    const lo_addr: [4]u8 = .{ 127, 0, 0, 1 };
    _ = std.c.setsockopt(tx_sock, 0, IP_MULTICAST_IF, &lo_addr, @sizeOf([4]u8));

    std.debug.print(
        "[op/display] control room node (glu)\n" ++
            "[op/display]   {s} ← raw joints (2nd subscriber)\n" ++
            "[op/display]   {s} ← fused state\n" ++
            "[op/display]   UDP :{d} ← sensor heartbeats\n" ++
            "[op/display]   UDP → {s}:{d} multicast broadcast\n" ++
            "[op/display]   TCP :{d} ← control client\n" ++
            "[op/display]   Ctrl-C to stop\n",
        .{ topic_joints, topic_fused, discovery_port, multicast_group, multicast_port, tcp_port },
    );

    var recv_buf: [128]u8 = undefined;
    var recv_future: IO.Future = undefined;
    var recv_active = false;

    var broadcast_future: IO.Future = undefined;
    var broadcast_active = false;

    var tick: u32 = 0;

    while (true) {
        var joints_seen: u32 = 0;
        var latest_joint: ?msgs.JointState = null;
        while (joints_sub.peek()) |raw| {
            const msg: *msgs.JointState = @ptrCast(@alignCast(raw));
            latest_joint = msg.*;
            joints_seen += 1;
            joints_sub.ack();
        }

        var latest_fused: ?msgs.FusedState = null;
        while (fused_sub.peek()) |raw| {
            const msg: *msgs.FusedState = @ptrCast(@alignCast(raw));
            latest_fused = msg.*;
            fused_sub.ack();
        }

        if (recv_future.done) {
            if (recv_future.result.recv_from) |n| {
                std.debug.print("[op/display] UDP discovery: {s}\n", .{recv_buf[0..n]});
            } else |_| {}
            recv_active = false;
        }
        if (!recv_active) {
            recv_future = undefined;
            glu.udp.receive_from(&io, &recv_future, discovery_sock, &recv_buf) catch {
                recv_active = false;
            };
            recv_active = true;
        }

        if (broadcast_future.done) {
            if (broadcast_future.result.send_to) |_| {
                // Broadcast delivered.
            } else |e| {
                std.debug.print("[op/display] multicast send_to error: {}\n", .{e});
            }
            broadcast_active = false;
        }
        if (!broadcast_active) {
            broadcast_future = undefined;
            glu.udp.send_to(&io, &broadcast_future, tx_sock, multicast_group, multicast_port, "operator:online") catch |e| {
                std.debug.print("[op/display] multicast send_to error: {}\n", .{e});
                broadcast_active = true;
            };
            broadcast_active = true;
        }

        tick += 1;
        if (tick >= tick_rate_hz * 2) {
            tick = 0;
            if (latest_fused) |f| {
                std.debug.print("[op/display] fused seq={d} joints={d} avg_effort={d:.2} energy={d:.2} fault={d}\n", .{
                    f.seq, f.joint_count, f.avg_effort, f.energy, f.fault_level,
                });
            }
            if (latest_joint) |j| {
                std.debug.print("[op/display]   last joint seq={d} pos={d:.2} vel={d:.2} effort={d:.2}\n", .{
                    j.seq, j.position, j.velocity, j.effort,
                });
            }

            var entry_buf: [128]glu.registry.NodeEntry = undefined;
            if (glu.registry.list_alive(&entry_buf)) |count| {
                if (count > 0) {
                    std.debug.print("[op/display] nodes:", .{});
                    for (entry_buf[0..count]) |entry| {
                        const s = if (entry.alive) "\x1b[32malive\x1b[0m" else "\x1b[31mdead\x1b[0m";
                        std.debug.print("  {s}(pid={d},{s})", .{ entry.name[0..entry.name_len], entry.pid, s });
                    }
                    std.debug.print("\n", .{});
                }
            } else |_| {}
        }

        io.run(0) catch |e| {
            std.debug.print("[op/display] IO run error: {}\n", .{e});
        };
        util.timer_sleep(&io, 1000 / tick_rate_hz);
    }
}

pub fn main() void {
    glu.registry.register(node_name) catch |e| {
        std.debug.print("[operator] warning: failed to register node: {}\n", .{e});
    };
    defer glu.registry.unregister(node_name);

    const pid = std.c.fork();
    if (pid == 0) {
        run_tcp_server();
        std.c.exit(0);
    } else if (pid > 0) {
        run_display();
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[operator] fork failed\n", .{});
    }
}
