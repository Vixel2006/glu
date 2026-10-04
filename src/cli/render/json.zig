const std = @import("std");

pub fn write_string(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try w.writeAll(s);
    try w.writeByte('"');
}
