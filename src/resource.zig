//! The typed application side: resources as real Zig declarations and
//! tasks referenced by their handler functions.
//!
//! The application writes its system definition in its root (see
//! `examples/beats/root.zig`) as
//! one `config`: each resource is its own `pub var` — placeable in its
//! own linker section or alignment — each interrupt task is a row
//! naming its handler, its line, its priority and its resource
//! accesses, and the entry points are named by reference:
//!
//! ```zig
//! pub var res_a: u64 = 0;
//!
//! pub const config: rticz.Config(context.idle) = .{
//!     .init = init,
//!     .idle = .{ .task_id = idle, .resources = … },
//!     .tasks = .{
//!         .{ .name = "t0", .interrupt_id = "TIMER0", .priority = 1,
//!            .resources = rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b }) },
//!     },
//! };
//! ```
//!
//! A resource access is a *named pair* (`ResourceRef`): the name and
//! `&` of the same declaration, written together as one literal, so
//! no analysis ever recovers a name by walking a namespace or
//! comparing addresses — the name is written down exactly where it is
//! claimed.  An interrupt task's `name` doubles as its handler's
//! declared name (RTIC's rule, checked at the build), so the tasks
//! need no function reference at all; init and idle do have one,
//! because an app may hold any number of `fn () void`s and only a
//! reference says which — the glue resolves each back to its declared
//! name by walking the application namespace and comparing addresses
//! (`std.meta.eql` compares pointers to declared items at comptime),
//! so the JSON analysis front end keeps seeing plain names, and the
//! boot banner can print what the program is made of.
//!
//! Two Zig facts shape the implementation.  A `var` in the namespace
//! cannot be read at comptime, so the handler walk asks only
//! `@TypeOf(@field(app, name))` — a type question that comptime can
//! answer for `var`s, `const`s and functions alike — and evaluates
//! `@field` only after the type test has skipped the non-fns.
//! And the walk must run in the framework (glue), never in root: a
//! `const` in root whose initializer reads root's own declarations
//! via `@field` is a self-dependency Zig rejects.  Hence
//! `namedTasks` takes the application namespace from the outside.
//!
//! Task handlers take a per-task *context* (RTIC's `Context`): a
//! plain struct named after the *task* — `context.t0`, not
//! `context.TIMER0`, exactly as RTIC hands `Context<T0>` to the task
//! that binds an interrupt — generated into
//! the application's `generated/context.zig` by `codegen/generate.zig` from the
//! very `config` declared here: one struct per declared name,
//! fields one per accessed resource, a `Claim(name, T, ceiling)`
//! proxy over the application's declaration — the resource's name
//! and priority ceiling baked into the field type, the ceiling the
//! same number the glue banner prints
//! (see `Claim` below): the handler reaches the data only inside a
//! `claim`ed critical section, under the mask that ceiling stands
//! for.  The name lives
//! in the config as a plain string because the generator reads the
//! config from the application's *text* (codegen/appsrc.zig, on
//! `std.zig.Ast`), where a row naming its handler is a name token —
//! and the reader checks that the name really names a public
//! function of the same file.  Idle gets
//! a context too (`context.idle`, built from its config row), the one
//! activation being the runtime loop itself, whose context the glue
//! constructs once with the generated `makeIdleCtx`.
//!
//! Handlers share no signature, so a handler reference, where one
//! exists at all, is an erased address: identity is what the system
//! needs, and the generated trampoline's call is what checks the
//! signature.  Only the *generated* binding table holds such
//! addresses; the config itself needs none for the interrupt tasks,
//! whose name *is* the reference.  Idle is the exception that proves
//! the point: the glue *calls* idle, so `IdleTask` is generic over
//! its context type and keeps the reference typed.

const std = @import("std");

/// The handler of an interrupt task, or of init.
pub const Handler = *const fn () void;

