const std = @import("std");
const linux = std.os.linux;

const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");
const hash = @import("../hash.zig");

const Hypervisor = struct {
    alive_nodes: [constants.MAX_NODES]protocol.Node,
    alive_nodes_count: u32,

    dead_nodes: [constants.MAX_NODES]protocol.Node,
    dead_nodes_count: u32,

    shm_keys: [constants.MAX_SHM_CHANS][]const u8,
    alive_shm_chans: [constants.MAX_SHM_CHANS]protocol.SHM_CHAN,
    alive_shm_chans_count: u32,

    dead_shm_chans: [constants.MAX_SHM_CHANS]protocol.SHM_CHAN,
    dead_shm_chans_count: u32,

    net_keys: [constants.MAX_NET_CHANS][]const u8,
    alive_net_chans: [constants.MAX_NET_CHANS]protocol.NET_CHAN,
    alive_net_chans_count: u32,

    dead_net_chans: [constants.MAX_NET_CHANS]protocol.NET_CHAN,
    dead_net_chans_count: u32,

    pub fn init() Hypervisor {
        return std.mem.zeroes(Hypervisor);
    }

    pub fn deinit(self: *Hypervisor) void {
        _ = self;
    }

    pub fn register_shm(self: *Hypervisor, shm_req: *protocol.SHM_CHAN) void {
        putChan(
            protocol.SHM_CHAN,
            constants.MAX_SHM_CHANS,
            &self.shm_keys,
            &self.alive_shm_chans,
            &self.alive_shm_chans_count,
            shm_req,
        );
    }

    pub fn unregister_shm(self: *Hypervisor, name: *protocol.SHM_NAME) void {
        deleteChan(
            protocol.SHM_CHAN,
            constants.MAX_SHM_CHANS,
            &self.shm_keys,
            &self.alive_shm_chans,
            &self.alive_shm_chans_count,
            &self.dead_shm_chans,
            &self.dead_shm_chans_count,
            std.mem.sliceTo(name.*[0..], 0),
        );
    }

    pub fn register_net(self: *Hypervisor, net_req: *protocol.NET_CHAN) void {
        putChan(
            protocol.NET_CHAN,
            constants.MAX_NET_CHANS,
            &self.net_keys,
            &self.alive_net_chans,
            &self.alive_net_chans_count,
            net_req,
        );
    }

    pub fn unregister_net(self: *Hypervisor, name: *protocol.NET_NAME) void {
        deleteChan(
            protocol.NET_CHAN,
            constants.MAX_NET_CHANS,
            &self.net_keys,
            &self.alive_net_chans,
            &self.alive_net_chans_count,
            &self.dead_net_chans,
            &self.dead_net_chans_count,
            std.mem.sliceTo(name.*[0..], 0),
        );
    }
};

fn putChan(
    comptime T: type,
    comptime cap: usize,
    keys: *[cap][]const u8,
    chans: *[cap]T,
    count: *u32,
    req: *T,
) void {
    const name = req.name[0..req.name_len];
    if (hash.get(name, keys)) |slot| {
        chans[slot] = req.*;
        keys[slot] = chans[slot].name[0..chans[slot].name_len];
        return;
    } else |_| {}

    const slot = hash.put(name, keys) catch return;
    chans[slot] = req.*;
    keys[slot] = chans[slot].name[0..chans[slot].name_len];
    count.* += 1;
}

fn deleteChan(
    comptime T: type,
    comptime cap: usize,
    keys: *[cap][]const u8,
    alive: *[cap]T,
    alive_count: *u32,
    dead: *[cap]T,
    dead_count: *u32,
    name: []const u8,
) void {
    const slot = hash.get(name, keys) catch return;
    dead[dead_count.*] = alive[slot];
    dead_count.* += 1;
    alive_count.* -= 1;
    hash.delete(name, keys) catch {};
}

test "Hypervisor.init zeroes all counters" {
    const h = Hypervisor.init();
    try std.testing.expectEqual(@as(u32, 0), h.alive_nodes_count);
    try std.testing.expectEqual(@as(u32, 0), h.dead_nodes_count);
    try std.testing.expectEqual(@as(u32, 0), h.alive_shm_chans_count);
    try std.testing.expectEqual(@as(u32, 0), h.dead_shm_chans_count);
    try std.testing.expectEqual(@as(u32, 0), h.alive_net_chans_count);
    try std.testing.expectEqual(@as(u32, 0), h.dead_net_chans_count);
}

