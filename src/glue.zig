//! The glue: the minimum runtime that boots the system declared by the
//! application.
//!
//! This module is the entry point of the produced binary.  It reads
//! `app.config` — the system definition from `src/root.zig` — and turns
//! its *references* into names at compile time: handlers are matched
//! against the application namespace by address, resource pointers
//! against the fields of `app.resources`.  The resolution must happen
//! out here: a `const` in root that reads root's own declarations via
//! `@field` is a self-dependency Zig rejects, so the framework walks
//! the application, never the other way round.  The walk also checks
//! the definition (duplicate handlers, duplicate resources, valid
//! names), and `main` calls exactly the functions the config names.

const std = @import("std");
const app = @import("app"); // the application root, src/root.zig — NOT
const rticz = @import("rticz"); // @import("root"), which would be *this*
                                // file when glue is the executable entry

pub const config = app.config;

pub const tasks = app.config.tasks;

/// The declared-name view of the config: same order as `tasks`, with
/// handler references resolved to their names in the application
/// namespace and resource pointers resolved to field names of
/// `app.resources` — plus the idle task as the last row, at logical
/// priority 0, because idle is a task too and its resource accesses
/// are a fact about the system worth recording.  This is the input
/// to the JSON-shaped analysis; the ceilings below use only the
/// interrupt-task prefix of it.
pub const named_tasks = rticz.resource.namedTasks(app.config.tasks, app.config.idle, &app.resources, app);

/// Resource ceilings, derived from the config by the framework — the
/// application never states them.  The ceiling is computed over the
/// interrupt tasks only.  Priority 0 is the bottom of the scale:
/// idle is preempted by every task (theirs are 1 and upwards), so
/// its 0 can never be the maximum of a shared resource.  A resource
/// only idle touches needs no ceiling either — no preempting task
/// touches it, so no access to it can be interrupted mid-way.  The
/// side that does need protecting is idle itself, whenever it shares
/// a resource; the level of that protection comes from the other
/// sharers, not from idle.  Idle's declared accesses still live in
/// `named_tasks` — they say *where* that protection will have to be
/// applied, which we will want later.
pub const ceilings = rticz.ceiling.computeAtComptime(named_tasks[0..tasks.len]);

/// init and idle are referenced tasks; these are their declared names,
/// for the banner.
pub const init_name = rticz.resource.handlerName(app, app.config.init) orelse
    @compileError("the application config references an init handler that is not a function declared in the application namespace");
pub const idle_name = rticz.resource.handlerName(app, app.config.idle.task_id) orelse
    @compileError("the application config references an idle handler that is not a function declared in the application namespace");

/// A dispatch table: the glue's view of the tasks, as data.  The
/// `handler` is the very function the config references.
pub const Dispatch = struct {
    task_id: []const u8,
    priority: u8,
    handler: rticz.Handler,
};

/// The table is built in a comptime var, then frozen into a `const`:
/// a slice that escapes as a global must point into constant memory.
const DispatchTable = struct { items: [tasks.len]Dispatch };

const dispatch_table: DispatchTable = blk: {
    var t: DispatchTable = .{ .items = undefined };
    for (tasks, 0..) |task, i| {
        t.items[i] = .{
            .task_id = named_tasks[i].task_id,
            .priority = task.priority,
            .handler = task.task_id,
        };
    }
    break :blk .{ .items = t.items };
};

pub const dispatch: []const Dispatch = &dispatch_table.items;

// A valid system definition is a compile error otherwise: a handler
// referenced twice is the same name appearing twice in the resolved
// table.  (Doc comments are not allowed on comptime blocks, so: plain
// comment.)
comptime {
    rticz.parser.comptimeValidate(named_tasks);
}