/// One claimed resource: its name, and the very instance it names.
/// The pair is written as one atomic literal — `.res_a = &res_a` —
/// so the name is never a label recovered from elsewhere: it is the
/// declaration's own name at the place of the claim, and the pointer
/// is that declaration's own storage.  `refs` produces these from
/// the anonymous-struct literal an application writes; the analysis,
/// the generated context structs, and the generated trampolines all
/// read names straight from here — the names must be *data* because
/// they cross the boundary between the generator, which reads the
/// application as text, and the compiler, which alone can reflect
/// into its namespace.
pub const ResourceRef = struct {
    name: []const u8,
    ptr: *anyopaque,
    /// The declared type of what the name names — captured from the
    /// reference itself, so the report can name the type of every
    /// resource without ever reflecting back into the application.
    type_name: []const u8,
};

/// Write the resource accesses of one task:
///
/// ```zig
/// rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b })
/// ```
///
/// The field names become the context struct's fields and the
/// analysis's vocabulary; the values must be references to the
/// application's resource declarations.  The result is constant
/// memory, safe to store in global task tables.
pub fn refs(comptime named: anytype) []const ResourceRef {
    // 0.17.1 struct reflection: field_names/field_types, no `.fields`.
    const info = @typeInfo(@TypeOf(named)).@"struct";
    const N = info.field_names.len;
    var items: [N]ResourceRef = undefined;
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        items[i] = .{
            .name = field_name,
            .ptr = @ptrCast(@field(named, field_name)),
            // The field's own type is the reference `&name` wrote —
            // a pointer; its child is the declared resource type.
            .type_name = @typeName(@typeInfo(field_type).pointer.child),
        };
    }
    // Freeze: a slice escaping this function must point into
    // constant memory, and a comptime `var` does not qualify.
    const Frozen = struct { items: [N]ResourceRef };
    const frozen: Frozen = .{ .items = items };
    return &frozen.items;
}

/// What one interrupt task declares in the config: its name, its
/// interrupt line, its priority, and the resources it accesses.  This
/// is what the generator reads from the application's text and
/// trampolines from.  It carries no function reference: the handler
/// is *named*, and RTIC's rule makes the name three names at once —
/// it names the emitted context struct (`context.t0`), it names the
/// handler (`pub fn t0`), and the generator enforces that the
/// application declares exactly this function.  A name, not a
/// reference, is what survives the crossing: the config is written
/// once, read as text by the generator and as Zig by the compiler,
/// and a name means the same thing on both sides.
pub const TaskSpec = struct {
    name: []const u8,
    interrupt_id: []const u8,
    priority: u8,
    resources: []const ResourceRef,
};

/// A task with its handler attached: the spec plus the erased address
/// of the function its name names.  The application never writes
/// these — `codegen/generate.zig` *emits* the table (as `pub const
/// tasks` in the generated vectors) from the config rows and the
/// functions their names name.  The address is erased because
/// handlers take
/// per-task contexts and share no signature; identity is what
/// `priorityOf` looks up, and the trampoline's own call is what types
/// the handler against its context.
pub const Task = struct {
    task_id: *const anyopaque,
    name: []const u8,
    interrupt_id: []const u8,
    priority: u8,
    resources: []const ResourceRef,
};

/// The idle task, declared like a task — except that it has no
/// interrupt (it *is* the fallback context) and no priority to
/// declare: idle is the lowest-priority context of the system,
/// logical priority 0, by definition, so the framework fixes it in
/// the analysis rather than asking.  What it *can* declare, like any
/// task, is which resources it touches.
///
/// Generic over the idle context type (the application's
/// `context.idle`) because the glue *calls* idle: unlike the
/// interrupt tasks, whose erased addresses are only compared for
/// identity while the generated trampoline makes the typed call, the
/// runtime enters idle itself and needs a typed, callable reference —
/// `*const fn (*IdleCtx) noreturn`, the handler taking its context
/// like every other task.
pub fn IdleTask(comptime IdleCtx: type) type {
    return struct {
        task_id: *const fn (*IdleCtx) noreturn,
        resources: []const ResourceRef,
    };
}

