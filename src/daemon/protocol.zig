const std = @import("std");
const linux = std.os.linux;

const constants = @import("../constants.zig");

pub const CMD = enum(u8) {
    PING = 0x01,
    SPAWN_NODE = 0x02,
    STOP_NODE = 0x03,
    RESTART_NODE = 0x04,
    REG_SHM = 0x05,
    UNREG_SHM = 0x06,
    REG_NET = 0x07,
    UNREG_NET = 0x08,
    LIST_NODES = 0x09,
    LIST_TOPICS = 0x0A,
    LIST_NET = 0x0B,
    START_NODE = 0x0C,
};

pub const Node = struct {
    bin: [1024]u8,
    bin_len: u32,
    path: [1024]u8,
    path_len: u32,
    extra_cfg: [constants.MAX_ARGS][128]u8,
    extra_cfg_lens: [constants.MAX_ARGS]u32,
    extra_cfg_len: u32,
    name: [64]u8,
    name_len: u32,
    pid: ?linux.pid_t,
    uptime: ?linux.timespec,

    pub const name_buf_len = 64;
    pub const arg_buf_len = 128;

    pub fn name_slice(self: *const Node) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn bin_slice(self: *const Node) []const u8 {
        return self.bin[0..self.bin_len];
    }
    pub fn path_slice(self: *const Node) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn arg(self: *const Node, i: usize) []const u8 {
        return self.extra_cfg[i][0..self.extra_cfg_lens[i]];
    }
};

pub const NODE_NAME = [64]u8;

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
    owner_pid: u32,
    tos: u32,
};

pub const NET_NAME = [64]u8;
