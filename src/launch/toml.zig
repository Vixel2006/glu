const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

const TomlErr = error{
    FileSystem,
    UnterminatedString,
    UnterminatedArray,
    InvalidSyntax,
    TooManyNodes,
    TooManyArgs,
};

/// A parsed node. String fields reference the caller's file buffer and stay
/// valid only while that buffer lives.
pub const NodeConfig = struct {
    name: []const u8 = "",
    path: []const u8 = "",
    bin: []const u8 = "",
    extra_cfg: [constants.MAX_ARGS][]const u8 = undefined,
    extra_cfg_len: usize = 0,
};

pub const LaunchConfig = struct {
    nodes: []const NodeConfig,
};

const Parser = struct {
    buf: []const u8,
    pos: usize,

    fn init(buf: []const u8) Parser {
        return .{ .buf = buf, .pos = 0 };
    }

    fn done(self: *const Parser) bool {
        return self.pos >= self.buf.len;
    }

    fn skip_space(self: *Parser) void {
        while (!self.done()) switch (self.buf[self.pos]) {
            ' ', '\t', '\n', '\r' => self.pos += 1,
            else => break,
        };
    }

    fn skip_comment(self: *Parser) void {
        while (!self.done() and self.buf[self.pos] != '\n') self.pos += 1;
    }

    fn expect(self: *Parser, ch: u8) bool {
        if (!self.done() and self.buf[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn peek(self: *Parser) ?u8 {
        if (!self.done()) return self.buf[self.pos];
        return null;
    }

    fn parse_string(self: *Parser) TomlErr![]const u8 {
        self.pos += 1;
        const start = self.pos;
        while (!self.done() and self.buf[self.pos] != '"') self.pos += 1;
        if (self.done()) return error.UnterminatedString;
        const result = self.buf[start..self.pos];
        self.pos += 1;
        return result;
    }

    fn parse_inline_array(self: *Parser, out: [][]const u8) TomlErr!usize {
        self.pos += 1;
        var count: usize = 0;
        while (!self.done() and self.buf[self.pos] != ']') {
            self.skip_space();
            if (self.buf[self.pos] == '"') {
                if (count >= out.len) return error.TooManyArgs;
                out[count] = try self.parse_string();
                count += 1;
            }
            self.skip_space();
            _ = self.expect(',');
        }
        if (self.done()) return error.UnterminatedArray;
        self.pos += 1;
        return count;
    }

    fn parse_table_header(self: *Parser) ?struct { is_array: bool, name: []const u8 } {
        if (!self.expect('[')) return null;
        const is_array = self.expect('[');
        const name_start = self.pos;
        while (!self.done() and self.buf[self.pos] != ']') self.pos += 1;
        if (self.done()) return null;
        const name = std.mem.trim(u8, self.buf[name_start..self.pos], " \t");
        if (!self.expect(']')) return null;
        if (is_array and !self.expect(']')) return null;
        return .{ .is_array = is_array, .name = name };
    }

    fn parse_key_value(self: *Parser) ?[]const u8 {
        const key_start = self.pos;
        while (!self.done() and self.buf[self.pos] != '=') self.pos += 1;
        if (self.done()) return null;
        const key = std.mem.trim(u8, self.buf[key_start..self.pos], " \t");
        self.pos += 1;
        return key;
    }
};

/// Parse a TOML launch config file `content` (read by the caller into
/// `content`) into `nodes`. `nodes` slices reference `content`.
///
/// Supports `[[node]]` array-of-tables with `name`, `path`, `bin`, and
/// `extra_cfg` keys. Comments (`#`) and blank lines are ignored.
/// Returns the number of nodes parsed.
pub fn parse(io: std.Io, file_path: []const u8, content: []u8, nodes: []NodeConfig) TomlErr!usize {
    assert(file_path.len > 0);

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, file_path, .{}) catch return TomlErr.FileSystem;
    defer file.close(io);

    const size = @as(usize, @intCast(file.length(io) catch return TomlErr.FileSystem));
    if (size > content.len) return TomlErr.FileSystem;
    const got = file.readPositionalAll(io, content[0..size], 0) catch return TomlErr.FileSystem;

    var p = Parser.init(content[0..got]);
    var node_count: usize = 0;
    var active = false;

    while (!p.done()) {
        p.skip_space();
        if (p.done()) break;

        if (p.peek() == '#') {
            p.skip_comment();
            continue;
        }

        if (p.peek() == '[') {
            if (active) node_count += 1;
            active = false;
            const header = p.parse_table_header() orelse return error.InvalidSyntax;
            if (header.is_array and std.mem.eql(u8, header.name, "node")) {
                if (node_count >= nodes.len) return error.TooManyNodes;
                nodes[node_count] = .{};
                active = true;
            }
            continue;
        }

        const key = p.parse_key_value() orelse return error.InvalidSyntax;
        p.skip_space();
        const ch = p.peek() orelse return error.InvalidSyntax;
        if (active) {
            const node = &nodes[node_count];
            if (ch == '"') {
                const val = try p.parse_string();
                if (std.mem.eql(u8, key, "name")) {
                    node.name = val;
                } else if (std.mem.eql(u8, key, "path")) {
                    node.path = val;
                } else if (std.mem.eql(u8, key, "bin")) {
                    node.bin = val;
                }
            } else if (ch == '[') {
                node.extra_cfg_len = try p.parse_inline_array(node.extra_cfg[0..]);
            }
        }
    }

    if (active) node_count += 1;
    return node_count;
}

fn parse_tom(content: []const u8, nodes: []NodeConfig, content_buf: []u8) !usize {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const sub = "launch.toml";
    try dir.dir.writeFile(io, .{ .sub_path = sub, .data = content });
    var full_buf: [256]u8 = undefined;
    const full = try std.fmt.bufPrint(&full_buf, ".zig-cache/tmp/{s}/{s}", .{ &dir.sub_path, sub });
    return try parse(io, full, content_buf, nodes);
}

test "parse single node" {
    const toml =
        \\[[node]]
        \\name = "motor_driver"
        \\path = "./nodes/motor_driver"
    ;

    var content_buf: [1024]u8 = undefined;
    var nodes: [constants.MAX_NODES]NodeConfig = undefined;
    const n = try parse_tom(toml, &nodes, &content_buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("motor_driver", nodes[0].name);
    try std.testing.expectEqualStrings("./nodes/motor_driver", nodes[0].path);
}

test "parse multiple nodes with extra_cfg" {
    const toml =
        \\[[node]]
        \\name = "lidar"
        \\path = "./nodes/lidar"
        \\
        \\[[node]]
        \\name = "camera"
        \\path = "./nodes/camera"
        \\extra_cfg = ["--fps", "30"]
    ;

    var content_buf: [1024]u8 = undefined;
    var nodes: [constants.MAX_NODES]NodeConfig = undefined;
    const n = try parse_tom(toml, &nodes, &content_buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("lidar", nodes[0].name);
    try std.testing.expectEqualStrings("camera", nodes[1].name);
    try std.testing.expectEqual(@as(usize, 2), nodes[1].extra_cfg_len);
    try std.testing.expectEqualStrings("--fps", nodes[1].extra_cfg[0]);
    try std.testing.expectEqualStrings("30", nodes[1].extra_cfg[1]);
}

test "skip comments and blank lines" {
    const toml =
        \\# this is a comment
        \\
        \\[[node]]
        \\# inline comment
        \\name = "test"
        \\path = "./test"
    ;

    var content_buf: [1024]u8 = undefined;
    var nodes: [constants.MAX_NODES]NodeConfig = undefined;
    const n = try parse_tom(toml, &nodes, &content_buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("test", nodes[0].name);
}