/// The system definition, one section: the entry points and the
/// interrupt tasks, all of it the application's only declaration of
/// what the system is.  init and idle are referenced functions — the
/// config *has* their addresses, so their names are recovered by the
/// glue's namespace walk, and the generator sees them as the names
/// they are, text being reference-blind; the interrupt tasks name
/// their handler instead, every name checked against the functions
/// this same file declares.  Generic over the idle context type — see
/// `IdleTask`; the application spells it `rticz.Config(context.idle)`.
pub fn Config(comptime IdleCtx: type) type {
    return struct {
        init: Handler,
        idle: IdleTask(IdleCtx),
        tasks: []const TaskSpec,
    };
}

/// A claimed-for-the-moment resource: the RTIC *proxy* that stands in
/// a task's context for a resource it declared.  Shared state is
/// never reached directly — the only way inside is `claim`, the
/// equivalent of RTIC's `lock`: it runs the critical section and
/// lends its `*T` reference only into that section, restoring the
/// resource on the way out.
///
/// Rust hands `lock` a closure that captures its environment
/// implicitly; Zig closures capture nothing, so the same shape is
/// mimicked the way the standard library mimics it everywhere
/// (sort blocks, readers, predicates): `claim` takes a comptime-known
/// function and a *capture pack* — the value a closure would have
/// grabbed — and calls one with the other.  The call reads like a
/// closure and is checked like one; `body`'s first parameter is the
/// pack, its second the resource:
///
///     ctx.count.claim(|n, v| v.* += n, 5)   // Rust
///     ctx.count.claim(add_n, 5)             // here: add_n(n, v)
///
/// A section that captures nothing passes the void literal `{}` and
/// names its first parameter `void`.  The reference is alive only
/// during the call, and the `claimed` flag is the runtime echo of
/// Rust's borrow check: claiming a resource already claimed panics,
/// exactly as a nested `lock` of the same resource panics in RTIC.
/// Composing claims by *nesting* them (claim one, and claim the next
/// inside its body) stays legal — different resources, different
/// flags.
///
/// `name` is the resource's declared name and `ceiling` its priority
/// ceiling — the highest priority of any task that touches it — both
/// baked in by the context generator, which knows them from the task
/// table.  They ride in the *type* because the proxy cannot know
/// them by introspection — it is a struct whose only member is a
/// pointer; it is not told which field of which context it is — and
/// both are per-resource compile-time facts.  On a Cortex-M the
/// ceiling is the value BASEPRI takes for the duration of the
/// section, the mask that makes the race structurally impossible.
/// Until the runtime writes that register, `claim` traces the
/// protocol instead: `-- priority ceiling res_a 1` before the
/// section, `-- priority ceiling res_a restored` after — and only if
/// the section really returns, because one that never does leaves the
/// mask raised, and the trace saying so is the point of printing it.
///
/// ## What this does not prevent
///
/// The guard is a runtime echo of the borrow check, not the borrow
/// check.  Zig has no type-based alias analysis, no private struct
/// fields, and no lifetimes, so an application that wants to reach a
/// resource raw can do it three ways, and no arrangement of types
/// stops any of them:
///
///   1. Write the declaration directly.  Handlers live in the same
///      file as the resources they touch; `res_a += 1` inside a
///      handler never sees this proxy at all.  Same-file visibility
///      cannot be hidden from — `pub` is enforced across files, not
///      within one.
///   2. Read through the proxy: `ctx.res_a.ptr.*` is nine characters
///      to raw memory, because `ptr` is an ordinary struct field and
///      Zig has no private fields.
///   3. Stash the `*T` the claim lends and use it after the section
///      ends.  The retraction is ceremony; making references expire
///      needs a borrow checker — the real foundation of Rust RTIC,
///      and the reason its locks are compile-time facts.
///
/// Two rules follow for everything this project generates:
///
///   * Never emit `noalias`.  With no type-based alias analysis to
///     contradict it (verified: the app's ReleaseFast IR carries zero
///     `!tbaa` annotations), an honest-sounding `noalias` on anything
///     user code reaches lets the optimizer assume away the very
///     sharing the guard exists to catch.
///   * Never use `unreachable` to mean "the application should not do
///     this".  ReleaseFast deletes `unreachable` guards entirely —
///     probed: the double-claim check vanished, 2 raises, 0 restores,
///     segfault.  App misbehavior must meet `@panic` or
///     `@compileError`, which survive every optimization mode.
///
/// Enforcement tiers — a source lint in the generator, moving storage
/// behind an import the application cannot wire, a checked wrapper in
/// place of the lent `*T` — were considered and deliberately deferred
/// (the second also waits for the library split, where resources
/// declared inside the config become natural).  For now the honest
/// answer is the one above: the protocol is traced and guarded
/// against accidents, and enforced against nothing else.
pub fn Claim(comptime name: []const u8, comptime T: type, comptime ceiling: u8) type {
    return struct {
        const Self = @This();

        /// The instance this proxy stands for — the application's own
        /// declaration, pointed at by the generated trampoline that
        /// built the context.  Reached through `claim` by everything
        /// that behaves; nothing but convention keeps a field read
        /// away (see *What this does not prevent*).
        ptr: *T,
        claimed: bool = false,

        /// Run `body` as the critical section, lending it the
        /// resource's reference.  `captured` is the fake closure's
        /// environment; the call to `body` is what types it against
        /// the section.  Around it: the ceiling raise and restore,
        /// printed for now, register-backed eventually.
        pub fn claim(self: *Self, comptime body: anytype, captured: anytype) void {
            std.debug.print("-- priority ceiling {s} {d}\n", .{ name, ceiling });
            if (self.claimed) @panic("resource claimed while already claimed — compose by nesting *different* resources, never re-claim the same one");
            self.claimed = true;
            defer self.claimed = false;
            body(captured, self.ptr);
            std.debug.print("-- priority ceiling {s} restored\n", .{name});
        }
    };
}

