const std = @import("std");

const ParseErr = error{
    OutOfMemory,
    FileSystem,
    InvalidMessage,
    MessageTooLarge,
};

pub const Field = struct {
    name: []const u8,
    type_: []const u8,
};

pub const Msg = struct {
    name: []const u8,
    fields: []const Field,
};

const BUF_SIZE = 4096;

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => break,
        }
    }
    return i;
}

fn findClosingBrace(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var found_open = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => {
                depth += 1;
                found_open = true;
            },
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (found_open and depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn dupStr(allocator: std.mem.Allocator, s: []const u8) ParseErr![]u8 {
    const result = try allocator.alloc(u8, s.len);
    @memcpy(result, s);
    return result;
}

fn parseMessageText(allocator: std.mem.Allocator, text: []const u8) ParseErr!Msg {
    var pos: usize = 7;
    pos = skipWhitespace(text, pos);

    var name_end = pos;
    while (name_end < text.len) : (name_end += 1) {
        switch (text[name_end]) {
            ' ', '\t', '\n', '\r', '{' => break,
            else => {},
        }
    }

    const name = try dupStr(allocator, text[pos..name_end]);
    errdefer allocator.free(name);

    pos = name_end;
    pos = skipWhitespace(text, pos);

    if (pos >= text.len or text[pos] != '{') return error.InvalidMessage;
    pos += 1;

    var fields = std.ArrayListAligned(Field, null).empty;
    errdefer {
        for (fields.items) |f| {
            allocator.free(f.name);
            allocator.free(f.type_);
        }
        fields.deinit(allocator);
    }

    while (pos < text.len and text[pos] != '}') {
        pos = skipWhitespace(text, pos);
        if (pos >= text.len) break;

        var field_start = pos;
        while (pos < text.len and text[pos] != ':') : (pos += 1) {}
        if (pos >= text.len or text[pos] != ':') return error.InvalidMessage;
        const field_name = std.mem.trim(u8, text[field_start..pos], " \t");
        pos += 1;

        pos = skipWhitespace(text, pos);
        field_start = pos;
        while (pos < text.len and text[pos] != ',' and text[pos] != '\n' and text[pos] != '}') : (pos += 1) {}
        const field_type = std.mem.trim(u8, text[field_start..pos], " \t");

        if (field_name.len == 0 or field_type.len == 0) return error.InvalidMessage;

        try fields.append(allocator, .{
            .name = try dupStr(allocator, field_name),
            .type_ = try dupStr(allocator, field_type),
        });

        if (pos < text.len and text[pos] == ',') pos += 1;
        if (pos < text.len and text[pos] == '\n') pos += 1;
    }

    return Msg{
        .name = name,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

/// Parse a `.glu` message definition file into an array of `Msg`.
///
/// The file is read incrementally into a fixed buffer. Messages are
/// delimited by `message <name> { ... }` blocks. Supports multiple
/// messages per file.
pub fn parse(init: std.process.Init, fp: []const u8) ParseErr![]Msg {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(init.io, fp, .{}) catch return ParseErr.FileSystem;
    defer file.close(init.io);

    var messages = std.ArrayListAligned(Msg, null).empty;
    errdefer {
        for (messages.items) |msg| {
            init.gpa.free(msg.name);
            for (msg.fields) |f| {
                init.gpa.free(f.name);
                init.gpa.free(f.type_);
            }
            init.gpa.free(msg.fields);
        }
        messages.deinit(init.gpa);
    }

    var buf: [BUF_SIZE]u8 = undefined;
    var end: usize = 0;
    var file_offset: u64 = 0;

    while (true) {
        if (end < buf.len) {
            const n = file.readPositionalAll(init.io, buf[end..], file_offset) catch return ParseErr.FileSystem;
            if (n == 0 and end == 0) break;
            end += n;
            file_offset += n;
        }
        if (end == 0) break;

        var pos: usize = 0;
        while (pos < end) {
            pos = skipWhitespace(buf[0..end], pos);
            if (pos >= end) break;

            if (pos + 7 <= end and std.mem.eql(u8, buf[pos..pos + 7], "message")) {
                const close = findClosingBrace(buf[0..end], pos);
                if (close) |c| {
                    const msg = try parseMessageText(init.gpa, buf[pos..c + 1]);
                    try messages.append(init.gpa, msg);
                    pos = c + 1;
                } else {
                    break;
                }
            } else {
                pos += 1;
            }
        }

        if (pos > 0) {
            if (pos < end) {
                std.mem.copyForwards(u8, buf[0..], buf[pos..end]);
                end -= pos;
            } else {
                end = 0;
            }
        }

        if (end >= buf.len) return error.MessageTooLarge;
    }

    return messages.toOwnedSlice(init.gpa);
}

test "parse inline stub" {
    const content =
        \\message frame {
        \\  id: i32,
        \\  name: i32
        \\}
        \\
        \\message pose {
        \\  x: f64,
        \\  y: f64,
        \\  z: f64
        \\}
    ;

    const init: std.process.Init = .{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = &.{} },
        },
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };

    const cwd = std.Io.Dir.cwd();
    const filename = "src/codegen/_test_stub.glu";

    try cwd.createDirPath(init.io, "src/codegen");

    {
        var file = try cwd.createFile(init.io, filename, .{});
        defer file.close(init.io);
        try file.writePositionalAll(init.io, content, 0);
    }
    defer cwd.deleteFile(init.io, filename) catch {};

    const msgs = try parse(init, filename);
    defer {
        for (msgs) |msg| {
            init.gpa.free(msg.name);
            for (msg.fields) |f| {
                init.gpa.free(f.name);
                init.gpa.free(f.type_);
            }
            init.gpa.free(msg.fields);
        }
        init.gpa.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqualStrings("frame", msgs[0].name);
    try std.testing.expectEqual(@as(usize, 2), msgs[0].fields.len);
    try std.testing.expectEqualStrings("id", msgs[0].fields[0].name);
    try std.testing.expectEqualStrings("i32", msgs[0].fields[0].type_);
    try std.testing.expectEqualStrings("pose", msgs[1].name);
    try std.testing.expectEqual(@as(usize, 3), msgs[1].fields.len);
    try std.testing.expectEqualStrings("x", msgs[1].fields[0].name);
    try std.testing.expectEqualStrings("f64", msgs[1].fields[0].type_);
    try std.testing.expectEqualStrings("z", msgs[1].fields[2].name);
    try std.testing.expectEqualStrings("f64", msgs[1].fields[2].type_);
}
