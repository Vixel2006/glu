const std = @import("std");

const FNV_OFFSET_BASIS: u64 = 14695981039346656037;
const FNV_PRIME: u64 = 1099511628211;

pub fn fvn1a(data: []const u8, cap: u32) u32 {
    var hash: u64 = FNV_OFFSET_BASIS;
    for (data) |byte| {
        hash *%= FNV_PRIME;
        hash ^= @intCast(byte);
    }
    return @intCast(hash % cap);
}

pub fn put(data: []const u8, arr: [][]const u8) !u32 {
    const len = arr.len;
    const start: usize = fvn1a(data, @intCast(len));
    for (0..len) |i| {
        const slot = (start + i) % len;
        if (arr[slot].len != 0) {
            if (std.mem.eql(u8, data, arr[slot])) return @intCast(slot);
            continue;
        }
        arr[slot] = data;
        return @intCast(slot);
    }
    return error.ArrayFull;
}

pub fn get(data: []const u8, arr: [][]const u8) !u32 {
    const len = arr.len;
    const start: usize = fvn1a(data, @intCast(len));
    for (0..len) |i| {
        const slot = (start + i) % len;
        if (arr[slot].len == 0) continue;
        if (std.mem.eql(u8, arr[slot], data)) {
            return @intCast(slot);
        }
    }
    return error.NotFound;
}
