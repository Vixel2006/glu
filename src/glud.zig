const std = @import("std");
const IO = @import("io.zig").IO;
const constants = @import("constants.zig");
const Server = @import("daemon/server.zig").Server;

pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "/tmp/glu");
    try cwd.createDirPath(init.io, constants.LOGS_DIR);

    var io: IO = try IO.init(64, 0);
    defer io.deinit();

    var server = try Server.init(&io, std.heap.page_allocator);
    defer server.deinit();

    try server.listen(16);
}
