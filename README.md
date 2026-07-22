<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/glu.png">
    <img src="assets/glu.png" alt="glu" width="96">
  </picture>
</p>

<p align="center">
  <b>glu</b> — lock-free IPC for robotics, written in Zig.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-%23F7A41D.svg?style=flat-square&logo=zig&logoColor=white" alt="Zig" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Alpha" />
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

glu is a robotics communication middleware built on POSIX shared memory. It provides zero-copy, lock-free message passing between processes with deterministic latency. Pass any packed Zig struct directly — no serialization framework, no protocol overhead, just direct memory access.

---

## Key Features

- **Lockless Zero-Copy IPC**: `shm_open` / `mmap` ring buffers. Publishers write directly into shared memory slots; subscribers read by pointer dereference. No serialization, no syscall on each transfer, no copies.
- **Slowest-Reader Backpressure**: Up to 8 subscribers per topic with independent read cursors. The publisher spins on the slowest reader before overwriting — guaranteed no data loss without allocating.
- **Sub-ms Registration & Discovery**: Nodes register under `/tmp/glu/nodes` by PID. No discovery daemon, no multicast, no seconds-long spin-up.
- **TCP/UDP Networking**: Socket APIs (`glu.tcp`, `glu.udp`) for cross-machine streams and telemetry. Raw sockets, no framing overhead.
- **Process Orchestrator**: `glu launch` reads a TOML config and manages the node lifecycle — spawn, monitor, signal, log.

---

## How It Works

Each topic is a POSIX shared memory segment at `/dev/shm/topic` mapped as a ring buffer with capacity `N`.

```
                 +------------------------------------------------------+
                 |               POSIX Shared Memory Segment            |
                 |                     (/dev/shm/topic)                 |
                 |                                                      |
                 |  +--------------------+---------------------------+  |
                 |  |       Header       |       Ring Buffer         |  |
                 |  |                    |                           |  |
                 |  |  Write Cursor (W)  |  +------+------+------+   |  |
+-----------+    |  |  Read Cursors:     |  |Slot 0|Slot 1|Slot 2|   |  |  +------------+
| Publisher |--->|  |    Sub 0: R0       |  +------+------+------+   |  |->| Sub 0 (R0) |
+-----------+    |  |    Sub 1: R1       |  |  T   |  T   |  T   |   |  |  +------------+
  [Zero-Copy]    |  |                    |  +------+------+------+   |  |    [Zero-Copy]
  Writes via     +------------------------------------------------------+    Reads via
  .publish() or  |  * Write blocks if (W - slowest(R0, R1) >= Capacity) |    .receive()
  .reserve()     +------------------------------------------------------+
```

### Multi-Subscriber Ring Buffer

The segment starts with a `Header` containing the write cursor and an array of read cursors (one per subscriber, max 8):

- **Publish**: the message is written to `slot = write % capacity`, then the write cursor advances.
- **Subscribe**: each subscriber holds a slot ID (0–7) and reads from its own read index.
- **Backpressure**: if the publisher's next slot hasn't been read by the slowest subscriber, it spins (`std.atomic.spinLoopHint()`) until that slot is free.

---

## Install the CLI

```bash
# Build the glu binary
zig build

# Symlink into ~/.local/bin (most distros include this in $PATH by default)
ln -sf "$(pwd)/zig-out/bin/glu" ~/.local/bin/glu

# Verify it works
glu --help
```

If `~/.local/bin` isn't on your `$PATH`, add this line to your `~/.bashrc` or `~/.zshrc` instead:
```bash
export PATH="$PATH:/home/vixel/code/glu/zig-out/bin"
```

---

## Quickstart

### 1. Add glu to your project

```bash
zig fetch --save https://github.com/Vixel2006/glu/archive/refs/<enter-glu-version>.tar.gz
```

In your `build.zig`:

```zig
const glu = b.dependency("glu", .{
    .target = target,
    .optimize = optimize,
}).module("glu");

exe.root_module.addImport("glu", glu);
```

### 2. Define a message type

```zig
const Telemetry = extern struct {
    seq: u32,
    timestamp: i64,
    temperature: f32,
    pressure: f32,
    humidity: f32,
    altitude: f32,
};
```

