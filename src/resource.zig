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
//! `@field` only after the signature test has skipped the non-fns.
//! And the walk must run in the framework (glue), never in root: a
//! `const` in root whose initializer reads root's own declarations
//! via `@field` is a self-dependency Zig rejects.  Hence
//! `namedTasks` takes the application namespace from the outside.

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
    task_id: Handler,
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
/// The walk stays legal even when the namespace holds `var`s (like
/// `resources`) that comptime may not evaluate: each declaration is
/// first asked for its *type* — `@TypeOf(@field(...))` is a type
/// question comptime can answer for `var`s, `const`s and functions
/// alike — and `@field` is only evaluated once the signature test has
/// skipped the non-fns.
pub fn handlerName(comptime handlers_ns: type, comptime handler: anytype) ?[]const u8 {
    const target = @typeInfo(@TypeOf(handler)).pointer.child;
    // `inline` is essential: the iteration value feeds `@field`, which
    // needs the name comptime-known, and plain for-loops do not give
    // that even to a comptime-evaluated function.
    inline for (@typeInfo(handlers_ns).@"struct".decl_names) |decl_name| {
        const name: []const u8 = decl_name;
        if (@TypeOf(@field(handlers_ns, name)) != target) continue;
        if (std.meta.eql(handler, &@field(handlers_ns, name))) return name;
    }
    return null;
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
    const Store = @typeInfo(@TypeOf(store_ptr)).pointer.child;
    const store_info = @typeInfo(Store).@"struct";

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
                    "`pub fn <name>() void` declared in the application namespace " ++
                    "(or an alias of one)");
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
            var found: ?[]const u8 = null;
            inline for (store_info.field_names) |field_name| {
                const candidate: *anyopaque = @ptrCast(&@field(store_ptr.*, field_name));
                if (std.meta.eql(res_ptr, candidate)) {
                    found = field_name;
                    break;
                }
            }
            pool_items[total + ri] = found orelse {
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
