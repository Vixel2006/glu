const std = @import("std");
const time = @import("time.zig");
const Queue = @import("queue.zig").Queue;
const assert = std.debug.assert;
const os = std.os;
const posix = std.posix;
const linux = os.linux;
const IoUring = linux.IoUring;
const io_uring_cqe = linux.io_uring_cqe;
const io_uring_sqe = linux.io_uring_sqe;
const log = std.log.scoped(.io);

// Opaque import shims for the fiber scheduler.  Imported lazily so that
// io.zig does not create a hard compile-time dependency on fiber/sched.zig
// in environments that do not use the scheduler.
const Fiber = @import("fiber/fiber.zig").Fiber;
const Sched = @import("fiber/sched.zig");

fn unexpected_errno(name: []const u8, err: posix.E) posix.UnexpectedError {
    _ = name;
    return posix.unexpectedErrno(err);
}

pub const IO = struct {
    ring: IoUring,
    completed: Queue(Future),
    inflight: u32 = 0,

    pub fn init(entries: u16, flags: u32) !IO {
        var ring: IoUring = try .init(entries, flags);
        errdefer ring.deinit();

        return .{
            .ring = ring,
            .completed = Queue(Future).init(),
        };
    }

    pub fn deinit(self: *IO) void {
        while (!self.completed.is_empty()) {
            _ = self.completed.dequeue() catch unreachable;
        }
        self.ring.deinit();
    }

    pub fn run(self: *IO, nanoseconds: u64) !void {
        const deadline = try time.monotonic() + nanoseconds;
        const sched = Sched.try_current();

        while (true) {
            if (sched) |s| s.drive();

            try self.submit(0);
            if (self.inflight == 0) break;

            const now = try time.monotonic();
            if (now >= deadline) {
                if (nanoseconds == 0) {
                    try self.complete(0);
                    try self.run_callback();
                }
                break;
            }

            try self.complete(1);
            try self.run_callback();
        }

        try self.submit(0);
    }

    pub fn submit(self: *IO, wait_nr: u32) !void {
        const queued = self.ring.sq.sqe_tail -% self.ring.sq.sqe_head;
        if (queued == 0 and wait_nr == 0) {
            return;
        }

        while (true) {
            _ = self.ring.submit_and_wait(wait_nr) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                error.CompletionQueueOvercommitted, error.SystemResources => {
                    log.err("submit: completion queue overcommitted.", .{});
                    try self.complete(1);
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    pub fn complete(self: *IO, wait_nr: u32) !void {
        var cqes: [256]io_uring_cqe = undefined;
        while (true) {
            const completed = self.ring.copy_cqes(&cqes, wait_nr) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };

            self.inflight -|= @intCast(completed);

            for (cqes[0..completed]) |cqe| {
                const future: *Future = @ptrFromInt(cqe.user_data);
                future.result_raw = cqe.res;
                self.completed.enqueue(future);
            }
            break;
        }
    }

    pub fn enqueue(self: *IO, future: *Future) !void {
        const sqe = try self.ring.get_sqe();
        self.inflight += 1;
        future.prep(sqe);
    }

    pub fn run_callback(self: *IO) !void {
        while (true) {
            if (self.completed.is_empty()) return;
            const completed = try self.completed.dequeue();
            Future.complete(completed);
        }
    }

    pub fn wait(self: *IO, future: *Future, comptime T: type) anyerror!T {
        if (!future.done) {
            if (Sched.try_current()) |sched| {
                if (sched.current_fiber) |fiber| {
                    assert(fiber.state == .RUNNING);
                    future.wakeup_fiber = fiber;
                    sched.park();
                    return future.result_of(T);
                }
            }

            while (!future.done) {
                if (Sched.try_current()) |sched| {
                    sched.drive();
                }
                if (future.done) break;

                try self.submit(0);
                if (self.inflight > 0) {
                    try self.complete(1);
                    try self.run_callback();
                } else {
                    break;
                }
            }
        }
        return future.result_of(T);
    }

    pub const NextTickResult = struct {};

    pub fn socket(self: *IO, domain: u32, type_: u32, protocol: u32) !posix.socket_t {
        _ = self;
        while (true) {
            const rc = posix.system.socket(domain, type_ | posix.SOCK.CLOEXEC, protocol);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .ACCES => return error.PermissionDenied,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .INVAL => return error.ProtocolNotSupported,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolNotSupported,
                .PROTOTYPE => return error.ProtocolNotSupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub fn bind(self: *IO, sock: posix.socket_t, address: posix.sockaddr.in) !void {
        _ = self;
        const addr: *const posix.sockaddr = @ptrCast(&address);
        while (true) {
            const rc = posix.system.bind(sock, addr, @sizeOf(posix.sockaddr.in));
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .ADDRINUSE => return error.AddressInUse,
                .ADDRNOTAVAIL => return error.AddressNotAvailable,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .BADF => return error.FileDescriptorInvalid,
                .FAULT => unreachable,
                .INVAL => return error.AlreadyBound,
                .NOTSOCK => return error.FileDescriptorNotASocket,
                .OPNOTSUPP => return error.OperationNotSupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub fn listen(self: *IO, sock: posix.socket_t, backlog: u32) !void {
        _ = self;
        while (true) {
            const rc = posix.system.listen(sock, backlog);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .ADDRINUSE => return error.AddressInUse,
                .BADF => return error.FileDescriptorInvalid,
                .NOTSOCK => return error.FileDescriptorNotASocket,
                .OPNOTSUPP => return error.OperationNotSupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub const Operation = union(enum) {
        accept: struct {
            socket: posix.socket_t,
            address: posix.sockaddr = undefined,
            addrlen: posix.socklen_t = @sizeOf(posix.sockaddr),
        },
        close: struct {
            fd: posix.fd_t,
        },
        connect: struct {
            socket: posix.socket_t,
            address: posix.sockaddr.in,
        },
        read: struct {
            fd: posix.fd_t,
            buffer: []u8,
            offset: u64,
        },
        recv: struct {
            socket: posix.socket_t,
            buffer: []u8,
        },
        send: struct {
            socket: posix.socket_t,
            buffer: []const u8,
        },
        write: struct {
            fd: posix.fd_t,
            buffer: []const u8,
            offset: u64,
        },
        fsync: struct {
            fd: posix.fd_t,
        },
        openat: struct {
            fd: posix.fd_t,
            path: [*:0]const u8,
            flags: posix.O,
            mode: u32,
        },
        statx: struct {
            fd: posix.fd_t,
            path: [*:0]const u8,
            flags: u32,
            mask: os.linux.STATX,
            buffer: *std.os.linux.Statx,
        },
        timeout: struct {
            timeout: *std.os.linux.kernel_timespec,
            flags: u32,
        },
        next_tick: struct {},
        send_to: struct {
            socket: posix.socket_t,
            buffer: []const u8,
            address: posix.sockaddr.in,
            iov: [1]posix.iovec_const = undefined,
            msg: std.os.linux.msghdr_const = undefined,
        },
        recv_from: struct {
            socket: posix.socket_t,
            buffer: []u8,
            address: posix.sockaddr.in = undefined,
            addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.in),
            iov: [1]posix.iovec = undefined,
            msg: std.os.linux.msghdr = undefined,
        },
    };

    pub const Future = struct {
        io: *IO,
        result_raw: i32 = undefined,
        result: Result = undefined,
        operation: Operation,
        done: bool = false,
        next: ?*Future = null,
        /// If set, the fiber to wake when this future completes.
        wakeup_fiber: ?*Fiber = null,

        pub const Result = union(enum) {
            accept: AcceptError!posix.socket_t,
            close: CloseError!void,
            connect: ConnectError!void,
            read: ReadError!usize,
            recv: RecvError!usize,
            send: SendError!usize,
            write: WriteError!usize,
            fsync: FsyncError!void,
            openat: OpenatError!posix.fd_t,
            statx: StatxError!void,
            timeout: TimeoutError!void,
            next_tick: NextTickResult,
            send_to: SendToError!usize,
            recv_from: RecvFromError!usize,
        };

        fn prep(future: *Future, sqe: *io_uring_sqe) void {
            switch (future.operation) {
                .accept => |*op| {
                    sqe.prep_accept(
                        op.socket,
                        &op.address,
                        &op.addrlen,
                        posix.SOCK.CLOEXEC,
                    );
                },
                .close => |op| {
                    sqe.prep_close(op.fd);
                },
                .connect => |*op| {
                    const addr: *const posix.sockaddr = @ptrCast(&op.address);
                    sqe.prep_connect(
                        op.socket,
                        addr,
                        @sizeOf(posix.sockaddr.in),
                    );
                },
                .read => |op| {
                    sqe.prep_read(
                        op.fd,
                        op.buffer[0..op.buffer.len],
                        op.offset,
                    );
                },
                .recv => |op| {
                    sqe.prep_recv(op.socket, op.buffer, 0);
                },
                .send => |op| {
                    sqe.prep_send(op.socket, op.buffer, posix.MSG.NOSIGNAL);
                },
                .write => |op| {
                    sqe.prep_write(
                        op.fd,
                        op.buffer[0..op.buffer.len],
                        op.offset,
                    );
                },
                .fsync => |op| {
                    sqe.prep_fsync(op.fd, 0);
                },
                .openat => |op| {
                    sqe.prep_openat(op.fd, op.path, op.flags, op.mode);
                },
                .statx => |op| {
                    sqe.prep_statx(op.fd, op.path, op.flags, op.mask, op.buffer);
                },
                .timeout => |op| {
                    sqe.prep_timeout(op.timeout, op.flags, 0);
                },
                .next_tick => {
                    sqe.prep_nop();
                },
                .send_to => |*op| {
                    const addr: *const posix.sockaddr = @ptrCast(&op.address);
                    op.iov = [1]posix.iovec_const{
                        .{ .base = op.buffer.ptr, .len = op.buffer.len },
                    };
                    op.msg = std.os.linux.msghdr_const{
                        .name = addr,
                        .namelen = @sizeOf(posix.sockaddr.in),
                        .iov = &op.iov,
                        .iovlen = 1,
                        .control = null,
                        .controllen = 0,
                        .flags = 0,
                    };
                    sqe.prep_sendmsg(op.socket, &op.msg, posix.MSG.NOSIGNAL);
                },
                .recv_from => |*op| {
                    const addr: *posix.sockaddr = @ptrCast(&op.address);
                    op.iov = [1]posix.iovec{
                        .{ .base = op.buffer.ptr, .len = op.buffer.len },
                    };
                    op.msg = std.os.linux.msghdr{
                        .name = addr,
                        .namelen = op.addrlen,
                        .iov = &op.iov,
                        .iovlen = 1,
                        .control = null,
                        .controllen = 0,
                        .flags = 0,
                    };
                    sqe.prep_recvmsg(op.socket, &op.msg, 0);
                },
            }
            sqe.user_data = @intFromPtr(future);
        }

        /// Called after `done` is set to `true` to notify a waiting fiber, if any.
        inline fn maybe_wake(future: *Future) void {
            if (future.wakeup_fiber) |fiber| {
                future.wakeup_fiber = null;
                if (Sched.try_current()) |sched| {
                    sched.wake(fiber);
                }
            }
        }

        fn complete(future: *Future) void {
            switch (future.operation) {
                .accept => {
                    const result: AcceptError!posix.socket_t = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .AGAIN => error.WouldBlock,
                                .BADF => error.FileDescriptorInvalid,
                                .CONNABORTED => error.ConnectionAborted,
                                .FAULT => unreachable,
                                .INVAL => error.SocketNotListening,
                                .MFILE => error.ProcessFdQuotaExceeded,
                                .NFILE => error.SystemFdQuotaExceeded,
                                .NOBUFS => error.SystemResources,
                                .NOMEM => error.SystemResources,
                                .NOTSOCK => error.FileDescriptorNotASocket,
                                .OPNOTSUPP => error.OperationNotSupported,
                                .PERM => error.PermissionDenied,
                                .PROTO => error.ProtocolFailure,
                                else => |errno| unexpected_errno("accept", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .accept = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .close => {
                    const result: CloseError!void = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {},
                                .BADF => error.FileDescriptorInvalid,
                                .DQUOT => error.DiskQuota,
                                .IO => error.InputOutput,
                                .NOSPC => error.NoSpaceLeft,
                                else => |errno| unexpected_errno("close", errno),
                            };
                            break :blk err;
                        } else {
                            assert(future.result_raw == 0);
                        }
                    };
                    future.result = .{ .close = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .connect => {
                    const result: ConnectError!void = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .ACCES => error.AccessDenied,
                                .ADDRINUSE => error.AddressInUse,
                                .ADDRNOTAVAIL => error.AddressNotAvailable,
                                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                                .AGAIN, .INPROGRESS => error.WouldBlock,
                                .ALREADY => error.OpenAlreadyInProgress,
                                .BADF => error.FileDescriptorInvalid,
                                .CANCELED => error.Canceled,
                                .CONNREFUSED => error.ConnectionRefused,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .FAULT => unreachable,
                                .ISCONN => error.AlreadyConnected,
                                .NETUNREACH => error.NetworkUnreachable,
                                .HOSTUNREACH => error.HostUnreachable,
                                .NOENT => error.FileNotFound,
                                .NOTSOCK => error.FileDescriptorNotASocket,
                                .PERM => error.PermissionDenied,
                                .PROTOTYPE => error.ProtocolNotSupported,
                                .TIMEDOUT => error.ConnectionTimedOut,
                                else => |errno| unexpected_errno("connect", errno),
                            };
                            break :blk err;
                        } else {
                            assert(future.result_raw == 0);
                        }
                    };
                    future.result = .{ .connect = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .fsync => {
                    const result: FsyncError!void = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .BADF => error.FileDescriptorInvalid,
                                .IO => error.InputOutput,
                                .INVAL => unreachable,
                                else => |errno| unexpected_errno("fsync", errno),
                            };
                            break :blk err;
                        } else {
                            assert(future.result_raw == 0);
                        }
                    };
                    future.result = .{ .fsync = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .openat => {
                    const result: OpenatError!posix.fd_t = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .FAULT => unreachable,
                                .INVAL => unreachable,
                                .BADF => unreachable,
                                .ACCES => error.AccessDenied,
                                .FBIG => error.FileTooBig,
                                .OVERFLOW => error.FileTooBig,
                                .ISDIR => error.IsDir,
                                .LOOP => error.SymLinkLoop,
                                .MFILE => error.ProcessFdQuotaExceeded,
                                .NAMETOOLONG => error.NameTooLong,
                                .NFILE => error.SystemFdQuotaExceeded,
                                .NODEV => error.NoDevice,
                                .NOENT => error.FileNotFound,
                                .NOMEM => error.SystemResources,
                                .NOSPC => error.NoSpaceLeft,
                                .NOTDIR => error.NotDir,
                                .PERM => error.AccessDenied,
                                .EXIST => error.PathAlreadyExists,
                                .BUSY => error.DeviceBusy,
                                .OPNOTSUPP => error.FileLocksUnsupported,
                                .AGAIN => error.WouldBlock,
                                .TXTBSY => error.FileBusy,
                                else => |errno| unexpected_errno("openat", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .openat = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .read => {
                    const result: ReadError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR, .AGAIN => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .BADF => error.NotOpenForReading,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .FAULT => unreachable,
                                .INVAL => error.Alignment,
                                .IO => error.InputOutput,
                                .ISDIR => error.IsDir,
                                .NOBUFS => error.SystemResources,
                                .NOMEM => error.SystemResources,
                                .NXIO => error.Unseekable,
                                .OVERFLOW => error.Unseekable,
                                .SPIPE => error.Unseekable,
                                .TIMEDOUT => error.ConnectionTimedOut,
                                else => |errno| unexpected_errno("read", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .read = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .recv => {
                    const result: RecvError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .AGAIN => error.WouldBlock,
                                .BADF => error.FileDescriptorInvalid,
                                .CANCELED => error.Canceled,
                                .CONNREFUSED => error.ConnectionRefused,
                                .FAULT => unreachable,
                                .INVAL => unreachable,
                                .NOMEM => error.SystemResources,
                                .NOTCONN => error.SocketNotConnected,
                                .NOTSOCK => error.FileDescriptorNotASocket,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .TIMEDOUT => error.ConnectionTimedOut,
                                .OPNOTSUPP => error.OperationNotSupported,
                                else => |errno| unexpected_errno("recv", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .recv = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .send => {
                    const result: SendError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .ACCES => error.AccessDenied,
                                .AGAIN => error.WouldBlock,
                                .ALREADY => error.FastOpenAlreadyInProgress,
                                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                                .BADF => error.FileDescriptorInvalid,
                                .CONNREFUSED => error.ConnectionRefused,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .DESTADDRREQ => unreachable,
                                .FAULT => unreachable,
                                .INVAL => unreachable,
                                .ISCONN => unreachable,
                                .MSGSIZE => error.MessageTooBig,
                                .NOBUFS => error.SystemResources,
                                .NOMEM => error.SystemResources,
                                .NOTCONN => error.SocketNotConnected,
                                .NOTSOCK => error.FileDescriptorNotASocket,
                                .OPNOTSUPP => error.OperationNotSupported,
                                .PIPE => error.BrokenPipe,
                                .TIMEDOUT => error.ConnectionTimedOut,
                                .CANCELED => error.Canceled,
                                else => |errno| unexpected_errno("send", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .send = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .statx => {
                    const result: StatxError!void = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .FAULT => unreachable,
                                .INVAL => unreachable,
                                .BADF => unreachable,
                                .ACCES => error.AccessDenied,
                                .LOOP => error.SymLinkLoop,
                                .NAMETOOLONG => error.NameTooLong,
                                .NOENT => error.FileNotFound,
                                .NOMEM => error.SystemResources,
                                .NOTDIR => error.NotDir,
                                else => |errno| unexpected_errno("statx", errno),
                            };
                            break :blk err;
                        } else {
                            assert(future.result_raw == 0);
                        }
                    };
                    future.result = .{ .statx = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .timeout => {
                    assert(future.result_raw < 0);
                    const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                        .INTR => {
                            future.io.enqueue(future) catch {
                                const result: TimeoutError!void = error.Unexpected;
                                future.result = .{ .timeout = result };
                                future.done = true;
                                future.maybe_wake();
                                return;
                            };
                            return;
                        },
                        .CANCELED => error.Canceled,
                        .TIME => {}, // A success.
                        else => |errno| unexpected_errno("timeout", errno),
                    };
                    const result: TimeoutError!void = err;
                    future.result = .{ .timeout = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .write => {
                    const result: WriteError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.Unexpected;
                                    };
                                    return;
                                },
                                .AGAIN => error.WouldBlock,
                                .BADF => error.NotOpenForWriting,
                                .DESTADDRREQ => error.NotConnected,
                                .DQUOT => error.DiskQuota,
                                .FAULT => unreachable,
                                .FBIG => error.FileTooBig,
                                .INVAL => error.Alignment,
                                .IO => error.InputOutput,
                                .NOSPC => error.NoSpaceLeft,
                                .NXIO => error.Unseekable,
                                .OVERFLOW => error.Unseekable,
                                .PERM => error.AccessDenied,
                                .PIPE => error.BrokenPipe,
                                .SPIPE => error.Unseekable,
                                else => |errno| unexpected_errno("write", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .write = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .next_tick => {
                    const result: NextTickResult = .{};
                    future.result = .{ .next_tick = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .send_to => {
                    const result: SendToError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.NoMemory;
                                    };
                                    return;
                                },
                                .ACCES => error.AccessDenied,
                                .AGAIN => error.WouldBlock,
                                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                                .BADF => error.FileDescriptorInvalid,
                                .CONNREFUSED => error.ConnectionRefused,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .DESTADDRREQ => error.DestinationAddressRequired,
                                .FAULT => error.Fault,
                                .INVAL => error.InvalidArgument,
                                .MSGSIZE => error.MessageTooBig,
                                .NETUNREACH => error.NetworkUnreachable,
                                .NOBUFS => error.NoBuffers,
                                .NOMEM => error.NoMemory,
                                .NOTCONN => error.NotConnected,
                                .NOTSOCK => error.NotASocket,
                                .OPNOTSUPP => error.OperationNotSupported,
                                .PERM => error.PermissionDenied,
                                else => |errno| unexpected_errno("sendto", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .send_to = result };
                    future.done = true;
                    future.maybe_wake();
                },
                .recv_from => {
                    const result: RecvFromError!usize = blk: {
                        if (future.result_raw < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-future.result_raw))) {
                                .INTR => {
                                    future.io.enqueue(future) catch {
                                        break :blk error.NoMemory;
                                    };
                                    return;
                                },
                                .AGAIN => error.WouldBlock,
                                .BADF => error.FileDescriptorInvalid,
                                .CONNREFUSED => error.ConnectionRefused,
                                .CONNRESET => error.ConnectionResetByPeer,
                                .FAULT => error.Fault,
                                .INVAL => error.InvalidArgument,
                                .NOMEM => error.NoMemory,
                                .NOTCONN => error.NotConnected,
                                .NOTSOCK => error.NotASocket,
                                .OPNOTSUPP => error.OperationNotSupported,
                                .TIMEDOUT => error.TimedOut,
                                else => |errno| unexpected_errno("recvfrom", errno),
                            };
                            break :blk err;
                        } else {
                            break :blk @intCast(future.result_raw);
                        }
                    };
                    future.result = .{ .recv_from = result };
                    future.done = true;
                    future.maybe_wake();
                },
            }
        }


        fn result_of(self: *Future, comptime T: type) anyerror!T {
            switch (self.result) {
                .accept => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .close => |res| {
                    try res;
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .connect => |res| {
                    try res;
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .read => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .recv => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .send => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .write => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .fsync => |res| {
                    try res;
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .openat => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .statx => |res| {
                    try res;
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .timeout => |res| {
                    try res;
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .next_tick => {
                    if (comptime T == void) return;
                    return error.TypeMismatch;
                },
                .send_to => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
                .recv_from => |res| {
                    const val = try res;
                    if (comptime T == void) return;
                    return @intCast(val);
                },
            }
        }
    };

    pub const AcceptError = error{
        WouldBlock,
        FileDescriptorInvalid,
        ConnectionAborted,
        SocketNotListening,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        FileDescriptorNotASocket,
        OperationNotSupported,
        PermissionDenied,
        ProtocolFailure,
    } || posix.UnexpectedError;

    pub fn accept(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{ .accept = .{ .socket = sock } },
        };
        try self.enqueue(future);
    }

    pub const ConnectError = error{
        AccessDenied,
        AddressInUse,
        AddressNotAvailable,
        AddressFamilyNotSupported,
        WouldBlock,
        OpenAlreadyInProgress,
        FileDescriptorInvalid,
        ConnectionRefused,
        ConnectionResetByPeer,
        AlreadyConnected,
        NetworkUnreachable,
        HostUnreachable,
        FileNotFound,
        FileDescriptorNotASocket,
        PermissionDenied,
        ProtocolNotSupported,
        ConnectionTimedOut,
        SystemResources,
        Canceled,
    } || posix.UnexpectedError;

    pub fn connect(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
        address: posix.sockaddr.in,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .connect = .{
                    .socket = sock,
                    .address = address,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
    } || posix.UnexpectedError;

    pub fn read(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .read = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const WriteError = error{
        WouldBlock,
        NotOpenForWriting,
        NotConnected,
        DiskQuota,
        FileTooBig,
        Alignment,
        InputOutput,
        NoSpaceLeft,
        Unseekable,
        AccessDenied,
        BrokenPipe,
    } || posix.UnexpectedError;

    pub fn write(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .write = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const RecvError = error{
        WouldBlock,
        FileDescriptorInvalid,
        ConnectionRefused,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        OperationNotSupported,
        Canceled,
    } || posix.UnexpectedError;

    pub fn recv(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
        buffer: []u8,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .recv = .{
                    .socket = sock,
                    .buffer = buffer,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const SendError = error{
        AccessDenied,
        WouldBlock,
        FastOpenAlreadyInProgress,
        AddressFamilyNotSupported,
        FileDescriptorInvalid,
        ConnectionResetByPeer,
        MessageTooBig,
        SystemResources,
        SocketNotConnected,
        FileDescriptorNotASocket,
        OperationNotSupported,
        BrokenPipe,
        ConnectionTimedOut,
        ConnectionRefused,
        Canceled,
    } || posix.UnexpectedError;

    pub fn send(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
        buffer: []const u8,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .send = .{
                    .socket = sock,
                    .buffer = buffer,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .close = .{
                    .fd = fd,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const SendToError = error{
        AccessDenied,
        WouldBlock,
        AddressFamilyNotSupported,
        FileDescriptorInvalid,
        ConnectionRefused,
        ConnectionResetByPeer,
        DestinationAddressRequired,
        Fault,
        InvalidArgument,
        MessageTooBig,
        NetworkUnreachable,
        NoBuffers,
        NoMemory,
        NotConnected,
        NotASocket,
        OperationNotSupported,
        PermissionDenied,
    } || posix.UnexpectedError;

    pub fn send_to(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
        buffer: []const u8,
        address: posix.sockaddr.in,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .send_to = .{
                    .socket = sock,
                    .buffer = buffer,
                    .address = address,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const RecvFromError = error{
        WouldBlock,
        FileDescriptorInvalid,
        ConnectionRefused,
        ConnectionResetByPeer,
        Fault,
        InvalidArgument,
        NoMemory,
        NotConnected,
        NotASocket,
        OperationNotSupported,
        TimedOut,
    } || posix.UnexpectedError;

    pub fn recv_from(
        self: *IO,
        future: *Future,
        sock: posix.socket_t,
        buffer: []u8,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .recv_from = .{
                    .socket = sock,
                    .buffer = buffer,
                    .address = undefined,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const FsyncError = error{
        FileDescriptorInvalid,
        InputOutput,
        SystemResources,
    } || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .fsync = .{
                    .fd = fd,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub fn openat(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
        path: [*:0]const u8,
        flags: posix.O,
        mode: u32,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .openat = .{
                    .fd = fd,
                    .path = path,
                    .flags = flags,
                    .mode = mode,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const StatxError = error{
        SymLinkLoop,
        FileNotFound,
        NameTooLong,
        NotDir,
    } || std.Io.File.StatError || posix.UnexpectedError;

    pub fn statx(
        self: *IO,
        future: *Future,
        fd: posix.fd_t,
        path: [*:0]const u8,
        flags: u32,
        mask: os.linux.STATX,
        buffer: *std.os.linux.Statx,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .statx = .{
                    .fd = fd,
                    .path = path,
                    .flags = flags,
                    .mask = mask,
                    .buffer = buffer,
                },
            },
        };
        try self.enqueue(future);
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        future: *Future,
        timespec: *std.os.linux.kernel_timespec,
        flags: u32,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .{
                .timeout = .{
                    .timeout = timespec,
                    .flags = flags,
                },
            },
        };
        try self.enqueue(future);
    }

    pub fn next_tick(
        self: *IO,
        future: *Future,
    ) !void {
        future.* = .{
            .io = self,
            .operation = .next_tick,
        };
        try self.enqueue(future);
    }
};

const testing = std.testing;

test "init and deinit across entry sizes" {
    inline for (.{ 1, 2, 8, 32, 256 }) |entries| {
        var io = try IO.init(entries, 0);
        io.deinit();
    }
}

test "deinit with pending unsent completion does not crash" {
    var io = try IO.init(8, 0);
    var compl: IO.Future = undefined;
    try io.next_tick(&compl);
    io.deinit();
}

test "enqueue beyond ring capacity returns error.SQFull" {
    var io = try IO.init(2, 0);
    defer io.deinit();
    var compls: [4]IO.Future = undefined;
    var saw_full = false;
    for (&compls) |*compl| {
        io.next_tick(compl) catch |err| {
            try testing.expectEqual(error.SubmissionQueueFull, err);
            saw_full = true;
            break;
        };
    }
    try testing.expect(saw_full);
}

test "file ops: openat, write, fsync, statx, read, close" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [256:0]u8 = undefined;
    const path_len = (std.fmt.bufPrint(path_buf[0..255], ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path[0..], "glu_io_test.bin" }) catch unreachable).len;
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..];

    const data = "hello io_uring file io";
    var compl: IO.Future = undefined;

    // openat: create + truncate + read-write
    try io.openat(&compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const fd = try io.wait(&compl, posix.fd_t);

    // write
    try io.write(&compl, fd, data, 0);
    try testing.expectEqual(data.len, try io.wait(&compl, usize));

    // fsync
    try io.fsync(&compl, fd);
    try io.wait(&compl, void);

    // statx: verify size
    var stx: std.os.linux.Statx = undefined;
    try io.statx(&compl, posix.AT.FDCWD, path_z, 0, std.os.linux.STATX.BASIC_STATS, &stx);
    try io.wait(&compl, void);
    try testing.expectEqual(@as(u64, data.len), stx.size);

    // read back
    var buf: [64]u8 = undefined;
    try io.read(&compl, fd, &buf, 0);
    const n = try io.wait(&compl, usize);
    try testing.expectEqual(data.len, n);
    try testing.expectEqualStrings(data, buf[0..n]);

    // close
    try io.close(&compl, fd);
    try io.wait(&compl, void);
}

test "tcp connect accept send recv round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const listener = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer _ = std.c.close(listener);
    const one: c_int = 1;
    _ = std.c.setsockopt(listener, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));
    try io.bind(listener, .{ .port = 0, .addr = 0 });
    try io.listen(listener, 16);

    var sockname: posix.sockaddr.in = undefined;
    var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try testing.expect(std.c.getsockname(listener, @ptrCast(&sockname), &namelen) == 0);
    const port = std.mem.bigToNative(u16, sockname.port);
    try testing.expect(port != 0);

    const client = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer _ = std.c.close(client);

    var compl_accept: IO.Future = undefined;
    var compl_connect: IO.Future = undefined;

    try io.accept(&compl_accept, listener);
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port),
        .addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 })),
    };
    try io.connect(&compl_connect, client, addr);

    try io.wait(&compl_connect, void);
    const server_fd = try io.wait(&compl_accept, posix.socket_t);

    const msg = "glu io_uring tcp";
    var compl_send: IO.Future = undefined;
    var compl_recv: IO.Future = undefined;
    var recv_buf: [64]u8 = undefined;

    try io.send(&compl_send, client, msg);
    try io.recv(&compl_recv, server_fd, &recv_buf);

    try testing.expectEqual(@as(usize, msg.len), try io.wait(&compl_send, usize));
    const rn = try io.wait(&compl_recv, usize);
    try testing.expectEqual(@as(usize, msg.len), rn);
    try testing.expectEqualStrings(msg, recv_buf[0..rn]);

    var compl_close: IO.Future = undefined;
    try io.close(&compl_close, server_fd);
    try io.wait(&compl_close, void);
}

test "udp send_to recv_from round-trip" {
    var io = try IO.init(32, 0);
    defer io.deinit();

    const s1 = try io.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer _ = std.c.close(s1);
    const s2 = try io.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer _ = std.c.close(s2);

    try io.bind(s1, .{ .port = 0, .addr = 0 });
    try io.bind(s2, .{ .port = 0, .addr = 0 });

    var sockname: posix.sockaddr.in = undefined;
    var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try testing.expect(std.c.getsockname(s1, @ptrCast(&sockname), &namelen) == 0);
    const port1 = std.mem.bigToNative(u16, sockname.port);
    try testing.expect(port1 != 0);

    const msg = "glu io_uring udp";
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port1),
        .addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 })),
    };

    var compl_send: IO.Future = undefined;
    var compl_recv: IO.Future = undefined;
    var buf: [64]u8 = undefined;

    try io.send_to(&compl_send, s2, msg, addr);
    try io.recv_from(&compl_recv, s1, &buf);

    try testing.expectEqual(@as(usize, msg.len), try io.wait(&compl_send, usize));
    const n = try io.wait(&compl_recv, usize);
    try testing.expectEqual(@as(usize, msg.len), n);
    try testing.expectEqualStrings(msg, buf[0..n]);
}

test "timeout fires after the requested duration" {
    var io = try IO.init(8, 0);
    defer io.deinit();

    var ts: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 40 * std.time.ns_per_ms };
    var compl: IO.Future = undefined;
    try io.timeout(&compl, &ts, 0);

    const start = try time.monotonic();
    try io.wait(&compl, void);
    const elapsed_ns = try time.monotonic() - start;

    try testing.expect(elapsed_ns >= 30 * std.time.ns_per_ms);
}

test "next_tick completes immediately" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var compl: IO.Future = undefined;
    try io.next_tick(&compl);
    try io.wait(&compl, void);
    try testing.expect(compl.done);
}

test "openat nonexistent path returns FileNotFound" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [256:0]u8 = undefined;
    const path_len = (std.fmt.bufPrint(path_buf[0..255], ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path[0..], "glu_missing.bin" }) catch unreachable).len;
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..];

    var compl: IO.Future = undefined;
    try io.openat(&compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0o644);
    try testing.expectError(error.FileNotFound, io.wait(&compl, posix.fd_t));
}

test "statx nonexistent path returns FileNotFound" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [256:0]u8 = undefined;
    const path_len = (std.fmt.bufPrint(path_buf[0..255], ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path[0..], "glu_missing.bin" }) catch unreachable).len;
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..];

    var stx: std.os.linux.Statx = undefined;
    var compl: IO.Future = undefined;
    try io.statx(&compl, posix.AT.FDCWD, path_z, 0, std.os.linux.STATX.BASIC_STATS, &stx);
    try testing.expectError(error.FileNotFound, io.wait(&compl, void));
}

test "connect to a closed port returns ConnectionRefused" {
    var io = try IO.init(8, 0);
    defer io.deinit();

    const probe = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try io.bind(probe, .{ .port = 0, .addr = 0 });
    var sockname: posix.sockaddr.in = undefined;
    var namelen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try testing.expect(std.c.getsockname(probe, @ptrCast(&sockname), &namelen) == 0);
    const port = std.mem.bigToNative(u16, sockname.port);
    _ = std.c.close(probe);
    try testing.expect(port != 0);

    const s = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer _ = std.c.close(s);
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port),
        .addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 })),
    };
    var compl: IO.Future = undefined;
    try io.connect(&compl, s, addr);
    try testing.expectError(error.ConnectionRefused, io.wait(&compl, void));
}

