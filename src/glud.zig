const std = @import("std");
const glu = @import("glu");

pub fn main(init: std.process.Init) !void {
    try glu.daemon.daemon.daemon_main(init);
}
