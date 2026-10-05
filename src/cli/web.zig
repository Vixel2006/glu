const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const constants = @import("../constants.zig");
const protocol = @import("../daemon/protocol.zig");
const daemon_client = @import("../daemon/client.zig");
const IO = @import("../io.zig").IO;
const Shm = @import("../channel/shm.zig").Shm;
const slowest_reader = @import("../channel/shm.zig").slowest_reader;
const logs = @import("../debug/logs.zig");
const c = std.c;
const linux = std.os.linux;

const ui = @embedFile("webui/index.html");

pub const WebOptions = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    open: bool = false,
};

fn parseU16(s: []const u8, def: u16) u16 {
    return std.fmt.parseInt(u16, s, 10) catch def;
}

pub fn cmd_web(init: std.process.Init, args: *parser.Args) !void {
    var opts = WebOptions{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bind")) {
            if (args.next()) |v| {
                opts.bind = v;
            } else {
                var ew = utils.err_writer(init);
                ew.interface.print("usage: glu web [--bind <addr>] [--port <n>] [--open|-o]\n", .{}) catch {};
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |v| {
                opts.port = parseU16(v, opts.port);
            } else {
                var ew = utils.err_writer(init);
                ew.interface.print("usage: glu web [--bind <addr>] [--port <n>] [--open|-o]\n", .{}) catch {};
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, arg, "--open") or std.mem.eql(u8, arg, "-o")) {
            opts.open = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var ew = utils.err_writer(init);
            ew.interface.print("unknown flag: {s}\nusage: glu web [--bind <addr>] [--port <n>] [--open|-o]\n", .{arg}) catch {};
            return error.InvalidArgument;
        } else {
            var ew = utils.err_writer(init);
            ew.interface.print("unexpected argument: {s}\nusage: glu web [--bind <addr>] [--port <n>] [--open|-o]\n", .{arg}) catch {};
            return error.InvalidArgument;
        }
    }

    try run_web_server(init.arena.allocator(), init, opts);
}

fn owner_name(buf: []u8, nodes: []protocol.Node, pid: std.os.linux.pid_t) []const u8 {
    if (pid == 0) return "-";
    for (nodes) |n| {
        if (n.pid) |p| {
            if (p == pid) {
                const name = n.name_slice();
                // Copy into provided buffer to ensure valid lifetime and content
                const len = @min(name.len, buf.len);
                @memcpy(buf[0..len], name[0..len]);
                return buf[0..len];
            }
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{pid}) catch "-";
}

fn build_status_json(allocator: std.mem.Allocator) ![]const u8 {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var client = daemon_client.Client.ensure_running(&io) catch |err| {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"error\",\"error\":\"{s}\"}}",
            .{@errorName(err)},
        );
    };
    defer client.deinit();

    var node_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    var nodes_count: usize = 0;
    nodes_count = client.list_nodes(&node_buf) catch 0;
    const nodes_list = node_buf[0..nodes_count];

    var topic_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    var topics_count: usize = 0;
    topics_count = client.list_topics(&topic_buf) catch 0;
    const topics_list = topic_buf[0..topics_count];

    var net_buf: [constants.MAX_ENTRIES]protocol.NET_CHAN = undefined;
    const list_net_result = client.list_net(&net_buf);
    const nets_count = blk: {
        const res = list_net_result catch |err| {
            std.debug.print("list_net error: {s}\n", .{@errorName(err)});
            break :blk 0;
        };
        break :blk res;
    };
    const nets_list = net_buf[0..nets_count];

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "{{\"status\":\"ok\",\"nodes\":[", .{});
    for (nodes_list, 0..) |n, i| {
        if (i > 0) try out.append(allocator, ',');
        const alive = n.pid != null;
        const pid_str = if (n.pid) |p| blk: {
            var b: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&b, "{d}", .{p}) catch "-";
        } else "-";
        var up_s: u64 = 0;
        if (alive) {
            up_s = utils.uptime_secs(&n);
        }
        try out.print(allocator, "{{\"name\":\"{s}\",\"pid\":{s},\"alive\":{s},\"uptime_s\":{d}}}", .{
            n.name_slice(),
            pid_str,
            if (alive) "true" else "false",
            up_s,
        });
    }

    try out.appendSlice(allocator, "],\"topics\":[");
    for (topics_list, 0..) |t, i| {
        if (i > 0) try out.append(allocator, ',');
        var owner_buf: [64]u8 = undefined;
        const owner = owner_name(&owner_buf, nodes_list, t.writer_pid);
        try out.print(allocator, "{{\"name\":\"{s}\",\"writer_pid\":{d},\"owner\":\"{s}\",\"tos\":{d},\"msg_size\":{d},\"capacity\":{d},\"num_readers\":{d}}}", .{
            t.name[0..t.name_len],
            t.writer_pid,
            owner,
            t.tos,
            t.msg_size,
            t.capacity,
            t.num_readers,
        });
    }

    try out.appendSlice(allocator, "],\"net\":[");
    for (nets_list, 0..) |n, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(allocator, "{{\"name\":\"{s}\",\"writer_pid\":{d},\"tos\":{d},\"msg_size\":{d},\"capacity\":{d},\"num_reg\":{d},\"port\":{d}}}", .{
            n.name[0..n.name_len],
            n.writer_pid,
            n.tos,
            n.msg_size,
            n.capacity,
            n.num_reg,
            n.port,
        });
    }

    try out.appendSlice(allocator, "]}");

    return try out.toOwnedSlice(allocator);
}

