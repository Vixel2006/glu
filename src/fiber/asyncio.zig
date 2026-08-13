const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const Fiber = @import("fiber.zig").Fiber;
const Queue = @import("../queue.zig").Queue;

threadlocal var tls_loop: ?*AsyncIo = null;
threadlocal var tls_starting_fiber: ?*Fiber = null;

/// Return the event loop bound to the current thread, or null.
pub fn current() ?*AsyncIo {
    return tls_loop;
}

/// Create (or reuse) the thread-local event loop and return it.
/// The loop stays bound to the thread for its lifetime.
pub fn get_event_loop() *AsyncIo {
    if (tls_loop) |loop| {
        return loop;
    }
    const loop = std.heap.page_allocator.create(AsyncIo) catch @panic("out of memory allocating event loop");
    loop.* = .{
        .ready = Queue(Fiber).init(),
        .current_fiber = null,
        .ctx = std.mem.zeroes(Fiber.Context),
    };
    tls_loop = loop;
    return loop;
}

pub const AsyncIo = struct {
    /// FCFS run-queue of fibers in READY state.
    ready: Queue(Fiber),
    current_fiber: ?*Fiber = null,
    ctx: Fiber.Context,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    stack_size: usize = default_stack_size,

    pub const default_stack_size: usize = 1 << 20;

    /// Schedule a fiber that runs `func(arg)` until it returns. The fiber and
    /// its stack are allocated from `allocator` and freed when the fiber exits.
    pub fn create_task(self: *AsyncIo, comptime func: anytype, arg: anytype) void {
        const fn_ptr: *const fn (*anyopaque) void = @ptrFromInt(@intFromPtr(&func));
        const arg_ptr: *anyopaque = @ptrCast(arg);

        const stack = self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), self.stack_size) catch |e| {
            std.debug.panic("create_task: unable to allocate fiber stack: {s}", .{@errorName(e)});
        };

        const fiber = self.allocator.create(Fiber) catch |e| {
            self.allocator.free(stack);
            std.debug.panic("create_task: unable to allocate fiber: {s}", .{@errorName(e)});
        };

        fiber.* = .{
            .ctx = undefined,
            .state = .READY,
            .next = null,
            .func = fn_ptr,
            .arg = arg_ptr,
            .stack = stack,
        };

        const top = @intFromPtr(fiber.stack.ptr) + fiber.stack.len;
        switch (builtin.cpu.arch) {
            .x86_64 => {
                fiber.ctx = .{
                    .rsp = top - 8,
                    .rbp = 0,
                    .rip = @intFromPtr(&fiber_boot),
                };
            },
            .aarch64 => {
                fiber.ctx = .{
                    .sp = top,
                    .fp = 0,
                    .pc = @intFromPtr(&fiber_boot),
                };
            },
            else => @compileError("unsupported architecture"),
        }
        self.ready.enqueue(fiber);
    }

    /// Run all currently-ready fibers, switching into each and resuming them
    /// one at a time until they park or finish.
    pub fn run_ready(self: *AsyncIo) void {
        while (true) {
            if (self.ready.is_empty()) break;
            const fiber = self.ready.dequeue() catch unreachable;
            assert(fiber.state == .READY);
            fiber.state = .RUNNING;
            self.current_fiber = fiber;

            tls_starting_fiber = fiber;
            _ = Fiber.context_switch(&Fiber.Switch{ .old = &self.ctx, .new = &fiber.ctx });

            self.current_fiber = null;

            if (fiber.state == .DEAD) {
                self.allocator.free(fiber.stack);
                self.allocator.destroy(fiber);
            }
        }
    }

    /// Yield control from the current fiber back to the event loop. The fiber
    /// stays suspended until `resume` enqueues it again; it wakes up at the
    /// instruction right after this call.
    pub fn yield(self: *AsyncIo) void {
        const fiber = self.current_fiber orelse @panic("yield outside a fiber");
        assert(fiber.state == .RUNNING);
        fiber.state = .WAITING;
        _ = Fiber.context_switch(&Fiber.Switch{ .old = &fiber.ctx, .new = &self.ctx });
    }

    /// Re-enqueue a yielded fiber so the next `run_ready` resumes it.
    pub fn wake(self: *AsyncIo, fiber: *Fiber) void {
        assert(fiber.state == .WAITING);
        fiber.state = .READY;
        self.ready.enqueue(fiber);
    }
};

/// Entry point for a freshly switched-to fiber. Reads the fiber out of the
/// thread-local set by the event loop, runs its function, marks it DEAD, and
/// hands control back to the loop so it can be reaped. Never returns.
fn fiber_boot() callconv(.c) noreturn {
    const fiber = tls_starting_fiber orelse unreachable;
    tls_starting_fiber = null;

    fiber.func(fiber.arg);
    fiber.state = .DEAD;
    _ = Fiber.context_switch(&Fiber.Switch{ .old = &fiber.ctx, .new = &tls_loop.?.ctx });
    unreachable;
}

