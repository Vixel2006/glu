pub const Channel = @import("channel.zig").Channel;
pub const GLU_MAGIC = @import("channel.zig").GLU_MAGIC;
pub const ToS = @import("channel.zig").ToS;
pub const write = @import("channel.zig").write;
pub const read = @import("channel.zig").read;
pub const Publisher = @import("api/publisher.zig").Publisher;
pub const Subscriber = @import("api/subscriber.zig").Subscriber;
pub const tcp = @import("api/tcp.zig");
pub const udp = @import("api/udp.zig");

comptime {
    _ = @import("channel.zig");
    _ = @import("api/publisher.zig");
    _ = @import("api/subscriber.zig");
    _ = @import("api/tcp.zig");
    _ = @import("api/udp.zig");
}
