//! INTENTIONALLY BROKEN — a copy of ../beats/root.zig with ONE edit,
//! marked `THE BUG` below.  Run `zig build` in this folder and read
//! README.md beside this file.
//! The application.  Everything lives in one file: resources as
//! plain declarations, the task handlers, and ONE `config` — the
//! system definition that is the file's only statement of what the
//! system is.  init and idle are referenced functions; each
//! interrupt task is a row that *names* its handler — RTIC's rule
//! that a task and its handler share one name — beside its interrupt
//! line, priority, and resource accesses.  The glue reads `config`,
//! derives the resource ceilings and the task table from it at
//! compile time, and prints the report in `main`.  Nothing is parsed.
//! And even RTIC's per-task context structs are never handwritten:
//! the code generator reads `config` and *emits* one context struct
//! per task into `src/generated/context.zig`, imported as `context`
//! below — a handler's signature simply names `context.t0`, and
//! nothing else in this file mentions contexts at all.  (Named after
//! the task — RTIC's `Context<T0>` for task `t0`.  The generator
//! reads this file as *text*, with `std.zig.Ast` — the same parser
//! the compiler uses — so it understands the config, function
//! references and all, without compiling anything: to a reader of
//! text a reference is a name, and names are checked against the
//! declarations of this file.  Real RTIC does the same thing with
//! its `#[app]` macro.  This application is then compiled exactly
//! once, against the real generated files — the place where every
//! promise finally meets its types.)  Idle is a task too:
//! `context.idle`, from its config row, and the glue enters idle
//! with the generated `makeIdleCtx`.
//!
//! Two modules are generated, both from what you see below, both in
//! src/generated/ — visible, regenerated every build:
//!
//! *   `context.zig` — the per-task context structs, from
//!     `config` (codegen/generate.zig);
//! *   `irq.zig` — one trampoline per `interrupt_id`, which builds
//!     the context struct and calls its handler, plus the generated
//!     handler-binding table `tasks` that `priorityOf` reads; on
//!     hardware the trampoline names are the vector-table symbols.
//!
//! Handlers are plain file-scope functions taking their context, so
//! a handler may as well come from another file —
//! `const t0 = @import("irq.zig").t0;` — an imported alias is just
//! as nameable.

const std = @import("std");
const rticz = @import("rticz");

// The per-task contexts: a module emitted by codegen/generate.zig
// from `config` below, before this file is ever compiled.  The
// import is a deliberate cycle — the contexts import "app" to reach
// the resource declarations they point into, and the app imports
// "context" to name them — and module cycles are fine to the
// compiler: two views of one program.
const context = @import("context");

// The interrupt vector table: the other module emitted by
// codegen/generate.zig from `config` below.  The same deliberate
// cycle: the vectors import "app" to reach the handlers, and the app
// imports "vectors" to call them.  Both generated files live at
// src/generated/context.zig and src/generated/irq.zig — in the tree
// for anyone to read, regenerated on every build.
const vectors = @import("vectors");

/// The system definition, one section: what the application is, in
/// one literal.  The generators and the glue all read *this* —
/// ceilings, contexts, vectors, banner — so there is nothing else to
/// keep in sync.  An interrupt task row names its handler (the name
/// is the reference: RTIC's rule, checked by the code generator
/// against this file's declarations, and turned into the generated
/// trampoline's typed call) and lists its resources as name-`&`-the-
/// instance pairs, so the *declaration* is where names are claimed,
/// for the analysis, the generated contexts, and the generated
/// trampolines alike.
///
/// init and idle, by contrast, are references, not names: an app may
/// hold any number of `fn () void`s, and only a reference says which.
/// They are the config's two function references — possible because
/// the generator reads this literal as text: a reference is a name
/// token, checked against the functions this file declares, and no
/// body is ever compiled before the real contexts and vectors
/// exist.  (The glue, in the final compile, resolves each reference
/// back to the name it refers to, for the banner and the tables.)
/// Idle is the lowest-priority context: logical priority 0 comes
/// from being idle, not from a declaration, so it states only what
/// is a choice — the resources it touches — and the code generator
/// emits `context.idle` from that same row.
pub const config: rticz.Config(context.idle) = .{
    .init = init,
    .idle = .{
        .task_id = idle,
        .resources = rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b, .res_c = &res_c }),
    },
    // `&.{ … }`: the field is a slice, so the rows live in a constant
    // array the slice points into — Zig needs to know where they are.
    .tasks = &.{
        .{
            .name = "t0",
            .interrupt_id = "TIMER0",
            .priority = 1,
            .resources = rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b }),
        },
        .{
            .name = "t1",
            .interrupt_id = "UART0",
            .priority = 2,
            .resources = rticz.resource.refs(.{ .res_b = &res_b, .res_c = &res_c }),
        },
    },
};

