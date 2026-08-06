const std = @import("std");

/// A positional-aware command-line argument parser.
///
/// Reads straight from the raw argv vector so flags and positionals can be
/// mixed in any order. `next` returns the next untouched argument;
/// `flag`/`value` consume an argument only when it matches `name`, leaving
/// the position intact otherwise.
pub const Args = struct {
    items: []const [*:0]const u8,
    pos: usize,

    pub fn init(p: std.process.Init) Args {
        const items = p.minimal.args.vector;
        return .{ .items = if (items.len > 0) items[1..] else items, .pos = 0 };
    }

    /// The next untouched argument, or null when exhausted.
    pub fn next(self: *Args) ?[]const u8 {
        if (self.pos >= self.items.len) return null;
        const arg = std.mem.span(self.items[self.pos]);
        self.pos += 1;
        return arg;
    }

    /// If the next argument equals `name`, consume it and return true.
    pub fn flag(self: *Args, name: []const u8) bool {
        if (self.pos >= self.items.len) return false;
        if (!std.mem.eql(u8, std.mem.span(self.items[self.pos]), name)) return false;
        self.pos += 1;
        return true;
    }

    /// If the next argument equals `name`, consume it and the value after it.
    pub fn value(self: *Args, name: []const u8) ?[]const u8 {
        if (!self.flag(name)) return null;
        if (self.pos >= self.items.len) return null;
        const val = std.mem.span(self.items[self.pos]);
        self.pos += 1;
        return val;
    }
};

fn make_init(argv: []const [*:0]const u8) std.process.Init {
    return .{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = argv },
        },
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };
}

test "next skips argv0 and drains positionals" {
    var a = Args.init(make_init(&.{ "glu", "info", "/topic" }));
    try std.testing.expectEqualStrings("info", a.next().?);
    try std.testing.expectEqualStrings("/topic", a.next().?);
    try std.testing.expect(a.next() == null);
}

test "switch consumes a matching flag only" {
    var a = Args.init(make_init(&.{ "glu", "ps", "-w" }));
    _ = a.next(); // consume the subcommand, as main does
    try std.testing.expect(a.flag("-w"));
    try std.testing.expect(a.next() == null);
}

test "switch does not consume a non-matching flag" {
    var a = Args.init(make_init(&.{ "glu", "ps", "-v" }));
    _ = a.next();
    try std.testing.expect(!a.flag("-w"));
    try std.testing.expectEqualStrings("-v", a.next().?);
}

test "value consumes flag and trailing value" {
    var a = Args.init(make_init(&.{ "glu", "launch", "-f", "gly.toml" }));
    _ = a.next();
    try std.testing.expectEqualStrings("gly.toml", a.value("-f").?);
    try std.testing.expect(a.next() == null);
}

test "value returns null when absent, leaving position intact" {
    var a = Args.init(make_init(&.{ "glu", "launch", "-d" }));
    _ = a.next();
    try std.testing.expect(a.value("-f") == null);
    try std.testing.expect(a.flag("-d"));
}

test "flags may follow positionals" {
    var a = Args.init(make_init(&.{ "glu", "logs", "node", "--tail", "50" }));
    var node: ?[]const u8 = null;
    var tail: ?[]const u8 = null;
    while (a.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tail")) {
            tail = a.next();
        } else {
            node = arg;
        }
    }
    try std.testing.expectEqualStrings("node", node.?);
    try std.testing.expectEqualStrings("50", tail.?);
}
