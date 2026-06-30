/// controller.zig — telemetry controller / alert node
///
/// Subscribes to /telemetry and maintains a rolling 5-second statistics window.
/// Prints colour-coded ALERT messages when thresholds are exceeded and outputs
/// a formatted summary every 5 seconds.
///
/// ANSI colour codes:
///   \x1b[32m  green  — nominal / normal range
///   \x1b[33m  yellow — soft warning
///   \x1b[31m  red    — alert / threshold exceeded
///   \x1b[0m   reset
const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const subscriber_id = 0;
const summary_interval_ms = 5_000; // print rolling summary every 5 s

// Alert thresholds
const temp_alert: f32 = 30.0; // °C
const alt_alert: f32 = 150.0; // m

// ANSI colour codes
const CLR_RESET = "\x1b[0m";
const CLR_GREEN = "\x1b[32m";
const CLR_YELLOW = "\x1b[33m";
const CLR_RED = "\x1b[31m";
const CLR_BOLD = "\x1b[1m";
const CLR_CYAN = "\x1b[36m";

// -- helpers -----------------------------------------------------------------

fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

// -- main --------------------------------------------------------------------
pub fn main() void {
    const allocator = std.heap.page_allocator;

    var subscriber = glu.Subscriber.init(
        allocator,
        subscriber_id,
        topic,
        @sizeOf(msgs.Telemetry),
        capacity,
    ) catch |e| {
        std.debug.print("[controller] subscriber init failed: {}\n", .{e});
        return;
    };
    defer subscriber.deinit();

    std.debug.print(
        CLR_BOLD ++ CLR_CYAN ++
            "[controller] ── telemetry controller ────────────────────\n" ++
            "[controller]   topic   : {s}\n" ++
            "[controller]   window  : 5 s rolling statistics\n" ++
            "[controller]   alerts  : temp > {d}°C  |  alt > {d} m\n" ++
            "[controller]   Ctrl-C to stop\n" ++
            "[controller] ──────────────────────────────────────────────\n" ++
            CLR_RESET ++ "\n",
        .{ topic, temp_alert, alt_alert },
    );

    // Rolling 5-second window accumulators.
    var w_count: u32 = 0;
    var w_temp_sum: f64 = 0;
    var w_pres_sum: f64 = 0;
    var w_hum_sum: f64 = 0;
    var w_temp_min: f32 = std.math.floatMax(f32);
    var w_temp_max: f32 = -std.math.floatMax(f32);
    var w_alt_min: f32 = std.math.floatMax(f32);
    var w_alt_max: f32 = -std.math.floatMax(f32);
    var total_count: u64 = 0;
    var alert_count: u64 = 0;
    var last_summary = milliTimestamp();

    while (true) {
        if (subscriber.receive(msgs.Telemetry)) |msg| {
            total_count += 1;
            w_count += 1;

            w_temp_sum += msg.temperature;
            w_pres_sum += msg.pressure;
            w_hum_sum += msg.humidity;
            w_temp_min = @min(w_temp_min, msg.temperature);
            w_temp_max = @max(w_temp_max, msg.temperature);
            w_alt_min = @min(w_alt_min, msg.altitude);
            w_alt_max = @max(w_alt_max, msg.altitude);

            // -- alert logic -----------------------------------------------
            var alert = false;
            if (msg.temperature > temp_alert) {
                alert = true;
                alert_count += 1;
                std.debug.print(
                    CLR_RED ++ "[controller] ALERT  temp={d:.1}°C > {d}°C threshold  (seq={d})\n" ++ CLR_RESET,
                    .{ msg.temperature, temp_alert, msg.seq },
                );
            }
            if (msg.altitude > alt_alert) {
                if (!alert) alert_count += 1;
                alert = true;
                std.debug.print(
                    CLR_RED ++ "[controller] ALERT  alt={d:.1}m > {d:.0}m threshold  (seq={d})\n" ++ CLR_RESET,
                    .{ msg.altitude, alt_alert, msg.seq },
                );
            }

            // Soft warning: approaching limits.
            if (!alert) {
                if (msg.temperature > temp_alert * 0.9) {
                    std.debug.print(
                        CLR_YELLOW ++ "[controller] WARN   temp={d:.1}°C approaching limit\n" ++ CLR_RESET,
                        .{msg.temperature},
                    );
                }
            }
        } else {
            sleepMs(1);
        }

        // -- rolling summary every 5 seconds ---------------------------------
        const now = milliTimestamp();
        if (now - last_summary >= summary_interval_ms) {
            if (w_count > 0) {
                const avg_temp: f32 = @floatCast(w_temp_sum / @as(f64, @floatFromInt(w_count)));
                const avg_pres: f32 = @floatCast(w_pres_sum / @as(f64, @floatFromInt(w_count)));
                const avg_hum: f32 = @floatCast(w_hum_sum / @as(f64, @floatFromInt(w_count)));

                std.debug.print(
                    CLR_BOLD ++ "\n[controller] ── 5-second rolling summary ──────────────\n" ++ CLR_RESET,
                    .{},
                );
                std.debug.print(
                    CLR_BOLD ++ "[controller]   msgs in window : {d}  (total: {d})\n" ++ CLR_RESET,
                    .{ w_count, total_count },
                );

                // Colour-coded temperature line: pick a fully static format string.
                if (w_temp_max > temp_alert) {
                    std.debug.print(
                        "[controller]   temperature   : \x1b[31mavg={d:.2}°C  min={d:.2}°C  max={d:.2}°C\x1b[0m\n",
                        .{ avg_temp, w_temp_min, w_temp_max },
                    );
                } else if (w_temp_max > temp_alert * 0.9) {
                    std.debug.print(
                        "[controller]   temperature   : \x1b[33mavg={d:.2}°C  min={d:.2}°C  max={d:.2}°C\x1b[0m\n",
                        .{ avg_temp, w_temp_min, w_temp_max },
                    );
                } else {
                    std.debug.print(
                        "[controller]   temperature   : \x1b[32mavg={d:.2}°C  min={d:.2}°C  max={d:.2}°C\x1b[0m\n",
                        .{ avg_temp, w_temp_min, w_temp_max },
                    );
                }

                std.debug.print(
                    "[controller]   pressure      : " ++ CLR_GREEN ++ "avg={d:.2} hPa" ++ CLR_RESET ++ "\n",
                    .{avg_pres},
                );
                std.debug.print(
                    "[controller]   humidity      : " ++ CLR_GREEN ++ "avg={d:.1}%" ++ CLR_RESET ++ "\n",
                    .{avg_hum},
                );

                // Colour-coded altitude line.
                if (w_alt_max > alt_alert) {
                    std.debug.print(
                        "[controller]   altitude      : \x1b[31mmin={d:.1}m  max={d:.1}m\x1b[0m\n",
                        .{ w_alt_min, w_alt_max },
                    );
                } else {
                    std.debug.print(
                        "[controller]   altitude      : \x1b[32mmin={d:.1}m  max={d:.1}m\x1b[0m\n",
                        .{ w_alt_min, w_alt_max },
                    );
                }

                std.debug.print(
                    "[controller]   alerts fired  : {d}\n",
                    .{alert_count},
                );
                std.debug.print(
                    CLR_BOLD ++ "[controller] ──────────────────────────────────────────\n\n" ++ CLR_RESET,
                    .{},
                );
            } else {
                std.debug.print("[controller] waiting for data on '{s}'…\n", .{topic});
            }

            // Reset window.
            w_count = 0;
            w_temp_sum = 0;
            w_pres_sum = 0;
            w_hum_sum = 0;
            w_temp_min = std.math.floatMax(f32);
            w_temp_max = -std.math.floatMax(f32);
            w_alt_min = std.math.floatMax(f32);
            w_alt_max = -std.math.floatMax(f32);
            last_summary = now;
        }
    }
}
