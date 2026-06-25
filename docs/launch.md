# orchestration & CLI tools

becuase we know managing 20 terminal windows just to run a robot navigation stack is a nightmare. `glu` has a built-in process manager and diagnostic suite packed right into our single binary. 

no master node. no daemon servers. just a simple TOML configuration and clean shell commands.

---

## configuration: `launch.toml`

to configure your robot node ecosystem, write a `launch.toml` file in your workspace root. 

you can launch compiled binaries, or run raw `.zig` source files directly (super helpful for rapid hacking):

```toml
# launch.toml

# launch a compiled binary
[[node]]
name = "lidar_driver"
bin  = "zig-out/bin/rplidar_node"
extra_cfg = ["--serial-port", "/dev/ttyUSB0", "--baud", "115200"]

# launch a raw zig file directly (glu runs: zig run src/tracker.zig -- args)
[[node]]
name = "tracker"
path = "src/tracker.zig"
extra_cfg = ["--fps", "30", "--threshold", "0.85"]
```

### configuration schema
- `name`: string name of the node. this registers the process name in the `/tmp/glu/nodes/` PID tracker.
- `bin`: absolute or relative path to a compiled binary.
- `path`: (optional) path to a `.zig` file to compile and execute on the fly using `zig run`.
- `extra_cfg`: (optional) string array of arguments passed directly to the node executable.

---

## cli reference

run `glu` in your shell to see all available commands. they're designed to be fast and simple.

### 1. launch nodes
```bash
glu launch -f launch.toml
```
spawns all nodes in the config. logs are streamed straight to your current shell. press `Ctrl+C` to terminate all of them cleanly.

#### background mode (detached daemons):
```bash
glu launch -f launch.toml -d
```
runs the nodes in the background, redirecting output to `/dev/null` and saving the child process IDs under `/tmp/glu/nodes/`. 

---

### 2. inspect running nodes (`glu ps`)
```bash
glu ps
```
reads the node registry to list all registered processes, showing their names, PIDs, and active status.

example output:
```
node          pid      status
-----------------------------
lidar_driver  48202    active
tracker       48205    active
```
under the hood, this simply verifies if `/proc/<pid>/status` exists. no network round-trips.

---

### 3. list active topics (`glu list`)
```bash
glu list
# or
glu ls
```
scans the directory space to display all active communication topics.

---

### 4. diagnostic topic inspection (`glu info`)
want to see if a publisher is running too fast, or if a subscriber is blocking the channel? 

```bash
glu info /joint_states
```

example output:
```
topic:           /joint_states
magic:           GLU\0
message size:    24 bytes
capacity:        1024 slots
connections:     2 active connections
write cursor:    1012
subscribers:
  [sub 0]:       1012 (active, synced with publisher)
  [sub 1]:       959 (active, lagging behind by 53 messages!)
  [sub 2..7]:    inactive
```
this prints the actual structure of the POSIX shared memory header so you know exactly which subscriber is holding up the publishers.

---

### 5. view node logs (`glu logs`)
when running in detached mode (`-d`), each node's stdout and stderr are saved to `/tmp/glu/logs/<node>.log`. use `glu logs` to inspect them:

```bash
glu logs <node>
```
prints the last 10 lines of the node's log file (default).

```bash
glu logs --tail 50 <node>
```
prints the last 50 lines.

```bash
glu logs --head 20 <node>
```
prints the first 20 lines.

output is capped at 4096 bytes per read.

---

### 6. teardown (`glu down`)
if you launched nodes with `-d` (detached mode) and want to shut down your robot system, run:

```bash
glu down
```
this sends a termination signal to all registered PIDs in `/tmp/glu/nodes` and deletes the stale files. clean exit.
