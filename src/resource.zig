//! The typed application side: resources as real Zig declarations and
//! tasks referenced by their handler functions.
//!
//! The application writes its system definition in `src/root.zig`:
//! each resource is its own `pub var` — placeable in its own linker
//! section or alignment — and `task_specs` declares each interrupt
//! task's line, priority and resource accesses, while `config` names
//! the entry points by reference:
//!
//! ```zig
//! pub var res_a: u64 = 0;
//!
//! const task_specs = [_]rticz.resource.TaskSpec{
//!     .{ .interrupt_id = "TIMER0", .priority = 1,
//!        .resources = rticz.resource.refs(.{ .res_a = &res_a, .res_b = &res_b }) },
//! };
//!
//! .tasks = &rticz.resource.bindHandlers(.{ t0, t1 }, &task_specs),
//! ```
//!
//! A resource access is a *named pair* (`ResourceRef`): the name and
//! `&` of the same declaration, written together as one literal, so
//! no analysis ever recovers a name by walking a namespace or
//! comparing addresses — the name is written down exactly where it is
//! claimed.  init and idle are tasks, so they are declared the same
//! way as the interrupt tasks: a reference to the function, no
//! invented name.  The glue layer resolves each function pointer back
//! to its declared name by walking the application namespace and
//! comparing addresses (`std.meta.eql` compares pointers to declared
//! items at comptime), so the JSON analysis front end keeps seeing
//! plain names, and the boot banner can print what the program is
//! made of.
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
//! plain struct named after the interrupt, generated into
//! `src/generated/context.zig` by `codegen/gen_context.zig` from the very
//! `task_specs` declared here — one field per accessed resource,
//! typed `*T` over the application's declaration.  Handlers therefore
//! do not share a signature, which is why a task's `task_id`
//! reference is an erased address: the config needs identity, and
//! the generated trampoline's call is what checks the signature.

const std = @import("std");

/// The handler of an interrupt task, or of init.
pub const Handler = *const fn () void;

/// The handler of the idle task.  Idle is still the infinite loop the
/// runtime falls into, so it keeps the `noreturn` signature — but it
/// is referenced like every other task, not by name convention.
pub const IdleHandler = *const fn () noreturn;

/// One claimed resource: its name, and the very instance it names.
/// The pair is written as one atomic literal — `.res_a = &res_a` —
/// so the name is never a label recovered from elsewhere: it is the
/// declaration's own name at the place of the claim, and the pointer
/// is that declaration's own storage.  `refs` produces these from
/// the anonymous-struct literal an application writes; the analysis,
/// the generated context structs, and the generated trampolines all
/// read names straight from here — no reflection back through the
/// application namespace, which comptime cannot do safely (a
/// namespace holds consts whose evaluation would force handler
/// analysis, exactly what the build's stub passes must not trigger).
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

/// What one interrupt task declares, before any handler is attached:
/// its interrupt line, its priority, and the resources it accesses.
/// The application writes a list of these; it is the input the
/// context generator reads.  It deliberately contains no function
/// references: reading it must not force the analysis of any handler,
/// because the generator that produces the handler contexts has to
/// read the declaration *before* those handlers can compile — a
/// handler's signature is going to *name* one of the very contexts
/// the generator emits.
pub const TaskSpec = struct {
    interrupt_id: []const u8,
    priority: u8,
    resources: []const ResourceRef,
};

/// The complete declaration of one interrupt task: its spec (from the
/// application's `task_specs`) and the handler that answers its
/// interrupt.  The handler is held as an erased address because each
/// handler takes its own context struct and therefore shares no
/// signature; identity is what the system needs from the reference,
/// and the generated trampoline's call checks the signature.
pub const Task = struct {
    task_id: *const anyopaque,
    interrupt_id: []const u8,
    priority: u8,
    resources: []const ResourceRef,
};

/// Attach handlers to specs, in order: entry `i` of `handlers`
/// answers interrupt `i` of `specs`.  The application's `pub const
/// tasks` is this one line, which is what keeps the two views of a
/// task — the declaration the generator reads, the executable entry
/// the analysis walks — from ever disagreeing.  A handler paired with
/// the wrong spec fails at the trampoline: the context literal built
/// from the spec's resources would not fit the context type the
/// handler's signature demands.
pub fn bindHandlers(comptime handlers: anytype, comptime specs: []const TaskSpec) [specs.len]Task {
    const names = @typeInfo(@TypeOf(handlers)).@"struct".field_names;
    if (names.len != specs.len) {
        @compileError("bindHandlers: the handler list and the task spec list have different lengths");
    }
    var out: [specs.len]Task = undefined;
    inline for (names, specs, 0..) |handler_name, spec, i| {
        out[i] = .{
            .task_id = @field(handlers, handler_name),
            .interrupt_id = spec.interrupt_id,
            .priority = spec.priority,
            .resources = spec.resources,
        };
    }
    return out;
}

