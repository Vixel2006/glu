pub const Channel = @import("channel.zig").Channel;
pub const GLU_MAGIC = @import("channel.zig").GLU_MAGIC;
pub const ToS = @import("channel.zig").ToS;
pub const write = @import("channel.zig").write;
pub const read = @import("channel.zig").read;
pub const Publisher = @import("api/publisher.zig").Publisher;
pub const Subscriber = @import("api/subscriber.zig").Subscriber;
pub const registry = @import("registry.zig");
pub const net = @import("transport/net.zig");
pub const tcp = @import("transport/tcp.zig");
pub const udp = @import("transport/udp.zig");
pub const io_mod = @import("io.zig");
pub const io = io_mod;

comptime {
    _ = @import("channel.zig");
    _ = @import("api/publisher.zig");
    _ = @import("api/subscriber.zig");
    _ = @import("io.zig");
    _ = @import("transport/net.zig");
    _ = @import("transport/tcp.zig");
    _ = @import("transport/udp.zig");
}
