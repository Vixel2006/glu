const std = @import("std");
const zbench = @import("zbench");

const channel = @import("channel.zig");
const api = @import("api.zig");
const codegen = @import("codegen.zig");

const StatsRecord = struct {
    name: []const u8,
    iterations: u64,
    mean_ns: u64,
    stddev_ns: u64,
    min_ns: u64,
    max_ns: u64,
    p75_ns: u64,
    p99_ns: u64,
    p995_ns: u64,
};

const HistoryFile = struct {
    timestamp: i64,
    results: []const StatsRecord,
};

fn statsFromResult(r: *const zbench.Result) !zbench.statistics.Statistics(u64) {
    return try zbench.statistics.Statistics(u64).init(r.readings.timings_ns);
}

fn fmtDuration(ns: u64) struct { f64, []const u8 } {
    if (ns < 1000) return .{ @as(f64, @floatFromInt(ns)), "ns" };
    if (ns < 1_000_000) return .{ @as(f64, @floatFromInt(ns)) / 1_000.0, "µs" };
    if (ns < 1_000_000_000) return .{ @as(f64, @floatFromInt(ns)) / 1_000_000.0, "ms" };
    return .{ @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, "s" };
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14...31 => {
                try w.print("\\u{0:>4}", .{@as(u16, @intCast(c))});
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout: std.Io.File = .stdout();
    const allocator = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const bench_dir = ".benchmarks";
    const history_dir = bench_dir ++ "/history";

    try cwd.createDirPath(io, history_dir);

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try bench.add("channel write 32B", channel.benchChannelWrite32, .{ .hooks = channel.write32_hooks });
    try bench.add("channel write 256B", channel.benchChannelWrite256, .{ .hooks = channel.write256_hooks });
    try bench.add("channel write 1024B", channel.benchChannelWrite1024, .{ .hooks = channel.write1024_hooks });
    try bench.add("channel write 4096B", channel.benchChannelWrite4096, .{ .hooks = channel.write4096_hooks });
    try bench.add("channel read 32B", channel.benchChannelRead32, .{ .hooks = channel.read32_hooks });
    try bench.add("publisher publish", api.benchPublisherPublish, .{ .hooks = api.publish_hooks });
    try bench.add("subscriber receive", api.benchSubscriberReceive, .{ .hooks = api.receive_hooks });
    try bench.add("node init", api.benchNodeInit, .{});
    try bench.add("node create publisher", api.benchNodeCreatePublisher, .{});
    try bench.add("node create subscriber", api.benchNodeCreateSubscriber, .{});
    try bench.add("generate code", codegen.benchGenerateCode, .{});

    try zbench.prettyPrintHeader(io, stdout, bench.max_name_len);

    var iter = try bench.iterator();
    var results = std.ArrayList(zbench.Result).empty;
    defer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    while (try iter.next(io)) |step| {
        switch (step) {
            .progress => {},
            .result => |r| {
                try r.prettyPrint(io, stdout, bench.max_name_len);
                try results.append(allocator, r);
            },
        }
    }

    const os = std.os.linux;
    var clock_ts: os.timespec = undefined;
    _ = os.clock_gettime(os.CLOCK.REALTIME, &clock_ts);
    const timestamp = clock_ts.sec;

    saveLatestJson(io, cwd, bench_dir, results.items, timestamp) catch |e| {
        std.debug.print("warning: save latest.json: {s}\n", .{@errorName(e)});
    };

    const prev = loadPreviousStats(allocator, io, cwd, bench_dir) catch null;

    saveHistoryStats(io, cwd, history_dir, results.items, timestamp) catch |e| {
        std.debug.print("warning: save history: {s}\n", .{@errorName(e)});
    };

    savePreviousStats(io, cwd, bench_dir, results.items, timestamp) catch |e| {
        std.debug.print("warning: save previous stats: {s}\n", .{@errorName(e)});
    };

    if (prev) |p| {
        defer p.deinit();
        try printComparison(io, stdout, results.items, p.value);
    }
}

fn writeStatsRecord(w: *std.Io.Writer, name: []const u8, r: *const zbench.Result) !void {
    const st = try statsFromResult(r);
    try writeJsonString(w, name);
    try w.print(": {{ \"iterations\": {d}, \"mean_ns\": {d}, \"stddev_ns\": {d}, \"min_ns\": {d}, \"max_ns\": {d}, \"p75_ns\": {d}, \"p99_ns\": {d}, \"p995_ns\": {d} }}", .{
        r.readings.iterations,
        st.mean, st.stddev, st.min, st.max,
        st.percentiles.p75, st.percentiles.p99, st.percentiles.p995,
    });
}

fn saveLatestJson(
    io: std.Io,
    cwd: std.Io.Dir,
    bench_dir: []const u8,
    results: []const zbench.Result,
    timestamp: i64,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/latest.json", .{bench_dir});
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;

    try w.print("{{\n  \"timestamp\": {d},\n  \"results\": [\n", .{timestamp});
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    ");
        try r.writeJSON(w);
    }
    try w.writeAll("\n  ]\n}\n");
}

