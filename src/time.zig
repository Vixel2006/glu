const std = @import("std");
const linux = std.os.linux;

pub fn monotonic() !u64 {
    var ts: linux.timespec = undefined;
    // NOTE: Here we use the BOOTTIME clock as it's the same as MONOTONIC
    // but it also count the suspend time. look at the man page for clock_gettime
    // also you can read the incredible tigerbeetle blog post down below
    // link: https://tigerbeetle.com/blog/2021-08-30-three-clocks-are-better-than-one/
    const ret: usize = linux.clock_gettime(linux.CLOCK.BOOTTIME, &ts);

    if (ret != 0) {
        return switch (linux.errno(ret)) {
            .ACCES, .PERM => error.NoPermission,
            .FAULT => error.InvalidAddr,
            .INVAL => error.InvalidConfig,
            .OVERFLOW => error.Overflow,
            else => error.FAILURE,
        };
    }

    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