/// The interrupt tasks arrive with their context: a pointer to a
/// struct of `Claim` proxies, one per resource the task declared.
/// Shared state is reached *only* through a proxy, and only inside a
/// `claim`ed critical section — the handler never holds the reference
/// itself, which is what makes the task's resource list more than
/// documentation.  `claim` takes the critical section and, next to
/// it, the value that section would have captured (a Zig stand-in for
/// a Rust closure environment; the empty capture is `{}`), lends the
/// reference into the section, and retracts it on the way out.  The
/// host build reaches handlers through the generated vector functions,
/// which *build* the context — fresh proxies, so the guard lives for
/// exactly one activation — and call the handler with a pointer to it.
///
/// A handler referenced from the system definition is part of the
/// application's visible surface: the framework resolves references by
/// walking the module's *public* declarations, so `t0` and `t1` are
/// `pub` — exactly what a name-based config could name across files.
pub fn t0(ctx: *context.t1) void { // THE BUG: t1's context, t0's row
    // The capture is a bare literal, on purpose.  A bare `1` is a
    // `comptime_int`: no machine type of its own until it is used,
    // and the use is `claim` handing it to the section's first
    // parameter — `amount: u64` for `add_n` — where the literal
    // takes *that* type, at comptime; a value the parameter cannot
    // represent (negative, overflowing, a string) is a comptime error
    // raised at `claim`'s `body(captured, ...)`.  So the section's
    // signature owns the capture type and the call site needs no
    // `@as` — one fewer place the same type is written, and it can
    // never disagree with the other.  The boundary: literals bend to
    // the parameter; a *typed* value (`const`/`var`) must already
    // match it exactly, at any width.
    ctx.res_a.claim(add_n, 1); // capture: the amount to add
    ctx.res_b.claim(bump_x, 1); // the same `1`, this time as `step: u32`
    // A handler can ask its own priority — from the config table, at
    // comptime, off the function's own address.
    comptime {
        if (priorityOf(&t0) != 1) @compileError("t0 must run at priority 1");
    }
}

pub fn t1(ctx: *context.t1) void {
    ctx.res_b.claim(bump_y, 1); // `step: u32` again, literal as ever
    // A string literal is the other case: it *has* a type — an array
    // pointer, `*const [6:0]u8` here — and reaches `text: []const u8`
    // by coercion, the array-to-slice one Zig allows in that
    // direction and only it.  Bending versus coercing, two roads to
    // the same end: `overwrite`'s signature still owns the type.
    ctx.res_c.claim(overwrite, "from t1");
}

// The critical sections above, written as the plain functions Zig
// passes to `claim` in place of a closure: first parameter the
// capture pack `claim` hands back, second the resource reference the
// section is lent for its duration only.

fn add_n(amount: u64, counter: *u64) void {
    counter.* += amount;
}
fn bump_x(step: u32, point: *Position) void {
    point.x += step;
}
fn bump_y(step: u32, point: *Position) void {
    point.y += step;
}
fn overwrite(text: []const u8, label: *Label) void {
    label.set(text) catch {};
}

