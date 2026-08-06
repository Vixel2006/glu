const std = @import("std");
const dispatch = @import("cli/dispatch.zig");

pub fn main(init: std.process.Init) void {
    dispatch.run(init);
}
