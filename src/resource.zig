//! The typed application side: resources as real Zig instances and
//! tasks referenced by their handler functions.
//!
//! The application writes its system definition in `src/root.zig`:
//! `pub var resources` holds the storage instances, and `config` names
//! the entry points by reference —
//!
//! ```zig
//! .init = init,
//! .idle = idle,
//! .tasks = &.{.{ .task_id = t0, ... }},
//! ```
//!
//! init and idle are tasks, so they are declared the same way as the
//! interrupt tasks: a reference to the function, no invented name.
//! Handlers are plain file-scope functions; one imported with
//! `const t0 = @import("irq.zig").t0;` is just as addressable as one
//! written here.  The glue layer resolves each function pointer back
//! to its declared name by walking the application namespace and
//! comparing addresses (`std.meta.eql` compares pointers to declared
//! items at comptime), so the JSON analysis front end keeps seeing
//! plain names, and the boot banner can print what the program is
//! made of.
//!
//! Two Zig facts shape the implementation.  A `var` in the namespace
//! cannot be read at comptime, so the walk asks only
//! `@TypeOf(@field(app, name))` — a type question that comptime can
//! answer for `var`s, `const`s and functions alike — and evaluates
//! `@field` only after the type test has skipped the non-fns.
//! And the walk must run in the framework (glue), never in root: a
//! `const` in root whose initializer reads root's own declarations
//! via `@field` is a self-dependency Zig rejects.  Hence
//! `namedTasks` takes the application namespace from the outside.
//!
//! Task handlers take a per-task *context* (RTIC's `Context`): the
//! `Ctx` type function derives that struct — one field per accessed
//! resource, named by the store and typed `*T` over the instance —
//! from the same address identity the analysis uses.  Handlers
//! therefore no longer share a signature, which is why a task's
//! `task_id` reference is an erased address: the config needs
//! identity, and the generated trampoline's call is what checks the
//! signature.

const std = @import("std");

/// The handler of an interrupt task, or of init.
pub const Handler = *const fn () void;

/// The handler of the idle task.  Idle is still the infinite loop the
/// runtime falls into, so it keeps the `noreturn` signature — but it
/// is referenced like every other task, not by name convention.
pub const IdleHandler = *const fn () noreturn;

/// One task in the application's system definition, as declared in
/// `src/root.zig`.
pub const Task = struct {
    /// The task *is* its handler: a reference to a function in the
    /// application namespace.  Resolved to a name for the analysis.
    /// The pointer is type-erased because handlers no longer share a
    /// signature — each takes its own context struct (see `Ctx`) —
    /// and all the config needs from the reference is *identity*,
    /// which is what the address carries.  The signature is checked
    /// where it matters: the generated trampoline calls the handler
    /// with a context literal that must type-check against it.
    task_id: *const anyopaque,
    interrupt_id: []const u8,
    priority: u8,
    /// Pointers to the resource instances this task accesses.  The
    /// pointer target type is erased (`*anyopaque`) so a `&u64`, a
    /// `*Position` and a `*BoundedString(32)` coexist in one list.
    /// The address *is* the identity of a resource: `&resources.res_b`
    /// names exactly one instance, whatever its type.
    resources: []const *anyopaque,
};

/// The idle task, declared like a task — except that it has no
/// interrupt (it *is* the fallback context) and no priority to
/// declare: idle is the lowest-priority context of the system,
/// logical priority 0, by definition, so the framework fixes it in
/// the analysis rather than asking.  What it *can* declare, like any
/// task, is which resources it touches.
pub const IdleTask = struct {
    task_id: IdleHandler,
    resources: []const *anyopaque,
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
/// The walk stays legal even when the namespace holds `var`s (like
/// `resources`) that comptime may not evaluate: each declaration is
/// first asked for its *type* — `@TypeOf(@field(...))` is a type
/// question comptime can answer for `var`s, `const`s and functions
/// alike — and `@field` is only evaluated once the type test has
/// skipped the non-fns.
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
        // The app's contract surface — the system definition and the
        // hoisted task list it embeds — is vocabulary, never a
        // handler, and probing it is not merely wasted but wrong:
        // reading a container-level const evaluates its value, and
        // `config`'s value embeds idle's address, whose analysis
        // names the interrupt vectors.  During the vector-generation
        // pass the app compiles against the empty stub, and that
        // analysis would (rightly) reject it.  Handlers are the
        // application's *other* functions; these two names stay out
        // of the walk.  (Shape is load-bearing: the guards must be
        // short-circuit operands, not `if … continue` — comptime flow
        // control inside a block that a runtime instantiation also
        // sees is rejected, and this generic does get instantiated
        // from runtime code.)
        const is_contract = std.mem.eql(u8, name, "config") or std.mem.eql(u8, name, "tasks");
        if (!is_contract and @typeInfo(@TypeOf(@field(handlers_ns, name))) == .@"fn" and
            std.meta.eql(target, @as(*const anyopaque, &@field(handlers_ns, name)))) return name;
    }
    return null;
}