/// The declared name of `handler` inside the namespace
/// `handlers_ns` — or null if it is not one of that namespace's
/// functions (a stray function from elsewhere, a copy behind a
/// different address).  Handlers live at file scope or arrive through
/// an alias; either way they are addressable declarations here.
///
/// `handler` may be a typed function pointer or an erased address
/// (task references are erased now that each handler takes its own
/// context type); the comparison is by address either way.  Any
/// function signature qualifies: with per-task contexts there is no
/// single signature to test for, and the trampoline call type-checks
/// what the config referenced.
///
/// The walk stays legal even when the namespace holds `var`s (the
/// resource declarations themselves) that comptime may not evaluate:
/// each declaration is first asked for its *type* —
/// `@TypeOf(@field(...))` is a type question comptime can answer for
/// `var`s, `const`s and functions alike — and `@field` is only
/// evaluated once the type test has skipped the non-fns.
pub fn handlerName(comptime handlers_ns: type, comptime handler: anytype) ?[]const u8 {
    // Identity by pointer equality, not integer addresses: a
    // function's address is a link-time fact, so `@intFromPtr` cannot
    // run at comptime — but comparing two pointers for identity can,
    // which is exactly the question.  Erasing to `*const anyopaque`
    // puts a typed function pointer and the config's erased task
    // reference into the same comparable shape.
    const target: *const anyopaque = handler;
    // `inline` is essential: the iteration value feeds `@field`, which
    // needs the name comptime-known, and plain for-loops do not give
    // that even to a comptime-evaluated function.
    inline for (@typeInfo(handlers_ns).@"struct".decl_names) |decl_name| {
        const name: []const u8 = decl_name;
        // The app's contract surface — the single system definition —
        // is vocabulary, never a handler, and probing it is not merely
        // wasted but wrong: `@field` on a container-level const
        // evaluates it, and `config`'s value is the whole system
        // definition — the last thing a walk looking for *handlers*
        // should mistake for one.  Handlers are the application's
        // *other* functions; this name stays out of the walk.
        // (Shape is load-bearing: the guards must be short-circuit
        // operands, not `if … continue` — comptime flow control
        // inside a block that a runtime instantiation also sees is
        // rejected, and this generic does get instantiated from
        // runtime code.)
        const is_contract = std.mem.eql(u8, name, "config");
        if (!is_contract and @typeInfo(@TypeOf(@field(handlers_ns, name))) == .@"fn" and
            std.meta.eql(target, @as(*const anyopaque, &@field(handlers_ns, name)))) return name;
    }
    return null;
}

