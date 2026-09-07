const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");

pub const Inventory = struct {
    alive_nodes: std.AutoHashMap([64]u8, protocol.Node),
    dead_nodes: std.AutoHashMap([64]u8, protocol.Node),

    alive_shm: std.StringHashMap(protocol.SHM_CHAN),
    dead_shm: std.StringHashMap(protocol.SHM_CHAN),

    alive_net: std.StringHashMap(protocol.NET_CHAN),
    dead_net: std.StringHashMap(protocol.NET_CHAN),

    pub fn init(allocator: std.mem.Allocator) Inventory {
        return .{
            .alive_nodes = std.AutoHashMap([64]u8, protocol.Node).init(allocator),
            .dead_nodes = std.AutoHashMap([64]u8, protocol.Node).init(allocator),
            .alive_shm = std.StringHashMap(protocol.SHM_CHAN).init(allocator),
            .dead_shm = std.StringHashMap(protocol.SHM_CHAN).init(allocator),
            .alive_net = std.StringHashMap(protocol.NET_CHAN).init(allocator),
            .dead_net = std.StringHashMap(protocol.NET_CHAN).init(allocator),
        };
    }

    pub fn deinit(self: *Inventory) void {
        self.alive_nodes.deinit();
        self.dead_nodes.deinit();
        self.alive_shm.deinit();
        self.dead_shm.deinit();
        self.alive_net.deinit();
        self.dead_net.deinit();
    }

    fn name_key(name: []const u8) [64]u8 {
        var key = [_]u8{0} ** 64;
        const n = @min(name.len, 64);
        @memcpy(key[0..n], name[0..n]);
        return key;
    }

    pub fn alive_node(self: *Inventory, name: []const u8) ?protocol.Node {
        return self.alive_nodes.get(name_key(name));
    }

    pub fn dead_node(self: *Inventory, name: []const u8) ?protocol.Node {
        return self.dead_nodes.get(name_key(name));
    }

    pub fn register_node(self: *Inventory, node: *protocol.Node) void {
        assert(self.alive_nodes.count() < constants.MAX_NODES);

        const key = name_key(node.name_slice());
        self.alive_nodes.put(key, node.*) catch return;
    }

    pub fn unregister_node(self: *Inventory, name: []const u8) void {
        assert(self.alive_nodes.count() > 0);
        assert(self.dead_nodes.count() < constants.MAX_NODES);

        const key = name_key(name);
        if (self.alive_nodes.fetchRemove(key)) |kv| {
            self.dead_nodes.put(key, kv.value) catch return;
        }
    }

    pub fn register_shm(self: *Inventory, req: *protocol.SHM_CHAN) void {
        assert(self.alive_shm.count() < constants.MAX_SHM_CHANS);

        const key = req.name[0..req.name_len];
        const gop = self.alive_shm.getOrPut(key) catch return;
        gop.value_ptr.* = req.*;
        // StringHashMap keys are borrowed slices, so key into the durable copy
        // stored in the map rather than the caller's (possibly transient) buffer.
        if (!gop.found_existing) gop.key_ptr.* = gop.value_ptr.name[0..gop.value_ptr.name_len];
    }

    pub fn unregister_shm(self: *Inventory, name: *protocol.SHM_NAME) void {
        assert(self.alive_shm.count() > 0);
        assert(self.dead_shm.count() < constants.MAX_SHM_CHANS);

        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_shm.fetchRemove(key)) |kv| {
            const dead_key = kv.value.name[0..kv.value.name_len];
            const gop = self.dead_shm.getOrPut(dead_key) catch return;
            gop.value_ptr.* = kv.value;
            if (!gop.found_existing) gop.key_ptr.* = gop.value_ptr.name[0..gop.value_ptr.name_len];
        }
    }

    pub fn register_net(self: *Inventory, req: *protocol.NET_CHAN) void {
        assert(self.alive_net.count() < constants.MAX_NET_CHANS);

        const key = req.name[0..req.name_len];
        const gop = self.alive_net.getOrPut(key) catch return;
        gop.value_ptr.* = req.*;
        if (!gop.found_existing) gop.key_ptr.* = gop.value_ptr.name[0..gop.value_ptr.name_len];
    }

    pub fn unregister_net(self: *Inventory, name: *protocol.NET_NAME) void {
        assert(self.alive_net.count() > 0);
        assert(self.dead_net.count() < constants.MAX_NET_CHANS);

        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_net.fetchRemove(key)) |kv| {
            const dead_key = kv.value.name[0..kv.value.name_len];
            const gop = self.dead_net.getOrPut(dead_key) catch return;
            gop.value_ptr.* = kv.value;
            if (!gop.found_existing) gop.key_ptr.* = gop.value_ptr.name[0..gop.value_ptr.name_len];
        }
    }

    pub fn spawn_node(self: *Inventory, node: *protocol.Node) !void {
        const rc = linux.fork();
        const pid: linux.pid_t = if (posix.errno(rc) == .SUCCESS) @intCast(rc) else return error.ForkFailed;
        if (pid == 0) {
            var argv: [constants.MAX_ARGS + 4]?[*:0]const u8 = .{null} ** (constants.MAX_ARGS + 4);
            var bin_buf: [1024]u8 = undefined;
            var path_buf: [1024]u8 = undefined;
            var arg_bufs: [constants.MAX_ARGS][128]u8 = undefined;

            var argc: usize = 0;
            if (node.bin_len > 0) {
                argv[0] = std.fmt.bufPrintZ(&bin_buf, "{s}", .{node.bin_slice()}) catch linux.exit_group(1);
                argc = 1;
            } else {
                argv[0] = "zig";
                argv[1] = "run";
                argv[2] = std.fmt.bufPrintZ(&path_buf, "{s}", .{node.path_slice()}) catch linux.exit_group(1);
                argv[3] = "--";
                argc = 4;
            }
            for (0..node.extra_cfg_len) |i| {
                argv[argc] = std.fmt.bufPrintZ(&arg_bufs[i], "{s}", .{node.arg(i)}) catch linux.exit_group(1);
                argc += 1;
            }

            if (node.name_len > 0) {
                var log_buf: [512:0]u8 = undefined;
                if (std.fmt.bufPrintZ(&log_buf, "{s}/{s}.log", .{ constants.LOGS_DIR, node.name_slice() })) |log_z| {
                    const fd = std.c.open(log_z.ptr, linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
                    if (fd >= 0) {
                        _ = std.c.dup2(fd, 1);
                        _ = std.c.dup2(fd, 2);
                        _ = std.c.close(fd);
                    }
                } else |_| {}
            }

            exec_on_path(argv[0].?, @ptrCast(&argv));
            const err = "glu: execve failed\n";
            _ = std.c.write(2, err, err.len);
            linux.exit_group(1);
        }
        node.*.pid = pid;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(linux.CLOCK.BOOTTIME, &ts) == 0) node.*.uptime = ts;
        self.register_node(node);
    }

    fn exec_on_path(name: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
        var cand_buf: [4096]u8 = undefined;
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        if (std.mem.indexOfScalar(u8, std.mem.span(name), '/') != null) {
            _ = std.c.execve(name, argv, envp);
            return;
        }
        const path_list: []const u8 = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/local/bin:/usr/bin:/bin";
        var it = std.mem.tokenizeScalar(u8, path_list, ':');
        while (it.next()) |dir| {
            const cand = std.fmt.bufPrintZ(&cand_buf, "{s}/{s}", .{ dir, std.mem.span(name) }) catch continue;
            _ = std.c.execve(cand, argv, envp);
        }
    }

    pub fn start_node(self: *Inventory, name: []const u8) bool {
        const key = name_key(name);
        if (self.alive_nodes.contains(key)) return true;
        if (self.dead_nodes.fetchRemove(key)) |kv| {
            var node = kv.value;
            node.pid = null;
            node.uptime = null;
            self.spawn_node(&node) catch return false;
            return true;
        }
        return false;
    }

    pub fn stop_node(self: *Inventory, name: []const u8) bool {
        const key = name_key(name);
        if (self.alive_nodes.fetchRemove(key)) |kv| {
            if (kv.value.pid) |pid| posix.kill(pid, posix.SIG.TERM) catch {};
            var stopped = kv.value;
            stopped.pid = null;
            self.dead_nodes.put(key, stopped) catch {};
            return true;
        }
        return false;
    }

    pub fn restart_node(self: *Inventory, name: []const u8) bool {
        _ = self.stop_node(name);
        return self.start_node(name);
    }

    pub fn list_nodes(self: *Inventory, out: []protocol.Node) usize {
        var n: usize = 0;
        var alive = self.alive_nodes.valueIterator();
        while (alive.next()) |v| {
            if (n >= out.len) break;
            out[n] = v.*;
            n += 1;
        }
        var dead = self.dead_nodes.valueIterator();
        while (dead.next()) |v| {
            if (n >= out.len) break;
            out[n] = v.*;
            n += 1;
        }
        return n;
    }

    pub fn list_shm(self: *Inventory, out: []protocol.SHM_CHAN) usize {
        var n: usize = 0;
        var it = self.alive_shm.valueIterator();
        while (it.next()) |v| {
            if (n >= out.len) break;
            out[n] = v.*;
            n += 1;
        }
        return n;
    }

    pub fn list_net(self: *Inventory, out: []protocol.NET_CHAN) usize {
        var n: usize = 0;
        var it = self.alive_net.valueIterator();
        while (it.next()) |v| {
            if (n >= out.len) break;
            out[n] = v.*;
            n += 1;
        }
        return n;
    }
};
