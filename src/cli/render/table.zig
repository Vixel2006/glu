const std = @import("std");

pub fn truncate_end(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max == 0) return "";
    if (max <= 1) return "…";
    return s[0 .. max - 1] ++ "…";
}

pub fn truncate_middle(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max <= 3) return truncate_end(s, max);
    const head = max / 2 - 1;
    const tail = max - head - 2;
    if (tail >= s.len) return truncate_end(s, max);
    return s[0..head] ++ "…" ++ s[s.len - tail ..];
}
