const std = @import("std");
const assert = std.debug.assert;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,
        len: u32 = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn enqueue(self: *Self, item: *T) void {
            defer self.len += 1;

            if (self.tail) |tail| {
                tail.next = item;
                self.tail = item;
            } else {
                self.head = item;
                self.tail = item;
            }
        }

        pub fn dequeue(self: *Self) !*T {
            assert(!self.is_empty());
            defer self.len -= 1;

            const item = self.head.?;
            self.head = item.next;
            item.next = null;
            if (self.head == null) self.tail = null;

            return item;
        }

        pub fn peek(self: *Self) !*T {
            assert(!self.is_empty());
            return self.head.?;
        }

        pub fn is_empty(self: *Self) bool {
            return self.len == 0;
        }
    };
}
