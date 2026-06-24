# api reference

One of the main missions of glu is to give developers the most intuitive api possible, we know that glu is just the communication layer between your main drivers logic, so we try to make glu very easy and fast to integrate so that you can work on what's important.

---

## `glu.Publisher`

the publisher manages writing messages into a topic's shared memory segment. 

### 1. initialization & cleanup

```zig
pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) !Publisher
```
- **what it does**: creates (or opens) the shared memory channel at `/dev/shm/<name>`, maps it to your process address space, and registers your node under `/tmp/glu/nodes`.
- **deletes stale shm**: if a previous run crashed and left an old shared memory file hanging, `init` automatically unlinks it first so you start with fresh, uncorrupted memory. based.
- **parameters**:
  - `allocator`: standard allocator for string duplication.
  - `name`: the topic path (must start with a slash, e.g. `/camera/image`).
  - `msg_size`: the size of your message struct in bytes (`@sizeOf(T)`).
  - `capacity`: number of slots in the ring buffer. make it a power of two for optimal index wrapping calculations.

```zig
pub fn deinit(self: *Publisher) void
```
- **what it does**: unregisters your node's PID, unmaps the memory, closes the file descriptors, and automatically cleans up `/dev/shm` if you are the last node standing on this topic.

---

### 2. writing data

you have two ways to publish. one is simple, the other is also simple but faster.

#### option A: publish by copy (e.g. for simple things)
```zig
pub fn publish(self: *Publisher, comptime T: type, msg: *const T) void
```
- **how it works**: you pass a pointer to a local struct. `glu` waits until a slot is free, copies the struct directly into shared memory, and atomically increments the write cursor.
- **use case**: great for quick prototyping or small structs where copying doesn't impact performance.

```zig
// example
const msg = msgs.Status{ .ok = true, .uptime = 42 };
publisher.publish(msgs.Status, &msg);
```

#### option B: zero-copy reserve & commit (the performance peak)
```zig
pub fn reserve(self: *Publisher, comptime T: type) *T
```
- **how it works**: instead of creating a struct locally and copying it, `reserve` waits for the next free slot in shared memory and returns a direct, aligned pointer to that memory slot. you write your fields directly into the shared memory segment.
- **zero copies**: zero CPU cycles spent copying bytes. zero stack allocation.

```zig
pub fn commit(self: *Publisher) void
```
- **how it works**: once you have finished filling the fields of your reserved slot, call `commit()`. this atomically increments the write cursor, making the slot visible to subscribers.

```zig
// example
const slot = publisher.reserve(msgs.LargePointCloud);
// write directly into shared memory!
slot.timestamp = std.time.milliTimestamp();
slot.points[0] = Point{ .x = 1.0, .y = 2.0, .z = 3.0 };
// ... fill in other points ...

publisher.commit(); // done, go read it subs!
```

---

## `glu.Subscriber`

the subscriber listens to messages on a topic.

### 1. initialization & cleanup

```zig
pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, msg_size: u32, capacity: u32) !Subscriber
```
- **what it does**: connects to the existing shared memory segment, registers your reader slot, and writes your PID to the active node registry.
- **parameters**:
  - `id`: your unique subscriber index (integer from `0` to `7`). each process subscribing to the same topic needs its own ID. 
  - `name`: the topic path (must match the publisher, e.g., `/camera/image`).
  - `msg_size`: the size of your message struct.
  - `capacity`: the capacity of the publisher's ring buffer (must match the publisher's capacity).

```zig
pub fn deinit(self: *Subscriber) void
```
- **what it does**: updates the reader array to mark this subscriber ID as inactive (by setting its cursor to `std.math.maxInt(u32)`). this tells the publisher to stop waiting for this subscriber. then it unmaps the memory and closes file handles.

---

### 2. reading data

```zig
pub fn receive(self: *Subscriber, comptime T: type) ?*T
```
- **how it works**: checks if the subscriber's private read cursor is behind the publisher's write cursor. 
  - if there is a new message: atomically advances the read cursor and returns a direct pointer to the data inside the shared memory segment (no serialization/deserialization, no copies!).
  - if no new message: returns `null` immediately.
- **non-blocking**: `receive` never blocks. if there is no data, you get `null`. you control the polling frequency or your own sleep duration.

```zig
// example
while (true) {
    if (subscriber.receive(msgs.Status)) |msg| {
        if (!msg.ok) std.debug.print("system down! panic!", .{});
    }
    std.time.sleep(10 * std.time.ns_per_ms);
}
```