test "spawn and run single fiber" {
    const testing = std.testing;
    const loop = get_event_loop();
    loop.allocator = testing.allocator;

    var ran = false;
    const S = struct {
        fn work(flag: *bool) void {
            flag.* = true;
        }
    };

    loop.create_task(S.work, &ran);
    loop.run_ready();

    try testing.expect(ran);
}

test "fiber parks on io future and resumes" {
    const IO = @import("../io.zig").IO;
    const testing = std.testing;
    var io = try IO.init(16, 0);
    defer io.deinit();
    const loop = get_event_loop();
    loop.allocator = testing.allocator;

    var result: bool = false;

    const Ctx = struct {
        io_ref: *IO,
        flag: *bool,
    };

    const S = struct {
        fn work(ctx: *Ctx) void {
            var future: IO.Future = undefined;
            ctx.io_ref.next_tick(&future) catch unreachable;
            ctx.io_ref.wait(&future, void) catch unreachable;
            ctx.flag.* = future.done;
        }
    };

    var ctx = Ctx{ .io_ref = &io, .flag = &result };
    loop.create_task(S.work, &ctx);
    try io.run(10 * std.time.ns_per_ms);

    try testing.expect(result);
}

test "root io.wait drives spawned fibers" {
    const IO = @import("../io.zig").IO;
    const testing = std.testing;
    var io = try IO.init(16, 0);
    defer io.deinit();
    const loop = get_event_loop();
    loop.allocator = testing.allocator;

    var ran = false;
    const S = struct {
        fn work(flag: *bool) void {
            flag.* = true;
        }
    };

    loop.create_task(S.work, &ran);

    var future: IO.Future = undefined;
    try io.next_tick(&future);
    try io.wait(&future, void);

    try testing.expect(ran);
}

test "waiter yields to other fibers and resumes with the io result" {
    const IO = @import("../io.zig").IO;
    const posix = std.posix;
    const testing = std.testing;
    var io = try IO.init(16, 0);
    defer io.deinit();
    const loop = get_event_loop();
    loop.allocator = testing.allocator;

    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [256:0]u8 = undefined;
    const path_len = (std.fmt.bufPrint(path_buf[0..255], ".zig-cache/tmp/{s}/{s}", .{ dir.sub_path[0..], "sched_yield.bin" }) catch unreachable).len;
    path_buf[path_len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..];

    var open_fut: IO.Future = undefined;
    try io.openat(&open_fut, posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const fd = try io.wait(&open_fut, posix.fd_t);

    const Order = enum { a_start, b_start, b_end, a_end };
    var order: [4]Order = undefined;
    var idx: usize = 0;
    var written: usize = 0;
    const data = "fiber io yield with result";

    const Ctx = struct {
        io_ref: *IO,
        fd: posix.fd_t,
        data: []const u8,
        order: []Order,
        idx: *usize,
        written: *usize,
    };

    const S = struct {
        fn work_a(ctx: *Ctx) void {
            ctx.order[ctx.idx.*] = .a_start;
            ctx.idx.* += 1;
            var future: IO.Future = undefined;
            ctx.io_ref.write(&future, ctx.fd, ctx.data, 0) catch unreachable;
            ctx.written.* = ctx.io_ref.wait(&future, usize) catch unreachable;
            ctx.order[ctx.idx.*] = .a_end;
            ctx.idx.* += 1;
        }
        fn work_b(ctx: *Ctx) void {
            ctx.order[ctx.idx.*] = .b_start;
            ctx.idx.* += 1;
            ctx.order[ctx.idx.*] = .b_end;
            ctx.idx.* += 1;
        }
    };

    var ctx = Ctx{ .io_ref = &io, .fd = fd, .data = data, .order = &order, .idx = &idx, .written = &written };
    loop.create_task(S.work_a, &ctx);
    loop.create_task(S.work_b, &ctx);

    try io.run(10 * std.time.ns_per_ms);

    try testing.expectEqual(@as(usize, 4), idx);
    try testing.expectEqual(Order.a_start, order[0]);
    try testing.expectEqual(Order.b_start, order[1]);
    try testing.expectEqual(Order.b_end, order[2]);
    try testing.expectEqual(Order.a_end, order[3]);
    try testing.expectEqual(@as(usize, data.len), written);

    var close_fut: IO.Future = undefined;
    try io.close(&close_fut, fd);
    try io.wait(&close_fut, void);
}
