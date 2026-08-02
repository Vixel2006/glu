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
    *   `capacity`: Number of slots in the ring buffer (must be a power of two for optimal performance).
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
    var pub = try glu.Publisher.init("/sensor", @sizeOf(JointState), 1024, .reliable);
    defer pub.deinit();

    // Option A: Zero-Copy (Recommended for large data)
    const slot: *JointState = @ptrCast(@alignCast(pub.reserve()));
    slot.* = JointState{
        .seq = 1,
        .timestamp = std.time.milliTimestamp(), // or custom epoch
        .position = 1.57,
        .velocity = 0.1,
        .effort = 4.2,
    };
    pub.commit();

    // Option B: Publish by Copy
    const local_msg = JointState{
        .seq = 2,
        .timestamp = 0,
        .position = 1.58,
        .velocity = 0.0,
        .effort = 0.0,
    };
    pub.publish(@ptrCast(&local_msg));
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
*   **Description**: Attaches to the existing shared memory segment under the given topic name. It automatically finds an unused reader slot index (max 8 subscribers per topic) and registers the process PID.
*   **Returns**: An initialized `Subscriber` struct, or an error.

#### `deinit`
```zig
pub fn deinit(self: *Subscriber) void
```
*   **Description**: Marks the reader slot as inactive so the publisher no longer waits for it, closes the segment, and unmaps the memory.

#### `receive`
```zig
pub fn receive(self: *Subscriber) ?*anyopaque
```
*   **Description**: Non-blocking retrieve. Compares the subscriber's private read cursor against the publisher's global write cursor. If new data is available, it advances the cursor and returns a direct pointer to the slot.
*   **Returns**: An aligned pointer (`*anyopaque`) to the slot if a new message is available; otherwise, `null`.

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
    var sub = try glu.Subscriber.init("/sensor", @sizeOf(JointState), 1024);
    defer sub.deinit();

    while (true) {
        if (sub.receive()) |raw| {
            const msg: *JointState = @ptrCast(@alignCast(raw));
            std.debug.print("Received: seq={d}, pos={d:.2}\n", .{ msg.seq, msg.position });
        }
        sleepMs(10);
    }
}
```

---

## 2. Asynchronous I/O Engine (`glu.IO`)

`glu` includes a highly optimized asynchronous I/O engine powered by Linux `io_uring`. All network operations (`tcp` and `udp`) run on top of this engine.

### Struct Definition
```zig
pub const IO = struct {
    pub fn init(entries: u16, flags: u32) !IO
    pub fn deinit(self: *IO) void
    pub fn run(self: *IO, nanoseconds: u64) !void
    pub fn submit(self: *IO, wait_nr: u32) !void
    pub fn complete(self: *IO, wait_nr: u32) !void
    pub fn run_callback(self: *IO) !void
};
```

### The Callback Pattern
All asynchronous operations in `glu` accept:
1.  A pointer to `IO`.
2.  A generic `Context` type and a `context` pointer.
3.  A callback function that takes the context, a pointer to `IO.Completion`, and a tagged error union/result.
4.  A preallocated `IO.Completion` structure to hold operational state.

---

## 3. TCP Network Transport (`glu.tcp`)

`glu.tcp` provides TCP socket transport managed by the `io_uring` IO engine.

### Core Functions

#### `listen`
```zig
pub fn listen(io: *IO, port: u16, config: Config) !Server
```
*   **Description**: Starts a TCP server socket bound to the specified port and configures it to listen for connections.

#### `accept`
```zig
pub fn accept(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.AcceptError!Stream
    ) void,
    completion: *IO.Completion,
    server: *Server,
    comptime config: Config
) !void
```
*   **Description**: Enqueues an asynchronous accept request. When a client connects, the callback will be invoked with a `Stream` representation.

#### `connect`
```zig
pub fn connect(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.ConnectError!Stream
    ) void,
    completion: *IO.Completion,
    host: []const u8,
    port: u16,
    comptime config: Config
) !void
```
*   **Description**: Enqueues an asynchronous TCP connection request to a remote host.

#### `send` (Synchronous Helper)
```zig
pub fn send(io: *IO, stream: *Stream, data: []const u8) !void
```
*   **Description**: A helper function that writes the entire data buffer over TCP by synchronously driving the `io` completion loop until the write completes.

#### `receive` (Synchronous Helper)
```zig
pub fn receive(io: *IO, stream: *Stream, buffer: []u8) !usize
```
*   **Description**: A helper function that reads a framed message from the TCP stream into the buffer by synchronously driving the `io` completion loop.

#### Asynchronous Read and Write Methods (on `Stream`)
```zig
pub fn write(
    self: *Stream,
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.WriteError!usize
    ) void,
    completion: *IO.Completion,
    buf: []const u8
) !void
```
```zig
pub fn read(
    self: *Stream,
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.ReadError!usize
    ) void,
    completion: *IO.Completion,
    buf: []u8
) !void
```

---

### Example: Async TCP Server (Echo)

```zig
const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

