const std = @import("std");
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;
const net = @import("net.zig");
const sockopt = @import("sockopt.zig");

pub const TcpErr = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    SetSockOptFailed,
    AddressResolveFailed,
    WouldBlock,
    ConnectionReset,
    Interrupted,
    MessageTooLarge,
};

fn mapErr(errno_val: i32) TcpErr {
    return switch (@as(linux.E, @enumFromInt(errno_val))) {
        .AGAIN => TcpErr.WouldBlock,
        .INTR => TcpErr.Interrupted,
        .CONNRESET => TcpErr.ConnectionReset,
        .PIPE => TcpErr.ConnectionReset,
        else => TcpErr.SocketFailed,
    };
}

pub const Config = struct {
    nodelay: bool = true,
    quickack: bool = true,
    keepalive: bool = false,
    keepalive_idle: u32 = 7200,
    keepalive_interval: u32 = 75,
    keepalive_count: u32 = 9,
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    defer_accept: bool = false,
    connect_timeout_ms: u32 = 5000,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};

pub fn listen(port: u16, config: Config) TcpErr!struct { fd: i32, port: u16 } {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return mapErr(c._errno().*);

    const opt: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &opt, @sizeOf(c_int)) == -1) {
        _ = c.close(fd);
        return TcpErr.SetSockOptFailed;
    }

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }

    var addr = posix.sockaddr.in{
        .family = c.AF.INET,
        .port = mem.nativeToBig(u16, port),
        .addr = 0,
    };

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) == -1)
        return TcpErr.BindFailed;

    if (c.listen(fd, c.SOMAXCONN) == -1)
        return TcpErr.ListenFailed;

    const actual_port = blk: {
        if (port != 0) break :blk port;
        var sockname: posix.sockaddr.in = undefined;
        var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.getsockname(fd, @ptrCast(&sockname), &namelen) == 0)
            break :blk mem.bigToNative(u16, sockname.port)
        else
            break :blk port;
    };

    return .{ .fd = fd, .port = actual_port };
}

pub fn accept(fd: i32, config: Config) TcpErr!i32 {
    var client_addr: posix.sockaddr.in = undefined;
    var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const client_fd = c.accept(fd, @ptrCast(&client_addr), &addrlen);
    if (client_fd == -1) return mapErr(c._errno().*);

    sockopt.applyTcp(client_fd, .{
        .nodelay = config.nodelay,
        .quickack = config.quickack,
        .keepalive = config.keepalive,
        .keepalive_idle = config.keepalive_idle,
        .keepalive_interval = config.keepalive_interval,
        .keepalive_count = config.keepalive_count,
        .recv_buf = null,
        .send_buf = config.send_buf,
        .defer_accept = false,
        .recv_timeout_ms = config.recv_timeout_ms,
        .send_timeout_ms = config.send_timeout_ms,
    }) catch |e| {
        _ = c.close(client_fd);
        return e;
    };

    return client_fd;
}

pub fn connect(host: []const u8, port: u16, config: Config) TcpErr!i32 {
    const addr = try net.resolve(host, port, c.SOCK.STREAM);

    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return mapErr(c._errno().*);

    if (config.recv_buf) |buf| {
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &buf, @sizeOf(c_int));
    }
    if (config.send_buf) |buf| {
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &buf, @sizeOf(c_int));
    }

    const orig_flags = c.fcntl(fd, c.F.GETFL);
    if (orig_flags == -1) {
        _ = c.close(fd);
        return mapErr(c._errno().*);
    }
    const nonblock: c_int = @bitCast(linux.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, orig_flags | nonblock) == -1) {
        _ = c.close(fd);
        return mapErr(c._errno().*);
    }

    const conn_rc = c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    if (conn_rc == -1) {
        const errno_val = c._errno().*;
        if (@as(linux.E, @enumFromInt(errno_val)) != .INPROGRESS) {
            _ = c.close(fd);
            return mapErr(errno_val);
        }
    }

    if (conn_rc != 0) {
        var pfd = [1]c.pollfd{
            .{ .fd = fd, .events = 0x004, .revents = 0 },
        };
        const poll_rc = c.poll(&pfd, 1, @as(c_int, @intCast(config.connect_timeout_ms)));
        if (poll_rc < 0) {
            const err = c._errno().*;
            _ = c.close(fd);
            return mapErr(err);
        }
        if (poll_rc == 0) {
            _ = c.close(fd);
            return TcpErr.ConnectFailed;
        }

        var err_val: c_int = 0;
        var err_len: posix.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL.SOCKET, 4, &err_val, &err_len) == -1 or err_val != 0) {
            _ = c.close(fd);
            return TcpErr.ConnectFailed;
        }
    }

    _ = c.fcntl(fd, c.F.SETFL, orig_flags & ~nonblock);

    sockopt.applyTcp(fd, .{
        .nodelay = config.nodelay,
        .quickack = config.quickack,
        .keepalive = config.keepalive,
        .keepalive_idle = config.keepalive_idle,
        .keepalive_interval = config.keepalive_interval,
        .keepalive_count = config.keepalive_count,
        .recv_buf = null,
        .send_buf = null,
        .defer_accept = false,
        .recv_timeout_ms = config.recv_timeout_ms,
        .send_timeout_ms = config.send_timeout_ms,
    }) catch |e| {
        _ = c.close(fd);
        return e;
    };

    return fd;
}

