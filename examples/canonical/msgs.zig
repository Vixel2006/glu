// Shared message definitions for the "robot control room" showcase.
//
// Every topic in glu is backed by a POSIX shared-memory segment, so each
// message type is laid out as an `extern struct` to guarantee an identical
// memory layout in every node that opens the topic.

pub const JointState = extern struct {
    seq: u32,
    timestamp: i64,
    index: u32,
    position: f32,
    velocity: f32,
    effort: f32,
};

pub const Health = extern struct {
    seq: u32,
    timestamp: i64,
    uptime_sec: u32,
    battery_voltage: f32,
    temperature: f32,
    error_count: u32,
};

pub const FusedState = extern struct {
    seq: u32,
    timestamp: i64,
    joint_count: u32,
    avg_effort: f32,
    energy: f32,
    fault_level: u32,
};

pub const CommandKind = enum(u8) {
    home = 0,
    torque = 1,
    velocity = 2,
    stop = 3,
};

pub const RobotCommand = extern struct {
    seq: u32,
    timestamp: i64,
    kind: u8,
    target: u32,
    value: f32,
};

pub const LogLevel = enum(u8) {
    info = 0,
    warn = 1,
    fatal = 2,
};

pub const LogEntry = extern struct {
    seq: u32,
    timestamp: i64,
    level: u8,
    source: [16]u8,
    msg: [64]u8,
};

/// Copy a NUL-terminated name/string into a fixed-size field.
pub fn set_str(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
}
