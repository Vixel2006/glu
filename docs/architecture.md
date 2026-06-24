# architecture internals

if you've ever looked at a DDS specification, you've probably seen 500-page PDF documents detailing discovery protocols, dynamic type representations, and QoS policies. 

we don't do that here. `glu` keeps things simple. here is how it actually works.

---

## the memory layout

each topic is a single POSIX shared memory file mapped into RAM under `/dev/shm/<topic_name>`. we do not copy bytes over network sockets or pipe them through a broker process. it's just raw memory shared between processes.

the memory structure looks like this:

```
+-------------------------------------------------------+
|                       Header                          |
|  - magic (u32)        - write cursor (u32)            |
|  - connections (u32)  - msg_size / capacity (u32)     |
|  - topic name (64B)   - read cursors (8 x u32)        |
+-------------------------------------------------------+
|                      Slot 0                           |
|                      Slot 1                           |
|                        ...                            |
|                    Slot (N-1)                         |
+-------------------------------------------------------+
```

### the `Header` struct (120 bytes)
at offset 0 of the shared memory file sits a strict, packed `Header` layout:
- `magic`: `0x474C5500` (ASCII for `GLU\0`). if this isn't there, we don't touch the memory.
- `write`: the publisher's write cursor (monotonically increasing counter).
- `conns`: how many processes are currently mapped to this topic. when it hits 0, the last one to leave deletes the file from `/dev/shm`.
- `msg_size` & `capacity`: configuration parameters of the topic.
- `name`: the topic path (padded to 64 bytes to push read cursor indices past typical CPU cache line boundaries to prevent false sharing).
- `read`: an array of 8 integers representing the current read cursor of each active subscriber.

---

## lock-free coordination

`glu` does not use POSIX mutexes, semaphores, or condition variables. context switching to the kernel is too slow for high-rate robotics loops. instead, we coordinate publishers and subscribers using atomic operations.

### publishing a message:
1. the publisher checks if it is allowed to write to the next slot (see "slowest-reader protection" below).
2. if allowed, it writes the data into slot: `Slot = write % capacity`.
3. it updates the write cursor using atomic store with release semantics:
   ```zig
   @atomicStore(u32, &self.channel.header.write, self.channel.header.write + 1, .release);
   ```
   this ensures that the data write is fully completed and visible to other CPU cores before the cursor increments.

### subscribing to a message:
1. the subscriber reads its own read cursor `r = read[id]` and the publisher's write cursor `w = write` using acquire semantics.
2. if `r < w` (new data is available):
   - it fetches the slot at `r % capacity`.
   - it increments its read cursor atomically using acquire semantics:
     ```zig
     _ = @atomicRmw(u32, &self.channel.header.read[self.id], .Add, 1, .acquire);
     ```
3. if `r == w`, there is no new data. the subscriber receives `null` and yields/polls.

---

## slowest-reader protection

what happens if subscriber 0 is processing camera frames at 60Hz, but subscriber 1 gets stuck in a heavy neural network loop and drops to 2Hz? 

in a naive ring buffer, the publisher would overwrite slots, corrupting subscriber 1's read buffer. in `glu`, the publisher guarantees data integrity.

before writing a slot, the publisher checks:
```zig
write_cursor - slowestReader(read_cursors, write_cursor) >= capacity
```

if the difference is equal to or greater than the capacity, it means the fastest writer has caught up to the slowest active reader. writing now would overwrite unread data.

instead of corrupting data, the publisher enters a CPU spin loop hint:
```zig
while (write_cursor - slowest_reader >= capacity) {
    std.atomic.spinLoopHint();
}
```

the publisher spins until the slow reader completes its read and increments its cursor, freeing the slot. 

### what about inactive readers?
if a subscriber terminates or is not running, we don't want the publisher to block forever. 
when a subscriber calls `deinit()`, it sets its cursor in the header to `std.math.maxInt(u32)` (max u32). the `slowestReader` calculation ignores any cursor set to this value, meaning inactive subscribers never block the publisher. W.

---

## the file-based node registry

ROS2 uses DDS discovery (dynamic multicast over local network loopback), which takes seconds to resolve and is famous for failing entirely on office Wi-Fi.

`glu` does not use the network for local node discovery. active nodes register themselves under `/tmp/glu/nodes/`:
1. when a publisher or subscriber starts, it gets its own process path using `/proc/self/exe`, extracts its name, and writes its PID to `/tmp/glu/nodes/<node_name>.pid`.
2. when checking if a node is running (e.g. via `glu ps`), `glu` reads the PID from the file and checks if `/proc/<pid>/status` exists using a cheap OS access check.
3. when a node exits cleanly, it deletes its `.pid` file. if it crashes, the file remains, but the next health check realizes the PID is dead and ignores it.

no discovery daemons, no background threads eating memory. it just works.
