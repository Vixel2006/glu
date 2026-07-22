const std = @import("std");

pub fn logErr(comptime ctx: []const u8, err: anyerror) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fw = std.Io.File.stderr().writerStreaming(io, &.{});
    const w = &fw.interface;
    w.print("error: {s}: {s}\n", .{ ctx, @errorName(err) }) catch {};
    if (@errorReturnTrace()) |trace| {
        const cast: *const std.debug.StackTrace = @ptrCast(trace);
        std.debug.dumpStackTrace(cast);
    }
}

pub fn writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, &.{});
}

pub fn errWriter(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(init.io, &.{});
}