/// The priority assigned to `handler` in the task table.  The address
/// of a function is stable, so a handler can look itself up in the
/// table it is declared in.  `inline` + `comptime` parameter: the
/// lookup runs at every call site at compile time — even from the
/// idle task's runtime code — and a handler missing from `config` is
/// a compile error there.
///
/// It reads the generated binding table `vectors.tasks` — the table
/// `codegen/generate.zig` emits from the config rows and the
/// functions their names name, where both sides of the pairing are
/// visible.  The lookup keys on handler
/// *addresses*, which the config's rows deliberately do not carry;
/// the table lives in `vectors` because it is the vector generator
/// that sees both sides of the pairing — the name in the row, the
/// function in the namespace.
pub inline fn priorityOf(comptime handler: anytype) u8 {
    // Pointer identity, not `@intFromPtr`: a function's address is a
    // link-time fact, but identity is a comptime question — and the
    // erased `task_id` in the table gives the common shape.
    const self: *const anyopaque = handler;
    for (vectors.tasks) |task| {
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
/// priority 0), running only while nothing else does — and a task
/// like any other, so it takes a context too: `context.idle`, built
/// once by the glue with the generated `makeIdleCtx`, its one
/// activation being this whole loop.  It publishes the beat *through*
/// the resources — reads and writes all happen inside claimed
/// sections, the way the declaration says — and enters the interrupt
/// handlers *through their vector functions*, in the order the
/// simulated priorities dictate; on real hardware the lines fire and
/// the core enters those same functions from the vector table.
pub fn idle(ctx: *context.idle) noreturn {
    var beat: usize = 0;
    while (true) : (beat += 1) {
        vectors.UART0();
        vectors.TIMER0();

        // The whole beat, published through claims: open `res_a` and
        // carry everything the later sections will need in the
        // capture — a context pointer and the beat count, the Zig
        // stand-in for what a Rust closure would capture.
        ctx.res_a.claim(read_a, IdleEnv{ .ctx = ctx, .beat = beat });

        // Sleep long enough to be unmissable, short enough to stop.
        sleep_ms(2_000);
    }
}

/// The capture packs idle's nested claims pass along.  Each level
/// hands the next everything it may need, because a claimed section
/// receives nothing else: the previous holdings, and the one
/// reference this level borrows.  Nesting *different* resources is
/// how accesses compose; the guards make that rule literal.  These
/// captures are typed literals — `WithA{...}`, not a bare `1` — the
/// strict side of `claim`'s typing: a typed capture must match the
/// section's first parameter exactly, while a bare literal would
/// have bent to it (the note at `t0` holds the other side).
const IdleEnv = struct { ctx: *context.idle, beat: usize };
const WithA = struct { env: IdleEnv, a: u64 };
const WithAB = struct { with_a: WithA, b: Position };

fn read_a(env: IdleEnv, a: *u64) void {
    env.ctx.res_b.claim(read_b, WithA{ .env = env, .a = a.* });
}

fn read_b(held: WithA, b: *Position) void {
    held.env.ctx.res_c.claim(publish, WithAB{ .with_a = held, .b = b.* });
}

/// The innermost section: the beat message goes through `res_c`'s
/// claim — the config says idle touches `res_c`, and here it does —
/// and the snapshot printed is the one the enclosing claims carried
/// in.  `beat_msg_len` bounds the worst case, so neither format can
/// overflow its buffer ("beat " + 20 digits ≤ 32 = capacity).
fn publish(held: WithAB, c: *Label) void {
    var msg_buf: [beat_msg_len]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "beat {d}", .{held.with_a.env.beat}) catch unreachable;
    c.set(msg) catch unreachable;
    std.debug.print("  [{d}] a={d} b=({d},{d}) c=\"{s}\"\n", .{
        held.with_a.env.beat,
        held.with_a.a,
        held.b.x,
        held.b.y,
        c.slice(),
    });
}

/// The longest message idle can produce: "beat " + 20 digits of
/// usize + NUL, rounded up, under the label's capacity of 32.
const beat_msg_len: usize = 5 + 20 + 1;

/// Host stand-in for a `WFI`.
fn sleep_ms(ms: u64) void {
    const ts = std.posix.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast(ms % 1000 * 1_000_000) };
    _ = std.c.nanosleep(&ts, null);
}
