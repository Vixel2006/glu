const std = @import("std");

/// A positional-aware command-line argument parser.
///
/// Reads straight from the raw argv vector so flags and positionals can be
/// mixed in any order. `next` returns the next untouched argument.
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
