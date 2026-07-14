/// telemetry_bridge.zig — UDP telemetry bridge node
///
/// Subscribes to /odom and /battery and forwards data via UDP to 127.0.0.1:9999
/// as human-readable ASCII strings:
///
///   ODOM seq=N x=X y=Y theta=T\n
///   BAT  seq=N pct=P%\n
///
/// The node forks at startup:
///   • Parent process: the bridge — polls glu topics and sends UDP datagrams.
///   • Child process:  the receiver — binds port 9999 and prints what arrives,
///                     simulating a remote ground station or dashboard.
///
/// This showcases glu.udp alongside pub/sub in a single demo.
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const odom_topic = "/odom";
const bat_topic = "/battery";
const capacity = 4096;
const udp_host = "127.0.0.1";
const udp_port: u16 = 9999;

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

// -- child process: UDP receiver (ground station simulator) ------------------

fn runReceiver() void {
    // Give the parent a moment to set up its socket before we bind.
    sleepMs(200);

    const io = std.Io.Threaded.global_single_threaded.io();
    var sock = glu.udp.bind(io, udp_port, .{}) catch |e| {
        std.debug.print("[bridge/rx] bind port {d} failed: {}\n", .{ udp_port, e });
        return;
    };
    defer glu.udp.close(&sock, io);

    std.debug.print(
        "[bridge/rx] ground station listening on :{d}\n",
        .{udp_port},
    );

    var buf: [256]u8 = undefined;
    while (true) {
        const result = glu.udp.receiveFrom(&sock, io, &buf) catch |e| {
            if (e == error.WouldBlock or e == error.Interrupted) continue;
            std.debug.print("[bridge/rx] receiveFrom error: {}\n", .{e});
            break;
        };
        // Print the received ASCII telemetry line (strip trailing newline for clean output).
        const data = result.data;
        const trimmed = if (data.len > 0 and data[data.len - 1] == '\n')
            data[0 .. data.len - 1]
        else
            data;
        std.debug.print("[bridge/rx] ← {s}\n", .{trimmed});
    }
}

// -- parent process: bridge (pub/sub → UDP) ----------------------------------

fn runBridge() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.heap.page_allocator;

    var odom_sub = glu.Subscriber.init(
        allocator,
        odom_topic,
        @sizeOf(msgs.Odometry),
        capacity,
    ) catch |e| {
        std.debug.print("[bridge/tx] odom subscriber init failed: {}\n", .{e});
        return;
    };
    defer odom_sub.deinit();

    var bat_sub = glu.Subscriber.init(
        allocator,
        bat_topic,
        @sizeOf(msgs.BatteryStatus),
        capacity,
    ) catch |e| {
        std.debug.print("[bridge/tx] battery subscriber init failed: {}\n", .{e});
        return;
    };
    defer bat_sub.deinit();

    // Sender socket (ephemeral port — OS assigns it).
    var sender = glu.udp.bind(io, 0, .{}) catch |e| {
        std.debug.print("[bridge/tx] sender socket failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&sender, io);

    std.debug.print(
        "[bridge/tx] bridge  {s},{s} → UDP {s}:{d}\n",
        .{ odom_topic, bat_topic, udp_host, udp_port },
    );

    var count: u64 = 0;
    var buf: [256]u8 = undefined;

    while (true) {
        // Forward all available odometry messages.
        while (odom_sub.receive()) |raw| {
            const odom: *msgs.Odometry = @ptrCast(@alignCast(raw));
            count += 1;
            const line = std.fmt.bufPrint(
                &buf,
                "ODOM seq={d} x={d:.3} y={d:.3} theta={d:.4}\n",
                .{ odom.seq, odom.x, odom.y, odom.theta },
            ) catch continue;
            _ = glu.udp.sendTo(&sender, io, udp_host, udp_port, line) catch {};
        }

        // Forward all available battery status messages.
        while (bat_sub.receive()) |raw| {
            const bat: *msgs.BatteryStatus = @ptrCast(@alignCast(raw));
            const line = std.fmt.bufPrint(
                &buf,
                "BAT  seq={d} pct={d:.1}%\n",
                .{ bat.seq, bat.percentage },
            ) catch continue;
            _ = glu.udp.sendTo(&sender, io, udp_host, udp_port, line) catch {};
        }

        // Status print every 100 forwarded messages.
        if (count > 0 and count % 100 == 0) {
            std.debug.print(
                "[bridge/tx] forwarded {d} odom datagrams  ts={d}\n",
                .{ count, milliTimestamp() },
            );
        }

        sleepMs(1);
    }
}

// -- main --------------------------------------------------------------------
pub fn main() void {
    // Fork: child becomes the UDP receiver, parent runs the bridge.
    const pid = std.c.fork();

    if (pid == 0) {
        // Child process — ground station receiver.
        runReceiver();
        std.c.exit(0);
    } else if (pid > 0) {
        // Parent process — glu telemetry bridge.
        runBridge();
        // If the bridge exits (e.g. signal), also terminate the receiver child.
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[bridge] fork failed\n", .{});
    }
}
