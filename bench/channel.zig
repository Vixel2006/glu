const std = @import("std");
const c = std.c;
const zbench = @import("zbench");
const Channel = @import("glu").Channel;
const write = @import("glu").write;
const read = @import("glu").read;

const Msg32 = extern struct { data: [32]u8 };
const Msg256 = extern struct { data: [256]u8 };
const Msg1024 = extern struct { data: [1024]u8 };
const Msg4096 = extern struct { data: [4096]u8 };

fn initMsg(comptime T: type) T {
    var msg: T = undefined;
    @memset(@as(*[1]u8, @ptrCast(&msg)), 0xAB);
    return msg;
}

var chan32: Channel = undefined;
var chan256: Channel = undefined;
var chan1024: Channel = undefined;
var chan4096: Channel = undefined;
var chan_read: Channel = undefined;

const CAP = 16384;

fn beforeWrite(chan: *Channel, comptime T: type, name: []const u8) void {
    chan.* = Channel.open(std.heap.page_allocator, name, @sizeOf(T), CAP) catch unreachable;
}

fn afterWrite(chan: *Channel) void {
    chan.close();
}

fn resetWrite(chan: *Channel) void {
    chan.header.write = 0;
}

fn resetRead(chan: *Channel) void {
    chan.header.read = 0;
}

fn beforeWrite32() void {
    beforeWrite(&chan32, Msg32, "/glu_bw32");
}

fn afterWrite32() void {
    afterWrite(&chan32);
}

fn resetWrite32() void {
    resetWrite(&chan32);
}

fn beforeWrite256() void {
    beforeWrite(&chan256, Msg256, "/glu_bw256");
}

fn afterWrite256() void {
    afterWrite(&chan256);
}

fn resetWrite256() void {
    resetWrite(&chan256);
}

fn beforeWrite1024() void {
    beforeWrite(&chan1024, Msg1024, "/glu_bw1024");
}

fn afterWrite1024() void {
    afterWrite(&chan1024);
}

fn resetWrite1024() void {
    resetWrite(&chan1024);
}

fn beforeWrite4096() void {
    beforeWrite(&chan4096, Msg4096, "/glu_bw4096");
}

fn afterWrite4096() void {
    afterWrite(&chan4096);
}

fn resetWrite4096() void {
    resetWrite(&chan4096);
}

fn beforeRead32() void {
    beforeWrite(&chan_read, Msg32, "/glu_br32");
    const msg = initMsg(Msg32);
    var i: u32 = 0;
    while (i < CAP) : (i += 1) {
        write(&chan_read, Msg32, &msg);
    }
}

fn afterRead32() void {
    afterWrite(&chan_read);
}

fn resetRead32() void {
    resetRead(&chan_read);
}

pub fn benchChannelWrite32(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = initMsg(Msg32);
    write(&chan32, Msg32, &msg);
}

pub fn benchChannelWrite256(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = initMsg(Msg256);
    write(&chan256, Msg256, &msg);
}

pub fn benchChannelWrite1024(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = initMsg(Msg1024);
    write(&chan1024, Msg1024, &msg);
}

pub fn benchChannelWrite4096(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = initMsg(Msg4096);
    write(&chan4096, Msg4096, &msg);
}

pub fn benchChannelRead32(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = read(&chan_read, Msg32);
    std.mem.doNotOptimizeAway(msg);
}

pub const write32_hooks = zbench.Hooks{
    .before_all = beforeWrite32,
    .after_all = afterWrite32,
    .before_each = resetWrite32,
};
pub const write256_hooks = zbench.Hooks{
    .before_all = beforeWrite256,
    .after_all = afterWrite256,
    .before_each = resetWrite256,
};
pub const write1024_hooks = zbench.Hooks{
    .before_all = beforeWrite1024,
    .after_all = afterWrite1024,
    .before_each = resetWrite1024,
};
pub const write4096_hooks = zbench.Hooks{
    .before_all = beforeWrite4096,
    .after_all = afterWrite4096,
    .before_each = resetWrite4096,
};
pub const read32_hooks = zbench.Hooks{
    .before_all = beforeRead32,
    .after_all = afterRead32,
    .before_each = resetRead32,
};