/// The analysis-facing task list of an application: the config's
/// interrupt-task rows, then the idle row — idle is a task too
/// (logical priority 0, the system's floor; it has no interrupt, so
/// its row reads `none`).  Nothing is resolved here: interrupt tasks
/// *name* their handler, so the declared name is already written in
/// the row, and resource references carry their names; `idle_name`
/// arrives resolved because idle, uniquely, is referenced by address
/// (its resolution is the caller's, where the namespace is visible
/// from outside).  The ceiling analysis deliberately skips the last
/// row: idle sits at the bottom of the scale and is preempted by every
/// interrupt task, so its 0 can never be a ceiling.  But the row
/// records what idle-context code touches — which is exactly where a
/// ceiling will later have to be enforced.
///
/// The whole thing runs at comptime, so a priority that claims idle's
/// 0 stops the build with an error that quotes the task by name.
pub fn namedTasks(
    comptime specs: []const TaskSpec,
    comptime idle_name: []const u8,
    comptime idle_resources: []const ResourceRef,
) []const parser.Task {
    const count = specs.len + 1;

    // One uniform view for both passes: the interrupt tasks, then
    // idle — the only differences being idle's missing interrupt and
    // the fixed logical priority 0.
    const Entry = struct {
        name: []const u8,
        interrupt_id: []const u8,
        priority: u8,
        resources: []const ResourceRef,
    };
    var entries: [count]Entry = undefined;

    // The name is already the row's own — what error messages about a
    // task quote is what the config wrote.
    for (specs, 0..) |task, ti| {
        if (task.priority == 0) {
            @compileError("interrupt tasks start at priority 1; priority 0 is idle");
        }
        entries[ti] = .{
            .name = task.name,
            .interrupt_id = task.interrupt_id,
            .priority = task.priority,
            .resources = task.resources,
        };
    }
    entries[count - 1] = .{
        .name = idle_name,
        .interrupt_id = "none",
        // The floor of the system, fixed here: idle declares no
        // priority because there is nothing to choose.
        .priority = 0,
        .resources = idle_resources,
    };

    // Collect every resource name into one pool.  Slices that escape
    // this function must point into constant memory, and a comptime
    // `var` does not qualify — so the pool is first copied into a
    // `const`, and only then are the slices taken from it.
    const cap = count * 8;
    var pool_items: [cap][]const u8 = undefined;
    var total: usize = 0;

    for (entries) |entry| {
        for (entry.resources, 0..) |res, ri| {
            pool_items[total + ri] = res.name;
        }
        total += entry.resources.len;
    }

    const Pool = struct { items: [cap][]const u8 };
    const pool: Pool = .{ .items = pool_items };

    const Built = struct {
        tasks: [count]parser.Task,
    };
    const built: Built = blk: {
        var out: Built = .{ .tasks = undefined };
        var pos: usize = 0;
        for (entries, 0..) |entry, ti| {
            out.tasks[ti] = .{
                .task_id = entry.name,
                .interrupt_id = entry.interrupt_id,
                .priority = entry.priority,
                .resources = pool.items[pos..][0..entry.resources.len],
            };
            pos += entry.resources.len;
        }
        break :blk .{ .tasks = out.tasks };
    };

    return &built.tasks;
}