### 3. Publish

```zig
const std = @import("std");
const glu = @import("glu");

const Telemetry = extern struct {
    seq: u32,
    timestamp: i64,
    temperature: f32,
    pressure: f32,
    humidity: f32,
    altitude: f32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var publisher = try glu.Publisher.init(allocator, "/telemetry", @sizeOf(Telemetry), 4096);
    defer publisher.deinit();

    // Copy a struct into the ring buffer
    const msg = Telemetry{
        .seq = 0,
        .timestamp = std.time.milliTimestamp(),
        .temperature = 24.5,
        .pressure = 1013.25,
        .humidity = 45.0,
        .altitude = 120.0,
    };
    publisher.publish(Telemetry, &msg);

    // Zero-copy: write directly into the reserved shared-memory slot
    const slot = publisher.reserve(Telemetry);
    slot.* = Telemetry{
        .seq = 1,
        .timestamp = std.time.milliTimestamp(),
        .temperature = 24.6,
        .pressure = 1013.24,
        .humidity = 45.2,
        .altitude = 120.1,
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
    timestamp: i64,
    temperature: f32,
    pressure: f32,
    humidity: f32,
    altitude: f32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var subscriber = try glu.Subscriber.init(allocator, "/telemetry", @sizeOf(Telemetry), 4096, 0);
    defer subscriber.deinit();

    while (true) {
        if (subscriber.receive(Telemetry)) |msg| {
            std.debug.print("seq={d}, temp={d:.2}°C, alt={d:.1}m\n", .{
                msg.seq, msg.temperature, msg.altitude,
            });
        }
        std.time.sleep(std.time.ns_per_ms);
    }
}
```

### 5. Launch nodes

Define a `launch.toml`:

```toml
[[node]]
name = "sensor"
bin  = "zig-out/bin/sensor_node"

[[node]]
name = "controller"
bin  = "zig-out/bin/controller_node"
```

```bash
glu launch -f launch.toml
```

---

## CLI Reference

```bash
usage: glu <command> [args]

commands:
  launch   Launch nodes from a TOML config file
           glu launch -f <file.toml> [-d]

  list     List active topics in shared memory
           glu list

  info     Show detailed info about a topic
           glu info <topic>

  ps       List registered nodes
           glu ps

  logs     View a node's log output
           glu logs [--tail <n>] [--head <n>] <node>

  down     Stop all running nodes
           glu down
```

### Launch nodes
```bash
glu launch -f launch.toml
```
Spawns defined nodes as child processes. Use `-d` for detached background daemons.

### List active topics
```bash
glu list
glu ls
```
Lists all active topics in shared memory.

### Inspect a topic
```bash
glu info /telemetry
```
Shows topic diagnostics: slot size, write cursor, subscriber count, read cursors, capacity.

### Show running nodes
```bash
glu ps
```
Lists registered nodes from `/tmp/glu/nodes` with PID and live status.

### View node logs
```bash
glu logs <node>
glu logs --tail 50 <node>
glu logs --head 20 <node>
```
Prints last 10 lines by default. Output capped at 4096 bytes.

### Graceful teardown
```bash
glu down
```
Sends termination signals to all registered nodes.

---

## Performance & Benchmarks

```bash
zig build bench
```

Results on Intel Core i5, 100k iterations (ReleaseFast):

| Operation | Time | Notes |
| :--- | :--- | :--- |
| `channel write 32B–4096B` | **~18 ns** | Zero-copy write to POSIX shared memory |
| `channel read 32B` | **~18 ns** | Pointer dereference from shared memory |
| `publisher publish` | **~18 ns** | Publisher wrapping write |
| `subscriber receive` | **~18 ns** | Cursor alignment, check, and read |
| `node creation` | **~5 µs** | `shm_open` + `mmap` setup |

---

## Contributing

Read [CONTRIBUTING.md](./CONTRIBUTING.md) for the setup guide, coding style, PR process, and where to start.

---

<p align="center">
  <sub>
    <a href="https://ziglang.org">Zig</a> — robots deserve better.
  </sub>
</p>