pub fn send(fd: i32, data: []const u8) TcpErr!void {
    const len: u32 = @intCast(data.len);
    var len_buf: [4]u8 = undefined;
    mem.writeInt(u32, &len_buf, len, .little);

    const buf = [_][]const u8{ &len_buf, data };
    inline for (buf) |b| {
        var offset: usize = 0;
        while (offset < b.len) {
            const rc = c.send(fd, b.ptr + offset, b.len - offset, c.MSG.NOSIGNAL);
            if (rc == -1) {
                const err = mapErr(c._errno().*);
                if (err == TcpErr.Interrupted) continue;
                return err;
            }
            offset += @as(usize, @intCast(rc));
        }
    }
}

pub fn receive(fd: i32, buffer: []u8) TcpErr!usize {
    var len_buf: [4]u8 = undefined;

    var offset: usize = 0;
    while (offset < 4) {
        const rc = c.recv(fd, &len_buf[offset], 4 - offset, 0);
        if (rc == -1) {
            const err = mapErr(c._errno().*);
            if (err == TcpErr.Interrupted) continue;
            return err;
        }
        if (rc == 0) return TcpErr.ConnectionReset;
        offset += @as(usize, @intCast(rc));
    }

    const msg_len = mem.readInt(u32, &len_buf, .little);
    if (msg_len == 0) return 0;
    if (msg_len > buffer.len) {
        var discard: [4096]u8 = undefined;
        var remaining = msg_len;
        while (remaining > 0) {
            const chunk = @min(remaining, @as(u32, @intCast(discard.len)));
            const rc = c.recv(fd, &discard, chunk, 0);
            if (rc == -1) {
                const err = mapErr(c._errno().*);
                if (err == TcpErr.Interrupted) continue;
                return err;
            }
            if (rc == 0) return TcpErr.ConnectionReset;
            remaining -= @as(u32, @intCast(rc));
        }
        return TcpErr.MessageTooLarge;
    }

    offset = 0;
    while (offset < msg_len) {
        const rc = c.recv(fd, buffer.ptr + offset, msg_len - offset, 0);
        if (rc == -1) {
            const err = mapErr(c._errno().*);
            if (err == TcpErr.Interrupted) continue;
            return err;
        }
        if (rc == 0) return TcpErr.ConnectionReset;
        offset += @as(usize, @intCast(rc));
    }
    return msg_len;
}

pub fn close(fd: i32) void {
    _ = c.close(fd);
}

test "listener: bind and close cleanly" {
    const r = try listen(0, .{});
    defer close(r.fd);
    try std.testing.expect(r.fd >= 0);
}

test "connect: refused returns ConnectFailed" {
    const result = connect("127.0.0.1", 1, .{});
    try std.testing.expectError(error.ConnectFailed, result);
}

test "listener + connect + accept round-trip" {
    const r = try listen(0, .{});
    defer close(r.fd);
    const port = r.port;

    const pid = c.fork();
    if (pid == 0) {
        const fd = connect("127.0.0.1", port, .{}) catch c.exit(1);
        close(fd);
        c.exit(0);
    }

    const client_fd = accept(r.fd, .{}) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer close(client_fd);

    var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
    _ = c.nanosleep(&ts, null);
    _ = c.waitpid(pid, null, 0);
}

test "send and receive data" {
    const r = try listen(0, .{});
    defer close(r.fd);
    const port = r.port;

    const msg = "hello glu!";
    const pid = c.fork();
    if (pid == 0) {
        const fd = connect("127.0.0.1", port, .{}) catch c.exit(1);
        send(fd, msg) catch c.exit(1);
        close(fd);
        c.exit(0);
    }

    const client_fd = accept(r.fd, .{}) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer close(client_fd);

    var buf: [64]u8 = undefined;
    const n = receive(client_fd, &buf) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..n]));

    _ = c.waitpid(pid, null, 0);
}

test "non-blocking receive yields WouldBlock" {
    const r = try listen(0, .{});
    defer close(r.fd);
    const port = r.port;

    const pid = c.fork();
    if (pid == 0) {
        const fd = connect("127.0.0.1", port, .{}) catch c.exit(1);
        net.setBlocking(fd, false);
        var buf: [4]u8 = undefined;
        const result = receive(fd, &buf);
        if (result == error.WouldBlock or result == error.MessageTooLarge) c.exit(0);
        c.exit(1);
    }

    const client_fd = accept(r.fd, .{}) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer close(client_fd);

    var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = c.nanosleep(&ts, null);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const exited = (status & 0x7f) == 0;
    const exit_code = (status >> 8) & 0xff;
    try std.testing.expect(exited);
    try std.testing.expectEqual(@as(c_int, 0), exit_code);
}

test "empty message round-trip" {
    const r = try listen(0, .{});
    defer close(r.fd);
    const port = r.port;

    const pid = c.fork();
    if (pid == 0) {
        const fd = connect("127.0.0.1", port, .{}) catch c.exit(1);
        send(fd, "") catch c.exit(1);
        close(fd);
        c.exit(0);
    }

    const client_fd = accept(r.fd, .{}) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer close(client_fd);

    var buf: [1]u8 = undefined;
    const n = receive(client_fd, &buf) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    try std.testing.expectEqual(@as(usize, 0), n);

    _ = c.waitpid(pid, null, 0);
}
