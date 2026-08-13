# GLU API Reference

This document provides a comprehensive reference for the `glu` public API, including shared memory pub/sub, the node registry, the asynchronous I/O engine, and network transport (TCP/UDP).

---

## 1. Shared Memory Pub/Sub API

The core of `glu` is its lock-free, zero-copy publisher-subscriber system based on POSIX shared memory segments.

### Message Definition Requirements
To ensure predictable layout and alignment across different processes and architectures, message structures should be defined as `extern struct` or `packed struct`.

```zig
const JointState = extern struct {
    seq: u32,
    timestamp: i64,
    position: f32,
    velocity: f32,
    effort: f32,
};
```

---

### `glu.Publisher`

Manages the allocation and writing of messages into a topic's shared memory segment.

#### `init`
```zig
pub fn init(
    name: []const u8,
    msg_size: u32,
    capacity: u32,
    tos: ToS
) PubErr!Publisher
```
*   **Description**: Creates or attaches to a shared memory channel under `/dev/shm/<name>` and registers the publisher node. If the existing segment is stale (e.g. from a crashed previous run), it is automatically unlinked and initialized fresh.
*   **Parameters**:
    *   `name`: Topic path (must start with a slash, e.g. `/robot/telemetry`).
    *   `msg_size`: Size of the message struct in bytes (`@sizeOf(T)`).
    *   `capacity`: Number of slots in the ring buffer.
    *   `tos`: Type of Service (quality of service policy). Can be `.reliable` (publisher blocks if buffer is full) or `.best_effort` (publisher overwrites if buffer is full).
*   **Returns**: An initialized `Publisher` struct, or an error.

#### `deinit`
```zig
pub fn deinit(self: *Publisher) void
```
*   **Description**: Unmaps the shared memory segment, closes the file descriptors, and automatically unlinks the shared memory file if no other processes are connected to it.

#### `reserve`
```zig
pub fn reserve(self: *Publisher) *anyopaque
```
*   **Description**: The first phase of the **zero-copy** pattern. Finds the next available slot in the shared memory segment and returns a direct pointer to it. If the queue is full and `tos` is `.reliable`, it spins until a slot is freed by subscribers.
*   **Returns**: An aligned pointer (`*anyopaque`) to the reserved memory slot. Cast it using `@ptrCast(@alignCast(ptr))`.

#### `commit`
```zig
pub fn commit(self: *Publisher) void
```
*   **Description**: The second phase of the **zero-copy** pattern. Atomically advances the write cursor, making the recently written slot visible to all subscribers.

#### `publish`
```zig
pub fn publish(self: *Publisher, msg: *const anyopaque) void
```
*   **Description**: A one-shot, copy-based convenience function. It reserves a slot, copies the message from your local memory into the shared memory slot, and commits it. Useful for small structs or simple telemetry.

#### Example: Publishing Data
```zig
const std = @import("std");
const glu = @import("glu");

pub fn main() !void {
    var publisher = try glu.Publisher.init("/sensor", @sizeOf(JointState), 1024, .reliable);
    defer publisher.deinit();

    // Option A: Zero-Copy (Recommended for large data)
    const slot: *JointState = @ptrCast(@alignCast(publisher.reserve()));
    slot.* = JointState{
        .seq = 1,
        .timestamp = 0,
        .position = 1.57,
        .velocity = 0.1,
        .effort = 4.2,
    };
    publisher.commit();

    // Option B: Publish by Copy
    const local_msg = JointState{
        .seq = 2,
        .timestamp = 0,
        .position = 1.58,
        .velocity = 0.0,
        .effort = 0.0,
    };
    publisher.publish(@ptrCast(&local_msg));
}
```

---

### `glu.Subscriber`

Manages reading messages from a topic's shared memory segment.

#### `init`
```zig
pub fn init(
    name: []const u8,
    msg_size: u32,
    capacity: u32
) SubErr!Subscriber
```
*   **Description**: Attaches to the existing shared memory segment under the given topic name. It atomically claims an unused reader slot (up to 8 subscribers per topic). A late-joining subscriber starts reading from the current write position so it only sees new messages.
*   **Returns**: An initialized `Subscriber` struct, or `error.NoReaderSlots` when the topic is already subscribed to by 8 readers.

#### `deinit`
```zig
pub fn deinit(self: *Subscriber) void
```
*   **Description**: Releases the reader slot so the publisher no longer waits for it, closes the segment, and unmaps the memory.

#### `peek`
```zig
pub fn peek(self: *Subscriber) ?*anyopaque
```
*   **Description**: Non-blocking retrieve. Compares the subscriber's read cursor against the publisher's global write cursor. If new data is available, returns a direct pointer to the slot *without consuming it*.
*   **Returns**: An aligned pointer (`*anyopaque`) to the slot if a new message is available; otherwise, `null`.
*   **Note**: The returned pointer stays valid until `ack` is called. Copy the message before acknowledging, otherwise the publisher may wrap around and overwrite the slot.