/// The idle task, declared like a task — except that it has no
/// interrupt (it *is* the fallback context) and no priority to
/// declare: idle is the lowest-priority context of the system,
/// logical priority 0, by definition, so the framework fixes it in
/// the analysis rather than asking.  What it *can* declare, like any
/// task, is which resources it touches.
pub const IdleTask = struct {
    task_id: IdleHandler,
    resources: []const ResourceRef,
};

/// The system definition: entry points and interrupt tasks, all as
/// function references.  init and idle are tasks like the rest; only
/// the runtime treats them specially (init runs before interrupts are
/// enabled, idle runs when nothing else does).
pub const Config = struct {
    init: Handler,
    idle: IdleTask,
    tasks: []const Task,
};

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
        // The app's contract surface — the system definition, the
        // hoisted task list it embeds, and the specs the task list is
        // bound from — is vocabulary, never a handler, and probing it
        // is not merely wasted but wrong: reading a container-level
        // const evaluates its value, and `config`'s value embeds
        // idle's address, whose analysis names the interrupt vectors
        // and the generated contexts.  During the generator passes
        // the app compiles against the stubs, and that analysis would
        // (rightly) reject them.  Handlers are the application's
        // *other* functions; these names stay out of the walk.
        // (Shape is load-bearing: the guards must be short-circuit
        // operands, not `if … continue` — comptime flow control
        // inside a block that a runtime instantiation also sees is
        // rejected, and this generic does get instantiated from
        // runtime code.)
        const is_contract = std.mem.eql(u8, name, "config") or
            std.mem.eql(u8, name, "tasks") or
            std.mem.eql(u8, name, "task_specs");
        if (!is_contract and @typeInfo(@TypeOf(@field(handlers_ns, name))) == .@"fn" and
            std.meta.eql(target, @as(*const anyopaque, &@field(handlers_ns, name)))) return name;
    }
    return null;
}

/// The analysis-facing task list of an application: the same tasks as
/// `tasks`, with the handler function pointers resolved to their
/// declared names — resource references carry their names directly,
/// so nothing else needs resolving — followed by the idle task, which
/// is a task too (logical priority 0, the system's floor; it has no
/// interrupt, so its row reads `none`).  The ceiling analysis
/// deliberately skips that last row: idle sits at the bottom of the
/// scale and is preempted by every interrupt task, so its 0 can never
/// be a ceiling.  But the row records what idle-context code touches
/// — which is exactly where a ceiling will later have to be enforced.
///
/// `handlers_ns` is the application namespace where the handlers are
/// declared or imported; the analysis walks the application from the
/// outside — the analysis results cannot live in root itself (a
/// `const` in root that reads root's declarations via `@field` is a
/// self-dependency).  Resource names need no namespace at all: each
/// reference states its own name.
///
/// The whole thing runs at comptime, so a handler that is not a
/// function of the namespace, or a priority that claims idle's 0,
/// stops the build with an error that quotes the task by name.
pub fn namedTasks(
    comptime tasks: []const Task,
    comptime idle: IdleTask,
    comptime handlers_ns: type,
) []const parser.Task {
    const count = tasks.len + 1;

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

    // Resolve every handler to its declared name first: the name is
    // what error messages about the same task quote.
    for (tasks, 0..) |task, ti| {
        if (task.priority == 0) {
            @compileError("interrupt tasks start at priority 1; priority 0 is idle");
        }
        entries[ti] = .{
            .name = handlerName(handlers_ns, task.task_id) orelse {
                @compileError("the application config references a task handler that is not a " ++
                    "`pub fn <name>` declared in the application namespace (or an alias of one)");
            },
            .interrupt_id = task.interrupt_id,
            .priority = task.priority,
            .resources = task.resources,
        };
    }
    entries[count - 1] = .{
        .name = handlerName(handlers_ns, idle.task_id) orelse {
            @compileError("the application config references an idle handler that is not a " ++
                "`pub fn <name>() noreturn` declared in the application namespace " ++
                "(or an alias of one)");
        },
        .interrupt_id = "none",
        // The floor of the system, fixed here: idle declares no
        // priority because there is nothing to choose.
        .priority = 0,
        .resources = idle.resources,
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
    pub fn forever() noreturn {
        while (true) {}
    }
    pub fn not_a_handler(_: u8) u8 {
        return 0;
    }
    pub var hidden_state: u64 = 0;
};

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
    const system: Config = .{
        .init = TestTasks.alpha,
        .idle = .{ .task_id = TestTasks.forever, .resources = &.{} },
        .tasks = &.{.{ .task_id = TestTasks.beta, .interrupt_id = "X", .priority = 1, .resources = &.{} }},
    };
    try std.testing.expectEqualStrings("alpha", handlerName(TestTasks, system.init).?);
    try std.testing.expectEqualStrings("forever", handlerName(TestTasks, system.idle.task_id).?);
}

