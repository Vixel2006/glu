const std = @import("std");
const parser = @import("../src/codegen/parser.zig");
const generator = @import("../src/codegen/generator.zig");

fn makeInit(allocator: std.mem.Allocator) std.process.Init {
    return .{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = &.{} },
        },
        .arena = undefined,
        .gpa = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };
}

pub fn benchGenerateCode(allocator: std.mem.Allocator) void {
    const fields = [_]parser.Field{
        .{ .name = "x", .type_ = "f64" },
        .{ .name = "y", .type_ = "f64" },
        .{ .name = "z", .type_ = "f64" },
    };
    const msgs = [_]parser.Msg{
        .{ .name = "Vec3", .fields = &fields },
    };

    const init = makeInit(allocator);
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(init.io, "/tmp/glu_bench_gen") catch {};

    generator.generate(allocator, init, &msgs, "/tmp/glu_bench_gen/out.zig") catch unreachable;
}
