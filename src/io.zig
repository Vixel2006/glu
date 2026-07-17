const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = std.os.linux.IoUring;

/// Per-operation completion cookie.
/// Caller owns this. AsyncIo writes to it via the user_data pointer on completion.
pub const Completion = struct {
    result: i32 = 0,
    done: bool = false,
};

/// Generic future for async io_uring operations.
/// `T` is the type of the resolved value (e.g. `i32`, `usize`, `void`, or a pointer/struct).
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Completion token — the engine writes the CQE result here.
        completion: Completion = .{},
        /// Resolved value, set by the caller before/after submission.
        value: T = undefined,

        pub const Result = union(enum) {
            ok: T,
            err: anyerror,
        };

        /// Helper to resolve the value from completion.
        inline fn getVal(self: *const Self) T {
            switch (comptime @typeInfo(T)) {
                .void => return {},
                .int => return @as(T, @intCast(self.completion.result)),
                else => return self.value,
            }
        }

        /// Non-blocking check. Returns `null` while the operation is in-flight.
        pub fn poll(self: *const Self) ?Result {
            if (!self.completion.done) return null;
            if (self.completion.result < 0) return .{ .err = errnoToError(self.completion.result) };
            return .{ .ok = self.getVal() };
        }

        /// Blocking wait — drives the engine until this future completes.
        pub fn wait(self: *Self, asyncio: *AsyncIo) !T {
            while (!self.completion.done) {
                _ = try asyncio.submit();
                _ = try asyncio.flush(1);
            }
            if (self.completion.result < 0) return errnoToError(self.completion.result);
            return self.getVal();
        }

        /// Returns true when the kernel has completed this operation.
        pub fn isDone(self: *const Self) bool {
            return self.completion.done;
        }
    };
}

