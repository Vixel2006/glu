const std = @import("std");

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
        self.alive_nodes.put(node.name, node.*) catch return;
    }

    pub fn unregister_node(self: *Inventory, name: []const u8) void {
        if (self.alive_nodes.fetchRemove(name)) |kv| {
            self.dead_nodes.put(kv.key, kv.value) catch return;
        }
    }

    pub fn register_shm(self: *Inventory, req: *protocol.SHM_CHAN) void {
        const key = req.name[0..req.name_len];
        self.alive_shm.put(key, req.*) catch return;
    }

    pub fn unregister_shm(self: *Inventory, name: *protocol.SHM_NAME) void {
        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_shm.fetchRemove(key)) |kv| {
            self.dead_shm.put(kv.key, kv.value) catch return;
        }
    }

    pub fn register_net(self: *Inventory, req: *protocol.NET_CHAN) void {
        const key = req.name[0..req.name_len];
        self.alive_net.put(key, req.*) catch return;
    }

    pub fn unregister_net(self: *Inventory, name: *protocol.NET_NAME) void {
        const key = std.mem.sliceTo(name.*[0..], 0);
        if (self.alive_net.fetchRemove(key)) |kv| {
            self.dead_net.put(kv.key, kv.value) catch return;
        }
    }
};
