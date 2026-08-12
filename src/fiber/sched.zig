const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const Fiber = @import("fiber.zig").Fiber;
const Queue = @import("../queue.zig").Queue;

threadlocal var tls_sched: ?*Scheduler = null;
/// Set right before the scheduler switches to a fiber for the first time and
/// read once by that fiber's entry thunk. Only fresh fibers ever read it.
threadlocal var tls_starting_fiber: ?*Fiber = null;

/// Return the scheduler bound to the current thread, or null.
pub fn try_current() ?*Scheduler {
    return tls_sched;
}

/// Create (or reuse) the thread-local scheduler and return it.
/// The scheduler stays bound to the thread for its lifetime.
pub fn init() *Scheduler {
    if (tls_sched) |sched| {
        return sched;
    }
    const sched = std.heap.page_allocator.create(Scheduler) catch @panic("out of memory allocating scheduler");
    sched.* = .{
        .ready = Queue(Fiber).init(),
        .current_fiber = null,
        .ctx = std.mem.zeroes(Fiber.Context),
    };
    tls_sched = sched;
    return sched;
}

pub const Scheduler = struct {
    /// FCFS run-queue of fibers in READY state.
    ready: Queue(Fiber),
    /// The fiber currently executing, or null when the scheduler itself runs.
    current_fiber: ?*Fiber = null,
    /// Saved context for the scheduler.
    ctx: Fiber.Context,
    /// Allocator used for fiber stacks and fiber structs.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    /// Stack size for spawned fibers.
    stack_size: usize = default_stack_size,

    pub const default_stack_size: usize = 1 << 20;

    /// Add a fiber that runs `func(arg)` until it returns. The fiber and its
    /// stack are allocated from `allocator` and freed when the fiber exits.
    pub fn spawn(self: *Scheduler, comptime func: anytype, arg: anytype) void {
        const fn_ptr: *const fn (*anyopaque) void = @ptrFromInt(@intFromPtr(&func));
        const arg_ptr: *anyopaque = @ptrCast(arg);

        const stack = self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), self.stack_size) catch |e| {
            std.debug.panic("spawn: unable to allocate fiber stack: {s}", .{@errorName(e)});
        };

        const fiber = self.allocator.create(Fiber) catch |e| {
            self.allocator.free(stack);
            std.debug.panic("spawn: unable to allocate fiber: {s}", .{@errorName(e)});
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

    pub fn drive(self: *Scheduler) void {
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

    /// Suspend the current fiber.
    pub fn park(self: *Scheduler) void {
        const fiber = self.current_fiber orelse @panic("park outside a fiber");
        assert(fiber.state == .RUNNING);
        fiber.state = .WAITING;
        _ = Fiber.context_switch(&Fiber.Switch{ .old = &fiber.ctx, .new = &self.ctx });
    }

    /// Wake a parked fiber, moving it to the ready queue.
    pub fn wake(self: *Scheduler, fiber: *Fiber) void {
        assert(fiber.state == .WAITING);
        fiber.state = .READY;
        self.ready.enqueue(fiber);
    }
};

/// Entry point for a freshly switched-to fiber. Reads the fiber out of the
/// thread-local set by the scheduler, runs its function, marks it DEAD, and
/// hands control back to the scheduler so it can be reaped. Never returns.
fn fiber_boot() callconv(.c) noreturn {
    const fiber = tls_starting_fiber orelse unreachable;
    tls_starting_fiber = null;

    fiber.func(fiber.arg);
    fiber.state = .DEAD;
    _ = Fiber.context_switch(&Fiber.Switch{ .old = &fiber.ctx, .new = &tls_sched.?.ctx });
    unreachable;
}

test "spawn and run single fiber" {
    const testing = std.testing;
    const sched = init();
    sched.allocator = testing.allocator;

    var ran = false;
    const S = struct {
        fn work(flag: *bool) void {
            flag.* = true;
        }
    };

    sched.spawn(S.work, &ran);
    sched.drive();

    try testing.expect(ran);
}


test "fiber parks on io future and resumes" {
    const IO = @import("../io.zig").IO;
    const testing = std.testing;
    var io = try IO.init(16, 0);
    defer io.deinit();
    const sched = init();
    sched.allocator = testing.allocator;

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
    sched.spawn(S.work, &ctx);
    try io.run(10 * std.time.ns_per_ms);

    try testing.expect(result);
}

test "root io.wait drives spawned fibers" {
    const IO = @import("../io.zig").IO;
    const testing = std.testing;
    var io = try IO.init(16, 0);
    defer io.deinit();
    const sched = init();
    sched.allocator = testing.allocator;

    var ran = false;
    const S = struct {
        fn work(flag: *bool) void {
            flag.* = true;
        }
    };

    sched.spawn(S.work, &ran);

    var future: IO.Future = undefined;
    try io.next_tick(&future);
    try io.wait(&future, void);

    try testing.expect(ran);
}
