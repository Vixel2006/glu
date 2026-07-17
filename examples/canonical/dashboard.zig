const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

const topic_filtered = "/filtered_temp";
const topic_status = "/sensor_status";
const node_name = "temperature_dashboard";
const capacity = 4096;
const tcp_port: u16 = 9999;
const alert_port: u16 = 9998;
const tick_rate_hz = 200;

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

fn runDisplay(allocator: std.mem.Allocator) void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var filtered_sub = glu.Subscriber.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tx] subscriber init failed: {}\n", .{e});
        return;
    };
    defer filtered_sub.deinit();

    var status_sub = glu.Subscriber.init(allocator, topic_status, @sizeOf(msgs.SensorStatus), 128) catch |e| {
        std.debug.print("[dashboard/tx] status subscriber init failed: {}\n", .{e});
        return;
    };
    defer status_sub.deinit();

    var udp_sock = glu.udp.bind(io, 0, .{}) catch |e| {
        std.debug.print("[dashboard/tx] UDP bind failed: {}\n", .{e});
        return;
    };
    defer glu.udp.close(&udp_sock, io);

    // Initialize AsyncIo for display heartbeat sending
    var aio = glu.io_mod.AsyncIo.init(16) catch |e| {
        std.debug.print("[dashboard/tx] AsyncIo init failed: {}\n", .{e});
        return;
    };
    defer aio.deinit();

    const dest_ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:9997") catch unreachable;
    const dest_addr = glu.net.socketAddrFromIp(dest_ip) catch unreachable;

    std.debug.print(
        "[dashboard/tx] display + registry monitor (async UDP)\n" ++
        "[dashboard/tx]   Ctrl-C to stop\n",
        .{},
    );

    var latest_filtered: ?msgs.FilteredTemperature = null;
    var tick: u32 = 0;

    while (true) {
        while (filtered_sub.receive()) |raw| {
            const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
            latest_filtered = msg.*;
        }

        while (status_sub.receive()) |raw| {
            const msg: *msgs.SensorStatus = @ptrCast(@alignCast(raw));
            _ = msg;
        }

        tick += 1;
        if (tick >= tick_rate_hz * 2) {
            tick = 0;

            if (latest_filtered) |data| {
                std.debug.print(
                    "[dashboard] seq={d}  raw={d:.2}°C  filtered={d:.2}°C  hum={d:.1}%  samples={d}\n",
                    .{ data.seq, data.raw_temp, data.filtered_temp, data.humidity, data.sample_count },
                );
            }

            if (glu.registry.listAlive(allocator)) |entries| {
                if (entries.len > 0) {
                    std.debug.print("[dashboard] nodes:", .{});
                    for (entries) |entry| {
                        const s = if (entry.alive) "\x1b[32malive\x1b[0m" else "\x1b[31mdead\x1b[0m";
                        std.debug.print("  {s}(pid={d},{s})", .{ entry.name, entry.pid, s });
                        allocator.free(entry.name);
                    }
                    std.debug.print("\n", .{});
                }
                allocator.free(entries);
            } else |_| {}

            // Send heartbeat asynchronously
            const heartbeat = "dashboard_alive";
            var send_fut: glu.io_mod.Future(usize) = .{};
            var send_iov = [1]std.posix.iovec_const{ .{ .base = heartbeat.ptr, .len = heartbeat.len } };
            var send_msg = std.os.linux.msghdr_const{
                .name = dest_addr.ptr(),
                .namelen = dest_addr.len(),
                .iov = &send_iov,
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = aio.sendmsg(udp_sock.handle, &send_msg, &send_fut.completion, 0) catch {};
            _ = send_fut.wait(&aio) catch {};
        }

        sleepMs(1000 / tick_rate_hz);
    }
}

fn runTcpServer() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.heap.page_allocator;

    var sub = glu.Subscriber.init(allocator, topic_filtered, @sizeOf(msgs.FilteredTemperature), capacity) catch |e| {
        std.debug.print("[dashboard/tcp] subscriber init failed: {}\n", .{e});
        return;
    };
    defer sub.deinit();

    var server = glu.tcp.listen(io, tcp_port, .{}) catch |e| {
        std.debug.print("[dashboard/tcp] listen on {d} failed: {}\n", .{ tcp_port, e });
        return;
    };
    defer glu.tcp.closeServer(&server, io);

    // Initialize AsyncIo for async connections and data streaming
    var aio = glu.io_mod.AsyncIo.init(32) catch |e| {
        std.debug.print("[dashboard/tcp] AsyncIo init failed: {}\n", .{e});
        return;
    };
    defer aio.deinit();

    std.debug.print(
        "[dashboard/tcp] listening on :{d} (async accept + stream)\n",
        .{tcp_port},
    );

    while (true) {
        // Accept incoming client connection asynchronously
        var client_sockaddr: std.posix.sockaddr.in = undefined;
        var client_sockaddr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        var accept_fut: glu.io_mod.Future(std.os.linux.fd_t) = .{};

        _ = aio.accept(server.socket.handle, @ptrCast(&client_sockaddr), &client_sockaddr_len, &accept_fut.completion, 0) catch |e| {
            std.debug.print("[dashboard/tcp] accept queue error: {}\n", .{e});
            sleepMs(100);
            continue;
        };

        _ = aio.submit() catch {};
        const client_fd = accept_fut.wait(&aio) catch |e| {
            std.debug.print("[dashboard/tcp] accept wait error: {}\n", .{e});
            sleepMs(100);
            continue;
        };
        defer _ = std.os.linux.close(client_fd);

        // Apply TCP socket options manually
        glu.tcp.applySocketOpts(client_fd, .{});

        std.debug.print("[dashboard/tcp] client connected\n", .{});

        var latest: ?msgs.FilteredTemperature = null;
        while (true) {
            while (sub.receive()) |raw| {
                const msg: *msgs.FilteredTemperature = @ptrCast(@alignCast(raw));
                latest = msg.*;
            }

            if (latest) |data| {
                const bytes = std.mem.asBytes(&data);
                
                // Stream data to client asynchronously
                var send_fut: glu.io_mod.Future(usize) = .{};
                _ = aio.send(client_fd, bytes, &send_fut.completion, 0) catch {
                    break;
                };
                _ = send_fut.wait(&aio) catch {
                    break;
                };
            }

            sleepMs(1000 / tick_rate_hz);
        }
    }
}

pub fn main() void {
    const allocator = std.heap.page_allocator;

    glu.registry.register(node_name) catch {};
    defer glu.registry.unregister(node_name);

    std.debug.print(
        "[dashboard] temperature monitor\n" ++
        "[dashboard]   {s} ← filtered data\n" ++
        "[dashboard]   {s} ← sensor status\n" ++
        "[dashboard]   TCP :{d}  (connect with companion python client)\n" ++
        "[dashboard]   Ctrl-C to stop\n",
        .{ topic_filtered, topic_status, tcp_port },
    );

    const pid = std.c.fork();

    if (pid == 0) {
        runTcpServer();
        std.c.exit(0);
    } else if (pid > 0) {
        runDisplay(allocator);
        _ = std.c.kill(pid, std.posix.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
    } else {
        std.debug.print("[dashboard] fork failed\n", .{});
    }
}