/// The field name of the store `store_ptr` points at whose instance
/// `res_ptr` addresses — or null if the pointer addresses nothing in
/// the store.  The address *is* the identity of a resource, so this
/// is the question "which resource is this?" asked in the store's
/// vocabulary.  Runs at comptime; takes the store by pointer because
/// the store is a `var` whose value comptime may not evaluate, while
/// the addresses of its fields are known.
pub fn resourceName(comptime store_ptr: anytype, comptime res_ptr: *anyopaque) ?[]const u8 {
    const store_info = @typeInfo(@typeInfo(@TypeOf(store_ptr)).pointer.child).@"struct";
    inline for (store_info.field_names) |field_name| {
        const candidate: *anyopaque = @ptrCast(&@field(store_ptr.*, field_name));
        if (std.meta.eql(res_ptr, candidate)) return field_name;
    }
    return null;
}

/// The field names behind a whole access list, in order — the names a
/// task context uses as field names, and the vector trampoline uses
/// to build its context literal.  The result points into constant
/// memory, so it may escape a comptime evaluation.
pub fn resourceNames(comptime store_ptr: anytype, comptime accesses: []const *anyopaque) []const []const u8 {
    var items: [accesses.len][]const u8 = undefined;
    for (accesses, 0..) |res_ptr, i| {
        items[i] = resourceName(store_ptr, res_ptr) orelse {
            @compileError("a task references a resource that is not a field of the application resource store");
        };
    }
    const Frozen = struct { names: [accesses.len][]const u8 };
    const frozen: Frozen = .{ .names = items };
    return &frozen.names;
}

