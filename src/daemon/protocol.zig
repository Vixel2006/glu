const std = @import("std");

pub const GLUD_MAGIC: u32 = 0x474C5544; // "GLUD"

pub const Cmd = enum(u8) {
    launch = 0x01,
    status = 0x02,
    stop_node = 0x03,
    start_node = 0x04,
    list_nodes = 0x05,
    list_topics = 0x06,
    list_net = 0x07,
    node_logs = 0x08,
    register_shm = 0x09,
    register_net = 0x0A,
    unregister_shm = 0x0B,
    unregister_net = 0x0C,
    shutdown = 0x0D,
    ping = 0x0E,

    response = 0x80,
    _,
};

pub const Header = extern struct {
    magic: u32 = GLUD_MAGIC,
    cmd: u8,
    status: u8 = 0, // 0 = ok, >0 error code
    payload_len: u32,
};

pub const NodeStatus = enum(u8) {
    running = 0,
    stopped = 1,
    crashed = 2,
    restarting = 3,
};

pub const WireNode = extern struct {
    name: [64]u8,
    name_len: u32,
    pid: u32,
    status: u8, // NodeStatus
    start_time: i64,
    restart_count: u32,
    argv_len: u32, // bytes in argv string payload (nul-separated)
};

pub const WireShmTopic = extern struct {
    name: [64]u8,
    name_len: u32,
    owner_pid: u32,
    msg_size: u32,
    capacity: u32,
    tos: u32,
};

pub const WireNetChannel = extern struct {
    name: [64]u8,
    name_len: u32,
    owner_pid: u32,
    port: u16,
    msg_size: u32,
    capacity: u32,
    tos: u32,
};

pub const StatusSnapshotHeader = extern struct {
    node_count: u32,
    topic_count: u32,
};

pub const LaunchNodeReq = struct {
    name: []const u8,
    path: []const u8,
    bin: []const u8,
    argv: []const []const u8,
};
