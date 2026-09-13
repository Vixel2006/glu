 <p align="center">
  <img src="assets/glu.svg" alt="glu" />
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

- **Lockless Zero-Copy IPC**: Shared memory ring buffers managed with atomic release-acquire memory ordering. Zero stack copying or serialization.
- **Reliability Policies**: Configurable Type of Service (`ToS`). Supports `.reliable` backpressure (publisher spins on the slowest reader to guarantee no data loss) and `.best_effort` (publisher immediately overwrites old slots).
- **Daemon-Based Discovery & Orchestration**: A small `glud` companion daemon keeps a live inventory of nodes, shared-memory topics, and network channels. It spawns nodes, redirects their output to `/tmp/glu/logs`, and tracks liveness and uptime — no network discovery protocol, no DDS-style matchmaking. Nodes and channels self-register with the daemon as they start, and `glu launch`, `glu nodes ...`, `glu topics ...`, and `glu net ...` talk to it over the local Unix socket `/tmp/glu/glud.sock`.
- **Async TCP/UDP Networking**: Built-in network transport APIs integrated with a highly optimized `io_uring` asynchronous I/O engine.
- **Cooperative Fiber Scheduling**: `src/fiber/` bundles a user-space coroutine scheduler (x86_64 & aarch64) exposed through an `asyncio`-style API (`glu.asyncio`). Create tasks on the thread-local event loop and `io.wait` yields them in place — async code reads like blocking code with no kernel context switches.
- **Integrated Orchestrator**: Run entire node ecosystems using a simple TOML configuration. Manage logging, signaling, and diagnostics from the command line.

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
  .reserve() &   |  * Write blocks if (W - slowest(R0, R1) >= Capacity) |    .peek()
  .commit()      +------------------------------------------------------+    .ack()
```

- **Header (168 Bytes)**: Stores operational metadata, active connections, Type of Service, the segment owner's PID, and subscriber reader entries. Each entry packs the subscriber PID and read cursor into one 64-bit word, so a slot is claimed with a single atomic operation.
- **Write**: The publisher claims slot `W % capacity`, writes fields directly, and atomically increments the write cursor.
- **Read**: Each subscriber reads from its own reader index. If the subscriber's cursor lags behind the write cursor, it reads directly from the slot.

Async I/O — TCP, UDP, file access, and timers — runs on a single `io_uring` ring per thread. On top of that ring sits a cooperative fiber scheduler (`src/fiber/`): fibers are lightweight user-space coroutines with their own stacks. Calling `io.wait` inside a fiber yields it until the future completes; `io.run` runs both the ready fibers and the ring in one tight loop.

Orchestration lives in the `glud` companion daemon. `glu launch` sends your
TOML manifest to the daemon over the Unix socket `/tmp/glu/glud.sock`; the
daemon forks each node, redirects its stdout/stderr to
`/tmp/glu/logs/<node>.log`, and records its PID and start time in an in-memory
inventory (alive/dead nodes, topics, and network channels). Shared-memory and
network channels self-register with the daemon when they are created, so
`glu status`, `glu nodes list`, `glu topics list`, and `glu net list` reflect
the live system. Raw pub/sub works fine without the daemon; only the
orchestration and inspection commands need it.

---

## Install the CLI

```bash
# Clone the repository and build the binaries
zig build

# Symlink the CLI and daemon into your local bin path
ln -sf "$(pwd)/zig-out/bin/glu" ~/.local/bin/glu
ln -sf "$(pwd)/zig-out/bin/glud" ~/.local/bin/glud

# Verify execution
glu --help
```

Start the companion daemon before using the orchestration commands
(`glu launch`, `glu nodes ...`, `glu topics ...`, `glu net ...`, and
`glu status`). Those commands connect over the Unix socket
`/tmp/glu/glud.sock` and report an error when it is not running:

```bash
glud &
```

Raw pub/sub from your own code works fine without the daemon.

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

Start the node system. Nodes are spawned and supervised by the `glud`
daemon, so make sure it is running first (see Install above):

```bash
glu launch -f launch.toml
```

### 6. Discovery & CLI in Action

The classic **turtlesim** example (`examples/turtlesim`) shows the daemon in
action: a Python physics node publishes `/turtle1/pose`, and a Tkinter GUI
node subscribes to it. Launch both through the daemon:

```bash
zig build                                   # builds libglu.so + the glu/glud binaries
GLU_LIB_PATH="$PWD/zig-out/lib/libglu.so"   # let glupy find the native library
PYTHONPATH="$PWD/glu/python"
glud &
glu launch -f examples/turtlesim/launch.toml
```

Watch the live system through the daemon's inventory:

```bash
glu nodes list            # nodes the daemon is supervising   (alias: glu ps)
glu topics list           # topics that self-registered       (alias: glu list)
glu topics info /turtle1/pose    # shm header: size, cap, cursor state
glu nodes logs -f turtle_sim     # stream a node's log live    (alias: glu logs)
glu nodes down            # ask the daemon to stop everything (alias: glu down)
```

`glu status` correlates the daemon's node inventory with the shared-memory
topic headers in one screen — which PID owns which topic, how long each node
has been up, and each topic's geometry.

---

## CLI Reference

Commands are grouped into a tree: `glu nodes ...` manages processes,
`glu topics ...` inspects shared-memory channels, and `glu status` /
`glu launch` live at the top level. Legacy flat names still work as aliases.
All of the commands below (except `launch`) query the `glud` daemon, so start
it first.

```
usage: glu <command> [args]

commands:
  status   Overview of nodes and topics
  launch   Launch nodes from a TOML config file
           glu launch -f <file.toml>          (-d accepted, no-op)

  nodes    Manage node processes
           glu nodes list
           glu nodes start <node> [node...]
           glu nodes stop <node> [node...]
           glu nodes restart <node> [node...]
           glu nodes logs [--tail <n>] [--head <n>] [-f] <node>
           glu nodes down [node...]

  topics   Inspect shared-memory topics
           glu topics list
           glu topics info <topic>

  net      Discover and inspect network channels
           glu net list
           glu net info <channel>
           glu net sniff <channel> [-v]

run 'glu help <command>' for usage
```

Legacy aliases: `ps`, `start`, `stop`, `restart`, `logs`, `down`,
`list` / `ls`, `info`, `sniff`.

---

## Contributing

We welcome contributions! Please review [CONTRIBUTING.md](./CONTRIBUTING.md) for coding styles, development setups, and our pull request checklist.

---

<p align="center">
  <sub>
    <a href="https://ziglang.org">Zig</a> — robots deserve better.
  </sub>
</p>
