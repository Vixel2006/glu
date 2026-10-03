const std = @import("std");
const posix = std.posix;

pub const Format = enum { text, json };

pub const Ctx = struct {
    proc_init: std.process.Init,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    format: Format = .text,
    color: bool = false,
    is_tty: bool = false,
    term_width: u16 = 80,

    pub fn init_ctx(p: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer) Ctx {
        return .{
            .proc_init = p,
            .out = out,
            .err = err,
            .is_tty = isatty(1),
            .color = false,
            .term_width = get_width(),
        };
    }

    pub fn print(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }

    pub fn eprint(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        try self.err.print(fmt, args);
    }

    pub fn writeAll(self: *Ctx, s: []const u8) !void {
        try self.out.writeAll(s);
    }

    pub fn ewriteAll(self: *Ctx, s: []const u8) !void {
        try self.err.writeAll(s);
    }
};

fn isatty(fd: i32) bool {
    return posix.isatty(fd);
}

fn get_width() u16 {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS")) |cols| {
        defer std.heap.page_allocator.free(cols);
        const parsed = std.fmt.parseInt(u16, cols, 10) catch null;
        if (parsed) |w| {
            if (w > 0) return w;
        }
    } else |_| {}

    var ws: posix.winsize = undefined;
    if (posix.ioctl(1, posix.T.IOCGWINSZ, @ptrCast(&ws)) == 0) {
        if (ws.col > 0) return ws.col;
    }

    return 80;
}
