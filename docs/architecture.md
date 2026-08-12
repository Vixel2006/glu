# GLU Architecture & Internals

If you have ever looked at a DDS (Data Distribution Service) specification, you've probably faced hundreds of pages detailing dynamic discovery protocols, XML schemas, and complex Quality of Service (QoS) negotiation. 

`glu` rejects that complexity. It is designed to be simple, fast, and deterministic. This document explains exactly how it works under the hood.

---

## 1. Memory Layout

Each topic in `glu` maps to a single POSIX shared memory file located under `/dev/shm/`. All communicating processes on a topic map this segment directly into their virtual memory address spaces. No network loopback sockets or IPC message queues are involved.

The shared memory layout looks like this:

```
+-------------------------------------------------------+
|                    Header (168B)                      |
|  - magic (u32)        - write cursor (u32)            |
|  - connections (u32)  - msg_size / capacity (u32)     |
|  - tos (u32)          - name length & name (68B)      |
|  - owner_pid (u32)    - reader entries (8 x u64)      |
|    (PID + cursor packed per subscriber)               |
+-------------------------------------------------------+
|                      Slot 0                           |
|                      Slot 1                           |
|                        ...                            |
|                    Slot (N-1)                         |
+-------------------------------------------------------+
```

### The `Header` Struct (168 Bytes)
At the very beginning (offset 0) of the shared memory file sits a strictly laid-out `Header` structure:
*   `magic`: `0x474C5500` (ASCII for `GLU\0`). Used to verify that the segment is a valid `glu` channel.
*   `write`: The publisher's write cursor (monotonically increasing counter).
*   `conns`: The active connection count. The last process to close the segment unlinks the file from `/dev/shm/`.
*   `msg_size` & `capacity`: Setup options defined at topic creation.
*   `tos`: Type of Service (0 = `.reliable`, 1 = `.best_effort`).
*   `name`: The topic path name (up to 64 bytes). Pushed to align the reader entry array.
*   `owner_pid`: The PID of the process that created the segment (used to scope stale-segment cleanup).
*   `readers`: An array of 8 entries, each packing the owning subscriber's PID (high 32 bits) and read cursor (low 32 bits). A zero entry is an unclaimed slot; a subscriber claims one with a single atomic compare-and-swap.

---

## 2. Lock-Free Coordination

`glu` avoids using kernel mutexes, semaphores, or condition variables. Inter-process coordination is handled purely via CPU atomic instructions with acquire/release semantics.

### Publishing a Message (Zero-Copy)
1.  **Check Slots**: The publisher checks if writing the next message would overwrite unread data of any active subscriber (see "Slowest-Reader Backpressure").
2.  **Resolve Slot**: The publisher determines the target memory slot using `Slot = write % capacity`.
3.  **Retrieve Pointer**: The publisher returns the direct address of the slot to the user code. The user code populates it.
4.  **Atomic Release**: When committed, the publisher stores the incremented write cursor:
    ```zig
    @atomicStore(u32, &self.channel.header.write, self.channel.header.write + 1, .release);
    ```
    This ensures that the data write is fully completed and visible to other CPU cores before the cursor increments.

### Subscribing to a Message (Zero-Copy)
1.  **Read Cursors**: The subscriber reads its own read cursor `r = read[id]` and the publisher's write cursor `w = write` using acquire semantics:
    ```zig
    const entry = @atomicLoad(u64, &self.channel.header.readers[self.id], .acquire);
    const r: u32 = @truncate(entry); // low 32 bits = read cursor
    const w = @atomicLoad(u32, &self.channel.header.write, .acquire);
    ```
2.  **Consume**: If `r < w` (new data is available), the subscriber reads the slot directly from `/dev/shm/` by dereferencing the pointer to the slot.
3.  **Atomic Advance**: Once processed, the read cursor is incremented (keeping the PID in the high 32 bits untouched):
    ```zig
    // atomic compare-and-swap loop on the 64-bit reader entry,
    // advancing only the low 32 bits
    ```
4.  **No Data**: If `r == w`, the subscriber gets `null` and yields or polls.

---

## 3. Slowest-Reader Backpressure

What happens if a node publishing camera frames runs at 60Hz, but a heavy neural network subscriber runs at 2Hz? In a naive ring buffer, the publisher would wrap around and overwrite unread frames, corrupting data.

`glu` guarantees data integrity based on the `ToS` policy:

### Reliable Mode (`.reliable`)
Before writing to a slot, the publisher checks if the write cursor is catching up to the slowest active reader:
```zig
write_cursor - slowestReader(read_cursors) >= capacity
```
If this condition is met, writing would overwrite unread data. The publisher enters a spin loop hint to yield CPU execution:
```zig
while (write_cursor - slowest_reader >= capacity) {
    std.atomic.spinLoopHint();
}
```
This guarantees no data loss at the expense of slowing down the publisher.