const AppContext = struct {
    io: *IO,
    server: glu.tcp.Server,
    accept_compl: IO.Completion = undefined,
    stream: ?glu.tcp.Stream = null,
    read_compl: IO.Completion = undefined,
    write_compl: IO.Completion = undefined,
    buf: [1024]u8 = undefined,
};

pub fn main() !void {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var server = try glu.tcp.listen(&io, 9999, .{});
    defer glu.tcp.close_server(&server);

    var app = AppContext{ .io = &io, .server = server };

    try armAccept(&app);

    std.debug.print("TCP Echo Server listening on port 9999...\n", .{});
    while (true) {
        try io.run(10_000_000); // Drive the io_uring loop
    }
}

fn armAccept(app: *AppContext) !void {
    const cb = struct {
        fn call(ctx: *AppContext, _: *IO.Completion, res: IO.AcceptError!glu.tcp.Stream) void {
            var stream = res catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                return;
            };
            ctx.stream = stream;
            std.debug.print("Client connected!\n", .{});
            armRead(ctx) catch {};
        }
    }.call;
    try glu.tcp.accept(app.io, *AppContext, app, cb, &app.accept_compl, &app.server, .{});
}

fn armRead(app: *AppContext) !void {
    const cb = struct {
        fn call(ctx: *AppContext, _: *IO.Completion, res: IO.ReadError!usize) void {
            const n = res catch |err| {
                std.debug.print("Read error: {}\n", .{err});
                if (ctx.stream) |*s| glu.tcp.close(s);
                ctx.stream = null;
                armAccept(ctx) catch {};
                return;
            };
            if (n == 0) {
                std.debug.print("Client disconnected.\n", .{});
                if (ctx.stream) |*s| glu.tcp.close(s);
                ctx.stream = null;
                armAccept(ctx) catch {};
                return;
            }
            armWrite(ctx, n) catch {};
        }
    }.call;
    try app.stream.?.read(app.io, *AppContext, app, cb, &app.read_compl, &app.buf);
}

fn armWrite(app: *AppContext, len: usize) !void {
    const cb = struct {
        fn call(ctx: *AppContext, _: *IO.Completion, res: IO.WriteError!usize) void {
            _ = res catch {};
            armRead(ctx) catch {};
        }
    }.call;
    try app.stream.?.write(app.io, *AppContext, app, cb, &app.write_compl, app.buf[0..len]);
}
```

---

## 4. UDP Network Transport (`glu.udp`)

`glu.udp` provides asynchronous and multicast UDP network operations managed by the `io_uring` IO engine.

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
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.SendToError!usize
    ) void,
    completion: *IO.Completion,
    socket: Socket,
    host: []const u8,
    port: u16,
    data: []const u8
) !void
```
*   **Description**: Sends a UDP datagram to a remote target asynchronously.