fn build_topics_detail_json(allocator: std.mem.Allocator) ![]const u8 {
    var io = try IO.init(32, 0);
    defer io.deinit();

    var client = daemon_client.Client.ensure_running(&io) catch |err| {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"error\",\"error\":\"{s}\"}}",
            .{@errorName(err)},
        );
    };
    defer client.deinit();

    var node_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    var nodes_count: usize = 0;
    nodes_count = client.list_nodes(&node_buf) catch 0;
    const nodes_list = node_buf[0..nodes_count];

    var topic_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    var topics_count: usize = 0;
    topics_count = client.list_topics(&topic_buf) catch 0;
    const topics_list = topic_buf[0..topics_count];

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.print(allocator, "{{\"status\":\"ok\",\"topics\":[", .{});
    for (topics_list, 0..) |t, i| {
        if (i > 0) try out.append(allocator, ',');

        var owner_buf: [64]u8 = undefined;
        const owner = owner_name(&owner_buf, nodes_list, t.writer_pid);

        // Open the shared memory segment to read live cursor data
        const topic_name = t.name[0..t.name_len];
        var shm = Shm.open(topic_name, t.msg_size, t.capacity, @enumFromInt(t.tos)) catch {
            // If we can't open, return basic info without cursor data
            try out.print(allocator, "{{\"name\":\"{s}\",\"writer_pid\":{d},\"owner\":\"{s}\",\"tos\":{d},\"msg_size\":{d},\"capacity\":{d},\"num_readers\":{d},\"write_cursor\":0,\"readers\":[]}}", .{
                t.name[0..t.name_len],
                t.writer_pid,
                owner,
                t.tos,
                t.msg_size,
                t.capacity,
                t.num_readers,
            });
            continue;
        };
        defer shm.close();

        const hdr = shm.header;
        const write_cursor = hdr.write;
        const slowest = slowest_reader(&hdr.readers, write_cursor);
        const depth = write_cursor -% slowest;
        const pct = if (t.capacity > 0) @as(f64, @floatFromInt(depth)) / @as(f64, @floatFromInt(t.capacity)) * 100.0 else 0.0;

        try out.print(allocator, "{{\"name\":\"{s}\",\"writer_pid\":{d},\"owner\":\"{s}\",\"tos\":{d},\"msg_size\":{d},\"capacity\":{d},\"num_readers\":{d},\"write_cursor\":{d},\"queued\":{d},\"pct_full\":{d:.1},\"readers\":[", .{
            t.name[0..t.name_len],
            t.writer_pid,
            owner,
            t.tos,
            t.msg_size,
            t.capacity,
            t.num_readers,
            write_cursor,
            depth,
            pct,
        });

        var first_reader = true;
        for (hdr.readers, 0..) |entry, idx| {
            if (entry >> 32 == 0) continue; // Skip inactive
            if (!first_reader) try out.append(allocator, ',');
            first_reader = false;
            const pid: u32 = @intCast(entry >> 32);
            const cursor: u32 = @truncate(entry);
            const behind = write_cursor -% cursor;
            const read_pos = if (t.capacity > 0) cursor % t.capacity else 0;
            // Find node name for this PID
            var reader_name: []const u8 = "unknown";
            for (nodes_list) |n| {
                if (n.pid) |p| {
                    if (p == pid) {
                        reader_name = n.name_slice();
                        break;
                    }
                }
            }
            try out.print(allocator, "{{\"index\":{d},\"pid\":{d},\"name\":\"{s}\",\"cursor\":{d},\"read_pos\":{d},\"behind\":{d}}}", .{
                idx, pid, reader_name, cursor, read_pos, behind,
            });
        }

        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "]}");

    return try out.toOwnedSlice(allocator);
}