const parser = @import("parser.zig");

// ── Tests ───────────────────────────────────────────────────────────

const TestTasks = struct {
    pub fn alpha() void {}
    pub fn beta() void {}
    pub fn forever(_: *TestIdleCtx) noreturn {
        while (true) {}
    }
    pub fn not_a_handler(_: u8) u8 {
        return 0;
    }
    pub var hidden_state: u64 = 0;
};

/// Stand-in for the application's generated `context.idle` — the
/// tests do not run a generated file, but `IdleTask` is generic over
/// exactly this type, so one must exist to parameterize it.
const TestIdleCtx = struct {};

// An application-shaped namespace: resources as individual `pub var`
// declarations, exactly as an app root declares them.
const App = struct {
    pub var counter1: u64 = 0;
    pub var counter2: u64 = 0;
    pub var flag: bool = false;
};

test "references resolve to declared names, whatever the signature" {
    try std.testing.expectEqualStrings("alpha", handlerName(TestTasks, &TestTasks.alpha).?);
    try std.testing.expectEqualStrings("beta", handlerName(TestTasks, &TestTasks.beta).?);
    try std.testing.expectEqualStrings("forever", handlerName(TestTasks, &TestTasks.forever).?);
    try std.testing.expect(handlerName(TestTasks, &stray) == null);
}

fn stray() void {}

test "the system definition references init and idle by function too" {
    const system: Config(TestIdleCtx) = .{
        .init = TestTasks.alpha,
        .idle = .{ .task_id = TestTasks.forever, .resources = &.{} },
        .tasks = &.{.{ .name = "beta", .interrupt_id = "X", .priority = 1, .resources = &.{} }},
    };
    try std.testing.expectEqualStrings("alpha", handlerName(TestTasks, system.init).?);
    try std.testing.expectEqualStrings("forever", handlerName(TestTasks, system.idle.task_id).?);
}

test "a named access pair carries its own name and reaches its own storage" {
    // `comptime`: refs' whole design — names from reflection, a slice
    // frozen into constant memory — only exists in a comptime
    // evaluation, and an application uses it in exactly one place:
    // a config row's `resources` field, a container-level const.
    const claimed = comptime refs(.{ .counter1 = &App.counter1, .flag = &App.flag });
    try std.testing.expectEqual(@as(usize, 2), claimed.len);
    try std.testing.expectEqualStrings("counter1", claimed[0].name);
    try std.testing.expectEqualStrings("flag", claimed[1].name);
    // The pointer is the very declaration named — writes through it
    // land on `App.counter1` itself.
    const first: *u64 = @ptrCast(@alignCast(claimed[0].ptr));
    first.* += 3;
    try std.testing.expectEqual(@as(u64, 3), App.counter1);
}

// The resolution runs at comptime — the escape of `&built.tasks` and
// the error paths only exist in a comptime evaluation — so these
// tests force one with `comptime { ... }`.

test "references name the storage instance, not the type" {
    comptime {
        const specs = [_]TaskSpec{
            .{
                .name = "alpha",
                .interrupt_id = "X",
                .priority = 1,
                .resources = refs(.{ .counter1 = &App.counter1, .flag = &App.flag }),
            },
            .{
                .name = "beta",
                .interrupt_id = "Y",
                .priority = 2,
                .resources = refs(.{ .counter2 = &App.counter2 }),
            },
        };
        const named = namedTasks(&specs, "forever", &.{});

        try std.testing.expectEqualStrings("alpha", named[0].task_id);
        try std.testing.expectEqualStrings("X", named[0].interrupt_id);
        try std.testing.expectEqual(@as(u8, 1), named[0].priority);
        try std.testing.expectEqualStrings("Y", named[1].interrupt_id);
        try std.testing.expectEqual(@as(u8, 2), named[1].priority);

        try std.testing.expectEqualStrings("counter1", named[0].resources[0]);
        try std.testing.expectEqualStrings("flag", named[0].resources[1]);
        try std.testing.expectEqualStrings("counter2", named[1].resources[0]);
    }
}

