# glu docs

welcome to the `glu` docs. if you're tired of setting up 15 environment variables, downloading 4GB of docker images, and waiting 10 minutes for your robot middleware to compile a "hello world" node, you're in the right place. 

`glu` is a blazingly fast, zero-dependency robot middleware written in [Zig](https://ziglang.org/). no enterprise synergy, no DDS tax, no bloated layers of abstract factories. just raw, deterministic, lock-free, zero-copy process communication.

here's how we're doing things:

## documentation map

- [quickstart](../README.md#quickstart) — from zero to running your first node in 60 seconds. compiling faster than you can check twitter.
- [api reference](./api.md) — how to use `glu.Publisher` and `glu.Subscriber` without reading a 500-page manual.
- [architecture](./architecture.md) — under the hood. lock-free ring buffers, POSIX shared memory (`/dev/shm`), and how we keep it zero-copy.
- [orchestration & cli](./launch.md) — orchestrating your nodes using `launch.toml` and managing them via CLI. 

---

## why glu? (tl;dr)

| the old way (ROS2 / DDS) | the glu way |
| :--- | :--- |
| requires a whole ubuntu distro lock-in | runs anywhere with libc & POSIX |
| cmake + colcon + xml + yaml = build times that make you cry | `zig build` with parallel, cached builds |
| DDS discovery taking seconds (or just randomly dying) | sub-millisecond file-based registry |
| gigabytes of runtime dependencies | ~2MB single standalone binary, zero runtime deps |
| heavy serialization, copying, context-switches | zero-copy shared memory rings |

fr, robots deserve better than 2004-era enterprise Java architecture repackaged in C++. let's build something clean.