/// The core async I/O engine backed by io_uring.
pub const AsyncIo = struct {
    ring: IoUring,

    pub fn init(entries: u16) !AsyncIo {
        const flags = linux.IORING_SETUP_SQPOLL | linux.IORING_SETUP_COOP_TASKRUN;
        const ring = try IoUring.init(entries, flags);
        return AsyncIo{ .ring = ring };
    }

    pub fn init_flags(entries: u16, flags: u32) !AsyncIo {
        return AsyncIo{ .ring = try IoUring.init(entries, flags) };
    }

    pub fn deinit(self: *AsyncIo) void {
        self.ring.deinit();
    }

    /// Queue an accept SQE.
    pub fn accept(
        self: *AsyncIo,
        fd: linux.fd_t,
        addr: ?*posix.sockaddr,
        addrlen: ?*posix.socklen_t,
        c: *Completion,
        flags: u32,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_accept(fd, addr, addrlen, flags);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a connect SQE.
    pub fn connect(
        self: *AsyncIo,
        fd: linux.fd_t,
        addr: *const posix.sockaddr,
        addrlen: posix.socklen_t,
        c: *Completion,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_connect(fd, addr, addrlen);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a recv SQE.
    pub fn recv(
        self: *AsyncIo,
        fd: linux.fd_t,
        buffer: []u8,
        c: *Completion,
        flags: u32,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(fd, buffer, flags);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a send SQE.
    pub fn send(
        self: *AsyncIo,
        fd: linux.fd_t,
        data: []const u8,
        c: *Completion,
        flags: u32,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(fd, data, flags);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a writev SQE.
    pub fn writev(
        self: *AsyncIo,
        fd: linux.fd_t,
        iovecs: []const posix.iovec_const,
        offset: u64,
        c: *Completion,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_writev(fd, iovecs, offset);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a readv SQE.
    pub fn readv(
        self: *AsyncIo,
        fd: linux.fd_t,
        iovecs: []const posix.iovec,
        offset: u64,
        c: *Completion,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_readv(fd, iovecs, offset);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a sendmsg SQE.
    pub fn sendmsg(
        self: *AsyncIo,
        fd: linux.fd_t,
        msg: *const linux.msghdr_const,
        c: *Completion,
        flags: u32,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_sendmsg(fd, msg, flags);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a recvmsg SQE.
    pub fn recvmsg(
        self: *AsyncIo,
        fd: linux.fd_t,
        msg: *linux.msghdr,
        c: *Completion,
        flags: u32,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_recvmsg(fd, msg, flags);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a close SQE.
    pub fn close(
        self: *AsyncIo,
        fd: linux.fd_t,
        c: *Completion,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_close(fd);
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Queue a nop SQE (useful for link/drain testing).
    pub fn nop(
        self: *AsyncIo,
        c: *Completion,
    ) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_nop();
        sqe.user_data = @intFromPtr(c);
        return sqe;
    }

    /// Submit all queued SQEs to the kernel.
    /// Returns the number of SQEs actually submitted.
    pub fn submit(self: *AsyncIo) !u32 {
        return try self.ring.submit();
    }

    /// Drain the completion queue.
    /// Returns the number of CQEs processed.
    /// `wait_nr=0` for non-blocking, `wait_nr=1` to block until at least 1 completion.
    pub fn flush(self: *AsyncIo, wait_nr: u32) !u32 {
        var cqes: [64]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, wait_nr);

        for (cqes[0..count]) |cqe| {
            if (cqe.user_data == 0) continue;
            const c: *Completion = @ptrFromInt(cqe.user_data);
            c.result = cqe.res;
            c.done = true;
        }

        return count;
    }

    /// Convenience: submit all queued SQEs and do a non-blocking flush.
    /// Returns the number of CQEs processed.
    pub fn tick(self: *AsyncIo) !u32 {
        _ = try self.submit();
        return try self.flush(0);
    }
};

/// Convert a negative errno from a CQE result into a Zig error.
pub fn errnoToError(res: i32) anyerror {
    if (res >= 0) unreachable;
    const e: linux.E = @enumFromInt(@as(u16, @intCast(-res)));
    return switch (e) {
        .SUCCESS => unreachable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .CONNABORTED => error.ConnectionAborted,
        .TIMEDOUT => error.ConnectionTimedOut,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .BADF => error.BadFileDescriptor,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .NOBUFS => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .PIPE => error.BrokenPipe,
        .NOTCONN => error.SocketUnconnected,
        .OPNOTSUPP => error.OperationNotSupported,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .ALREADY => error.AlreadyInProgress,
        .ISCONN => error.AlreadyConnected,
        .DESTADDRREQ => error.DestinationAddressRequired,
        .FAULT => error.BadAddress,
        else => error.Unexpected,
    };
}

test "nop: submit and complete one nop" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var c: Completion = .{};
    _ = try aio.nop(&c);
    _ = try aio.submit();

    const count = try aio.flush(1);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(c.done);
    try std.testing.expectEqual(@as(i32, 0), c.result);
}

test "nop: submit 3 nops, flush all" {
    var aio = try AsyncIo.init_flags(32, 0);
    defer aio.deinit();

    var c1: Completion = .{};
    var c2: Completion = .{};
    var c3: Completion = .{};

    _ = try aio.nop(&c1);
    _ = try aio.nop(&c2);
    _ = try aio.nop(&c3);
    _ = try aio.submit();

    const count = try aio.flush(3);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expect(c1.done);
    try std.testing.expect(c2.done);
    try std.testing.expect(c3.done);
}

test "nop: non-blocking flush returns 0 when nothing ready" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    const count = try aio.flush(0);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "send and recv on socketpair" {
    var aio = try AsyncIo.init_flags(32, 0);
    defer aio.deinit();

    var fds: [2]linux.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.LOCAL, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const msg = "hello io!";
    var send_c: Completion = .{};
    var recv_c: Completion = .{};
    var recv_buf: [32]u8 = undefined;

    _ = try aio.send(fds[1], msg, &send_c, 0);
    _ = try aio.recv(fds[0], &recv_buf, &recv_c, 0);
    _ = try aio.submit();

    _ = try aio.flush(2);

    try std.testing.expect(send_c.done);
    try std.testing.expectEqual(@as(i32, @intCast(msg.len)), send_c.result);

    try std.testing.expect(recv_c.done);
    try std.testing.expectEqual(@as(i32, @intCast(msg.len)), recv_c.result);
    try std.testing.expect(std.mem.eql(u8, msg, recv_buf[0..@as(usize, @intCast(recv_c.result))]));
}

test "error: recv on bad fd returns negative errno" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var c: Completion = .{};
    var buf: [16]u8 = undefined;
    _ = try aio.recv(-1, &buf, &c, 0);
    _ = try aio.submit();
    _ = try aio.flush(1);

    try std.testing.expect(c.done);
    try std.testing.expect(c.result < 0);
}

test "flush returns 0 when called after all completions already consumed" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var c: Completion = .{};
    _ = try aio.nop(&c);
    _ = try aio.submit();
    _ = try aio.flush(1);

    try std.testing.expect(c.done);

    const count = try aio.flush(0);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "sqe pointer is returned for advanced modification" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var c: Completion = .{};
    const sqe = try aio.nop(&c);

    try std.testing.expectEqual(@intFromPtr(&c), sqe.user_data);
}

test "tick: submit + non-blocking flush" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var c: Completion = .{};
    _ = try aio.nop(&c);
    _ = try aio.tick();

    // May or may not have completed in the tick; flush with blocking to be sure.
    if (!c.done) {
        _ = try aio.flush(1);
    }
    try std.testing.expect(c.done);
}

test "Future: poll returns null before completion" {
    var f: Future(i32) = .{ .value = 42 };
    try std.testing.expect(f.poll() == null);
    try std.testing.expect(!f.isDone());
}

test "Future: poll returns ok after completion" {
    var f: Future(i32) = .{ .value = 42 };
    f.completion.done = true;
    f.completion.result = 0;
    const result = f.poll() orelse unreachable;
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(i32, 0), v), // Since T is an integer, it returns CQE result
        .err => unreachable,
    }
}

test "Future: poll returns err on negative result" {
    var f: Future(i32) = .{ .value = 0 };
    f.completion.done = true;
    f.completion.result = -@as(i32, @intCast(@intFromEnum(linux.E.CONNREFUSED)));
    const result = f.poll() orelse unreachable;
    switch (result) {
        .ok => unreachable,
        .err => |e| try std.testing.expectEqual(error.ConnectionRefused, e),
    }
}

test "Future: wait with nop completes immediately" {
    var aio = try AsyncIo.init_flags(16, 0);
    defer aio.deinit();

    var f: Future(i32) = .{ .value = 99 };
    const sqe = try aio.nop(&f.completion);
    _ = sqe;
    const v = try f.wait(&aio);
    try std.testing.expectEqual(@as(i32, 0), v); // Returns CQE result for integer T
}
