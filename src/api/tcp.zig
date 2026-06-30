const std = @import("std");
const c = std.c;
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;

const TcpErr = error{
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

/// A TCP listener bound to a port, accepting incoming connections.
pub const Listener = struct {
    fd: i32,
    port: u16,

    /// Bind to `port` on all interfaces and start listening.
    /// If `port` is 0, the OS assigns an available port (query
    /// `.port` afterwards to discover the actual port).
    pub fn listen(port: u16) TcpErr!Listener {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return mapErr(c._errno().*);

        const opt: c_int = 1;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &opt, @sizeOf(c_int)) == -1)
            return TcpErr.SetSockOptFailed;

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

        return Listener{ .fd = fd, .port = actual_port };
    }

    /// Accept an incoming connection. Blocks until one arrives.
    pub fn accept(self: *Listener) TcpErr!Connection {
        var client_addr: posix.sockaddr.in = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client_fd = c.accept(self.fd, @ptrCast(&client_addr), &addrlen);
        if (client_fd == -1) return mapErr(c._errno().*);
        return Connection{ .fd = client_fd };
    }

    pub fn deinit(self: *Listener) void {
        _ = c.close(self.fd);
    }
};

/// A TCP connection (client-side or accepted server-side).
pub const Connection = struct {
    fd: i32,

    /// Connect to `host:port` with automatic address resolution.
    pub fn connect(host: []const u8, port: u16) TcpErr!Connection {
        var hints = mem.zeroes(c.addrinfo);
        hints.family = c.AF.UNSPEC;
        hints.socktype = c.SOCK.STREAM;

        var host_buf: [256]u8 align(1) = undefined;
        if (host.len > host_buf.len - 1) return TcpErr.AddressResolveFailed;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;
        const host_z: [*:0]u8 = @ptrCast(&host_buf);

        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch
            return TcpErr.AddressResolveFailed;

        var result: ?*c.addrinfo = null;
        if (@intFromEnum(c.getaddrinfo(host_z, port_str.ptr, &hints, &result)) != 0)
            return TcpErr.AddressResolveFailed;
        defer if (result) |res| c.freeaddrinfo(res);

        var info = result;
        while (info) |inf| : (info = inf.next) {
            const addr = inf.addr orelse continue;
            const fd = c.socket(@as(c_uint, @intCast(inf.family)), @as(c_uint, @intCast(inf.socktype)), @as(c_uint, @intCast(inf.protocol)));
            if (fd == -1) continue;

            if (c.connect(fd, addr, inf.addrlen) == -1) {
                _ = c.close(fd);
                continue;
            }

            return Connection{ .fd = fd };
        }

        return TcpErr.ConnectFailed;
    }

    /// Send all `data` over the connection. Blocks until fully sent or error.
    pub fn send(self: *Connection, data: []const u8) TcpErr!usize {
        var offset: usize = 0;
        while (offset < data.len) {
            const rc = c.send(self.fd, data.ptr + offset, data.len - offset, c.MSG.NOSIGNAL);
            if (rc == -1) {
                const err = mapErr(c._errno().*);
                if (err == TcpErr.Interrupted) continue;
                return err;
            }
            offset += @as(usize, @intCast(rc));
        }
        return offset;
    }

    /// Receive up to `buffer.len` bytes. Returns number of bytes read.
    /// Returns `ConnectionReset` if the remote peer closed the connection
    /// (recv returned 0).
    pub fn receive(self: *Connection, buffer: []u8) TcpErr!usize {
        const rc = c.recv(self.fd, buffer.ptr, buffer.len, 0);
        if (rc == -1) return mapErr(c._errno().*);
        if (rc == 0) return TcpErr.ConnectionReset;
        return @as(usize, @intCast(rc));
    }

    pub fn deinit(self: *Connection) void {
        _ = c.close(self.fd);
    }

    /// Switch between blocking and non-blocking I/O mode.
    pub fn setBlocking(self: *Connection, blocking: bool) TcpErr!void {
        const flags = c.fcntl(self.fd, c.F.GETFL);
        if (flags == -1) return mapErr(c._errno().*);
        const nonblock: c_int = @bitCast(linux.O{ .NONBLOCK = true });
        const new_flags = if (blocking) flags & ~nonblock else flags | nonblock;
        if (c.fcntl(self.fd, c.F.SETFL, new_flags) == -1)
            return mapErr(c._errno().*);
    }
};

test "Listener: bind and deinit cleanly" {
    var listener = try Listener.listen(0);
    defer listener.deinit();
    try std.testing.expect(listener.fd >= 0);
}

test "Connection: connect refused returns ConnectFailed" {
    const result = Connection.connect("127.0.0.1", 1);
    try std.testing.expectError(error.ConnectFailed, result);
}

test "Listener + Connection: accept a connection" {
    var listener = try Listener.listen(0);
    defer listener.deinit();

    const port = listener.port;

    const pid = c.fork();
    if (pid == 0) {
        var conn = Connection.connect("127.0.0.1", port) catch c.exit(1);
        conn.deinit();
        c.exit(0);
    }

    var accepted = listener.accept() catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer accepted.deinit();

    var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
    _ = c.nanosleep(&ts, null);

    _ = c.waitpid(pid, null, 0);
}

test "Connection: send and receive data" {
    var listener = try Listener.listen(0);
    defer listener.deinit();
    const port = listener.port;

    const msg = "hello glu!";
    const pid = c.fork();
    if (pid == 0) {
        var conn = Connection.connect("127.0.0.1", port) catch c.exit(1);
        _ = conn.send(msg) catch c.exit(1);
        conn.deinit();
        c.exit(0);
    }

    var server = listener.accept() catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer server.deinit();

    var buf: [64]u8 = undefined;
    const n = server.receive(&buf) catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expect(std.mem.eql(u8, msg, buf[0..n]));

    _ = c.waitpid(pid, null, 0);
}

test "Connection: setBlocking toggles non-blocking mode" {
    var listener = try Listener.listen(0);
    defer listener.deinit();
    const port = listener.port;

    const pid = c.fork();
    if (pid == 0) {
        var conn = Connection.connect("127.0.0.1", port) catch c.exit(1);
        conn.setBlocking(false) catch c.exit(1);
        var buf: [1]u8 = undefined;
        const result = conn.receive(&buf);
        if (result == error.WouldBlock) c.exit(0);
        c.exit(1);
    }

    var server = listener.accept() catch {
        _ = c.waitpid(pid, null, 0);
        return error.TestFailed;
    };
    defer server.deinit();

    var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = c.nanosleep(&ts, null);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const exited = (status & 0x7f) == 0;
    const exit_code = (status >> 8) & 0xff;
    try std.testing.expect(exited);
    try std.testing.expectEqual(@as(c_int, 0), exit_code);
}
