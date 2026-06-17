//! By convention, root.zig is the root source file when making a package.
pub const Topic = @import("topic.zig").Topic;
pub const Channel = @import("channel.zig").Channel;
pub const write = @import("channel.zig").write;
pub const read = @import("channel.zig").read;