#### `receive_from`
```zig
pub fn receive_from(
    io: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (
        context: Context,
        completion: *IO.Completion,
        result: IO.RecvFromError!ReceiveResult
    ) void,
    completion: *IO.Completion,
    socket: Socket,
    buffer: []u8
) !void
```
*   **Description**: Enqueues an asynchronous request to receive a UDP datagram. The callback is invoked with a `ReceiveResult` struct containing `data: []u8` (sub-slice of `buffer`) and `sender: net.Endpoint`.

#### `join_multicast`
```zig
pub fn join_multicast(socket: Socket, group: []const u8) void
```
*   **Description**: Subscribes the socket to a multicast group (e.g. `"224.0.0.1"`).

---

### Example: Async UDP Echo Client / Server

```zig
const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

const UdpAppContext = struct {
    io: *IO,
    socket: glu.udp.Socket,
    recv_compl: IO.Completion = undefined,
    send_compl: IO.Completion = undefined,
    buf: [1024]u8 = undefined,
};

pub fn main() !void {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var sock = try glu.udp.bind(&io, 8888, .{});
    defer glu.udp.close(&sock);

    var app = UdpAppContext{ .io = &io, .socket = sock };
    try armRecv(&app);

    std.debug.print("UDP Receiver listening on port 8888...\n", .{});
    while (true) {
        try io.run(10_000_000);
    }
}

fn armRecv(app: *UdpAppContext) !void {
    const cb = struct {
        fn call(ctx: *UdpAppContext, _: *IO.Completion, res: IO.RecvFromError!glu.udp.ReceiveResult) void {
            const result = res catch |err| {
                std.debug.print("UDP receive error: {}\n", .{err});
                return;
            };

            std.debug.print("Received {d} bytes from {s}:{d}: {s}\n", .{
                result.data.len,
                result.sender.host[0..result.sender.host_len],
                result.sender.port,
                result.data,
            });

            // Echo back to sender
            ctx.io.submit(0) catch {};
            glu.udp.send_to(
                ctx.io,
                *UdpAppContext,
                ctx,
                struct {
                    fn sendCb(s_ctx: *UdpAppContext, _: *IO.Completion, s_res: IO.SendToError!usize) void {
                        _ = s_res catch {};
                        armRecv(s_ctx) catch {};
                    }
                }.sendCb,
                &ctx.send_compl,
                ctx.socket,
                result.sender.host[0..result.sender.host_len],
                result.sender.port,
                result.data,
            ) catch {
                armRecv(ctx) catch {};
            };
        }
    }.call;
    try glu.udp.receive_from(app.io, *UdpAppContext, app, cb, &app.recv_compl, app.socket, &app.buf);
}
```

---

## 5. Local Node Registry API (`glu.registry`)

`glu.registry` provides dynamic local discovery of active processes running in your robot environment.

#### `register`
```zig
pub fn register(name: []const u8) !void
```
*   **Description**: Registers the current process name and writes its PID to `/tmp/glu/nodes/<name>.pid`.

#### `unregister`
```zig
pub fn unregister(name: []const u8) void
```
*   **Description**: Removes the process registration PID file. Typically called via `defer`.

#### `list_alive`
```zig
pub fn list_alive(allocator: std.mem.Allocator) ![]NodeEntry
```
*   **Description**: Reads all `.pid` files under `/tmp/glu/nodes`, queries the OS to verify if the process is alive, and returns a list of active nodes.
*   **Returns**: An allocated slice of `NodeEntry` structs. The caller must free each entry's `name` string and the slice.

#### Example: Monitoring Nodes
```zig
const std = @import("std");
const glu = @import("glu");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    try glu.registry.register("my_monitor");
    defer glu.registry.unregister("my_monitor");

    const nodes = try glu.registry.list_alive(allocator);
    defer {
        for (nodes) |n| allocator.free(n.name);
        allocator.free(nodes);
    }

    for (nodes) |node| {
        std.debug.print("Node: {s} (PID: {d}, Alive: {})\n", .{ node.name, node.pid, node.alive });
    }
}
```
