# GLU Orchestration & CLI

Managing multiple processes, console logs, and diagnostic states across a robot system can be complex. `glu` has a built-in process manager, runner, and diagnostic toolset packed directly into its single executable binary.

No master nodes, background daemons, or complex configuration layers required. Just a simple TOML configuration file and clean command-line tools.

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
*   `name` (string): Unique identifier for the process. This registration name is tracked in the node registry.
*   `bin` (string): Absolute or relative path to a precompiled executable binary.
*   `path` (string): Path to a `.zig` source file to compile and execute on the fly using `zig run`.
*   `extra_cfg` (array of strings, optional): Command line arguments passed directly to the node.

---

## 2. Command Line Reference

Running `glu` in your shell displays the helper console. Commands are grouped
into a small tree so related actions live together: `glu nodes ...` manages
processes, `glu topics ...` inspects shared-memory channels, and `glu status` /
`glu launch` sit at the top level. The legacy flat names (`glu ps`, `glu list`,
`glu info`, `glu logs`, `glu down`, ...) still work as aliases.

```
usage: glu <command> [args]

commands:
  status   Overview of nodes and topics
  launch   Launch nodes from a TOML config file
  nodes    Manage node processes (list, start, stop, restart, logs, down)
  topics   Inspect shared-memory topics (list, info)

run 'glu help <command>' for usage
```

`glu nodes` alone (or `glu help nodes`) shows the node subcommands, and
`glu topics` shows the topic subcommands.

---

### `glu launch`
Spawns all nodes defined in the TOML configuration file.

```bash
glu launch -f launch.toml
```

By default, child processes run in the foreground, streaming stdout and stderr to the shell. Pressing `Ctrl+C` triggers a signal handler that terminates all child processes cleanly and unregisters them.

#### Background (Detached) Mode:
```bash
glu launch -f launch.toml -d
```
Runs the nodes in the background. Their PIDs are stored under `/tmp/glu/nodes/`, and their outputs are automatically redirected to log files under `/tmp/glu/logs/<node_name>.log`.

---

### `glu status`
A unified point-in-time view of the whole system. Correlates the node registry
(`/tmp/glu/nodes`) with the shared-memory topic headers (`/dev/shm`) by owning
PID, so you can see at a glance which node owns which topic, how long it has
been running, and how deep each topic's queue is.

```bash
glu status
```

**Example Output:**
```
nodes (4):
Node           PID Uptime Status Topics
----------- ------ ------ ------ ------
sensor_arm  192350 21m50s alive       0
coordinator 192348 21m50s alive       1
logger      192347 21m50s alive       1
operator    192346 21m50s alive       2

topics (5):
Topic               Owner       TOS         Size Depth  Cap
------------------- ----------- ----------- ---- ----- ----
/robot/health       coordinator reliable      32     0  128
/robot/logs         logger      best_effort  104     0  256
/robot/fused        operator    reliable      32     0 4096
/robot/command      192349      reliable      32     0  128
/robot/joint_states operator    reliable      32     1 4096
```
`Topics` counts the topics a node owns (created via `Publisher`/`Channel`).
`Depth` is how many messages the slowest reader is behind the writer. A topic
whose owning process is unregistered or dead shows the raw PID as its `Owner`.

---

### `glu nodes list`
Queries the local node registry to list all registered processes, showing their names, PIDs, uptime, and active status. (Alias: `glu ps`.)

```bash
glu nodes list
```

**Example Output:**
```
node          pid      status
-----------------------------
lidar_driver  12095    active
tracker       12098    active
```
*Note: Under the hood, this simply verifies if `/proc/<pid>/status` exists, resulting in sub-microsecond execution time.*

---

### `glu topics list`
Scans `/dev/shm` to list all currently active communication topics. (Aliases: `glu list`, `glu ls`.)

```bash
glu topics list
```

---

### `glu topics info`
Retrieves detailed runtime diagnostics directly from the POSIX shared memory header of a given topic. (Alias: `glu info`.)

```bash
glu topics info /filtered_temp
```

**Example Output:**
```
topic:           /filtered_temp
magic:           GLU\0
message size:    32 bytes
capacity:        4096 slots
connections:     2 active connections
write cursor:    10482
subscribers:
  [sub 0]:       10482 (active, synced with publisher)
  [sub 1]:       10402 (active, lagging behind by 80 messages!)
  [sub 2..7]:    inactive
```
*This is invaluable for debugging pipeline bottlenecks, showing which subscriber is running slowly and holding up the publisher.*

---

### `glu nodes logs`
View log files generated by background nodes launched with the `-d` flag. (Alias: `glu logs`.)

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

---

### `glu nodes down`
Gracefully stops your detached robot node system. (Alias: `glu down`.)

```bash
glu nodes down
```
Sends a termination signal (`SIGTERM`) to all active process IDs registered in `/tmp/glu/nodes/` and cleans up stale registration files.

---

### Node lifecycle: `glu nodes start` / `stop` / `restart`

Start, stop, or restart specific nodes by name from their persisted launch
manifests. (Aliases: `glu start`, `glu stop`, `glu restart`.)

```bash
glu nodes start sensor_arm logger
glu nodes stop sensor_arm
glu nodes restart operator
```