fn build_logs_json(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    // Parse query parameters: /api/logs?node=<name>&tail=<n>&head=<n>
    var node_name: []const u8 = "";
    var tail: u64 = 100;
    var head: u64 = 0;

    const query_start = std.mem.indexOfScalar(u8, target, '?');
    if (query_start) |qs| {
        const query = target[qs + 1 ..];
        var params = std.mem.splitSequence(u8, query, "&");
        while (params.next()) |param| {
            var kv = std.mem.splitSequence(u8, param, "=");
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "node")) {
                node_name = value;
            } else if (std.mem.eql(u8, key, "tail")) {
                tail = std.fmt.parseInt(u64, value, 10) catch 100;
            } else if (std.mem.eql(u8, key, "head")) {
                head = std.fmt.parseInt(u64, value, 10) catch 0;
            }
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (node_name.len == 0) {
        try out.print(allocator, "{{\"status\":\"error\",\"error\":\"missing node parameter\"}}", .{});
        return try out.toOwnedSlice(allocator);
    }

    var buf: [16384]u8 = undefined;
    var len: usize = 0;

    if (head > 0) {
        len = try logs.read_log_head(constants.LOGS_DIR, node_name, head, &buf);
    } else {
        len = try logs.read_log_tail(constants.LOGS_DIR, node_name, tail, &buf);
    }

    const log_content = if (len > 0) buf[0..len] else "";

    // Count lines in content
    var line_count: u64 = 0;
    for (log_content) |ch| {
        if (ch == '\n') line_count += 1;
    }
    if (log_content.len > 0 and log_content[log_content.len - 1] != '\n') line_count += 1;

    // JSON-escape the log content
    var escaped = std.ArrayList(u8).empty;
    defer escaped.deinit(allocator);
    try escaped.ensureTotalCapacity(allocator, log_content.len * 2);
    for (log_content) |ch| {
        switch (ch) {
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            0x08 => try escaped.appendSlice(allocator, "\\b"),
            0x0C => try escaped.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20) {
                    var hex: [6]u8 = undefined;
                    const hi = ch >> 4;
                    const lo = ch & 0xF;
                    hex[0] = '\\';
                    hex[1] = 'u';
                    hex[2] = '0';
                    hex[3] = '0';
                    hex[4] = if (hi < 10) hi + '0' else hi - 10 + 'a';
                    hex[5] = if (lo < 10) lo + '0' else lo - 10 + 'a';
                    try escaped.appendSlice(allocator, &hex);
                } else {
                    try escaped.append(allocator, ch);
                }
            },
        }
    }

    try out.print(allocator, "{{\"status\":\"ok\",\"node\":\"{s}\",\"lines\":{d},\"content\":\"{s}\"}}", .{
        node_name, line_count, escaped.items,
    });

    return try out.toOwnedSlice(allocator);
}

const HttpRequest = struct {
    method: []const u8,
    target: []const u8,
};

fn parseRequestLine(line: []const u8) ?HttpRequest {
    var parts = std.mem.splitSequence(u8, line, " ");
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    _ = parts.next();
    return HttpRequest{ .method = method, .target = target };
}

fn writeResponse(fd: i32, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const hdr1 = try std.fmt.bufPrint(buf[pos..], "HTTP/1.1 {s}\r\n", .{status});
    pos += hdr1.len;
    const hdr2 = try std.fmt.bufPrint(buf[pos..], "Content-Type: {s}\r\n", .{content_type});
    pos += hdr2.len;
    const hdr3 = try std.fmt.bufPrint(buf[pos..], "Content-Length: {d}\r\n", .{body.len});
    pos += hdr3.len;
    if (std.mem.startsWith(u8, content_type, "application/json")) {
        const cc = "Cache-Control: no-store\r\n";
        @memcpy(buf[pos .. pos + cc.len], cc);
        pos += cc.len;
    } else {
        const cc = "Cache-Control: no-cache\r\n";
        @memcpy(buf[pos .. pos + cc.len], cc);
        pos += cc.len;
    }
    const conn_hdr = "Connection: close\r\n\r\n";
    @memcpy(buf[pos .. pos + conn_hdr.len], conn_hdr);
    pos += conn_hdr.len;

    var sent: usize = 0;
    while (sent < pos) {
        const n = c.send(fd, buf[sent..pos].ptr, pos - sent, 0);
        if (n < 0) break;
        sent += @intCast(n);
    }

    sent = 0;
    while (sent < body.len) {
        const n = c.send(fd, body[sent..].ptr, body[sent..].len, 0);
        if (n < 0) break;
        sent += @intCast(n);
    }
}

