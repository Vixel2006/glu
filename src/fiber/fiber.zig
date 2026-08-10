const std = @import("std");

const Fiber = struct {
    const status = enum(u32) {
        READY,
        RUNNING,
        WAITING,
        DEAD,
    };
};
