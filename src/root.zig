//! The application.  Everything lives in one file: typed resources,
//! the task handlers, and the system definition `config` that ties
//! them together by reference — init, idle, and the interrupt tasks
//! are all just functions referenced by name.
//!
//! `config` is the single source of truth: the glue layer reads it,
//! derives the resource ceilings and the task table from it at
//! compile time, and prints the report in `main`.  Nothing is parsed
//! and no code is generated; the Zig compiler *is* the generator.
//!
//! Handlers are plain file-scope functions, so a config entry is
//! simply `.task_id = t0`.  A handler may as well come from another
//! file — `const t0 = @import("irq.zig").t0;` — an imported alias is
//! just as addressable.

const std = @import("std");
const rticz = @import("rticz");

pub const config: rticz.ResourceConfig = .{
    // init and idle are tasks, so they are declared like tasks:
    // references to functions, no invented names.  init runs before
    // interrupts are enabled — nothing races it, so it declares no
    // resource list.  idle is the lowest-priority context: logical
    // priority 0 comes from being idle, not from a declaration, so it
    // states only what is a choice — the resources it touches.
    .init = init,
    .idle = .{
        .task_id = idle,
        .resources = &.{&resources.res_c},
    },

    .tasks = &.{
        .{
            .task_id = t0,
            .interrupt_id = "TIMER0",
            .priority = 1,
            .resources = &.{ &resources.res_a, &resources.res_b },
        },
        .{
            .task_id = t1,
            .interrupt_id = "UART0",
            .priority = 2,
            .resources = &.{ &resources.res_b, &resources.res_c },
        },
    },
};

/// Every interrupt context of the application would be a handler of
/// this shape.  The host build keeps them as functions the idle task
/// calls in sequence.
///
/// A handler referenced from the system definition is part of the
/// application's visible surface: the framework resolves references by
/// walking the module's *public* declarations, so `t0` and `t1` are
/// `pub` — exactly what a name-based config could name across files.
pub fn t0() void {
    resources.res_a += 1;
    resources.res_b.x += 1;
    // A handler can ask its own priority — from the config table, at
    // comptime, off the function's own address.
    comptime {
        if (priorityOf(&t0) != 1) @compileError("t0 must run at priority 1");
    }
}

pub fn t1() void {
    resources.res_b.y += 1;
    resources.res_c.set("from t1") catch {};
}

/// The priority assigned to `handler` in `config`.  The address of a
/// function is stable, so a handler can look itself up in the table
/// it is declared in.  `inline` + `comptime` parameter: the lookup
/// runs at every call site at compile time — even from the idle task's
/// runtime code — and a handler missing from `config` is a compile
/// error there.
pub inline fn priorityOf(comptime handler: rticz.Handler) u8 {
    for (config.tasks) |task| {
        if (task.task_id == handler) return task.priority;
    }
    @compileError("handler is not declared in config");
}

// ── Resources ───────────────────────────────────────────────────────

/// A 2-D point — a resource with structure.
pub const Position = struct {
    x: u32 = 0,
    y: u32 = 0,
};

/// A string with a compile-time capacity.  The `set` call fails at
/// *runtime* when the value is too long; the capacity is a type
/// parameter.
pub const Label = rticz.text.BoundedString(32);

/// The application's shared state.  Each field is one resource; the
/// analysis talks about them by address, so two fields of the same
/// type are two distinct resources.
pub const ResourceStore = struct {
    /// Plain counter — `res_a` in the sample system.
    res_a: u64 = 0,
    /// Struct resource — `res_b` in the sample system.
    res_b: Position = .{},
    /// Bounded-string resource — `res_c` in the sample system.
    res_c: Label = Label.init("rticz"),
};

pub var resources: ResourceStore = .{};

// ── Entry points ────────────────────────────────────────────────────

/// Application startup: runs before the scheduler enables interrupts,
/// so no task can be racing it.
pub fn init() void {
    std.debug.print("application init: res_c = \"{s}\", priorityOf(t1) = {d}\n", .{
        resources.res_c.slice(),
        comptime priorityOf(&t1),
    });
}

/// The idle loop: the lowest-priority context of the system (logical
/// priority 0), running only while nothing else does.  It publishes
/// the beat through `res_c` — the access the config declares for it —
/// and calls the handlers in the order the simulated priorities
/// dictate; on real hardware each call site is instead an interrupt.
pub fn idle() noreturn {
    var beat: usize = 0;
    while (true) : (beat += 1) {
        t1();
        t0();

        // Publish the beat through the resource, not around it: the
        // config says idle touches `res_c`, and here it does.
        // `beat_msg_len` bounds the worst case, so neither format can
        // overflow its buffer ("beat " + 20 digits ≤ 32 = capacity).
        var msg_buf: [beat_msg_len]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "beat {d}", .{beat}) catch unreachable;
        resources.res_c.set(msg) catch unreachable;
        std.debug.print("  [{d}] a={d} b=({d},{d}) c=\"{s}\"\n", .{
            beat,
            resources.res_a,
            resources.res_b.x,
            resources.res_b.y,
            resources.res_c.slice(),
        });

        // Sleep long enough to be unmissable, short enough to stop.
        sleep_ms(2_000);
    }
}

/// The longest message idle can produce: "beat " + 20 digits of
/// usize + NUL, rounded up, under the label's capacity of 32.
const beat_msg_len: usize = 5 + 20 + 1;

/// Host stand-in for a `WFI`.
fn sleep_ms(ms: u64) void {
    const ts = std.posix.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast(ms % 1000 * 1_000_000) };
    _ = std.c.nanosleep(&ts, null);
}