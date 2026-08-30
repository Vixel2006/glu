const std = @import("std");
const linux = std.os.linux;

// +-------------------------------------------------+
// |                  UDP Header                     |
// +-------------------------------------------------+
// |                 CMD FLAG (u8)                   |
// +-------------------------------------------------|
// |                    PAYLOAD                      |
// +-------------------------------------------------+

const CMD = enum(u8) {
    PING = 0x01,
    START_NODE = 0x02,
    STOP_NODE = 0x03,
    RESTART_NODE = 0x04,
    REG_SHM = 0x05,
    UNREG_SHM = 0x06,
    REG_NET = 0x07,
    UNREG_NET = 0x08,
};

pub const NODE_REQ = linux.pid_t;

const REG_SHM_REQ = struct {
    name: [64]u8,
    name_len: u32,
    writer_pid: linux.pid_t,
    msg_size: u32,
    capacity: u32,
    tos: u32,
};

const UNREG_SHM_REQ = [64]u8;

const REG_NET_REQ = struct {
    name: [64]u64,
    name_len: u32,
    msg_size: u32,
    capacity: u32,
    port: u16,
};

const UNREG_NET_REQ = [64]u8;
