const std = @import("std");

pub const Style = struct {
    color: bool = false,

    pub fn init(color: bool) Style {
        return .{ .color = color };
    }

    pub fn dim(self: Style, w: *std.Io.Writer, s: []const u8) !void {
        if (self.color) {
            try w.writeAll("\x1b[2m");
            try w.writeAll(s);
            try w.writeAll("\x1b[0m");
            return;
        }
        try w.writeAll(s);
    }

    pub fn bold(self: Style, w: *std.Io.Writer, s: []const u8) !void {
        if (self.color) {
            try w.writeAll("\x1b[1m");
            try w.writeAll(s);
            try w.writeAll("\x1b[0m");
            return;
        }
        try w.writeAll(s);
    }
};
