const std = @import("std");

const TomlErr = error{
    OutOfMemory,
    FileSystem,
    UnterminatedString,
    UnterminatedArray,
    InvalidSyntax,
};

pub const NodeConfig = struct {
    name: []const u8,
    path: []const u8 = "",
    bin: []const u8 = "",
    extra_cfg: []const []const u8 = &.{},

    fn free(self: NodeConfig, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.path.len > 0) allocator.free(self.path);
        if (self.bin.len > 0) allocator.free(self.bin);
        for (self.extra_cfg) |arg| allocator.free(arg);
        if (self.extra_cfg.len > 0) allocator.free(self.extra_cfg);
    }
};

pub const LaunchConfig = struct {
    nodes: []const NodeConfig,

    pub fn deinit(self: *LaunchConfig, allocator: std.mem.Allocator) void {
        for (self.nodes) |n| n.free(allocator);
        allocator.free(self.nodes);
        self.* = undefined;
    }
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

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (!self.done()) switch (self.buf[self.pos]) {
            ' ', '\t', '\n', '\r' => self.pos += 1,
            else => break,
        };
    }

    fn skipComment(self: *Parser) void {
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

    fn parseString(self: *Parser, allocator: std.mem.Allocator) TomlErr![]const u8 {
        self.pos += 1;
        const start = self.pos;
        while (!self.done() and self.buf[self.pos] != '"') {
            self.pos += 1;
        }
        if (self.done()) return error.UnterminatedString;
        const result = try allocator.dupe(u8, self.buf[start..self.pos]);
        self.pos += 1;
        return result;
    }

    fn parseInlineArray(self: *Parser, allocator: std.mem.Allocator) TomlErr![]const []const u8 {
        self.pos += 1;
        var items: std.ArrayListAligned([]const u8, null) = .empty;
        while (!self.done() and self.buf[self.pos] != ']') {
            self.skipWhitespaceAndNewlines();
            if (self.buf[self.pos] == '"') {
                const item = try self.parseString(allocator);
                try items.append(allocator, item);
            }
            self.skipWhitespaceAndNewlines();
            _ = self.expect(',');
        }
        if (self.done()) return error.UnterminatedArray;
        self.pos += 1;
        return try items.toOwnedSlice(allocator);
    }

    fn parseTableHeader(self: *Parser) ?struct { is_array: bool, name: []const u8 } {
        if (!self.expect('[')) return null;
        const is_array = self.expect('[');
        const name_start = self.pos;
        while (!self.done() and self.buf[self.pos] != ']') {
            self.pos += 1;
        }
        if (self.done()) return null;
        const name = std.mem.trim(u8, self.buf[name_start..self.pos], " \t");
        if (!self.expect(']')) return null;
        if (is_array and !self.expect(']')) return null;
        return .{ .is_array = is_array, .name = name };
    }

    fn parseKeyValue(self: *Parser) ?struct { key: []const u8 } {
        const key_start = self.pos;
        while (!self.done() and self.buf[self.pos] != '=') {
            self.pos += 1;
        }
        if (self.done()) return null;
        const key = std.mem.trim(u8, self.buf[key_start..self.pos], " \t");
        self.pos += 1;
        return .{ .key = key };
    }
};

/// Parse a TOML launch configuration file into a `LaunchConfig`.
///
/// Supports `[[node]]` array-of-tables with `name`, `path`, `bin`,
/// and `extra_cfg` keys. Comments (`#`) and blank lines are ignored.
pub fn parse(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) TomlErr!LaunchConfig {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, file_path, .{}) catch return TomlErr.FileSystem;
    defer file.close(io);

    const size = @as(usize, @intCast(file.length(io) catch return TomlErr.FileSystem));
    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return TomlErr.FileSystem;
    var p = Parser.init(content);
    var nodes: std.ArrayListAligned(NodeConfig, null) = .empty;
    errdefer {
        for (nodes.items) |n| n.free(allocator);
        nodes.deinit(allocator);
    }

    var current_node: ?NodeConfig = null;

    while (!p.done()) {
        p.skipWhitespaceAndNewlines();
        if (p.done()) break;

        if (p.peek() == '#') {
            p.skipComment();
            continue;
        }

        if (p.peek() == '[') {
            if (current_node) |node| try nodes.append(allocator, node);
            current_node = null;

            const header = p.parseTableHeader() orelse return error.InvalidSyntax;
            if (header.is_array and std.mem.eql(u8, header.name, "node")) {
                current_node = NodeConfig{
                    .name = "",
                    .path = "",
                };
            }
            continue;
        }

        if (current_node) |*node| {
            const kv = p.parseKeyValue() orelse return error.InvalidSyntax;
            p.skipWhitespaceAndNewlines();
            const ch = p.peek() orelse return error.InvalidSyntax;

            if (ch == '"') {
                const val = try p.parseString(allocator);
                if (std.mem.eql(u8, kv.key, "name")) {
                    node.name = val;
                } else if (std.mem.eql(u8, kv.key, "path")) {
                    node.path = val;
                } else if (std.mem.eql(u8, kv.key, "bin")) {
                    node.bin = val;
                }
            } else if (ch == '[') {
                node.extra_cfg = try p.parseInlineArray(allocator);
            }
        }
    }

    if (current_node) |node| try nodes.append(allocator, node);

    return LaunchConfig{ .nodes = try nodes.toOwnedSlice(allocator) };
}

fn testToml(allocator: std.mem.Allocator, content: []const u8) !LaunchConfig {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const sub = "launch.toml";
    try dir.dir.writeFile(io, .{ .sub_path = sub, .data = content });
    const full = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &dir.sub_path, sub });
    defer allocator.free(full);
    return try parse(io, allocator, full);
}

test "parse single node" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[node]]
        \\name = "motor_driver"
        \\path = "./nodes/motor_driver"
    ;

    var config = try testToml(allocator, toml);
    defer config.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), config.nodes.len);
    try std.testing.expectEqualStrings("motor_driver", config.nodes[0].name);
    try std.testing.expectEqualStrings("./nodes/motor_driver", config.nodes[0].path);
}

test "parse multiple nodes with extra_cfg" {
    const allocator = std.testing.allocator;
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

    var config = try testToml(allocator, toml);
    defer config.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), config.nodes.len);
    try std.testing.expectEqualStrings("lidar", config.nodes[0].name);
    try std.testing.expectEqualStrings("camera", config.nodes[1].name);
    try std.testing.expectEqual(@as(usize, 2), config.nodes[1].extra_cfg.len);
    try std.testing.expectEqualStrings("--fps", config.nodes[1].extra_cfg[0]);
    try std.testing.expectEqualStrings("30", config.nodes[1].extra_cfg[1]);
}

test "skip comments and blank lines" {
    const allocator = std.testing.allocator;
    const toml =
        \\# this is a comment
        \\
        \\[[node]]
        \\# inline comment
        \\name = "test"
        \\path = "./test"
    ;

    var config = try testToml(allocator, toml);
    defer config.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), config.nodes.len);
    try std.testing.expectEqualStrings("test", config.nodes[0].name);
}
