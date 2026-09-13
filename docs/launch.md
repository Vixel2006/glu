# GLU Orchestration & CLI

Managing multiple processes, console logs, and diagnostic states across a robot system can be complex. `glu` has a built-in process manager, runner, and diagnostic toolset backed by the small `glud` companion daemon.

No master nodes or complex configuration layers required — just a simple TOML configuration file and clean command-line tools that talk to the daemon over a local Unix socket.

---

## 1. Process Configuration: `launch.toml`

To manage your node ecosystem, write a `launch.toml` file in your workspace root. Slashes (`#`) define comments.

You can launch precompiled binaries or execute raw `.zig` source files on the fly:

```toml
# launch.toml

# Launch a compiled binary with arguments
[[node]]
name = "lidar_driver"
bin  = "zig-out/bin/rplidar_node"
extra_cfg = ["--serial-port", "/dev/ttyUSB0", "--baud", "115200"]

# Compile and run a raw Zig script directly
[[node]]
name = "tracker"
path = "src/tracker.zig"
extra_cfg = ["--fps", "30", "--threshold", "0.85"]
```

### Configuration Keys:
*   `name` (string): Unique identifier for the process. This name is tracked in the daemon's node inventory.
*   `bin` (string): Absolute or relative path to a precompiled executable binary.
*   `path` (string): Path to a `.zig` source file to compile and execute on the fly using `zig run`.
*   `extra_cfg` (array of strings, optional): Command line arguments passed directly to the node.

---

## 2. Command Line Reference

Running `glu` in your shell displays the helper console. Commands are grouped
into a small tree so related actions live together: `glu nodes ...` manages
processes, `glu topics ...` inspects shared-memory channels, `glu net ...`
inspects network channels, and `glu status` / `glu launch` sit at the top
level. The legacy flat names (`glu ps`, `glu list`, `glu info`, `glu logs`,
`glu down`, ...) still work as aliases.

```
usage: glu <command> [args]

commands:
  status   Overview of nodes and topics
  launch   Launch nodes from a TOML config file
  nodes    Manage node processes (list, start, stop, restart, logs, down)
  topics   Inspect shared-memory topics (list, info)
  net      Discover and inspect network channels (list, info, sniff)

run 'glu help <command>' for usage
```

Most commands — `launch`, `status`, `nodes ...`, `topics list`, and
`net ...` — talk to the `glud` daemon over `/tmp/glu/glud.sock`, so start it
first (`glud &`). `glu topics info` reads the shared-memory header directly,
and `glu nodes logs` reads log files directly; both still work without the
daemon.

`glu nodes` alone (or `glu help nodes`) shows the node subcommands, and
`glu topics` shows the topic subcommands.

---

### `glu launch`
Spawns all nodes defined in the TOML configuration file through the `glud`
daemon.

```bash
glud &   # make sure the daemon is running first
glu launch -f launch.toml
```

`glu launch` sends each node's manifest to the daemon over the Unix socket.
The daemon forks each node, redirects its stdout/stderr to
`/tmp/glu/logs/<node_name>.log`, and records its PID and start time in its
inventory. Nodes therefore always run in the background; the `-d` flag is
accepted for compatibility but has no effect.

---

### `glu status`
A unified point-in-time view of the whole system. Correlates the daemon's node
inventory with the shared-memory topic headers (`/dev/shm`) by owning PID, so
you can see at a glance which node owns which topic and how long it has been
running.

```bash
glu status
```

**Example Output:**
```
nodes (2):
Node       PID  Uptime Status Topics
---------- ---- ------ ------ ------
turtle_sim 12095 1m12s alive     0
turtle_gui 12098 1m12s alive     0

topics (2):
Topic            Owner       TOS         Size   Cap
---------------- ----------- ----------- ----- -----
/turtle1/pose    turtle_sim  reliable      16 4096
/turtle1/cmd_vel turtle_gui  best_effort    8 4096
```

`Owner` is the PID that created the topic, resolved to its node name when the
daemon is supervising that process. A topic whose owning process is no longer
tracked shows the raw PID.

---

### `glu nodes list`
Lists all processes the daemon is supervising, showing their names, PIDs,
uptime, and active status. (Alias: `glu ps`.)

```bash
glu nodes list
```

**Example Output:**
```
Node        PID  Uptime Status
---------- ---- ------- ------
lidar_driver  12095  2m04s alive
tracker       12098  1m58s alive
```
*Liveness and uptime come from the daemon's PID and `CLOCK.BOOTTIME` tracking —
no network round-trips.*

---

### `glu topics list`
Queries the daemon's shared-memory channel inventory to list all active
topics. (Aliases: `glu list`, `glu ls`.)

```bash
glu topics list
```

---

### `glu topics info`
Retrieves detailed runtime diagnostics directly from the POSIX shared memory
header of a given topic. (Alias: `glu info`.)

```bash
glu topics info /filtered_temp
```

**Example Output:**
```
Topic              Size  Cap   Conns Write Read Depth
------------------ ----- ---- ----- ----- ---- -----
/filtered_temp        32  4096      2 10482 10402    80
```
*Showing a topic whose second subscriber is lagging by 80 messages — the index
to look for when a `reliable` publisher appears to stall.*

---

### `glu net list` / `glu net info` / `glu net sniff`

Inspect the daemon's network channel inventory:

```bash
glu net list                     # channels registered with the daemon
glu net info <channel>           # derive its multicast port + frame geometry
glu net sniff <channel>          # decode live frames (seq/frag/drop), -v for payload
```

Every network channel derives a deterministic multicast port from its name
(`PORT_BASE + FNV1a(name) % PORT_SLOTS`), so `glu net info` can tell you which
group and port a peer session uses before any process joins.

---

### `glu nodes logs`
View log files produced by the daemon for supervised nodes. (Alias: `glu logs`.)

```bash
glu nodes logs <node_name>
```

Prints the last 10 lines of the node's log file (default).

#### Tail log outputs:
```bash
glu nodes logs --tail 50 <node_name>
```

#### Head log outputs:
```bash
glu nodes logs --head 20 <node_name>
```

#### Follow new lines live:
```bash
glu nodes logs -f <node_name>        # or --follow
```

---

### `glu nodes down`
Gracefully stops your supervised robot node system. (Alias: `glu down`.)

```bash
glu nodes down
```

Asks the daemon to stop every tracked node — or only the named ones
(`glu nodes down sensor logger`). The daemon sends each node a termination
signal (`SIGTERM`) and moves it from the alive to the dead inventory so it can
be relaunched later with `glu nodes start`.

---

### Node lifecycle: `glu nodes start` / `stop` / `restart`

Start, stop, or restart specific nodes by name, using the manifests the
daemon keeps in its inventory. A stopped node is preserved in the dead set, so
`start`/`restart` can relaunch it with the same command line. (Aliases:
`glu start`, `glu stop`, `glu restart`.)

```bash
glu nodes start lidar_driver tracker
glu nodes stop lidar_driver
glu nodes restart tracker
```