### Best Effort Mode (`.best_effort`)
The publisher does not check reader positions. It immediately overwrites old slots. This is optimal for high-frequency, loss-tolerant sensor data (like IMU readings or odometry).

### Dead Subscriber Mitigation
To prevent a crashed or terminated subscriber from deadlocking the publisher forever:
*   When a subscriber calls `deinit()`, it clears its reader entry to zero, removing it from the slowest-reader calculation entirely.
*   On a `reliable` topic, the publisher's backpressure loop calls `sweep_dead_readers()` before spinning. Each reader entry packs its owning PID in the high 32 bits; `sweep_dead_readers` clears any entry whose PID is no longer alive (checked via `access` on `/proc/<pid>/status`). The clear uses a compare-and-swap against the observed value, so a slot reclaimed by a new subscriber in the meantime is never clobbered.

---

## 4. File-Based Node Discovery

Instead of heavy multicast discovery protocols that take seconds to resolve and pollute the local network, `glu` uses a super-fast, file-based node registry located under `/tmp/glu/nodes/`.

1.  **Register**: When a node is created, it writes its PID to a file named `/tmp/glu/nodes/<node_name>.pid`.
2.  **Verify Status**: To check if a node is running, `glu` reads the PID and performs a fast libc `access` check on `/proc/<pid>/status`. This check takes sub-microseconds and requires no network round-trips.
3.  **Unregister**: When a node shuts down cleanly, it deletes its `.pid` file. If it crashes, the file remains, but the next health check identifies that the PID is inactive and ignores it.

---

## 5. Cooperative Fiber Scheduler

Driving `io.submit` / `io.complete` / `io.run_callback` by hand is powerful but tedious. `glu` layers a **cooperative fiber scheduler** (`src/fiber/`) on top of the io_uring engine so async code reads like straightforward blocking code — without paying kernel context-switch costs.

### User-Space Context Switching

Each `Fiber` carries a `Fiber.Context` capturing the minimum register set needed to resume: the stack pointer, frame pointer, and program counter (`sp`/`fp`/`pc` on aarch64, `rsp`/`rbp`/`rip` on x86_64). A switch (`Fiber.context_switch`) is a hand-written assembly routine that saves the old context, loads the new one, and jumps — no `ucontext`, no signal handlers, no syscalls. The full caller-saved and vector register file is spilled, making the switch safe around arbitrary code, and unsupported architectures are rejected at compile time with `@compileError`. A switch costs tens of nanoseconds.

### Thread-Local Scheduling

A scheduler instance lives in thread-local storage (`tls_sched`): one scheduler per thread, created lazily with `sched.init()` and observable via `sched.try_current()`. It keeps:

*   an **FCFS run-queue** (`Queue(Fiber)`) of `READY` fibers,
*   a **current fiber** pointer (null while the scheduler itself runs),
*   its own saved context — the thread's execution state while fibers run,
*   the allocator and default stack size (1 MiB) used when spawning.

`spawn` allocates a fresh stack and a `Fiber`, seeds the context to jump into a shared `fiber_boot` thunk, and enqueues the fiber as `READY`. Stacks and fiber structs are freed by the scheduler when the fiber is reaped.

### Fiber Lifecycle

```
spawn --> READY --> RUNNING --> WAITING ------> READY --> ... --> DEAD
               ^                  |                                  |
               `-----------------`-------- woken by future completion
```

1.  `sched.drive()` dequeues the next `READY` fiber, marks it `RUNNING`, and context-switches into it (`fiber_boot` runs the fiber's function).
2.  When the fiber awaits IO, `io.wait` stashes the fiber on the future (`wakeup_fiber`), and `sched.park()` marks it `WAITING`, handing control back to the scheduler.
3.  When the kernel completes the operation, `run_callback` → `Future.complete` re-queues the fiber with `sched.wake()` (`WAITING` → `READY`).
4.  When the fiber's function returns, `fiber_boot` marks it `DEAD` and switches back to the scheduler, which frees its stack and struct.

### Driving the Loop

`io.run(nanoseconds)` binds scheduler and ring together:

```
while (running) {
    sched.drive();        // run any ready fibers
    io.submit(0);         // flush pending SQEs
    io.complete(1);       // block until at least one CQE resolves
    io.run_callback();    // complete futures -> wake parked fibers
}
```

`io.wait` makes the pair feel synchronous: inside a fiber it parks and resumes transparently; outside one it falls back to blocking the thread on the same ring.
