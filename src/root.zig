//! Application root of the rticz program.
//!
//! This is the RTIC-style hand-written half of the application: it implements
//! `init`, `idle`, and one handler function per task declared in the build
//! configuration (`rticz.json`, analyzed by build.zig at build time). The
//! generated glue (also produced at build time) verifies at comptime that
//! every declared task has its handler right here, then boots:
//!
//!     init();
//!     idle();  // never returns
//!
//! The `analysis` module imported below is generated code: the task table and
//! the resource priority ceilings were computed from rticz.json during
//! `zig build` and are compiled into the binary as constants.

const std = @import("std");

pub const analysis = @import("analysis");

/// RTIC `#[init]`: runs exactly once before idle. Prints the task table and
/// the build-time computed resource ceilings — no JSON parsing at runtime.
pub fn init() void {
    std.debug.print(
        "rticz boot: {d} task(s), {d} resource(s) — analyzed at build time from {s}\n\n",
        .{ analysis.tasks.len, analysis.ceilings.len, analysis.source_file },
    );

    for (analysis.tasks) |task| {
        std.debug.print("  task {s:<4} interrupt={s:<8} priority={d} resources=[", .{
            task.task_id, task.interrupt_id, task.priority,
        });
        for (task.resources, 0..) |res, j| {
            if (j != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{res});
        }
        std.debug.print("]\n", .{});
    }
    std.debug.print("\n", .{});
    for (analysis.ceilings) |c| {
        std.debug.print("  resource {s:<8} ceiling={d}\n", .{ c.name, c.ceiling });
    }
    std.debug.print("\n", .{});
}

/// Task handler for the task declared as "t0" in the configuration.
/// The generated dispatch table wires interrupt TIMER0 here.
pub fn t0() void {
    std.debug.print("    [t0] ran (priority {d})\n", .{priorityOf("t0")});
}

/// Task handler for the task declared as "t1" in the configuration.
/// The generated dispatch table wires interrupt TIMER1 here.
pub fn t1() void {
    std.debug.print("    [t1] ran (priority {d})\n", .{priorityOf("t1")});
}

/// RTIC `#[idle]`: the lowest-priority context; runs forever.
/// `noreturn` is verified at comptime by the generated glue.
pub fn idle() noreturn {
    std.debug.print("idle: entering forever loop (Ctrl-C to exit)\n", .{});
    var beat: usize = 0;
    while (true) : (beat += 1) {
        std.debug.print("\n[idle] beat {d} — dispatching in descending priority\n", .{beat});
        // On real hardware, t0/t1 fire from their bound interrupts
        // (TIMER0/TIMER1) and preempt idle. On the host we simulate the
        // scheduler tick by dispatching ready tasks highest-priority first.
        // With the ceiling protocol active, t0 would additionally inherit
        // ceiling(res_b) = 2 while it holds res_b.
        t1();
        t0();
        sleepMs(2_000);
    }
}

/// Look a priority up in the build-time table — demonstrates that the baked
/// analysis is real data, not a hard-coded duplicate of the config.
fn priorityOf(id: []const u8) u8 {
    for (analysis.tasks) |task| {
        if (std.mem.eql(u8, task.task_id, id)) return task.priority;
    }
    unreachable; // the glue comptime-checks that handlers match the config
}

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}
