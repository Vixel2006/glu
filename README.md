
 <p align="center">
<pre>
 ██████╗ ██╗     ██╗   ██╗
██╔════╝ ██║     ██║   ██║
██║  ███╗██║     ██║   ██║
██║   ██║██║     ██║   ██║
╚██████╔╝███████╗╚██████╔╝
 ╚═════╝ ╚══════╝ ╚═════╝
</pre>
</p>

<p align="center">
  <b>glu</b> — blazingly fast, lock-free, zero-copy robot middleware in Zig.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-0.16.0-%23F7A41D.svg?style=flat-square&logo=zig&logoColor=white" alt="Zig Version" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Status" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square" alt="PRs Welcome" />
</p>

<p align="center">
  <a href="docs/INDEX.md"><b>Documentation</b></a> •
  <a href="#key-features">Key Features</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#quickstart">Quickstart</a> •
  <a href="#cli-reference">CLI Reference</a> •
  <a href="#performance--benchmarks">Benchmarks</a> •
  <a href="#contributing">Contribute</a>
</p>

---

`glu` is a high-performance, developer-friendly robot middleware built on POSIX shared memory (`/dev/shm`). It enables zero-copy, lock-free message passing between local processes with sub-microsecond latency. You pass packed or extern Zig structures directly—no serialization overhead, no transport layer copies, and no CPU cycles wasted.

---

## Key Features

* **Lockless Zero-Copy IPC**: Shared memory ring buffers managed with atomic release-acquire memory ordering. Zero stack copying or serialization.
* **Reliability Policies**: Configurable Type of Service (`ToS`). Supports `.reliable` backpressure (publisher spins on the slowest reader to guarantee no data loss) and `.best_effort` (publisher immediately overwrites old slots).
* **Sub-Millisecond Registry**: File-based node registration using `/tmp/glu/nodes/`. Cheap, local checks utilizing OS-level existence APIs—no discovery daemon.
* **Async TCP/UDP Networking**: Built-in network transport APIs integrated with a highly optimized `io_uring` asynchronous I/O engine.
* **Cooperative Fiber Scheduling**: `src/fiber/` bundles a user-space coroutine scheduler (x86_64 & aarch64). Spawn fibers onto the thread-local scheduler and `io.wait` parks them in place — async code reads like blocking code with no kernel context switches.
* **Integrated Orchestrator**: Run entire node ecosystems using a simple TOML configuration. Manage logging, signaling, and diagnostics from the command line.

---

## How It Works

Each topic is backed by a POSIX shared memory file mapped into each node's address space.

```
                 +------------------------------------------------------+
                 |               POSIX Shared Memory Segment            |
                 |                     (/dev/shm/topic)                 |
                 |                                                      |
                 |  +--------------------+---------------------------+  |
                 |  |    Header (168B)   |       Ring Buffer         |  |
                 |  |                    |                           |  |
                 |  |  Write Cursor (W)  |  +------+------+------+   |  |
+-----------+    |  |  Read Cursors:     |  |Slot 0|Slot 1|Slot 2|   |  |  +------------+
| Publisher |--->|  |    Sub 0: R0       |  +------+------+------+   |  |->| Subscriber |
+-----------+    |  |    Sub 1: R1       |  |  T   |  T   |  T   |   |  |  +------------+
  [Zero-Copy]    |  |                    |  +------+------+------+   |  |    [Zero-Copy]
  Writes via     +------------------------------------------------------+    Reads via
  .reserve() &   |  * Write blocks if (W - slowest(R0, R1) >= Capacity) |    .receive()
  .commit()      +------------------------------------------------------+
```

*   **Header (168 Bytes)**: Stores operational metadata, active connections, Type of Service, the segment owner's PID, and subscriber reader entries. Each entry packs the subscriber PID and read cursor into one 64-bit word, so a slot is claimed with a single atomic operation.
*   **Write**: The publisher claims slot `W % capacity`, writes fields directly, and atomically increments the write cursor.
*   **Read**: Each subscriber reads from its own reader index. If the subscriber's cursor lags behind the write cursor, it reads directly from the slot.

Async I/O — TCP, UDP, file access, and timers — runs on a single `io_uring` ring per thread. On top of that ring sits a cooperative fiber scheduler (`src/fiber/`): fibers are lightweight user-space coroutines with their own stacks. Calling `io.wait` inside a fiber parks it until the future completes; `io.run` drives both the ready fibers and the ring in one tight loop.

---

## Install the CLI

```bash
# Clone the repository and build the binary
zig build

# Symlink into your local bin path
ln -sf "$(pwd)/zig-out/bin/glu" ~/.local/bin/glu

# Verify execution
glu --help
```

---

## Quickstart

### 1. Add glu to your project
Run `zig fetch` to download and reference `glu` in your dependencies:
```bash
zig fetch --save https://github.com/Vixel2006/glu/archive/refs/tags/v0.2.0.tar.gz
```

Add the module to your target executable in your `build.zig`:
```zig
const glu = b.dependency("glu", .{
    .target = target,
    .optimize = optimize,
}).module("glu");

exe.root_module.addImport("glu", glu);
```

### 2. Define a Message Type
Message structures should be marked as `extern struct` or `packed struct` to guarantee exact layout:
```zig
const Telemetry = extern struct {
    seq: u32,
    temperature: f32,
    humidity: f32,
};
```

