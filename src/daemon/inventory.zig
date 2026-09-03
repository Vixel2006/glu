const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");

const Inventory = struct {
    alive_nodes: std.StringHashMap(protocol.Node),
    dead_nodes: std.StringHashMap(protocol.Node),

    alive_shm: std.StringHashMap(protocol.SHM_CHAN),
    dead_shm: std.StringHashMap(protocol.SHM_CHAN),

    alive_net: std.StringHashMap(protocol.NET_CHAN),
    dead_net: std.StringHashMap(protocol.NET_CHAN),

    pub fn init(allocator: std.mem.Allocator) Inventory {
        return .{
            .alive_nodes = std.StringHashMap(protocol.Node).init(allocator),
            .dead_nodes = std.StringHashMap(protocol.Node).init(allocator),
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

    pub fn register_node(self: *Inventory, node: *protocol.Node) void {
        assert(self.alive_nodes.count() < constants.MAX_NODES);

        self.alive_nodes.put(node.name, node.*) catch return;
    }

    pub fn unregister_node(self: *Inventory, name: []const u8) void {
        assert(self.alive_nodes.count() > 0);
        assert(self.dead_nodes.count() < constants.MAX_NODES);

        if (self.alive_nodes.fetchRemove(name)) |kv| {
            self.dead_nodes.put(kv.key, kv.value) catch return;
        }
    }

    pub fn register_shm(self: *Inventory, req: *protocol.SHM_CHAN) void {
        assert(self.alive_shm.count() < constants.MAX_SHM_CHANS);

        const key = req.name[0..req.name_len];
        self.alive_shm.put(key, req.*) catch return;
    }

    pub fn unregister_shm(self: *Inventory, name: *protocol.SHM_NAME) void {
        assert(self.alive_shm.count() > 0);
        assert(self.dead_shm.count() < constants.MAX_SHM_CHANS);

        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_shm.fetchRemove(key)) |kv| {
            self.dead_shm.put(kv.key, kv.value) catch return;
        }
    }

    pub fn register_net(self: *Inventory, req: *protocol.NET_CHAN) void {
        assert(self.alive_net.count() < constants.MAX_NET_CHANS);

        const key = req.name[0..req.name_len];
        self.alive_net.put(key, req.*) catch return;
    }

    pub fn unregister_net(self: *Inventory, name: *protocol.NET_NAME) void {
        assert(self.alive_net.count() > 0);
        assert(self.dead_net.count() < constants.MAX_NET_CHANS);

        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_net.fetchRemove(key)) |kv| {
            self.dead_net.put(kv.key, kv.value) catch return;
        }
    }

    pub fn start_node(self: *Inventory, node: *protocol.Node) !void {
        const pid = try posix.fork();
        if (pid == 0) {
            var argv: [constants.MAX_ARGS + 2]?[*:0]const u8 = .{null} ** (constants.MAX_ARGS + 2);
            argv[0] = node.bin.ptr;
            for (node.extra_cfg, 0..) |arg, i| {
                if (arg.len == 0) break;
                argv[i + 1] = arg.ptr;
            }
            _ = std.c.execve(node.bin.ptr, @ptrCast(&argv));
            linux.exit_group(1);
        }
        node.*.pid = pid;
        self.register_node(node);
    }

    pub fn stop_node(self: *Inventory, name: []const u8) void {
        if (self.alive_nodes.fetchRemove(name)) |kv| {
            if (kv.value.pid) |pid| posix.kill(pid, posix.SIG.TERM) catch {};
            self.dead_nodes.put(kv.key, kv.value) catch {};
        }
    }

    pub fn restart_node(self: *Inventory, name: []const u8) void {
        stop_node(self, name);
        if (self.dead_nodes.fetchRemove(name)) |kv| {
            var node = kv.value;
            node.pid = null;
            start_node(self, &node) catch {};
        }
    }
};