#### `ack`
```zig
pub fn ack(self: *Subscriber) void
```
*   **Description**: Marks the most recently peeked message as consumed, advancing the read cursor so the publisher may reuse the slot.

#### Example: Subscribing to Data
```zig
const std = @import("std");
const glu = @import("glu");

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub fn main() !void {
    var subscriber = try glu.Subscriber.init("/sensor", @sizeOf(JointState), 1024);
    defer subscriber.deinit();

    while (true) {
        if (subscriber.peek()) |raw| {
            const msg: *JointState = @ptrCast(@alignCast(raw));
            std.debug.print("Received: seq={d}, pos={d:.2}\n", .{ msg.seq, msg.position });
            subscriber.ack();
        }
        sleepMs(10);
    }
}
```

---

## 2. Asynchronous I/O Engine (`glu.IO`)

`glu` includes a highly optimized asynchronous I/O engine powered by Linux `io_uring`. All network operations (`tcp` and `udp`) run on top of this engine. The engine pairs with a stackful, user-space **fiber scheduler** (`src/fiber/`) so async code can be written as straight-line, blocking-style handlers.

### Struct Definition

```zig
pub const IO = struct {
    /// Create an io_uring ring with `entries` submission slots.
    pub fn init(entries: u16, flags: u32) !IO
    pub fn deinit(self: *IO) void

    /// Drive the event loop for up to `nanoseconds` of monotonic time.
    pub fn run(self: *IO, nanoseconds: u64) !void

    /// Submit queued SQEs to the kernel, optionally blocking for `wait_nr` completions.
    pub fn submit(self: *IO, wait_nr: u32) !void

    /// Reap up to `wait_nr` completed CQEs.
    pub fn complete(self: *IO, wait_nr: u32) !void

    /// Run callbacks for every future that has completed.
    pub fn run_callback(self: *IO) !void

    /// Block until `future` completes and return its typed result.
    pub fn wait(self: *IO, future: *Future, comptime T: type) anyerror!T
};
```

### The Future Pattern (not callbacks)

Every asynchronous operation takes a preallocated `IO.Future`:

1.  Declare an `IO.Future` (on the stack or embedded in a struct).
2.  Call an operation function, passing the future by pointer.
3.  Either block on the result with `io.wait(&future, T)`, or drive the ring
    yourself with `io.submit` / `io.complete` / `io.run_callback` and poll
    `future.done`.
4.  Inside a fiber, `io.wait` parks the calling fiber instead of blocking the
    thread; the fiber resumes automatically when the future completes.

The engine supports `accept`, `close`, `connect`, `read`, `recv`, `send`,
`write`, `fsync`, `openat`, `statx`, `timeout`, `next_tick`, `send_to`, and
`recv_from`. Each operation stores its result in `future.result.<op>`.

```zig
const IO = glu.IO;

var compl: IO.Future = undefined;
try io.next_tick(&compl);
try io.wait(&compl, void);
```

### Cooperative AsyncIO Scheduling (`glu.fiber`, `glu.asyncio`)

The IO engine is paired with a stackful, user-space fiber scheduler in `src/fiber/`. Its API mirrors Python's `asyncio`:

*   `glu.fiber.Fiber` — a coroutine with its own stack (default 1 MiB). It holds
    a saved CPU context (`sp`/`fp`/`pc` on aarch64, `rsp`/`rbp`/`rip` on
    x86_64) switched entirely in user space via hand-written assembly. Fibers
    move through `READY`, `RUNNING`, `WAITING`, and `DEAD` states.
*   `glu.asyncio.AsyncIo` — the thread-local event loop. Each thread hosts at
    most one loop, which keeps an FCFS run-queue, the fiber currently
    executing, and the allocator/stack-size used when creating tasks.

#### Event Loop API

```zig
const glu = @import("glu");

// Bind (or reuse) the thread-local event loop for this thread.
const loop = glu.asyncio.get_event_loop();

// Check whether this thread hosts an event loop.
const maybe_loop: ?*glu.asyncio.AsyncIo = glu.asyncio.current();

// Schedule a fiber that runs `func(arg)` until it returns.
loop.create_task(func, arg);

// Run ready fibers until the queue drains.
loop.run_ready();

// Yield the running fiber to the loop (used internally by io.wait).
loop.yield();

// Move a WAITING fiber back to the ready queue.
loop.wake(fiber);
```

#### Awaiting IO from a fiber

When `io.wait(&future, T)` is called from inside a created fiber, it stashes
the fiber on the future (`future.wakeup_fiber`), yields it, and immediately
returns control to the loop. When the kernel completes the operation and
its callback fires, `Future.complete` re-queues the fiber, which resumes inside
`io.wait` and returns the typed result. Handlers therefore read like ordinary
sequential code.

