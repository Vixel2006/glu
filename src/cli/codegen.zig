const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("../codegen/parser.zig");
const generate = @import("../codegen/generator.zig").generate;

pub fn cmdCodegen(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdCodegen_(init, args) catch |err| utils.logErr("codegen", err);
}

fn nextFlag(args: *std.process.Args.Iterator, flag: []const u8) ?[]const u8 {
    const f = args.next() orelse return null;
    if (std.mem.eql(u8, f, flag)) return args.next();
    return null;
}

fn cmdCodegen_(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const file = nextFlag(args, "-f") orelse {
        std.debug.print("usage: glu codegen -f <file.glu> -o </path/to/gen>\n", .{});
        return error.MissingArgument;
    };
    const out_dir = nextFlag(args, "-o") orelse {
        std.debug.print("usage: glu codegen -f <file.glu> -o </path/to/gen>\n", .{});
        return error.MissingArgument;
    };

    const msgs = try parser.parse(init, file);
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

    try generate(init.gpa, init, msgs, out_dir);
}
