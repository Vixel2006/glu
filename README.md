<p align="center">
  <img src="https://img.shields.io/badge/zig-%23F7A41D.svg?style=for-the-badge&logo=zig&logoColor=white" alt="Zig" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="MIT" />
  <img src="https://img.shields.io/badge/status-alpha-red?style=for-the-badge" alt="Alpha" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=for-the-badge" alt="PRs Welcome" />
</p>

<h1 align="center">
  <code>glu</code>
</h1>

<p align="center">
  <b>blazingly fast robot middleware.</b><br>
  <i>no bloat. no ROS taxes. just clean, real-time comms.</i>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> •
  <a href="#why">Why</a> •
  <a href="#philosophy">Philosophy</a> •
  <a href="#ecosystem">Ecosystem</a> •
  <a href="#contributing">Contribute</a>
</p>

---

**glu** is a next-gen communication protocol for robotics, built from scratch in Zig and CUDA. It's what happens when you ditch the corporate bloat and build exactly what a robot actually needs: fast, deterministic, peer-to-peer message passing between nodes — nothing more, nothing less.

ROS2 is the past. **glu is the glow-up.**

---

## the vibe

| ROS2 | glu |
|------|-----|
| 500+ dependencies | zero runtime deps |
| Python + C++ + launch files | one binary |
| DDS discovery taking seconds | sub-ms discovery |
| "just works" (it doesn't) | actually just works |
| coorp | indie |

## quickstart

```bash
# build from source
zig build -Doptimize=ReleaseFast

# run a node
glu node start --name motor_driver

# list active nodes
glu ps

# subscribe to a topic and pipe to stdout
glu sub /sensor/lidar | jq .
```

> **prereqs:** Zig 0.16+, CUDA Toolkit (optional — falls back to CPU)

## why

The robotics community has been screaming into the void about ROS2 for years. Here's what they actually say:

> *"I tried to use ROS2 twice in my professional career. Both times ended up with massively bloated build pipelines, significantly longer build times, and massively bloated Docker images."* — [HN]  
> *"ROS2 is always one hack away from working as it should."* — [r/robotics]  
> *"DDS discovery takes seconds. Python nodes eat your CPU above 100Hz. The build system destroys parallelism. It's a framework that thinks it's an OS."* — [Discourse]  
> *"colcon builds packages in topological order. This is an insane way to structure a C++ build."* — [HN]  
> *"Each ROS2 version only works with one Ubuntu version. Upgrade your Pi? All your packages break."* — [Medium]

**The pattern is loud and clear:**

| pain point | reality |
|---|---|
| **dependency hell** | `apt install` gigabytes before you spin a motor |
| **build system** | colcon → ament → cmake → you want to die |
| **DDS complexity** | discovery takes seconds, multicast breaks on WiFi, 200 nodes = pray |
| **version lock-in** | Ubuntu version dictates ROS2 version dictates which packages you're allowed to use |
| **serialization tax** | 4 CPU cores burning just to move a camera stream locally |
| **embedded-hostile** | Raspberry Pi cries. Real-time OS? Lol. |
| **CLI that fights you** | `source` this, `source` that, `ros2 run` can't even run a binary directly |

**glu fixes all of this. With one binary. Zero deps. Sub-ms messaging.**

This isn't a framework. It's a **protocol**. You get:
- **one binary** (~2MB stripped)
- **sub-millisecond** discovery and message passing
- **GPU-accelerated** transforms (CUDA)
- **a CLI** that's actually good (`glu --help` and you're already productive)
- **zero surprises**

Everything else — SLAM, planning, viz, drivers — lives in separate repos. Each does one thing well. Unix style. If it's not strictly about moving data between nodes, it doesn't belong here.

## philosophy

1. **do one thing.** glu moves data between processes. That's it.
2. **no surprises.** deterministic. predictable. real-time.
3. **eat the bloat.** every feature must prove it earns its place. default answer is "no."
4. **CLI-first.** you should never need a GUI to understand your robot.
5. **embedded-native.** built for ARM, runs on anything with a POSIX socket.

## ecosystem

glu is the core of a larger vision. Each piece will its own repo under an open-source org:

| repo | what it does |
|------|-------------|
| **glu** (this) | the protocol + CLI |
| glu-viz | real-time web dashboard |
| glu-nav | path planning & SLAM |
| glu-drivers | sensor driver toolkit |
| glu-linux | minimal embedded Linux distro with glu baked in |

*most of these don't exist yet. they will when they earn it.*

## build options

```bash
# minimum viable build (CPU only)
zig build -Doptimize=ReleaseFast

# with GPU acceleration
zig build -Doptimize=ReleaseFast -DCUDA_PATH=/usr/local/cuda

# debug mode with verbose logging
zig build
```

## contribute

This project lives on vibes and good code. If you:
- have a robotics background and hate ROS2
- write Zig and want to make something real
- just want to be part of the rebellion

...open an issue, PR, or discussion. No CLA. No drama. Just code.

```bash
git clone https://github.com/glu-os/glu
cd glu
zig build test
```

<p align="center">
  <sub>
    built with ❤️ and <a href="https://ziglang.org">Zig</a> because robots deserve better.
    <br>
    <b>star the repo if you want fast robots to win.</b>
  </sub>
</p>