/// The context type of a task: one public field per accessed resource
/// — named exactly as the store field it reaches, typed `*T` over the
/// instance.  This is the RTIC ctx struct; the bare pointer is the
/// proxy for now, and ceiling-aware wrappers (an exclusive handle at
/// the task's priority, a lock at a lower one) replace the field type
/// without changing any of the code written against it.
///
/// The type is *derived*, not emitted into a file: it is computed by
/// the compiler, from the task's access list, on every build — which
/// is the codegen Zig can do itself, and does before any hand of
/// codegen is possible: the handler signatures name these types, and
/// the vector generator must compile the app *before* the vectors
/// exist.  What genuinely needs codegen — a symbol named `TIMER0` —
/// then builds an instance of this type and calls the handler with
/// it, so the trampoline in `src/generated/irq.zig` is checked
/// against this struct field-for-field, type-for-type.
pub fn Ctx(comptime store_ptr: anytype, comptime accesses: []const *anyopaque) type {
    const Store = @typeInfo(@TypeOf(store_ptr)).pointer.child;
    var names: [accesses.len][]const u8 = undefined;
    var types: [accesses.len]type = undefined;
    var attrs: [accesses.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (accesses, 0..) |res_ptr, i| {
        const name = resourceName(store_ptr, res_ptr) orelse {
            @compileError("a task context reaches a resource that is not a field of the application resource store");
        };
        for (names[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) {
                @compileError(std.fmt.comptimePrint(
                    "a task context lists resource '{s}' twice; a context has one field per resource",
                    .{name},
                ));
            }
        }
        names[i] = name;
        types[i] = *@FieldType(Store, name);
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// The analysis-facing task list of an application: the same tasks as
/// `tasks`, with the handler function pointers resolved to their
/// declared names and the resource pointers resolved to the field
/// names of the resource store `store_ptr` points at — followed by
/// the idle task, which is a task too (logical priority 0, the
/// system's floor; it has no interrupt, so its row reads `none`).
/// The ceiling analysis deliberately skips that last row: idle sits
/// at the bottom of the scale and is preempted by every interrupt
/// task, so its 0 can never be a ceiling.  But the row records what
/// idle-context code touches — which is exactly where a ceiling will
/// later have to be enforced.
///
/// `handlers_ns` is the application namespace where the handlers are
/// declared or imported; `store_ptr` is `&app.resources`.  Both are
/// handed in by the glue layer, which walks the application from the
/// outside — the analysis results cannot live in root itself (a
/// `const` in root that reads root's declarations via `@field` is a
/// self-dependency).
///
/// The whole thing runs at comptime, so a handler that is not a
/// function of the namespace, a resource pointer that is not one of
/// the store's fields, or a priority that claims idle's 0, stops the
/// build with an error that quotes the task by name.
pub fn namedTasks(
    comptime tasks: []const Task,
    comptime idle: IdleTask,
    comptime store_ptr: anytype,
    comptime handlers_ns: type,
) []const parser.Task {
    const count = tasks.len + 1;

    // One uniform view for the two passes: the interrupt tasks, then
    // idle — the only differences being idle's missing interrupt and
    // the fixed logical priority 0.
    const Entry = struct {
        name: []const u8,
        interrupt_id: []const u8,
        priority: u8,
        resources: []const *anyopaque,
    };
    var entries: [count]Entry = undefined;

    // Resolve every handler to its declared name first: the name is
    // what error messages about the same task's resources quote.
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

    // Pass 2: resolve the resource pointers to store field names.
    const cap = count * 8;
    var pool_items: [cap][]const u8 = undefined;
    var total: usize = 0;

    for (entries, 0..) |entry, ti| {
        for (entry.resources, 0..) |res_ptr, ri| {
            pool_items[total + ri] = resourceName(store_ptr, res_ptr) orelse {
                @compileError(std.fmt.comptimePrint(
                    "task '{s}' references a resource that is not a field of " ++
                        "the application resource store",
                    .{entries[ti].name},
                ));
            };
        }
        total += entry.resources.len;
    }

    // Freeze the name pool.  Slices that escape this function must
    // point into constant memory, and a comptime `var` does not
    // qualify — so the pool is first copied into a `const`, and only
    // then are the slices taken from it.
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

const TestStore = struct {
    counter1: u64 = 0,
    counter2: u64 = 0,
    flag: bool = false,
};

var test_store: TestStore = .{};

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

// The resolution runs at comptime — the escape of `&built.tasks` and
// the error paths only exist in a comptime evaluation — so these
// tests force one with `comptime { ... }`.

const no_idle: IdleTask = .{ .task_id = TestTasks.forever, .resources = &.{} };

test "references name the storage instance, not the type" {
    comptime {
        const tasks: []const Task = &.{
            .{ .task_id = TestTasks.alpha, .interrupt_id = "X", .priority = 1, .resources = &.{
                &test_store.counter1, &test_store.flag,
            } },
            .{ .task_id = TestTasks.beta, .interrupt_id = "Y", .priority = 2, .resources = &.{&test_store.counter2} },
        };
        const named = namedTasks(tasks, no_idle, &test_store, TestTasks);

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
        const tasks: []const Task = &.{
            .{ .task_id = TestTasks.alpha, .interrupt_id = "X", .priority = 1, .resources = &.{} },
        };
        const idle: IdleTask = .{
            .task_id = TestTasks.forever,
            .resources = &.{&test_store.counter1},
        };
        const named = namedTasks(tasks, idle, &test_store, TestTasks);

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
        const tasks: []const Task = &.{
            .{ .task_id = TestTasks.alpha, .interrupt_id = "X", .priority = 1, .resources = &.{&test_store.counter1} },
            .{ .task_id = TestTasks.beta, .interrupt_id = "Y", .priority = 2, .resources = &.{&test_store.counter1} },
        };
        const named = namedTasks(tasks, no_idle, &test_store, TestTasks);
        const ceilings = @import("ceiling.zig").computeAtComptime(named);
        try std.testing.expectEqual(@as(usize, 1), ceilings.len);
        try std.testing.expectEqualStrings("counter1", ceilings[0].name);
        try std.testing.expectEqual(@as(u8, 2), ceilings[0].ceiling);
    }
}

test "a task context names its accesses and holds a proxy over each" {
    const C = Ctx(&test_store, &.{ &test_store.counter1, &test_store.flag });
    const info = @typeInfo(C).@"struct";
    try std.testing.expectEqual(@as(usize, 2), info.field_names.len);
    try std.testing.expectEqualStrings("counter1", info.field_names[0]);
    try std.testing.expectEqual(*u64, info.field_types[0]);
    try std.testing.expectEqualStrings("flag", info.field_names[1]);
    try std.testing.expectEqual(*bool, info.field_types[1]);
}

test "context fields reach the very storage instances they name" {
    const C = Ctx(&test_store, &.{&test_store.counter1});
    // `const` ctx: the struct itself is fixed; what mutates is the
    // storage its proxy reaches — which is precisely the point.
    const ctx: C = .{ .counter1 = &test_store.counter1 };
    const before = test_store.counter1;
    ctx.counter1.* += 5;
    try std.testing.expectEqual(before + 5, test_store.counter1);
}

test "a handler taking its context is still found by address" {
    const C = Ctx(&test_store, &.{&test_store.counter2});
    // A handler of the new shape — it takes a context, not nothing.
    const Handlers = struct {
        pub fn bump(ctx: C) void {
            ctx.counter2.* += 1;
        }
    };
    try std.testing.expectEqualStrings("bump", handlerName(Handlers, &Handlers.bump).?);
    // ...and the config's erased reference resolves the same way.
    const erased: *const anyopaque = &Handlers.bump;
    try std.testing.expectEqualStrings("bump", handlerName(Handlers, erased).?);
}
