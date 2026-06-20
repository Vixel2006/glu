const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("../codegen/parser.zig");
const generate = @import("../codegen/generator.zig").generate;

pub fn cmdCodegen(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdCodegen_(init, args) catch |err| utils.logErr("codegen", err);
}

fn cmdCodegen_(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const file = utils.parseFlag(args, "-f") orelse {
        std.debug.print("usage: glu codegen -f <file.glu> -o </path/to/gen>\n", .{});
        return error.MissingArgument;
    };

    const msgs = parser.parse(init, file) catch |err| {
        std.debug.print("error parsing '{s}': {}\n", .{ file, err });
        return err;
    };
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

    const out_dir = utils.parseFlag(args, "-o") orelse {
        std.debug.print("usage: glu codegen -f <file.glu> </path/to/gen\n", .{});
        return error.MissingArgument;
    };

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try generate(init.gpa, init, msgs, out_dir);
    try out.flush();
}