test "claim lends a reference into the section and retracts it after" {
    // The "closures": plain functions whose first parameter is the
    // capture pack `claim` hands back, whose second is the reference.
    const section = struct {
        fn add_to(captured: u64, target: *u64) void {
            target.* += captured;
        }
        fn touch(_: void, target: *u64) void {
            target.* = 99;
        }
    };

    var value: u64 = 10;
    var proxy = Claim("value", u64, 1){ .ptr = &value }; // name+ceiling: what claim traces

    proxy.claim(section.add_to, 5); // fake closure captures the 5
    try std.testing.expectEqual(@as(u64, 15), value);
    try std.testing.expect(!proxy.claimed); // guard restored on exit

    proxy.claim(section.touch, {}); // empty capture
    try std.testing.expectEqual(@as(u64, 99), value);
}

test "claims of different resources compose by nesting" {
    const inner = struct {
        fn into(_: void, target: *u64) void {
            target.* += 1;
        }
    };
    const outer = struct {
        fn nesting(nested: *Claim("b", u64, 2), held: *u64) void {
            held.* += 10;
            nested.claim(inner.into, {}); // claim B while holding A
        }
    };

    var a: u64 = 0;
    var b: u64 = 0;
    var pa = Claim("a", u64, 1){ .ptr = &a };
    var pb = Claim("b", u64, 2){ .ptr = &b };

    pa.claim(outer.nesting, &pb);
    try std.testing.expectEqual(@as(u64, 1), b); // inner ran
    try std.testing.expectEqual(@as(u64, 10), a); // outer ran
    try std.testing.expect(!pa.claimed and !pb.claimed); // both released
}

test "idle is a task in the resolved table, at logical priority 0" {
    comptime {
        const specs = [_]TaskSpec{.{
            .name = "alpha",
            .interrupt_id = "X",
            .priority = 1,
            .resources = &.{},
        }};
        const named = namedTasks(&specs, "forever", refs(.{ .counter1 = &App.counter1 }));

        try std.testing.expectEqual(@as(usize, 2), named.len); // the task, plus idle
        const row = named[named.len - 1];
        try std.testing.expectEqualStrings("forever", row.task_id);
        try std.testing.expectEqualStrings("none", row.interrupt_id); // idle has no interrupt
        try std.testing.expectEqual(@as(u8, 0), row.priority); // the floor, not a choice
        try std.testing.expectEqualStrings("counter1", row.resources[0]);
    }
}

test "resolved names feed the ceiling analysis unchanged" {
    comptime {
        const specs = [_]TaskSpec{
            .{ .name = "alpha", .interrupt_id = "X", .priority = 1, .resources = refs(.{ .counter1 = &App.counter1 }) },
            .{ .name = "beta", .interrupt_id = "Y", .priority = 2, .resources = refs(.{ .counter1 = &App.counter1 }) },
        };
        const named = namedTasks(&specs, "forever", &.{});
        const ceilings = @import("ceiling.zig").computeAtComptime(named);
        try std.testing.expectEqual(@as(usize, 1), ceilings.len);
        try std.testing.expectEqualStrings("counter1", ceilings[0].name);
        try std.testing.expectEqual(@as(u8, 2), ceilings[0].ceiling);
    }
}

test "a handler taking its context is still found by address" {
    // The new-world shape: the context is a plain struct named after
    // the task — exactly what a generated context.zig holds.
    const CtxX = struct { counter2: *u64 };
    const Handlers = struct {
        pub fn bump(ctx: CtxX) void {
            ctx.counter2.* += 1;
        }
    };
    try std.testing.expectEqualStrings("bump", handlerName(Handlers, &Handlers.bump).?);
    // ...and the config's erased reference resolves the same way.
    const erased: *const anyopaque = &Handlers.bump;
    try std.testing.expectEqualStrings("bump", handlerName(Handlers, erased).?);
}
