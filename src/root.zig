//! The application.  Everything lives in one file: resources as
//! plain declarations, the task handlers, and the system definition
//! that ties them together by reference — init, idle, and the
//! interrupt tasks are all just functions referenced by name.
//!
//! `task_specs` and `config` are the single source of truth: the
//! glue layer reads them, derives the resource ceilings and the task
//! table from them at compile time, and prints the report in `main`.
//! Nothing is parsed.  And even RTIC's per-task context structs are
//! never handwritten: `src/generated/gen_context.zig` reads `task_specs` and
//! *emits* one context struct per interrupt into
//! `src/generated/context.zig`, imported as `context` below — a
//! handler's signature simply names `context.TIMER0`, and nothing
//! else in this file mentions contexts at all.  (Named after the
//! interrupt, not the handler: the generator runs from the
//! handler-free declaration precisely so that no handler needs to
//! compile before its own context exists.)
//!
//! Two modules are generated, both from what you see below, both in
//! src/generated/ — visible, regenerated every build:
//!
//! *   `context.zig` — the per-task context structs, from
//!     `task_specs` (src/generated/gen_context.zig);
//! *   `irq.zig` — one trampoline per `interrupt_id`, which builds
//!     the context struct and calls its handler (src/generated/extract.zig);
//!     on hardware these names are the vector-table symbols.
//!
//! Handlers are plain file-scope functions taking their context, so
//! a handler may as well come from another file —
//! `const t0 = @import("irq.zig").t0;` — an imported alias is just
//! as addressable.

const std = @import("std");
const rticz = @import("rticz");

// The per-task contexts: a module emitted by src/generated/gen_context.zig
// from `task_specs` below, during the build.  The import is a
// deliberate cycle — the contexts import "app" to reach the resource
// declarations they point into, and the app imports "context" to
// name them — and module cycles are fine to the compiler: two views
// of one program.
const context = @import("context");

// The interrupt vector table: a module emitted by src/generated/extract.zig
// from the task list below, during the build.  The same deliberate
// cycle: the vectors import "app" to reach the handlers, and the app
// imports "vectors" to call them.  build.zig supplies both modules:
// while generating, the app is compiled against the committed stubs
// src/generated/context_stub.zig and src/generated/vectors_stub.zig; what ships links
// the generated files, src/generated/context.zig and
// src/generated/irq.zig — in the tree for anyone to read,
// regenerated on every build.
const vectors = @import("vectors");

/// The task declarations, handler-free by design: interrupt line,
/// priority, and the resources the task accesses — each access a
/// name-`&`-the-instance pair, so the *declaration* is where names
/// are claimed, for the analysis, the generated contexts, and the
/// generated trampolines alike.  The generators read only this list
/// (never `config`): no handler must compile before the context its
/// signature names exists, and reading a handler-free list forces no
/// handler's analysis.
pub const task_specs = [_]rticz.resource.TaskSpec{
    .{
        .interrupt_id = "TIMER0",
        .priority = 1,
        .resources = rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b }),
    },
    .{
        .interrupt_id = "UART0",
        .priority = 2,
        .resources = rticz.resource.refs(.{ .res_b = &res_b, .res_c = &res_c }),
    },
};

/// The interrupt tasks: the specs above, each bound to the handler
/// that answers its interrupt, in order.  Hoisted out of the config
/// literal so the vector generator can read the list without
/// touching the rest of `config`: materializing the full config
/// would materialize idle's address, and idle's body calls the very
/// vectors the generator is writing — a cycle the build resolves by
/// generating first.  A handler paired with the wrong spec cannot
/// hide: the generated trampoline builds the spec's context literal,
/// which must type-check against the handler's own signature.
pub const tasks: []const rticz.ResourceTask = &rticz.resource.bindHandlers(.{ t0, t1 }, &task_specs);

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
        .resources = rticz.resource.refs(.{ .res_c = &res_c }),
    },

    .tasks = tasks,
};

/// The interrupt tasks arrive with their context: every access to
/// shared state goes through a field of it, never through the
/// declarations directly — which is exactly what makes the task's
/// resource list more than documentation.  The host build reaches
/// handlers through the generated vector functions, which *create*
/// the context instance — the same path the core takes on hardware,
/// with idle's calls standing in for the interrupt lines firing.
///
/// A handler referenced from the system definition is part of the
/// application's visible surface: the framework resolves references by
/// walking the module's *public* declarations, so `t0` and `t1` are
/// `pub` — exactly what a name-based config could name across files.
pub fn t0(ctx: context.TIMER0) void {
    ctx.res_a.* += 1;
    ctx.res_b.x += 1;
    // A handler can ask its own priority — from the config table, at
    // comptime, off the function's own address.
    comptime {
        if (priorityOf(&t0) != 1) @compileError("t0 must run at priority 1");
    }
}

pub fn t1(ctx: context.UART0) void {
    ctx.res_b.y += 1;
    ctx.res_c.set("from t1") catch {};
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
/// generator passes, which run before the things idle names exist.
pub inline fn priorityOf(comptime handler: anytype) u8 {
    // Pointer identity, not `@intFromPtr`: a function's address is a
    // link-time fact, but identity is a comptime question — and the
    // erased `task_id` in the table gives the common shape.
    const self: *const anyopaque = handler;
    for (tasks) |task| {
        if (std.meta.eql(self, task.task_id)) return task.priority;
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

// Each resource is its own declaration — not a field of one shared
// store — because a resource's *placement* is its own business:
// `align` and `linksection` are per-declaration, so any one of these
// can land in its own memory region (a peripheral register block,
// DMA-reachable RAM, battery-backed backup registers) without
// dragging its neighbours along.  The declarations below carry
// nothing but their defaults; placement, when an app needs it, is
// written right here, e.g.
//
//     pub var res_b: Position align(8) linksection(".ccmram") = .{};

/// Plain counter — `res_a` in the sample system.
pub var res_a: u64 = 0;

/// Struct resource — `res_b` in the sample system.
pub var res_b: Position = .{};

/// Bounded-string resource — `res_c` in the sample system.
pub var res_c: Label = Label.init("rticz");

// ── Entry points ────────────────────────────────────────────────────

/// Application startup: runs before the scheduler enables interrupts,
/// so no task can be racing it.
pub fn init() void {
    std.debug.print("application init: res_c = \"{s}\", priorityOf(t1) = {d}\n", .{
        res_c.slice(),
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
        res_c.set(msg) catch unreachable;
        std.debug.print("  [{d}] a={d} b=({d},{d}) c=\"{s}\"\n", .{
            beat,
            res_a,
            res_b.x,
            res_b.y,
            res_c.slice(),
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
