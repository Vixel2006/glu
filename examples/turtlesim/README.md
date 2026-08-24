# glu Turtlesim Example

A full Python GUI `turtlesim` example demonstrating **glu**'s shared-memory zero-copy IPC and Python bindings (`glupy`).

---

## Features

* **GUI Canvas**: Tkinter visualizer drawing the turtle, heading orientation, grid lines, and pen trail on ROS 2 classic turtlesim blue background (`#4570b5`).
* **Zero-Copy Publishing**: The physics simulation node (`turtle_node.py`) updates pose using `pub.reserve_as(Pose)` directly in `/dev/shm` at 60 Hz.
* **QoS / ToS Selection**: `/turtle1/pose` uses `Tos.RELIABLE` while `/turtle1/cmd_vel` uses `Tos.BEST_EFFORT` (latest-command-wins semantics).
* **Keyboard Teleop**: Control the turtle live in the GUI using Arrow keys / WASD, or run the standalone terminal teleop script `teleop_node.py`.

---

## Quick Start

### 1. Build Native Library & Install Python Bindings

From the repository root:

```bash
# Build libglu.so
zig build

# Set environment variables for glupy import
export GLU_LIB_PATH="$(pwd)/zig-out/lib/libglu.so"
export PYTHONPATH="$(pwd)/glu/python:$PYTHONPATH"
```

### 2. Launch with `glu launch`

```bash
glu launch -f examples/turtlesim/launch.toml
```

Or run the nodes manually in separate terminals:

**Terminal 1 (Physics Simulator Node):**
```bash
python3 examples/turtlesim/turtle_node.py
```

**Terminal 2 (Tkinter GUI Node):**
```bash
python3 examples/turtlesim/gui_node.py
```

**Terminal 3 (Optional CLI Teleop Node):**
```bash
python3 examples/turtlesim/teleop_node.py
```

---

## 🕹️ Controls

When focused on the **GUI window**:
- **Arrow Keys** or **W / A / S / D**: Drive turtle (Forward/Back/Rotate)
- **Space**: Stop movement
- **C**: Clear pen trail

---

## 🧬 Architecture & Message Schemas

```
+------------------+         /turtle1/cmd_vel (BEST_EFFORT)       +------------------+
|  gui_node.py /   | -------------------------------------------> |  turtle_node.py  |
|  teleop_node.py  | <------------------------------------------- |  (Sim Engine)    |
+------------------+           /turtle1/pose (RELIABLE)           +------------------+
```

Defined in `messages.py`:

```python
@dataclass
class Pose:
    x: glupy.f32
    y: glupy.f32
    theta: glupy.f32
    linear_velocity: glupy.f32
    angular_velocity: glupy.f32

@dataclass
class CmdVel:
    linear: glupy.f32
    angular: glupy.f32
```
