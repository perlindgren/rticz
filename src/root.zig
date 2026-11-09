//! The application.  Everything lives in one file: typed resources,
//! the task handlers, and the system definition `config` that ties
//! them together by reference — init, idle, and the interrupt tasks
//! are all just functions referenced by name.
//!
//! `config` is the single source of truth: the glue layer reads it,
//! derives the resource ceilings and the task table from it at
//! compile time, and prints the report in `main`.  Nothing is parsed,
//! and the Zig compiler *is* the generator — for all but one thing:
//! the interrupt vector table.  On hardware a task is reached through
//! a function whose name is the vector's name, and no amount of
//! comptime reflection places symbols in a vector table, so exactly
//! one module is generated from this app: one trampoline per
//! `interrupt_id`, by src/extract.zig, imported as `vectors` below.
//!
//! Handlers are plain file-scope functions, so a config entry is
//! simply `.task_id = t0`.  A handler may as well come from another
//! file — `const t0 = @import("irq.zig").t0;` — an imported alias is
//! just as addressable.

const std = @import("std");
const rticz = @import("rticz");

// The interrupt vector table: a module emitted by src/extract.zig
// from the task list below, during the build.  The import is a
// deliberate cycle — the vectors import "app" to reach the handlers,
// and the app imports "vectors" to call them — and module cycles are
// fine to the compiler: two views of one program, one `resources`
// behind both.  build.zig supplies the module: while generating, the
// app is compiled against src/vectors_stub.zig; what ships links the
// generated file, src/generated/irq.zig — in the tree for anyone to
// read, regenerated on every build.
const vectors = @import("vectors");

/// The interrupt tasks, hoisted out of the config literal so the
/// vector generator can read the list without touching the rest of
/// `config`: materializing the full config would materialize idle's
/// address, and idle's body calls the very vectors the generator is
/// writing — a cycle the build resolves by generating first.
pub const tasks: []const rticz.ResourceTask = &.{
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
};

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

    .tasks = tasks,
};

/// Every interrupt context of the application would be a handler of
/// this shape.  The host build reaches them through the generated
/// vector functions — the same path the core takes on hardware, with
/// idle's calls standing in for the interrupt lines firing.
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

/// The priority assigned to `handler` in the task table (which
/// `config` embeds verbatim).  The address of a
/// function is stable, so a handler can look itself up in the table
/// it is declared in.  `inline` + `comptime` parameter: the lookup
/// runs at every call site at compile time — even from the idle task's
/// runtime code — and a handler missing from `config` is a compile
/// error there.
///
/// It reads the hoisted `tasks`, not `config.tasks`: a handler's
/// comptime self-lookup would otherwise materialize the full config,
/// idle included, wherever only the handler is needed — such as the
/// vector generator's pass, which runs before idle's vectors exist.
pub inline fn priorityOf(comptime handler: rticz.Handler) u8 {
    for (tasks) |task| {
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
/// and enters the interrupt handlers *through their vector functions*,
/// in the order the simulated priorities dictate; on real hardware the
/// lines fire and the core enters those same functions from the vector
/// table.
pub fn idle() noreturn {
    var beat: usize = 0;
    while (true) : (beat += 1) {
        vectors.UART0();
        vectors.TIMER0();

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