fn saveStatsJson(
    w: *std.Io.Writer,
    results: []const zbench.Result,
    timestamp: i64,
) !void {
    try w.print("{{\n  \"timestamp\": {d},\n  \"results\": [\n", .{timestamp});
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { ");
        try writeJsonString(w, "name");
        try w.writeAll(": ");
        try writeJsonString(w, r.name);
        try w.writeAll(", ");
        const st = try statsFromResult(&r);
        try w.print("\"iterations\": {d}, \"mean_ns\": {d}, \"stddev_ns\": {d}, \"min_ns\": {d}, \"max_ns\": {d}, \"p75_ns\": {d}, \"p99_ns\": {d}, \"p995_ns\": {d} }}", .{
            r.readings.iterations,
            st.mean, st.stddev, st.min, st.max,
            st.percentiles.p75, st.percentiles.p99, st.percentiles.p995,
        });
    }
    try w.writeAll("\n  ]\n}\n");
}

fn saveHistoryStats(
    io: std.Io,
    cwd: std.Io.Dir,
    history_dir: []const u8,
    results: []const zbench.Result,
    timestamp: i64,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ history_dir, timestamp });

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;

    try saveStatsJson(w, results, timestamp);
}

fn loadPreviousStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    bench_dir: []const u8,
) !std.json.Parsed(HistoryFile) {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/previous_stats.json", .{bench_dir});
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const size = @as(usize, @intCast(try file.length(io)));
    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);
    return try std.json.parseFromSlice(HistoryFile, allocator, content, .{});
}

fn savePreviousStats(
    io: std.Io,
    cwd: std.Io.Dir,
    bench_dir: []const u8,
    results: []const zbench.Result,
    timestamp: i64,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/previous_stats.json", .{bench_dir});

    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;

    try saveStatsJson(w, results, timestamp);
}

fn printComparison(
    io: std.Io,
    file: std.Io.File,
    results: []const zbench.Result,
    prev: HistoryFile,
) !void {
    var fw: std.Io.File.Writer = file.writerStreaming(io, &.{});
    const w: *std.Io.Writer = &fw.interface;

    try w.writeAll("\n\nComparison against previous run:\n");
    try w.writeAll("──────────────────────────────────────────────────────────────────\n");
    try w.print("  {s:<28} {s:>13} {s:>13} {s:>10}\n", .{ "Benchmark", "Before", "After", "Δ" });
    try w.print("  {s:<28} {s:>13} {s:>13} {s:>10}\n", .{ "─" ** 26, "─" ** 11, "─" ** 11, "─" ** 8 });

    for (results) |r| {
        const cur_st = try statsFromResult(&r);
        const prev_st = findPrev(prev.results, r.name) orelse continue;

        if (prev_st.mean_ns == 0) continue;

        const cur_f = fmtDuration(cur_st.mean);
        const prev_f = fmtDuration(prev_st.mean_ns);
        const delta = (@as(f64, @floatFromInt(cur_st.mean)) - @as(f64, @floatFromInt(prev_st.mean_ns))) / @as(f64, @floatFromInt(prev_st.mean_ns)) * 100.0;

        var tag: []const u8 = "";
        if (@abs(delta) > 10) {
            tag = if (delta > 0) " ⚠ regression" else " ✓ improvement";
        }

        const sign: []const u8 = if (delta >= 0) " +" else " ";
        try w.print("  {s:<28} {d:>5.2}{s:>7} {d:>5.2}{s:>7} {s}{d:>5.1}%{s}\n", .{
            r.name,
            prev_f[0], prev_f[1],
            cur_f[0], cur_f[1],
            sign, @abs(delta),
            tag,
        });
    }
}

fn findPrev(records: []const StatsRecord, name: []const u8) ?StatsRecord {
    for (records) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}