comptime {
    // Every handler must be a plain `fn () void` — the config type
    // already guarantees it, so there is nothing left to check except
    // that the tables agree with each other.
    if (dispatch.len != tasks.len) @compileError("dispatch table out of sync");
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    // One-time report of what the binary was built to do.  The
    // framework prints the system definition; init says hello from
    // the application.
    printSystemDefinition();

    // Call exactly the functions the config names as the entry
    // points.  On a real target, `init` would configure clocks and
    // peripherals, the glue would enable the interrupts named by each
    // task's `interrupt_id`, and `idle` would run inside a `loop {
    // WFI; }` — the handler calls inside `idle` stand in for interrupt
    // arrivals.
    const init_fn = app.config.init;
    init_fn();

    // idle is a task: the config references its handler; the glue
    // enters it and it never returns.
    const idle_fn = app.config.idle.task_id;
    idle_fn();
}

/// Print the system definition — tasks, ceilings, resources — read
/// from the config at comptime.
fn printSystemDefinition() void {
    std.debug.print("=== rticz glue: system definition from config ===\n", .{});

    std.debug.print("  tasks ({d}):\n", .{named_tasks.len});
    for (named_tasks) |named| {
        std.debug.print("    {s:>5} : irq={s:<7} priority={d}\n", .{ named.task_id, named.interrupt_id, named.priority });
    }

    std.debug.print("  resource ceilings:\n", .{});
    for (ceilings) |rc| {
        std.debug.print("    {s:>5} : ceiling={d}\n", .{ rc.name, rc.ceiling });
    }

    const store_info = @typeInfo(@TypeOf(app.resources)).@"struct";
    std.debug.print("  resources ({d}, declared types):\n", .{store_info.field_names.len});
    inline for (store_info.field_names, store_info.field_types) |field_name, field_type| {
        std.debug.print("    {s:>5} : {s}\n", .{ field_name, @typeName(field_type) });
    }

    std.debug.print("  entry points: init={s}, idle={s} (referenced in config)\n", .{ init_name, idle_name });
}

// ── Tests ───────────────────────────────────────────────────────────

test "generated tables are consistent" {
    // The resolved table holds every interrupt task plus the idle row.
    try std.testing.expectEqual(tasks.len + 1, named_tasks.len);
    try std.testing.expectEqual(tasks.len, dispatch.len);

    for (tasks, dispatch, 0..) |task, entry, i| {
        const named = named_tasks[i];
        // Priority comes straight from the app config, the name from
        // the resolution.
        try std.testing.expectEqual(task.priority, entry.priority);
        try std.testing.expectEqualStrings(task.interrupt_id, named.interrupt_id);

        // The dispatch table holds the very function the config
        // references.
        try std.testing.expectEqual(@intFromPtr(task.task_id), @intFromPtr(entry.handler));
    }
}

test "idle appears as a task at logical priority 0, with its resources" {
    const row = named_tasks[named_tasks.len - 1];
    try std.testing.expectEqualStrings("idle", row.task_id);
    try std.testing.expectEqualStrings("none", row.interrupt_id);
    try std.testing.expectEqual(@as(u8, 0), row.priority);
    try std.testing.expectEqual(@as(usize, 1), row.resources.len);
    try std.testing.expectEqualStrings("res_c", row.resources[0]);
}

test "init and idle are the functions the config references" {
    try std.testing.expectEqual(@intFromPtr(&app.init), @intFromPtr(app.config.init));
    try std.testing.expectEqual(@intFromPtr(&app.idle), @intFromPtr(app.config.idle.task_id));
    try std.testing.expectEqualStrings("init", init_name);
    try std.testing.expectEqualStrings("idle", idle_name);
}

test "ceilings computed from the app config" {
    // Ceilings see only the interrupt tasks: res_a by t0 (1); res_b
    // by both; res_c by t1 (2).  idle's access to res_c is real, but
    // idle sits at the bottom — t1 preempts it, so t1's priority
    // governs the resource; idle can never raise a ceiling.
    for (ceilings) |rc| {
        if (std.mem.eql(u8, rc.name, "res_a")) try std.testing.expectEqual(@as(u8, 1), rc.ceiling);
        if (std.mem.eql(u8, rc.name, "res_b")) try std.testing.expectEqual(@as(u8, 2), rc.ceiling);
        if (std.mem.eql(u8, rc.name, "res_c")) try std.testing.expectEqual(@as(u8, 2), rc.ceiling);
    }
}
