# GLU Documentation Index

Welcome to the **glu** documentation! If you are looking for a high-performance, developer-friendly, and lightweight middleware for robotics, you are in the right place. 

`glu` is a zero-dependency, lock-free robot middleware written in [Zig](https://ziglang.org/). It is designed to replace bloated, complex systems (like ROS 2 / DDS) with raw, deterministic, zero-copy process communication.

---

## Documentation Map

To help you get started and master `glu` quickly, we've structured our documentation into the following guides:

*   **[API Reference](file:///home/vixel/code/glu/docs/api.md)**: A complete reference of the `glu` API, featuring detailed signatures and verified code examples for Shared Memory Pub/Sub, `glu.IO` (io_uring), Cooperative AsyncIO (`glu.asyncio`), TCP, UDP, and the Node Registry.
*   **[Architecture & Internals](file:///home/vixel/code/glu/docs/architecture.md)**: Under the hood. Learn how our packed memory layouts, lock-free ring buffers, slowest-reader backpressure, file-based registry, and cooperative fiber scheduler keep things ultra-fast and robust.
*   **[Orchestration & CLI](file:///home/vixel/code/glu/docs/launch.md)**: Configure your node ecosystem with `launch.toml` and manage live processes easily using CLI commands like `glu launch`, `glu nodes list`, and `glu topics info`.

---

## Showcase Example

Run the **robot control room** demo under `examples/canonical` to see every
`glu` feature working together: reliable + best-effort pub/sub, multicast and
unicast UDP, bidirectional TCP, io_uring timers and file I/O, and the node
registry. See the README's *Showcase: Robot Control Room* section for a
walkthrough.

---

## Why GLU? (TL;DR)

If you have worked with ROS 2 or other enterprise middleware, here is how `glu` compares:

| Feature / Aspect | The Old Way (ROS 2 / DDS) | The GLU Way |
| :--- | :--- | :--- |
| **Dependencies** | Gigabytes of runtime dependencies, Ubuntu lock-in | Zero runtime dependencies, runs on any POSIX system |
| **Build System** | `cmake` + `colcon` + XML/YAML; long build times | `zig build` with parallel, cached compilation |
| **Discovery** | DDS discovery taking seconds (or failing randomly) | Sub-millisecond local file-based node registry |
| **Footprint** | Heavy system footprint | ~2MB standalone executable binary |
| **Overhead** | Complex serialization, copies, kernel context-switches | Zero-copy shared memory rings (acquire/release) |

Robots deserve clean, modern, and high-performance developer tools. Let's build something clean!