fn read_line(fd: i32, allocator: std.mem.Allocator, max: usize) !?[]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var ch: [1]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &ch, 1, 0);
        if (n <= 0) return null;
        try out.append(ch[0]);
        if (ch[0] == '\n') break;
        if (out.items.len >= max) break;
    }
    return try out.toOwnedSlice();
}

fn inet_addr(ip: []const u8) u32 {
    var a: [4]u8 = undefined;
    var it = std.mem.splitSequence(u8, ip, ".");
    a[0] = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    a[1] = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    a[2] = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    a[3] = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    return std.mem.bytesAsValue(u32, &a).*;
}

pub fn run_web_server(allocator: std.mem.Allocator, init: std.process.Init, opts: WebOptions) !void {
    const sock_res = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (sock_res < 0) return error.SocketCreateFailed;
    const sock = @as(i32, @intCast(sock_res));
    errdefer _ = linux.close(sock);

    const one: c_int = 1;
    _ = c.setsockopt(sock, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));

    var addr: linux.sockaddr.in = undefined;
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, opts.port);
    addr.addr = inet_addr(opts.bind);

    if (linux.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) < 0) {
        return error.BindFailed;
    }
    if (linux.listen(sock, 16) < 0) {
        return error.ListenFailed;
    }

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://{s}:{d}", .{ opts.bind, opts.port });

    var fw = utils.writer(init);
    fw.interface.print("glu web UI listening on {s}\n", .{url}) catch {};
    fw.interface.print("open in browser: {s}\n", .{url}) catch {};

    while (true) {
        var client_addr: linux.sockaddr = undefined;
        var client_len: linux.socklen_t = @sizeOf(linux.sockaddr);
        const client_fd_res = linux.accept(sock, @ptrCast(&client_addr), &client_len);
        if (client_fd_res < 0) {
            std.log.warn("accept error", .{});
            continue;
        }
        const client_fd = @as(i32, @intCast(client_fd_res));

        const first_line = read_line(client_fd, allocator, 4096) catch null;
        if (first_line == null) {
            _ = linux.close(client_fd);
            continue;
        }
        defer allocator.free(first_line.?);

        const req = parseRequestLine(first_line.?) orelse {
            _ = linux.close(client_fd);
            continue;
        };

        while (true) {
            const line = read_line(client_fd, allocator, 4096) catch break;
            if (line) |l| {
                if (l.len <= 2) {
                    allocator.free(l);
                    break;
                }
                allocator.free(l);
            } else break;
        }

        if (!std.mem.eql(u8, req.method, "GET")) {
            writeResponse(client_fd, "405 Method Not Allowed", "text/plain", "Method Not Allowed") catch {};
            _ = linux.close(client_fd);
            continue;
        }

        if (std.mem.startsWith(u8, req.target, "/api/status")) {
            const body = build_status_json(allocator) catch |err| blk: {
                const b = std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{@errorName(err)}) catch "error";
                break :blk b;
            };
            defer allocator.free(body);
            writeResponse(client_fd, "200 OK", "application/json; charset=utf-8", body) catch {};
            _ = linux.close(client_fd);
            continue;
        }

        if (std.mem.startsWith(u8, req.target, "/api/topics")) {
            const body = build_topics_detail_json(allocator) catch |err| blk: {
                const b = std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{@errorName(err)}) catch "error";
                break :blk b;
            };
            defer allocator.free(body);
            writeResponse(client_fd, "200 OK", "application/json; charset=utf-8", body) catch {};
            _ = linux.close(client_fd);
            continue;
        }

        if (std.mem.startsWith(u8, req.target, "/api/logs")) {
            const body = build_logs_json(allocator, req.target) catch |err| blk: {
                const b = std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{@errorName(err)}) catch "error";
                break :blk b;
            };
            defer allocator.free(body);
            writeResponse(client_fd, "200 OK", "application/json; charset=utf-8", body) catch {};
            _ = linux.close(client_fd);
            continue;
        }

        if (std.mem.eql(u8, req.target, "/") or std.mem.startsWith(u8, req.target, "/index.html")) {
            writeResponse(client_fd, "200 OK", "text/html; charset=utf-8", ui) catch {};
            _ = linux.close(client_fd);
            continue;
        }

        writeResponse(client_fd, "200 OK", "text/html; charset=utf-8", ui) catch {};
        _ = linux.close(client_fd);
    }
}