### 3. Publish
```zig
const std = @import("std");
const glu = @import("glu");

const Telemetry = extern struct {
    seq: u32,
    temperature: f32,
    humidity: f32,
};

pub fn main() !void {
    // Initialize a reliable publisher with a capacity of 1024 slots
    var publisher = try glu.Publisher.init("/telemetry", @sizeOf(Telemetry), 1024, .reliable);
    defer publisher.deinit();

    // Option A: Publish by Copy
    const msg = Telemetry{ .seq = 0, .temperature = 24.5, .humidity = 45.0 };
    publisher.publish(@ptrCast(&msg));

    // Option B: Zero-Copy (Direct write into the shared memory slot)
    const slot: *Telemetry = @ptrCast(@alignCast(publisher.reserve()));
    slot.* = Telemetry{
        .seq = 1,
        .temperature = 24.6,
        .humidity = 45.2,
    };
    publisher.commit();
}
```

### 4. Subscribe
```zig
const std = @import("std");
const glu = @import("glu");

const Telemetry = extern struct {
    seq: u32,
    temperature: f32,
    humidity: f32,
};

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub fn main() !void {
    // Initialize a subscriber (automatically joins the channel)
    var subscriber = try glu.Subscriber.init("/telemetry", @sizeOf(Telemetry), 1024);
    defer subscriber.deinit();

    while (true) {
        if (subscriber.peek()) |raw| {
            const msg: *Telemetry = @ptrCast(@alignCast(raw));
            std.debug.print("Received: seq={d}, temp={d:.2}°C, hum={d:.1}%\n", .{
                msg.seq, msg.temperature, msg.humidity,
            });
            subscriber.ack();
        }
        sleepMs(10);
    }
}
```

### 5. Orchestrate Nodes
Create a `launch.toml` to manage multiple processes:
```toml
[[node]]
name = "sensor"
bin  = "zig-out/bin/sensor_node"

[[node]]
name = "controller"
bin  = "zig-out/bin/controller_node"
```

Start the node system using the process runner:
```bash
glu launch -f launch.toml
```

### 6. Showcase: Robot Control Room

`examples/canonical` is a full robot-control-room demo that exercises every
`glu` capability — shared-memory pub/sub (reliable and best-effort QoS),
multicast and unicast UDP, bidirectional TCP, io_uring timers, async file I/O,
the node registry, and CLI-driven orchestration.

Build the four nodes and launch them:

```bash
zig build examples
glu launch -f examples/canonical/launch.toml -d
```

| Node | Role | What it demonstrates |
| :--- | :--- | :--- |
| `sensor_arm` | telemetry producer | zero-copy `reserve`/`commit` at 100 Hz, one-shot `publish`, UDP heartbeat |
| `coordinator` | fusion + control | multi-subscribe, raw `glu.write` on a **best-effort** log topic, UDP multicast `join_multicast` + `receive_from`, io_uring `timeout` pacing |
| `operator` | human-in-the-loop | second subscriber (slowest-reader backpressure), **bidirectional TCP** server, UDP discovery, `registry.list_alive` node table |
| `logger` | persistence | raw `glu.peek`/`glu.ack` on the best-effort topic, async `io.openat`/`write`/`fsync` → `telemetry.log` |

Topics: `/robot/joint_states`, `/robot/health`, `/robot/fused`,
`/robot/command`, `/robot/logs`.

Drive the robot from a terminal — the operator listens on TCP `:9998`:

```bash
printf 'torque 2.5\n' | nc 127.0.0.1 9998   # or: home / velocity <n> / stop
```

Inspect the live system while it runs:

```bash
glu nodes list               # registered nodes + liveness   (alias: glu ps)
glu topics list              # topics in /dev/shm with queue depth
glu topics info /robot/joint_states   # per-subscriber lag (see the backpressure)
glu nodes logs operator      # tail a detached node's output (alias: glu logs)
glu nodes down               # stop everything               (alias: glu down)
```

---

## CLI Reference

Commands are grouped into a tree: `glu nodes ...` manages processes,
`glu topics ...` inspects shared-memory channels, and `glu status` /
`glu launch` live at the top level. Legacy flat names still work as aliases.

```
usage: glu <command> [args]

commands:
  status   Overview of nodes and topics
  launch   Launch nodes from a TOML config file
           glu launch -f <file.toml> [-d]

  nodes    Manage node processes
           glu nodes list
           glu nodes start <node> [node...]
           glu nodes stop <node> [node...]
           glu nodes restart <node> [node...]
           glu nodes logs [--tail <n>] [--head <n>] <node>
           glu nodes down [node...]

  topics   Inspect shared-memory topics
           glu topics list
           glu topics info <topic>

run 'glu help <command>' for usage
```

---

## Performance & Benchmarks

A dedicated benchmark harness is being rebuilt (the previous `bench/` harness
was removed). Results below are from a previous internal run on an Intel Core
i5, 100k iterations (ReleaseFast); the raw history lives in
`.benchmarks/history/`:

| Operation | Latency | Notes |
| :--- | :--- | :--- |
| `channel write 32B-4096B` | **~18 ns** | Zero-copy write directly to POSIX shared memory |
| `channel read 32B` | **~25 ns** | Zero-copy pointer dereference from shared memory |
| `publisher publish` | **~18 ns** | Single copy-into-ring buffer operation |
| `subscriber receive` | **~25 ns** | Read check and atomic write cursor alignment |
| `node creation` | **~5 µs** | Node startup (`shm_open` + `mmap` initialization) |

---

## Contributing

We welcome contributions! Please review [CONTRIBUTING.md](./CONTRIBUTING.md) for coding styles, development setups, and our pull request checklist.

---

<p align="center">
  <sub>
    <a href="https://ziglang.org">Zig</a> — robots deserve better.
  </sub>
</p>
