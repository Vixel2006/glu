//! By convention, root.zig is the root source file when making a package.
pub const Topic = @import("topic.zig").Topic;
pub const Channel = @import("channel.zig").Channel;
pub const write = @import("channel.zig").write;
pub const read = @import("channel.zig").read;
pub const Publisher = @import("api/publisher.zig").Publisher;
pub const Subscriber = @import("api/subscriber.zig").Subscriber;
pub const Node = @import("api/node.zig").Node;

comptime {
    _ = @import("topic.zig");
    _ = @import("channel.zig");
    _ = @import("api/publisher.zig");
    _ = @import("api/subscriber.zig");
    _ = @import("api/node.zig");
}
