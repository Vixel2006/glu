//! By convention, root.zig is the root source file when making a package.
pub const Topic = @import("topic.zig").Topic;
pub const Channel = @import("channel.zig").Channel;
pub const write = @import("channel.zig").write;
pub const read = @import("channel.zig").read;
pub const parser = @import("codegen/parser.zig");
pub const generator = @import("codegen/generator.zig");
pub const Publisher = @import("api/publisher.zig").Publisher;
pub const Subscriber = @import("api/subscriber.zig").Subscriber;
pub const Node = @import("api/node.zig").Node;

comptime {
    _ = @import("topic.zig");
    _ = @import("codegen/parser.zig");
    _ = @import("codegen/generator.zig");
    _ = @import("channel.zig");
    _ = @import("api/publisher.zig");
    _ = @import("api/subscriber.zig");
    _ = @import("api/node.zig");
    _ = @import("launch/toml.zig");
    _ = @import("launch/launcher.zig");
}
