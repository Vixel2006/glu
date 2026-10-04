const std = @import("std");

pub fn print_kv(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print("{s: <12} {s}\n", .{ key, value });
}

pub fn print_kv_int(w: *std.Io.Writer, key: []const u8, value: usize) !void {
    try w.print("{s: <12} {d}\n", .{ key, value });
}
