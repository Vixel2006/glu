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

fn unexpected_errno(name: []const u8, err: posix.E) posix.UnexpectedError {
    _ = name;
    return posix.unexpectedErrno(err);
}

pub const IO = struct {
    ring: IoUring,
    completed: Queue(Completion),
    inflight: u32 = 0,

    pub fn init(entries: u16, flags: u32) !IO {
        var ring: IoUring = try .init(entries, flags);
        errdefer ring.deinit();

        return .{
            .ring = ring,
            .completed = Queue(Completion).init(),
        };
    }

    pub fn deinit(self: *IO) void {
        while (!self.completed.is_empty()) {
            // Dequeue is guaranteed to succeed because of the non-empty check.
            _ = self.completed.dequeue() catch unreachable;
        }
        self.ring.deinit();
    }

    pub fn run(self: *IO, nanoseconds: u64) !void {
        const deadline = time.monotonic() + nanoseconds;

        while (time.monotonic() >= deadline) {
            try self.submit(0);
            if (self.inflight == 0) break;
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
                const completion: *Completion = @ptrFromInt(cqe.user_data);
                completion.result = cqe.res;
                self.completed.enqueue(completion);
            }
            break;
        }
    }

    pub fn enqueue(self: *IO, completion: *Completion) !void {
        const sqe = try self.ring.get_sqe();
        self.inflight += 1;
        completion.prep(sqe);
    }

    pub fn run_callback(self: *IO) !void {
        while (true) {
            if (self.completed.is_empty()) return;
            const completed = try self.completed.dequeue();
            Completion.complete(completed);
        }
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

    pub const Completion = struct {
        io: *IO,
        result: i32 = undefined,
        operation: Operation,
        context: *anyopaque,
        callback: *const fn (
            context: *anyopaque,
            completion: *Completion,
            result: *const anyopaque,
        ) void,
        next: ?*Completion = null,

        fn check(completion: *Completion) !void {
            if (completion.result >= 0) return;
            const err: posix.E = @enumFromInt(-completion.result);
            switch (err) {
                .AGAIN, .INTR => return error.WouldBlock,
                .BADF => return error.FileDescriptorInvalid,
                .FAULT => unreachable,
                .INVAL => return error.InvalidInput,
                .NOMEM, .NOBUFS => return error.SystemResources,
                .PERM, .ACCES => return error.AccessDenied,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOTSOCK => return error.FileDescriptorNotASocket,
                .OPNOTSUPP => return error.OperationNotSupported,
                else => return error.UnexpectedSystemError,
            }
        }

        fn prep(completion: *Completion, sqe: *io_uring_sqe) void {
            switch (completion.operation) {
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
            sqe.user_data = @intFromPtr(completion);
        }

        fn complete(completion: *Completion) void {
            switch (completion.operation) {
                .accept => {
                    const result: AcceptError!posix.socket_t = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .close => {
                    const result: CloseError!void = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                // A success, see https://github.com/ziglang/zig/issues/2425.
                                .INTR => {},
                                .BADF => error.FileDescriptorInvalid,
                                .DQUOT => error.DiskQuota,
                                .IO => error.InputOutput,
                                .NOSPC => error.NoSpaceLeft,
                                else => |errno| unexpected_errno("close", errno),
                            };
                            break :blk err;
                        } else {
                            assert(completion.result == 0);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .connect => {
                    const result: ConnectError!void = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            assert(completion.result == 0);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .fsync => {
                    const result: FsyncError!void = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            assert(completion.result == 0);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .openat => {
                    const result: OpenatError!posix.fd_t = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .read => {
                    const result: ReadError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR, .AGAIN => {
                                    // Some file systems, like XFS, can return EAGAIN even when
                                    // reading from a blocking file without flags like RWF_NOWAIT.
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .recv => {
                    const result: RecvError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .send => {
                    const result: SendError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
                                        break :blk error.SystemResources;
                                    };
                                    return;
                                },
                                .ACCES => error.AccessDenied,
                                .AGAIN => error.WouldBlock,
                                .ALREADY => error.FastOpenAlreadyInProgress,
                                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                                .BADF => error.FileDescriptorInvalid,
                                // Can happen when send()'ing to a UDP socket.
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .statx => {
                    const result: StatxError!void = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            assert(completion.result == 0);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .timeout => {
                    assert(completion.result < 0);
                    const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                        .INTR => {
                            completion.io.enqueue(completion) catch {
                                const result: TimeoutError!void = error.Unexpected;
                                completion.callback(completion.context, completion, &result);
                                return;
                            };
                            return;
                        },
                        .CANCELED => error.Canceled,
                        .TIME => {}, // A success.
                        else => |errno| unexpected_errno("timeout", errno),
                    };
                    const result: TimeoutError!void = err;
                    completion.callback(completion.context, completion, &result);
                },
                .write => {
                    const result: WriteError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .next_tick => {
                    const result: NextTickResult = .{};
                    completion.callback(completion.context, completion, &result);
                },
                .send_to => {
                    const result: SendToError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
                },
                .recv_from => {
                    const result: RecvFromError!usize = blk: {
                        if (completion.result < 0) {
                            const err = switch (@as(posix.E, @enumFromInt(-completion.result))) {
                                .INTR => {
                                    completion.io.enqueue(completion) catch {
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
                            break :blk @intCast(completion.result);
                        }
                    };
                    completion.callback(completion.context, completion, &result);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!posix.socket_t,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const AcceptError!posix.socket_t = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{ .accept = .{ .socket = sock } },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
        address: posix.sockaddr.in,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const ConnectError!void = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .connect = .{
                    .socket = sock,
                    .address = address,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        buffer: []u8,
        offset: u64,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const ReadError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .read = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const WriteError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .write = .{
                    .fd = fd,
                    .buffer = buffer,
                    .offset = offset,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
        buffer: []u8,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const RecvError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .recv = .{
                    .socket = sock,
                    .buffer = buffer,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
        buffer: []const u8,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const SendError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .send = .{
                    .socket = sock,
                    .buffer = buffer,
                },
            },
        };
        try self.enqueue(completion);
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const CloseError!void = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .close = .{
                    .fd = fd,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendToError!usize,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
        buffer: []const u8,
        address: posix.sockaddr.in,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const SendToError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .send_to = .{
                    .socket = sock,
                    .buffer = buffer,
                    .address = address,
                },
            },
        };
        try self.enqueue(completion);
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
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvFromError!usize,
        ) void,
        completion: *Completion,
        sock: posix.socket_t,
        buffer: []u8,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const RecvFromError!usize = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .recv_from = .{
                    .socket = sock,
                    .buffer = buffer,
                    .address = undefined,
                },
            },
        };
        try self.enqueue(completion);
    }

    pub const FsyncError = error{
        FileDescriptorInvalid,
        InputOutput,
        SystemResources,
    } || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const FsyncError!void = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .fsync = .{
                    .fd = fd,
                },
            },
        };
        try self.enqueue(completion);
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub fn openat(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: OpenatError!posix.fd_t,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        path: [*:0]const u8,
        flags: posix.O,
        mode: u32,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const OpenatError!posix.fd_t = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .openat = .{
                    .fd = fd,
                    .path = path,
                    .flags = flags,
                    .mode = mode,
                },
            },
        };
        try self.enqueue(completion);
    }

    pub const StatxError = error{
        SymLinkLoop,
        FileNotFound,
        NameTooLong,
        NotDir,
    } || std.Io.File.StatError || posix.UnexpectedError;

    pub fn statx(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: StatxError!void,
        ) void,
        completion: *Completion,
        fd: posix.fd_t,
        path: [*:0]const u8,
        flags: u32,
        mask: os.linux.STATX,
        buffer: *std.os.linux.Statx,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const StatxError!void = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
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
        try self.enqueue(completion);
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        timespec: *std.os.linux.kernel_timespec,
        flags: u32,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const TimeoutError!void = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .{
                .timeout = .{
                    .timeout = timespec,
                    .flags = flags,
                },
            },
        };
        try self.enqueue(completion);
    }

    pub fn next_tick(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: NextTickResult,
        ) void,
        completion: *Completion,
    ) !void {
        const wrapper = struct {
            fn call(ctx: *anyopaque, compl: *Completion, res_ptr: *const anyopaque) void {
                const typed_context: Context = @ptrCast(@alignCast(ctx));
                const typed_result: *const NextTickResult = @ptrCast(@alignCast(res_ptr));
                callback(typed_context, compl, typed_result.*);
            }
        }.call;

        completion.* = .{
            .io = self,
            .context = @ptrCast(context),
            .callback = wrapper,
            .operation = .next_tick,
        };
        try self.enqueue(completion);
    }
};

const testing = std.testing;

test "init and deinit across entry sizes" {
    inline for (.{ 1, 2, 8, 32, 256 }) |entries| {
        var io = try IO.init(entries, 0);
        io.deinit();
    }
}

fn Sync(comptime ResultType: type) type {
    return struct {
        done: bool = false,
        result: ResultType = undefined,

        pub fn cb(ctx: *@This(), _: *IO.Completion, res: ResultType) void {
            ctx.result = res;
            ctx.done = true;
        }
    };
}

fn wait_completion(io: *IO, state: anytype) !void {
    while (!state.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
}

test "deinit with pending unsent completion does not crash" {
    var io = try IO.init(8, 0);
    var ctx = Sync(IO.NextTickResult){};
    var compl: IO.Completion = undefined;
    try io.next_tick(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl);
    io.deinit();
}

test "enqueue beyond ring capacity returns error.SQFull" {
    var io = try IO.init(2, 0);
    defer io.deinit();
    var ctx = Sync(IO.NextTickResult){};
    var compls: [4]IO.Completion = undefined;
    var saw_full = false;
    for (&compls) |*compl| {
        io.next_tick(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, compl) catch |err| {
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
    var compl: IO.Completion = undefined;

    // openat: create + truncate + read-write
    var open_sync = Sync(IO.OpenatError!posix.fd_t){};
    try io.openat(@TypeOf(&open_sync), &open_sync, @TypeOf(open_sync).cb, &compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    try wait_completion(&io, &open_sync);
    const fd = try open_sync.result;

    // write
    var write_sync = Sync(IO.WriteError!usize){};
    try io.write(@TypeOf(&write_sync), &write_sync, @TypeOf(write_sync).cb, &compl, fd, data, 0);
    try wait_completion(&io, &write_sync);
    try testing.expectEqual(data.len, try write_sync.result);

    // fsync
    var fsync_sync = Sync(IO.FsyncError!void){};
    try io.fsync(@TypeOf(&fsync_sync), &fsync_sync, @TypeOf(fsync_sync).cb, &compl, fd);
    try wait_completion(&io, &fsync_sync);
    try fsync_sync.result;

    // statx: verify size
    var stx: std.os.linux.Statx = undefined;
    var statx_sync = Sync(IO.StatxError!void){};
    try io.statx(@TypeOf(&statx_sync), &statx_sync, @TypeOf(statx_sync).cb, &compl, posix.AT.FDCWD, path_z, 0, std.os.linux.STATX.BASIC_STATS, &stx);
    try wait_completion(&io, &statx_sync);
    try statx_sync.result;
    try testing.expectEqual(@as(u64, data.len), stx.size);

    // read back
    var read_sync = Sync(IO.ReadError!usize){};
    var buf: [64]u8 = undefined;
    try io.read(@TypeOf(&read_sync), &read_sync, @TypeOf(read_sync).cb, &compl, fd, &buf, 0);
    try wait_completion(&io, &read_sync);
    const n = try read_sync.result;
    try testing.expectEqual(data.len, n);
    try testing.expectEqualStrings(data, buf[0..n]);

    // close
    var close_sync = Sync(IO.CloseError!void){};
    try io.close(@TypeOf(&close_sync), &close_sync, @TypeOf(close_sync).cb, &compl, fd);
    try wait_completion(&io, &close_sync);
    try close_sync.result;
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

    var accept_sync = Sync(IO.AcceptError!posix.socket_t){};
    var connect_sync = Sync(IO.ConnectError!void){};
    var compl_accept: IO.Completion = undefined;
    var compl_connect: IO.Completion = undefined;

    try io.accept(@TypeOf(&accept_sync), &accept_sync, @TypeOf(accept_sync).cb, &compl_accept, listener);
    const addr: posix.sockaddr.in = .{
        .port = @byteSwap(port),
        .addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 })),
    };
    try io.connect(@TypeOf(&connect_sync), &connect_sync, @TypeOf(connect_sync).cb, &compl_connect, client, addr);

    while (!accept_sync.done or !connect_sync.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    try connect_sync.result;
    const server_fd = try accept_sync.result;

    const msg = "glu io_uring tcp";
    var send_sync = Sync(IO.SendError!usize){};
    var recv_sync = Sync(IO.RecvError!usize){};
    var compl_send: IO.Completion = undefined;
    var compl_recv: IO.Completion = undefined;
    var recv_buf: [64]u8 = undefined;

    try io.send(@TypeOf(&send_sync), &send_sync, @TypeOf(send_sync).cb, &compl_send, client, msg);
    try io.recv(@TypeOf(&recv_sync), &recv_sync, @TypeOf(recv_sync).cb, &compl_recv, server_fd, &recv_buf);

    while (!send_sync.done or !recv_sync.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    try testing.expectEqual(@as(usize, msg.len), try send_sync.result);
    const rn = try recv_sync.result;
    try testing.expectEqual(@as(usize, msg.len), rn);
    try testing.expectEqualStrings(msg, recv_buf[0..rn]);

    var close_sync = Sync(IO.CloseError!void){};
    var compl_close: IO.Completion = undefined;
    try io.close(@TypeOf(&close_sync), &close_sync, @TypeOf(close_sync).cb, &compl_close, server_fd);
    try wait_completion(&io, &close_sync);
    try close_sync.result;
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

    var send_sync = Sync(IO.SendToError!usize){};
    var recv_sync = Sync(IO.RecvFromError!usize){};
    var compl_send: IO.Completion = undefined;
    var compl_recv: IO.Completion = undefined;
    var buf: [64]u8 = undefined;

    try io.send_to(@TypeOf(&send_sync), &send_sync, @TypeOf(send_sync).cb, &compl_send, s2, msg, addr);
    try io.recv_from(@TypeOf(&recv_sync), &recv_sync, @TypeOf(recv_sync).cb, &compl_recv, s1, &buf);

    while (!send_sync.done or !recv_sync.done) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    try testing.expectEqual(@as(usize, msg.len), try send_sync.result);
    const n = try recv_sync.result;
    try testing.expectEqual(@as(usize, msg.len), n);
    try testing.expectEqualStrings(msg, buf[0..n]);
}

test "timeout fires after the requested duration" {
    var io = try IO.init(8, 0);
    defer io.deinit();

    var ts: std.os.linux.kernel_timespec = .{ .sec = 0, .nsec = 40 * std.time.ns_per_ms };
    var ctx = Sync(IO.TimeoutError!void){};
    var compl: IO.Completion = undefined;
    try io.timeout(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl, &ts, 0);

    const start = time.monotonic();
    try wait_completion(&io, &ctx);
    const elapsed_ns = time.monotonic() - start;

    try ctx.result;
    try testing.expect(elapsed_ns >= 30 * std.time.ns_per_ms);
}

test "next_tick completes immediately" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    var ctx = Sync(IO.NextTickResult){};
    var compl: IO.Completion = undefined;
    try io.next_tick(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl);
    try wait_completion(&io, &ctx);
    try testing.expect(ctx.done);
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

    var ctx = Sync(IO.OpenatError!posix.fd_t){};
    var compl: IO.Completion = undefined;
    try io.openat(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0o644);
    try wait_completion(&io, &ctx);
    try testing.expectError(error.FileNotFound, ctx.result);
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
    var ctx = Sync(IO.StatxError!void){};
    var compl: IO.Completion = undefined;
    try io.statx(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl, posix.AT.FDCWD, path_z, 0, std.os.linux.STATX.BASIC_STATS, &stx);
    try wait_completion(&io, &ctx);
    try testing.expectError(error.FileNotFound, ctx.result);
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
    var ctx = Sync(IO.ConnectError!void){};
    var compl: IO.Completion = undefined;
    try io.connect(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl, s, addr);
    try wait_completion(&io, &ctx);
    try testing.expectError(error.ConnectionRefused, ctx.result);
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

    var open_sync = Sync(IO.OpenatError!posix.fd_t){};
    var compl: IO.Completion = undefined;
    try io.openat(@TypeOf(&open_sync), &open_sync, @TypeOf(open_sync).cb, &compl, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    try wait_completion(&io, &open_sync);
    const fd = try open_sync.result;
    _ = std.c.close(fd);

    var read_ctx = Sync(IO.ReadError!usize){};
    var buf: [16]u8 = undefined;
    try io.read(@TypeOf(&read_ctx), &read_ctx, @TypeOf(read_ctx).cb, &compl, fd, &buf, 0);
    try wait_completion(&io, &read_ctx);
    try testing.expectError(error.NotOpenForReading, read_ctx.result);
}

test "accept on a non-listening socket returns SocketNotListening" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    const s = try io.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer _ = std.c.close(s);
    try io.bind(s, .{ .port = 0, .addr = 0 });

    var ctx = Sync(IO.AcceptError!posix.socket_t){};
    var compl: IO.Completion = undefined;
    try io.accept(@TypeOf(&ctx), &ctx, @TypeOf(ctx).cb, &compl, s);
    try wait_completion(&io, &ctx);
    try testing.expectError(error.SocketNotListening, ctx.result);
}

test "batch: enqueue and drain many operations in one submission" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    const Ctx = struct {
        done: bool = false,
        calls: u32 = 0,
    };
    const cb = struct {
        fn call(ctx: *Ctx, _: *IO.Completion, _: IO.NextTickResult) void {
            ctx.calls += 1;
            ctx.done = true;
        }
    }.call;
    var ctx = Ctx{};
    var compls: [8]IO.Completion = undefined;
    for (&compls) |*compl| {
        try io.next_tick(*Ctx, &ctx, cb, compl);
    }
    while (ctx.calls < 8) {
        try io.submit(1);
        try io.complete(1);
        try io.run_callback();
    }
    try testing.expectEqual(@as(u32, 8), ctx.calls);
}

test "run pumps the event loop to completion" {
    var io = try IO.init(8, 0);
    defer io.deinit();
    const Ctx = struct {
        done: bool = false,
        calls: u32 = 0,
    };
    const cb = struct {
        fn call(ctx: *Ctx, _: *IO.Completion, _: IO.NextTickResult) void {
            ctx.calls += 1;
            ctx.done = true;
        }
    }.call;
    var ctx = Ctx{};
    var compl: IO.Completion = undefined;
    try io.next_tick(*Ctx, &ctx, cb, &compl);
    try io.run(10 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
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

    const TimerCtx = struct {
        fired: bool = false,
    };
    const timer_cb = struct {
        fn call(ctx: *TimerCtx, _: *IO.Completion, _: IO.TimeoutError!void) void {
            ctx.fired = true;
        }
    }.call;

    var ctxs = [_]TimerCtx{ .{}, .{}, .{} };
    var compls: [3]IO.Completion = undefined;
    var specs = [_]std.os.linux.kernel_timespec{
        .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms },
        .{ .sec = 0, .nsec = 60 * std.time.ns_per_ms },
        .{ .sec = 0, .nsec = 90 * std.time.ns_per_ms },
    };

    for (&compls, 0..) |*compl, i| {
        try io.timeout(*TimerCtx, &ctxs[i], timer_cb, compl, &specs[i], 0);
    }

    // Submitting hands the ops to the kernel: none complete synchronously.
    try pump(&io);
    try testing.expect(!ctxs[0].fired and !ctxs[1].fired and !ctxs[2].fired);

    // The app thread does real work while all three timeouts are in flight;
    // a blocking pump would let `work` barely advance.
    const started = time.monotonic();
    var work: u64 = 0;
    while (time.monotonic() - started < 40 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(ctxs[0].fired);
    try testing.expect(!ctxs[1].fired and !ctxs[2].fired);
    try testing.expect(work >= 1000);

    while (time.monotonic() - started < 70 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(ctxs[1].fired);
    try testing.expect(!ctxs[2].fired);

    while (time.monotonic() - started < 120 * std.time.ns_per_ms) {
        work += 1;
        try pump(&io);
    }
    try testing.expect(ctxs[2].fired);
}
