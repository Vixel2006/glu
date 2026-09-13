# GLU Documentation Index

Welcome to the **glu** documentation! If you are looking for a high-performance, developer-friendly, and lightweight middleware for robotics, you are in the right place. 

`glu` is a zero-dependency, lock-free robot middleware written in [Zig](https://ziglang.org/). It is designed to replace bloated, complex systems (like ROS 2 / DDS) with raw, deterministic, zero-copy process communication.

---

## Documentation Map

To help you get started and master `glu` quickly, we've structured our documentation into the following guides:

*   **[API Reference](api.md)**: A complete reference of the `glu` API, featuring detailed signatures and verified code examples for Shared Memory Pub/Sub, `glu.IO` (io_uring), Cooperative AsyncIO (`glu.asyncio`), TCP, UDP, and node orchestration.
*   **[Architecture & Internals](architecture.md)**: Under the hood. Learn how our packed memory layouts, lock-free ring buffers, slowest-reader backpressure, daemon-based discovery, and cooperative fiber scheduler keep things ultra-fast and robust.
*   **[Orchestration & CLI](launch.md)**: Configure your node ecosystem with `launch.toml` and manage live processes easily using CLI commands like `glu launch`, `glu nodes list`, and `glu topics info`.

---

## Showcase Example

Run the **turtlesim** demo under `examples/turtlesim` to see `glu` working
end to end: shared-memory pub/sub between a Python physics node and a Tkinter
GUI, orchestrated and inspected through the `glud` daemon. See the README's
*Discovery & CLI in Action* section for a walkthrough.

---

## Why GLU? (TL;DR)

If you have worked with ROS 2 or other enterprise middleware, here is how `glu` compares:

| Feature / Aspect | The Old Way (ROS 2 / DDS) | The GLU Way |
| :--- | :--- | :--- |
| **Dependencies** | Gigabytes of runtime dependencies, Ubuntu lock-in | Zero runtime dependencies, runs on any POSIX system |
| **Build System** | `cmake` + `colcon` + XML/YAML; long build times | `zig build` with parallel, cached compilation |
| **Discovery** | DDS discovery taking seconds (or failing randomly) | Sub-millisecond local discovery via the `glud` daemon (`/tmp/glu/glud.sock`) |
| **Footprint** | Heavy system footprint | ~2MB standalone executable binary |
| **Overhead** | Complex serialization, copies, kernel context-switches | Zero-copy shared memory rings (acquire/release) |

Robots deserve clean, modern, and high-performance developer tools. Let's build something clean!