test "read from a closed fd returns NotOpenForReading" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [256:0]u8 = undefined;
    const path_len = (std.fmt.bufPrint(path_buf[0..255], ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path[0..], "glu_closed.bin" }) catch unreachable).len;
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..];

    var compl: IO.Future = undefined;
    try io.openat(&compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const fd = try io.wait(&compl, posix.fd_t);
    _ = std.c.close(fd);

    var compl_read: IO.Future = undefined;
    var buf: [16]u8 = undefined;
    try io.read(&compl_read, fd, &buf, 0);
    try testing.expectError(error.NotOpenForReading, io.wait(&compl_read, usize));
}

test "accept on a non-listening socket returns SocketNotListening" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    const s = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer _ = std.c.close(s);
    try io.bind(s, .{ .port = 0, .addr = 0 });

    var compl: IO.Future = undefined;
    try io.accept(&compl, s);
    try testing.expectError(error.SocketNotListening, io.wait(&compl, posix.socket_t));
}

test "batch: enqueue and drain many operations in one submission" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var compls: [8]IO.Future = undefined;
    for (&compls) |*compl| {
        try io.next_tick(compl);
    }
    for (&compls) |*compl| {
        try io.wait(compl, void);
    }
}

test "run pumps the event loop to completion" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var compl: IO.Future = undefined;
    try io.next_tick(&compl);
    try io.run(10 * std.time.ns_per_ms);
    try testing.expect(compl.done);
}

test "timeouts complete asynchronously while the app does work" {
    var io = try IO.init(16, 0);
    defer io.deinit();

    const pump = struct {
        fn call(io_: *IO) !void {
            try io_.submit(0);
            try io_.complete(0);
            try io_.run_callback();
        }
    }.call;

    var compls: [3]IO.Future = undefined;
    var specs = [_]std.os.linux.kernel_timespec{
        .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms },
        .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms },
        .{ .sec = 0, .nsec = 90 * std.time.ns_per_ms },
    };

    for (&compls, 0..) |*compl, i| {
        try io.timeout(compl, &specs[i], 0);
    }

    try pump(&io);
    try testing.expect(!compls[0].done and !compls[1].done and !compls[2].done);

    const started = try time.monotonic();
    var work: u64 = 0;
    while (try time.monotonic() - started < 40 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(compls[0].done);
    try testing.expect(!compls[1].done and !compls[2].done);
    try testing.expect(work >= 1000);

    while (try time.monotonic() - started < 70 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(compls[1].done);
    try testing.expect(!compls[2].done);

    while (try time.monotonic() - started < 120 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(compls[2].done);
}
