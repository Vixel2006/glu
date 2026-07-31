const std = @import("std");
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
            _ = self.completed.dequeue() catch {};
        }
        self.ring.deinit();
    }

    pub fn enqueue(self: *IO, completion: *Completion) !void {
        const sqe = try self.ring.get_sqe();
        completion.prep(sqe);
    }

    pub fn submit(self: *IO, wait_nr: u32) !void {
        const queued = self.ring.sq.tail.* -% self.ring.sq.head.*;
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

            for (cqes[0..completed]) |cqe| {
                const completion: *Completion = @ptrFromInt(cqe.user_data);
                completion.result = cqe.res;
                self.completed.enqueue(completion);
            }
            break;
        }
    }

    pub fn next_completion(self: *IO) ?*Completion {
        if (self.completed.is_empty()) return null;
        return self.completed.dequeue() catch return null;
    }

    pub fn complete_all(self: *IO) !void {
        while (self.next_completion()) |completion| {
            Completion.complete(completion);
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
                else => @panic(@tagName(err)),
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
                    const result: anyerror!void = blk: {
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

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub const StatxError = error{
        SymLinkLoop,
        FileNotFound,
        NameTooLong,
        NotDir,
    } || std.Io.File.StatError || posix.UnexpectedError;

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;
};