test "register_shm adds channel, addressable by name" {
    var h = Hypervisor.init();

    var req: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req.name[0..10], "test_topic");
    req.name_len = 10;
    req.writer_pid = 1234;
    req.num_readers = 2;
    req.msg_size = 256;
    req.capacity = 1024;
    req.tos = 1;

    h.register_shm(&req);

    try std.testing.expectEqual(@as(u32, 1), h.alive_shm_chans_count);

    const slot = try hash.get(req.name[0..req.name_len], &h.shm_keys);
    try std.testing.expectEqual(@as(u32, 10), h.alive_shm_chans[slot].name_len);
    try std.testing.expectEqual(@as(linux.pid_t, 1234), h.alive_shm_chans[slot].writer_pid);
    try std.testing.expectEqual(@as(u32, 256), h.alive_shm_chans[slot].msg_size);
}

test "register_shm adds multiple channels" {
    var h = Hypervisor.init();

    var req1: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req1.name[0..7], "topic_a");
    req1.name_len = 7;
    req1.writer_pid = 100;
    req1.num_readers = 1;
    req1.msg_size = 128;
    req1.capacity = 512;
    req1.tos = 0;

    var req2: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req2.name[0..7], "topic_b");
    req2.name_len = 7;
    req2.writer_pid = 200;
    req2.num_readers = 3;
    req2.msg_size = 64;
    req2.capacity = 256;
    req2.tos = 2;

    h.register_shm(&req1);
    h.register_shm(&req2);

    try std.testing.expectEqual(@as(u32, 2), h.alive_shm_chans_count);

    const slot1 = try hash.get(req1.name[0..req1.name_len], &h.shm_keys);
    const slot2 = try hash.get(req2.name[0..req2.name_len], &h.shm_keys);
    try std.testing.expect(slot1 != slot2);
    try std.testing.expectEqual(@as(linux.pid_t, 100), h.alive_shm_chans[slot1].writer_pid);
    try std.testing.expectEqual(@as(linux.pid_t, 200), h.alive_shm_chans[slot2].writer_pid);
}

test "register_shm re-register does not double count" {
    var h = Hypervisor.init();

    var req1: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req1.name[0..7], "topic_a");
    req1.name_len = 7;
    req1.writer_pid = 100;
    req1.num_readers = 1;
    req1.msg_size = 128;
    req1.capacity = 512;
    req1.tos = 0;

    var req2 = req1;
    req2.writer_pid = 300;

    h.register_shm(&req1);
    h.register_shm(&req2);

    try std.testing.expectEqual(@as(u32, 1), h.alive_shm_chans_count);
    const slot = try hash.get(req1.name[0..req1.name_len], &h.shm_keys);
    try std.testing.expectEqual(@as(linux.pid_t, 300), h.alive_shm_chans[slot].writer_pid);
}

test "register_net adds channel, addressable by name" {
    var h = Hypervisor.init();

    var req: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req.name[0..9], "net_topic");
    req.name_len = 9;
    req.msg_size = 512;
    req.capacity = 64;
    req.num_reg = 1;
    req.port = 49200;

    h.register_net(&req);

    try std.testing.expectEqual(@as(u32, 1), h.alive_net_chans_count);

    const slot = try hash.get(req.name[0..req.name_len], &h.net_keys);
    try std.testing.expectEqual(@as(u32, 9), h.alive_net_chans[slot].name_len);
    try std.testing.expectEqual(@as(u16, 49200), h.alive_net_chans[slot].port);
}

test "register_net adds multiple channels" {
    var h = Hypervisor.init();

    var req1: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req1.name[0..5], "net_a");
    req1.name_len = 6;
    req1.msg_size = 100;
    req1.capacity = 10;
    req1.num_reg = 0;
    req1.port = 49152;

    var req2: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req2.name[0..5], "net_b");
    req2.name_len = 6;
    req2.msg_size = 200;
    req2.capacity = 20;
    req2.num_reg = 0;
    req2.port = 49153;

    h.register_net(&req1);
    h.register_net(&req2);

    try std.testing.expectEqual(@as(u32, 2), h.alive_net_chans_count);

    const slot1 = try hash.get(req1.name[0..req1.name_len], &h.net_keys);
    const slot2 = try hash.get(req2.name[0..req2.name_len], &h.net_keys);
    try std.testing.expect(slot1 != slot2);
    try std.testing.expectEqual(@as(u16, 49152), h.alive_net_chans[slot1].port);
    try std.testing.expectEqual(@as(u16, 49153), h.alive_net_chans[slot2].port);
}

test "deinit does not crash" {
    var h = Hypervisor.init();
    h.deinit();
}

