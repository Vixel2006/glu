<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/glu.png">
    <img src="assets/glu.png" alt="glu" width="96">
  </picture>
</p>

<p align="center">
  <b>glu</b> — a blazingly fast, zero-dependency robot middleware.
  <br>
  <i>No bloat. No DDS taxes. Just clean, lock-free, real-time communication.</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-%23F7A41D.svg?style=flat-square&logo=zig&logoColor=white" alt="Zig" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT" />
  <img src="https://img.shields.io/badge/status-alpha-orange?style=flat-square" alt="Alpha" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square" alt="PRs Welcome" />
</p>

<p align="center">
  <a href="docs/INDEX.md"><b>Documentation</b></a> •
  <a href="#the-vision">The Vision</a> •
  <a href="#key-features">Key Features</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#quickstart">Quickstart</a> •
  <a href="#cli-reference">CLI Reference</a> •
  <a href="#performance--benchmarks">Benchmarks</a> •
  <a href="#ecosystem">Ecosystem</a> •
  <a href="#contributing">Contribute</a>
</p>

---

**glu** is a next-generation communication protocol and middleware for robotics, written from scratch in [Zig](https://ziglang.org/). It is designed to replace the corporate bloat of ROS2 with what a real-time robot actually needs: deterministic, ultra-low-latency, zero-copy message passing between local processes—nothing more, nothing less.

ROS2 is the past. **glu is the glow-up.**

---

## The Vision

The robotics community has struggled with ROS2 for years. Between massive Docker images, sluggish DDS discovery, flaky Wi-Fi multicast, and compile times that drag on forever, building robotic systems has become an exercise in managing toolchain pain.

`glu` is built on a simple premise: **Robotics middleware should be a protocol, not an operating system.**

| Feature / Pain Point | ROS2 | glu |
| :--- | :--- | :--- |
| **Dependencies** | Gigabytes of runtime and build-time packages | **Zero** runtime dependencies |
| **Binary Size** | Monolithic installation (>2GB) | Single standalone binary (~2MB) |
| **Discovery Latency** | DDS discovery taking seconds (or failing) | **Sub-millisecond** file-based discovery |
| **Latency / Overhead** | Heavy serialization, copy-on-write, context-switches | **Zero-copy** lock-free POSIX Shared Memory |
| **Build System** | `colcon` + `ament` + `cmake` (sequential and slow) | Native `zig build` (fast, parallel, caching) |
| **Version Lock-in** | ROS version strict-bound to Ubuntu versions | OS-agnostic (runs anywhere with POSIX & libc) |
| **Embedded Support** | Hostile to microcontrollers and RTOS | Lightweight & friendly for ARM/POSIX targets |

---

## Key Features

- **Lockless Zero-Copy IPC**: Shared memory rings using `shm_open` and `mmap` let publishers write directly to memory slots, and subscribers read directly from them—no serialization, no syscall context switches, and no copies.
- **Slowest-Reader Protection**: Up to 8 concurrent subscribers per topic can read independently. If a subscriber runs slow, the publisher spins rather than overwriting unread slots, guaranteeing zero data loss.
- **Sub-ms Registry & Discovery**: No heavy discovery daemon or network multicasting. Active nodes are registered deterministically under `/tmp/glu/nodes` using their PID.
- **TCP/UDP Networking**: First-class socket APIs (`glu.tcp` and `glu.udp`) for cross-machine communication, telemetry streaming, and node discovery — no bloat, just raw sockets.
- **Integrated Process Orchestrator**: Run and manage your robot nodes gracefully via `glu launch` using simple TOML configuration files.

---

## How It Works

`glu` models communication using POSIX shared memory segments. Each topic corresponds to a unique file under `/dev/shm` acting as a ring buffer of capacity $N$.

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
The channel's memory begins with a `Header` containing metadata, the current `write` cursor, and an array of `read` cursors for up to 8 subscribers:
- When a publisher publishes, it copies the message into `Slot = write % capacity` and increments the write cursor.
- Subscribing processes register a subscriber ID ($0$ to $7$). When reading, they retrieve the slot matching their individual `read` index.
- If the publisher tries to write to a slot that has not yet been processed by the slowest reader, it will perform a spin loop (`std.atomic.spinLoopHint()`) until the slot becomes free.

---

## Install the CLI

To use `glu` as a global command (just type `glu` in your terminal), build it and add it to your `$PATH`:

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
Then run `source ~/.zshrc` (or open a new terminal).

---

## Quickstart

### 1. Add glu to your project
Initialize your Zig project and add `glu` to your dependencies:

```bash
zig fetch --save https://github.com/Vixel2006/glu/archive/refs/<enter-glu-version>.tar.gz
```

In your `build.zig` file, link the module to your executable:

```zig
const glu = b.dependency("glu", .{
    .target = target,
    .optimize = optimize,
}).module("glu");

exe.root_module.addImport("glu", glu);
```

### 2. Define your messages
Write your message structures in a `.glu` file. These definitions represent packed data structures suited for direct zero-copy transmission:

```protobuf
// msgs/sensor.glu
message Telemetry {
    seq:         u32,
    timestamp:   i64,
    temperature: f32,
    pressure:    f32,
    humidity:    f32,
    altitude:    f32,
}
```

Compile the DSL representation into native Zig structs:

```bash
glu codegen -f msgs/sensor.glu -o src/msgs.zig
```

This generates `src/msgs.zig`:
```zig
// Auto-generated by glu codegen. Do not edit.
pub const Telemetry = struct {
    seq: u32,
    timestamp: i64,
    temperature: f32,
    pressure: f32,
    humidity: f32,
    altitude: f32,
};
```

### 3. Implement a Publisher
Publishers write to a topic. You can write messages copying existing structs, or write directly into reserved shared memory slots for optimal zero-copy:

```zig
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const topic = "/telemetry";
    const capacity = 4096;

    // Initialize the publisher
    var publisher = try glu.Publisher.init(allocator, topic, @sizeOf(msgs.Telemetry), capacity);
    defer publisher.deinit();

    // Option A: Publish by copy
    const msg = msgs.Telemetry{
        .seq = 0,
        .timestamp = std.time.milliTimestamp(),
        .temperature = 24.5,
        .pressure = 1013.25,
        .humidity = 45.0,
        .altitude = 120.0,
    };
    publisher.publish(msgs.Telemetry, &msg);

    // Option B: Zero-copy direct write in shared memory (Highly Recommended!)
    const slot = publisher.reserve(msgs.Telemetry);
    slot.* = msgs.Telemetry{
        .seq = 1,
        .timestamp = std.time.milliTimestamp(),
        .temperature = 24.6,
        .pressure = 1013.24,
        .humidity = 45.2,
        .altitude = 120.1,
    };
    publisher.commit(); // Notify subscribers
}
```

### 4. Implement a Subscriber
Subscribers listen to a topic. Each subscriber in a channel requires a unique ID ($0$ to $7$) so its individual read cursor can be tracked:

```zig
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const topic = "/telemetry";
    const capacity = 4096;

    defer subscriber.deinit();

    std.debug.print("Subscribed to telemetry topic...\n", .{});

    while (true) {
        // Non-blocking poll for incoming data
        if (subscriber.receive(msgs.Telemetry)) |msg| {
            std.debug.print("Received: seq={d}, temp={d:.2}°C, alt={d:.1}m\n", .{
                msg.seq,
                msg.temperature,
                msg.altitude,
            });
        }
        std.time.sleep(std.time.ns_per_ms); // Poll rate control
    }
}
```

### 5. Launch multiple nodes
To orchestrate your system, define a `launch.toml` configuration:

```toml
[[node]]
name = "sensor"
bin  = "zig-out/bin/sensor_node"

[[node]]
name = "controller"
bin  = "zig-out/bin/controller_node"
```

Start the system with the launch tool:
```bash
glu launch -f launch.toml
```

---

## CLI Reference

`glu` ships with a complete toolkit inside a single, fast binary.

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
Spawns all defined nodes as child processes. Set `-d` to run them as detached background daemons.

### List active topics
```bash
glu list
# OR
glu ls
```
Discovers and lists all current active topics in shared memory.

### Inspect a topic
```bash
glu info /telemetry
```
Displays detailed topic diagnostics: size, current write cursor position, connection count, message capacities, and read cursors for registered subscribers.

### Show running nodes
```bash
glu ps
```
Queries the registry under `/tmp/glu/nodes` to list nodes, their system PID, and verification of their current active/alive state.

### View node logs
```bash
glu logs <node>
glu logs --tail 50 <node>
glu logs --head 20 <node>
```
Prints the last 10 lines of a node's log by default. Use `--tail <n>` to see the last N lines, or `--head <n>` to see the first N lines. Output is capped at 4096 bytes.

### Graceful teardown
```bash
glu down
```
Sends termination signals to shut down all nodes registered in the local environment.

---

## Performance & Benchmarks

`glu` compiles with aggressive compiler optimization and features micro-benchmarking using [zBench](https://github.com/hendriknielaender/zbench). Results are stored in `.benchmarks/` with automatic performance history.

To run the suite on your machine:
```bash
zig build bench
```

### Benchmark Results (ReleaseFast)

Measurements are taken on an Intel Core i5 system over 100,000 iterations:

| Operation | Time | Target Overhead Description |
| :--- | :--- | :--- |
| `channel write 32B–4096B` | **~18 ns** | Zero-copy write directly to POSIX shared memory |
| `channel read 32B` | **~18 ns** | Reading matching memory slot (Zero-copy pointer dereference) |
| `publisher publish` | **~18 ns** | High-level publisher wrapping write action |
| `subscriber receive` | **~18 ns** | Subscriber index alignment, check, and read |
| `node creation` | **~5 µs** | Operating system `shm_open` and `mmap` initialization |

---

## Ecosystem

The vision of `glu` is a modular, Unix-like ecosystem. Rather than a monolith, each tool lives in its own repository and composes with the others via glu's protocol:

| Repository | Scope / Purpose | Status |
| :--- | :--- | :--- |
| **glu** (this) | The core protocol library, and CLI tools | **Active (Alpha)** |
| **glu-sim** | Robotics simulator — test your nodes in a 3D world without real hardware | *Planned* |
| **glu-viz** | Web-based real-time 3D dashboard & diagnostics tool | *Planned* |
| **glu-nav** | Real-time path planning, navigation, and SLAM module | *Planned* |
| **glu-drivers** | Low-latency sensor drivers toolkit (Lidar, IMU, cameras) | *Planned* |
| **glu-linux** | Minimal embedded Linux distribution with `glu` pre-configured | *Planned* |
| **glu-cuda** | Optional CUDA plugin for in-shared-memory GPU transformations | *Planned* |

---

## Contributing

glu follows the Unix philosophy: **do one thing and do it well**. we keep the core lean and build everything else as separate, composable tools.

we welcome contributions of all skill levels. read [CONTRIBUTING.md](./CONTRIBUTING.md) for the full guide — how to set up, coding style, PR process, and where to start.

---

<p align="center">
  <sub>
    Built with ❤️ and <a href="https://ziglang.org">Zig</a> because robots deserve better.
    <br>
    <b>Star the repository to help fast robots win!</b>
  </sub>
</p>
