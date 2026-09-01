const std = @import("std");
const linux = std.os.linux;

// +-------------------------------------------------+
// |                  UDP Header                     |
// +-------------------------------------------------+
// |                 CMD FLAG (u8)                   |
// +-------------------------------------------------|
// |                    PAYLOAD                      |
// +-------------------------------------------------+

pub const CMD = enum(u8) {
    PING = 0x01,
    START_NODE = 0x02,
    STOP_NODE = 0x03,
    RESTART_NODE = 0x04,
    REG_SHM = 0x05,
    UNREG_SHM = 0x06,
    REG_NET = 0x07,
    UNREG_NET = 0x08,
};

pub const Node = struct {
    pid: linux.pid_t,
    uptime: linux.timespec,
};

pub const NODE_PID = linux.pid_t;

pub const SHM_CHAN = struct {
    name: [64]u8,
    name_len: u32,
    writer_pid: linux.pid_t,
    num_readers: u32,
    msg_size: u32,
    capacity: u32,
    tos: u32,
};

pub const SHM_NAME = [64]u8;

pub const NET_CHAN = struct {
    name: [64]u8,
    name_len: u32,
    msg_size: u32,
    capacity: u32,
    num_reg: u32,
    port: u16,
};

pub const NET_NAME = [64]u8;