`io.run(nanoseconds)` runs ready fibers on every loop iteration before it
submits SQEs and reaps CQEs (`loop.run_ready()` → `io.submit` → `io.complete` →
`io.run_callback`), so created fibers and the ring make progress together:

```zig
const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

const Ctx = struct {
    io: *IO,
    flag: *bool,
};

fn work(ctx: *Ctx) void {
    var future: IO.Future = undefined;
    ctx.io.next_tick(&future) catch return;
    ctx.io.wait(&future, void) catch return;
    ctx.flag.* = future.done;
}

pub fn main() !void {
    var io = try IO.init(16, 0);
    defer io.deinit();

    const loop = glu.asyncio.get_event_loop();
    var flag = false;
    var ctx = Ctx{ .io = &io, .flag = &flag };
    loop.create_task(work, &ctx);

    try io.run(10 * std.time.ns_per_ms);
    std.debug.assert(flag);
}
```

---

## 3. TCP Network Transport (`glu.tcp`)

`glu.tcp` provides TCP socket transport managed by the `io_uring` IO engine.

### Core Functions

#### `listen`
```zig
pub fn listen(io: *IO, port: u16, config: Config) !Server
```
*   **Description**: Starts a TCP server socket bound to `port` (pass `0` for an ephemeral port) and begins listening with backlog 128.
*   **Config**: `Config{ .host = "0.0.0.0", .nodelay = true }`. `host` controls the bind address — pass `"127.0.0.1"` (as the canonical demo does) to restrict a control channel to loopback; the transport has no built-in authentication or encryption.

#### `accept`
```zig
pub fn accept(io: *IO, future: *IO.Future, server: *Server) !void
```
-   **Description**: Enqueues an asynchronous accept operation.
-   **Await**: `io.wait(&future, posix.socket_t)` returns the accepted fd. Wrap it in a `Stream { .socket = fd, .handle = fd }`.

#### `connect`
```zig
pub fn connect(io: *IO, future: *IO.Future, host: []const u8, port: u16) !void
```
-   **Description**: Enqueues an async IPv4 connection to `host:port`. Await with `io.wait(&future, void)`. The connected socket is available at `future.operation.connect.socket`.
-   **Note**: IPv6 returns `error.AddressFamilyNotSupported`.

#### `send` / `receive` (on `Stream`)
```zig
pub fn send(io: *IO, future: *IO.Future, stream: *Stream, data: []const u8) !void
pub fn receive(io: *IO, future: *IO.Future, stream: *Stream, buffer: []u8) !void
```
-   **Description**: Async write/read on an accepted or connected stream.
-   **Await**: `io.wait(&future, usize)` returns the number of bytes sent/received. `receive` returns `0` on a clean disconnect.

`Stream` also exposes `write`/`read` methods that take an explicit offset for file-backed handles:

```zig
pub fn write(self: *Stream, io: *IO, future: *IO.Future, buf: []const u8) !void
pub fn read(self: *Stream, io: *IO, future: *IO.Future, buf: []u8) !void
```

#### Socket Options & Close
```zig
pub fn apply_socket_opts(fd: i32, config: Config) void
pub fn close(stream: *Stream) void
pub fn close_server(server: *Server) void
pub const Config = struct {
    nodelay: bool = true,
    quickack: bool = true,
    keepalive: bool = false,
    keepalive_idle: u32 = 7200,
    keepalive_interval: u32 = 75,
    keepalive_count: u32 = 9,
    recv_buf: ?i32 = null,
    send_buf: ?i32 = null,
    recv_timeout_ms: ?u32 = null,
    send_timeout_ms: ?u32 = null,
};
```

### Example: Async TCP Echo Server

```zig
const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

pub fn main() !void {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try glu.tcp.listen(&io, 9999, .{});
    defer glu.tcp.close_server(&server);

    std.debug.print("TCP echo server on :9999\n", .{});
    while (true) {
        var compl_accept: IO.Future = undefined;
        try glu.tcp.accept(&io, &compl_accept, &server);
        const sock = try io.wait(&compl_accept, std.posix.socket_t);

        glu.tcp.apply_socket_opts(sock, .{});
        var stream = glu.tcp.Stream{ .socket = sock, .handle = sock };
        defer glu.tcp.close(&stream);

        var compl_recv: IO.Future = undefined;
        var buf: [1024]u8 = undefined;
        try glu.tcp.receive(&io, &compl_recv, &stream, &buf);
        const n = try io.wait(&compl_recv, usize);
        if (n == 0) continue; // client disconnected

        var compl_send: IO.Future = undefined;
        try glu.tcp.send(&io, &compl_send, &stream, buf[0..n]);
        _ = try io.wait(&compl_send, usize);
    }
}
```