test "a named access pair carries its own name and reaches its own storage" {
    // `comptime`: refs' whole design — names from reflection, a slice
    // frozen into constant memory — only exists in a comptime
    // evaluation, and an application uses it in exactly one place:
    // the `task_specs` table, a container-level const.
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

test "bindHandlers attaches handlers to specs, in order" {
    comptime {
        const specs = [_]TaskSpec{
            .{ .interrupt_id = "X", .priority = 1, .resources = refs(.{ .counter1 = &App.counter1 }) },
            .{ .interrupt_id = "Y", .priority = 2, .resources = refs(.{ .counter2 = &App.counter2 }) },
        };
        const bound = bindHandlers(.{ TestTasks.alpha, TestTasks.beta }, &specs);
        try std.testing.expectEqual(@as(usize, 2), bound.len);
        try std.testing.expectEqualStrings("X", bound[0].interrupt_id);
        try std.testing.expectEqual(@as(u8, 2), bound[1].priority);
        try std.testing.expectEqualStrings("counter2", bound[1].resources[0].name);
        // Identity survives erasure: the reference still *is* the handler.
        try std.testing.expectEqualStrings("alpha", handlerName(TestTasks, bound[0].task_id).?);
        try std.testing.expectEqualStrings("beta", handlerName(TestTasks, bound[1].task_id).?);
    }
}

// The resolution runs at comptime — the escape of `&built.tasks` and
// the error paths only exist in a comptime evaluation — so these
// tests force one with `comptime { ... }`.

const no_idle: IdleTask = .{ .task_id = TestTasks.forever, .resources = &.{} };

test "references name the storage instance, not the type" {
    comptime {
        const specs = [_]TaskSpec{
            .{
                .interrupt_id = "X",
                .priority = 1,
                .resources = refs(.{ .counter1 = &App.counter1, .flag = &App.flag }),
            },
            .{
                .interrupt_id = "Y",
                .priority = 2,
                .resources = refs(.{ .counter2 = &App.counter2 }),
            },
        };
        const tasks: []const Task = &bindHandlers(.{ TestTasks.alpha, TestTasks.beta }, &specs);
        const named = namedTasks(tasks, no_idle, TestTasks);

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

test "idle is a task in the resolved table, at logical priority 0" {
    comptime {
        const specs = [_]TaskSpec{.{
            .interrupt_id = "X",
            .priority = 1,
            .resources = &.{},
        }};
        const tasks: []const Task = &bindHandlers(.{TestTasks.alpha}, &specs);
        const idle: IdleTask = .{
            .task_id = TestTasks.forever,
            .resources = refs(.{ .counter1 = &App.counter1 }),
        };
        const named = namedTasks(tasks, idle, TestTasks);

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
            .{ .interrupt_id = "X", .priority = 1, .resources = refs(.{ .counter1 = &App.counter1 }) },
            .{ .interrupt_id = "Y", .priority = 2, .resources = refs(.{ .counter1 = &App.counter1 }) },
        };
        const tasks: []const Task = &bindHandlers(.{ TestTasks.alpha, TestTasks.beta }, &specs);
        const named = namedTasks(tasks, no_idle, TestTasks);
        const ceilings = @import("ceiling.zig").computeAtComptime(named);
        try std.testing.expectEqual(@as(usize, 1), ceilings.len);
        try std.testing.expectEqualStrings("counter1", ceilings[0].name);
        try std.testing.expectEqual(@as(u8, 2), ceilings[0].ceiling);
    }
}

test "a handler taking its context is still found by address" {
    // The new-world shape: the context is a plain struct named after
    // the interrupt — exactly what src/generated/context.zig holds.
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
