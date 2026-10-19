const std = @import("std");
const linux = std.os.linux;

fn clock_gettime_ns(clock: linux.CLOCK) !u64 {
    var ts: linux.timespec = undefined;
    const ret: usize = linux.clock_gettime(clock, &ts);

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

pub fn monotonic() !u64 {
    // NOTE: Here we use the BOOTTIME clock as it's the same as MONOTONIC
    // but it also count the suspend time. look at the man page for clock_gettime
    // also you can read the incredible tigerbeetle blog post down below
    // link: https://tigerbeetle.com/blog/2021-08-30-three-clocks-are-better-than-one/
    return clock_gettime_ns(.BOOTTIME);
}

pub fn wallclock() !u64 {
    return @divTrunc(clock_gettime_ns(.REALTIME) catch 0, std.time.ns_per_s);
}