---

## 4. UDP Network Transport (`glu.udp`)

`glu.udp` provides async and multicast UDP operations managed by the `io_uring` IO engine.

### Core Functions

#### `bind`
```zig
pub fn bind(io: *IO, port: u16, config: SocketConfig) !Socket
```
*   **Description**: Binds a UDP socket to a local port (pass `0` to let the OS assign an ephemeral port).

#### `send_to`
```zig
pub fn send_to(
    io: *IO,
    future: *IO.Future,
    socket: Socket,
    host: []const u8,
    port: u16,
    data: []const u8
) !void
```
*   **Description**: Enqueues an async UDP datagram to `host:port`. Await with `io.wait(&future, usize)`.

#### `receive_from`
```zig
pub fn receive_from(io: *IO, future: *IO.Future, socket: Socket, buffer: []u8) !void
```
*   **Description**: Enqueues an async UDP receive into `buffer`. Await with `io.wait(&future, usize)` for the payload length; the sender address is at `future.operation.recv_from.address` (format it with `glu.net.address_to_endpoint`).

```zig
pub fn connect(io: *IO, future: *IO.Future, socket: Socket, host: []const u8, port: u16) !void
pub fn send(io: *IO, future: *IO.Future, socket: Socket, data: []const u8) !void
pub fn receive(io: *IO, future: *IO.Future, socket: Socket, buffer: []u8) !void
```

#### `join_multicast`
```zig
pub fn join_multicast(socket: Socket, group: []const u8) void
```
*   **Description**: Subscribes the socket to a multicast group (e.g. `"224.0.0.1"`).

#### `close`
```zig
pub fn close(socket: *Socket) void
```

### Example: Async UDP Receiver

```zig
const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

pub fn main() !void {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var sock = try glu.udp.bind(&io, 8888, .{});
    defer glu.udp.close(&sock);

    var buf: [1024]u8 = undefined;
    std.debug.print("UDP receiver on :8888\n", .{});
    while (true) {
        var compl_recv: IO.Future = undefined;
        try glu.udp.receive_from(&io, &compl_recv, sock, &buf);
        const n = try io.wait(&compl_recv, usize);
        const ep = glu.net.address_to_endpoint(compl_recv.operation.recv_from.address);
        std.debug.print("{d} bytes from {s}:{d}\n", .{ n, ep.host[0..ep.host_len], ep.port });
    }
}
```

---

## 5. Local Node Registry API (`glu.registry`)

`glu.registry` provides dynamic local discovery of active processes running in your robot environment.

#### `register`
```zig
pub fn register(name: []const u8) !void
```
*   **Description**: Registers the current process by name and writes its PID to `/tmp/glu/nodes/<name>.pid`.

```zig
pub fn register_pid(name: []const u8, pid: u32) !void
pub fn register_argv(name: []const u8, argv: []const []const u8) !void
```
*   `register_pid` writes an explicit PID (used by the launcher for children).
*   `register_argv` persists a node's spawn vector (NUL-separated) to `<name>.argv` so the node can be re-launched later.

#### Unregister
```zig
pub fn unregister(name: []const u8) void
```
*   **Description**: Removes the process registration PID file. Typically invoked via `defer`.

#### Lookup / Health
```zig
pub fn get_pid(name: []const u8) !?u32
pub fn is_alive(pid: u32) bool
pub fn proc_uptime(pid: u32) u64
```
*   `is_alive` uses `access(F_OK)` on `/proc/<pid>/status` — a sub-microsecond, privilege-free OS existence check.

#### List Alive Nodes
```zig
pub fn list_alive(entries: []NodeEntry) !usize
pub const NodeEntry = struct {
    name: [64]u8,
    name_len: u32,
    pid: u32,
    alive: bool,
    uptime: u64, // seconds since start, 0 if unknown
};
```
*   **Description**: Reads all `.pid` files under `/tmp/glu/nodes`, queries the OS to verify liveness, and fills `entries` up to its length.
*   **Returns**: The number of entries written. The caller provides the buffer (no allocation).

#### Example: Monitoring Nodes
```zig
const std = @import("std");
const glu = @import("glu");

pub fn main() void {
    glu.registry.register("my_monitor") catch {};
    defer glu.registry.unregister("my_monitor");

    var entry_buf: [128]glu.registry.NodeEntry = undefined;
    if (glu.registry.list_alive(&entry_buf)) |count| {
        for (entry_buf[0..count]) |node| {
            std.debug.print("Node: {s} (PID: {d}, Alive: {})\n", .{
                node.name[0..node.name_len], node.pid, node.alive,
            });
        }
    } else |err| {
        std.debug.print("list_alive failed: {s}\n", .{@errorName(err)});
    }
}
```