test "unregister_shm moves channel to dead and adjusts counts" {
    var h = Hypervisor.init();

    var req: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req.name[0..6], "victim");
    req.name_len = 6;
    req.writer_pid = 999;
    req.num_readers = 0;
    req.msg_size = 32;
    req.capacity = 16;
    req.tos = 0;

    h.register_shm(&req);
    try std.testing.expectEqual(@as(u32, 1), h.alive_shm_chans_count);

    var unreg: protocol.SHM_NAME = std.mem.zeroes(protocol.SHM_NAME);
    @memcpy(unreg[0..6], "victim");

    h.unregister_shm(&unreg);

    try std.testing.expectEqual(@as(u32, 0), h.alive_shm_chans_count);
    try std.testing.expectEqual(@as(u32, 1), h.dead_shm_chans_count);
    try std.testing.expectEqual(@as(linux.pid_t, 999), h.dead_shm_chans[0].writer_pid);
}

test "unregister_shm only removes matching channel" {
    var h = Hypervisor.init();

    var req1: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req1.name[0..4], "keep");
    req1.name_len = 4;
    req1.writer_pid = 10;
    req1.num_readers = 0;
    req1.msg_size = 64;
    req1.capacity = 32;
    req1.tos = 0;

    var req2: protocol.SHM_CHAN = std.mem.zeroes(protocol.SHM_CHAN);
    @memcpy(req2.name[0..6], "remove");
    req2.name_len = 6;
    req2.writer_pid = 20;
    req2.num_readers = 0;
    req2.msg_size = 64;
    req2.capacity = 32;
    req2.tos = 0;

    h.register_shm(&req1);
    h.register_shm(&req2);
    try std.testing.expectEqual(@as(u32, 2), h.alive_shm_chans_count);

    var unreg: protocol.SHM_NAME = std.mem.zeroes(protocol.SHM_NAME);
    @memcpy(unreg[0..6], "remove");

    h.unregister_shm(&unreg);

    try std.testing.expectEqual(@as(u32, 1), h.alive_shm_chans_count);
    try std.testing.expectEqual(@as(u32, 1), h.dead_shm_chans_count);

    const kept = try hash.get(req1.name[0..req1.name_len], &h.shm_keys);
    try std.testing.expectEqual(@as(linux.pid_t, 10), h.alive_shm_chans[kept].writer_pid);
}

test "unregister_net moves channel to dead and adjusts counts" {
    var h = Hypervisor.init();

    var req: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req.name[0..10], "net_victim");
    req.name_len = 10;
    req.msg_size = 128;
    req.capacity = 8;
    req.num_reg = 2;
    req.port = 50000;

    h.register_net(&req);
    try std.testing.expectEqual(@as(u32, 1), h.alive_net_chans_count);

    var unreg: protocol.NET_NAME = std.mem.zeroes(protocol.NET_NAME);
    @memcpy(unreg[0..10], "net_victim");

    h.unregister_net(&unreg);

    try std.testing.expectEqual(@as(u32, 0), h.alive_net_chans_count);
    try std.testing.expectEqual(@as(u32, 1), h.dead_net_chans_count);
    try std.testing.expectEqual(@as(u16, 50000), h.dead_net_chans[0].port);
}

test "unregister_net only removes matching channel" {
    var h = Hypervisor.init();

    var req1: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req1.name[0..5], "nkeep");
    req1.name_len = 5;
    req1.msg_size = 64;
    req1.capacity = 4;
    req1.num_reg = 0;
    req1.port = 49160;

    var req2: protocol.NET_CHAN = std.mem.zeroes(protocol.NET_CHAN);
    @memcpy(req2.name[0..7], "nremove");
    req2.name_len = 7;
    req2.msg_size = 64;
    req2.capacity = 4;
    req2.num_reg = 0;
    req2.port = 49161;

    h.register_net(&req1);
    h.register_net(&req2);
    try std.testing.expectEqual(@as(u32, 2), h.alive_net_chans_count);

    var unreg: protocol.NET_NAME = std.mem.zeroes(protocol.NET_NAME);
    @memcpy(unreg[0..7], "nremove");

    h.unregister_net(&unreg);

    try std.testing.expectEqual(@as(u32, 1), h.alive_net_chans_count);
    try std.testing.expectEqual(@as(u32, 1), h.dead_net_chans_count);

    const kept = try hash.get(req1.name[0..req1.name_len], &h.net_keys);
    try std.testing.expectEqual(@as(u16, 49160), h.alive_net_chans[kept].port);
}
