const std = @import("std");
const constants = @import("../constants.zig");
const protocol = @import("protocol.zig");
const is_alive = @import("../utils/process.zig").is_alive;

pub const MAX_NODES = constants.MAX_ENTRIES;
pub const MAX_TOPICS = constants.MAX_ENTRIES;
pub const MAX_NET_CHANNELS = constants.MAX_ENTRIES;

pub const Node = struct {
    name: [64]u8 = undefined,
    name_len: u32 = 0,
    pid: u32 = 0,
    child_handle: ?std.process.Child = null,
    status: protocol.NodeStatus = .stopped,
    start_time: i64 = 0,
    restart_count: u32 = 0,
    argv_buf: [constants.MAX_ARGV_LEN]u8 = undefined,
    argv_len: usize = 0,

    pub fn set_name(self: *Node, name_str: []const u8) void {
        const len = @min(name_str.len, 63);
        @memcpy(self.name[0..len], name_str[0..len]);
        self.name[len] = 0;
        self.name_len = @intCast(len);
    }

    pub fn get_name(self: *const Node) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ShmTopic = struct {
    name: [64]u8 = undefined,
    name_len: u32 = 0,
    owner_pid: u32 = 0,
    msg_size: u32 = 0,
    capacity: u32 = 0,
    tos: u32 = 0,

    pub fn set_name(self: *ShmTopic, name_str: []const u8) void {
        const len = @min(name_str.len, 63);
        @memcpy(self.name[0..len], name_str[0..len]);
        self.name[len] = 0;
        self.name_len = @intCast(len);
    }

    pub fn get_name(self: *const ShmTopic) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const NetChannel = struct {
    name: [64]u8 = undefined,
    name_len: u32 = 0,
    owner_pid: u32 = 0,
    msg_size: u32 = 0,
    capacity: u32 = 0,
    tos: u32 = 0,
    port: u16 = 0,

    pub fn set_name(self: *NetChannel, name_str: []const u8) void {
        const len = @min(name_str.len, 63);
        @memcpy(self.name[0..len], name_str[0..len]);
        self.name[len] = 0;
        self.name_len = @intCast(len);
    }

    pub fn get_name(self: *const NetChannel) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DaemonState = struct {
    nodes: [MAX_NODES]Node = undefined,
    node_count: usize = 0,

    shm_topics: [MAX_TOPICS]ShmTopic = undefined,
    shm_count: usize = 0,

    net_channels: [MAX_NET_CHANNELS]NetChannel = undefined,
    net_count: usize = 0,

    pub fn init() DaemonState {
        return .{};
    }

    pub fn find_node_by_name(self: *DaemonState, name: []const u8) ?*Node {
        for (self.nodes[0..self.node_count]) |*n| {
            if (std.mem.eql(u8, n.get_name(), name)) return n;
        }
        return null;
    }

    pub fn find_node_by_pid(self: *DaemonState, pid: u32) ?*Node {
        for (self.nodes[0..self.node_count]) |*n| {
            if (n.pid == pid) return n;
        }
        return null;
    }

    pub fn add_or_update_node(self: *DaemonState, name: []const u8, pid: u32, argv_data: []const u8) !*Node {
        // TODO: Update this with our new time module after we finish it
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now: i64 = @intCast(ts.sec);

        if (self.find_node_by_name(name)) |n| {
            n.pid = pid;
            n.status = .running;
            n.start_time = now;
            const argv_len = @min(argv_data.len, n.argv_buf.len);
            @memcpy(n.argv_buf[0..argv_len], argv_data[0..argv_len]);
            n.argv_len = argv_len;
            return n;
        }

        if (self.node_count >= MAX_NODES) return error.TooManyNodes;
        const n = &self.nodes[self.node_count];
        self.node_count += 1;
        n.* = .{ .pid = pid, .status = .running, .start_time = now };
        n.set_name(name);
        const argv_len = @min(argv_data.len, n.argv_buf.len);
        @memcpy(n.argv_buf[0..argv_len], argv_data[0..argv_len]);
        n.argv_len = argv_len;
        return n;
    }

    pub fn remove_node(self: *DaemonState, name: []const u8) bool {
        for (self.nodes[0..self.node_count], 0..) |*n, idx| {
            if (std.mem.eql(u8, n.get_name(), name)) {
                if (idx < self.node_count - 1) {
                    self.nodes[idx] = self.nodes[self.node_count - 1];
                }
                self.node_count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn register_shm(self: *DaemonState, entry: ShmTopic) void {
        for (self.shm_topics[0..self.shm_count]) |*t| {
            if (std.mem.eql(u8, t.get_name(), entry.get_name())) {
                t.* = entry;
                return;
            }
        }
        if (self.shm_count < MAX_TOPICS) {
            self.shm_topics[self.shm_count] = entry;
            self.shm_count += 1;
        }
    }

    pub fn unregister_shm(self: *DaemonState, name: []const u8) void {
        for (self.shm_topics[0..self.shm_count], 0..) |*t, idx| {
            if (std.mem.eql(u8, t.get_name(), name)) {
                if (idx < self.shm_count - 1) {
                    self.shm_topics[idx] = self.shm_topics[self.shm_count - 1];
                }
                self.shm_count -= 1;
                return;
            }
        }
    }

    pub fn register_net(self: *DaemonState, entry: NetChannel) void {
        for (self.net_channels[0..self.net_count]) |*ch| {
            if (std.mem.eql(u8, ch.get_name(), entry.get_name())) {
                ch.* = entry;
                return;
            }
        }
        if (self.net_count < MAX_NET_CHANNELS) {
            self.net_channels[self.net_count] = entry;
            self.net_count += 1;
        }
    }

    pub fn unregister_net(self: *DaemonState, name: []const u8) void {
        for (self.net_channels[0..self.net_count], 0..) |*ch, idx| {
            if (std.mem.eql(u8, ch.get_name(), name)) {
                if (idx < self.net_count - 1) {
                    self.net_channels[idx] = self.net_channels[self.net_count - 1];
                }
                self.net_count -= 1;
                return;
            }
        }
    }

    pub fn sweep_dead(self: *DaemonState) void {
        for (0..self.node_count) |i| {
            const n = &self.nodes[i];
            if (n.status == .running and n.pid > 0 and !is_alive(n.pid)) n.status = .crashed;
        }

        var i: usize = 0;
        while (i < self.shm_count) {
            const t = &self.shm_topics[i];
            if (t.owner_pid > 0 and !is_alive(t.owner_pid)) {
                self.unregister_shm(t.get_name());
            } else {
                i += 1;
            }
        }

        i = 0;
        while (i < self.net_count) {
            const ch = &self.net_channels[i];
            if (ch.owner_pid > 0 and !is_alive(ch.owner_pid)) {
                self.unregister_net(ch.get_name());
            } else {
                i += 1;
            }
        }
    }
};
