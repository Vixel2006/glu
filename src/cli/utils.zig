const std = @import("std");

pub fn log_err(comptime ctx: []const u8, err: anyerror) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fw = std.Io.File.stderr().writerStreaming(io, &.{});
    const w = &fw.interface;
    w.print("error: {s}: {s}\n", .{ ctx, @errorName(err) }) catch {};
    return 1;
}

pub fn writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, &.{});
}

pub fn err_writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(init.io, &.{});
}

/// "1h2m", "3m4s", or "5s"; "-" when uptime is unknown.
pub fn format_uptime(buf: []u8, secs: u64) []const u8 {
    if (secs == 0) return "-";
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h{d}m", .{ h, m }) catch "-";
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ m, s }) catch "-";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "-";
}
