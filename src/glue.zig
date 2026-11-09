//! The glue: the minimum runtime that boots the system declared by the
//! application.
//!
//! This module is the entry point of the produced binary.  It reads
//! `app.config` — the system definition from `src/root.zig` — and turns
//! its *references* into names at compile time: handlers are matched
//! against the application namespace by address; resource accesses
//! carry their names where they are claimed, so there is nothing to
//! match there.  The handler resolution must happen
//! out here: a `const` in root that reads root's own declarations via
//! `@field` is a self-dependency Zig rejects, so the framework walks
//! the application, never the other way round.  The walk also checks
//! the definition (duplicate handlers, duplicate resources, valid
//! names), and `main` calls exactly the functions the config names.

const std = @import("std");
const app = @import("app"); // the application root, src/root.zig — NOT
const rticz = @import("rticz"); // @import("root"), which would be *this*
                                // file when glue is the executable entry
const context = @import("context"); // the generated task contexts: idle
                                    // enters through the generated
                                    // `makeIdleCtx`, just as the vectors
                                    // enter interrupt tasks through
                                    // generated context literals

pub const config = app.config;

pub const tasks = app.config.tasks;

/// The declared-name view of the config: same order as `tasks`, with
/// handler references resolved to their names in the application
/// namespace (resource accesses name themselves) — plus the idle task
/// as the last row, at logical priority 0, because idle is a task too
/// and its resource accesses are a fact about the system worth
/// recording.  This is the input to the JSON-shaped analysis; the
/// ceilings below use only the interrupt-task prefix of it.
pub const named_tasks = rticz.resource.namedTasks(app.config.tasks, app.config.idle, app);

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
/// `handler` is the very function the config references.  It is held
/// as an address because handlers take per-task contexts and
/// therefore share no signature; on hardware this table *is* what the
/// vector entry points at — the generated trampoline, which builds
/// the context and makes the typed call.
pub const Dispatch = struct {
    task_id: []const u8,
    priority: u8,
    handler: *const anyopaque,
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
    // Nothing here can check handler signatures — each handler takes
    // its own context type — but nothing needs to: the generated
    // trampoline calls the handler with a context literal that must
    // type-check against it.  All that is left to verify is that the
    // tables agree with each other.
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

    // idle is a task: the config references its handler, and like
    // every task it takes a context — the glue enters idle with the
    // generated `makeIdleCtx`, whose literal lives in the same file
    // as the struct, built from the same `idle_spec` the struct was
    // emitted from.  Unlike a trampoline frame, this context lives
    // exactly as long as idle's single activation: the runtime loop
    // that never returns.
    const idle_fn = app.config.idle.task_id;
    var idle_ctx = context.makeIdleCtx();
    idle_fn(&idle_ctx);
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

    std.debug.print("  resources ({d}, declared types):\n", .{resources.len});
    for (resources) |res| {
        std.debug.print("    {s:>5} : {s}\n", .{ res.name, res.type_name });
    }

    std.debug.print("  entry points: init={s}, idle={s} (referenced in config)\n", .{ init_name, idle_name });
}

/// A resource as the system declares it: its name and the declared
/// type of the application's own instance.  Both facts are carried by
/// the access references themselves — each was written as
/// `.name = &name`, so name and type came straight from the
/// declaration the task pointed at; nothing here reflects into the
/// application to recover them.
pub const ResourceInfo = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Every resource any task claims, deduplicated, in first-claim
/// order: the interrupt tasks as declared, then idle's own list.
/// Built in a comptime const initializer, so the "runtime" loops
/// below are compile-time evaluation; the walk reads the config's
/// `ResourceRef`s directly, which carry name and type as written at
/// the claim.  The table is frozen as a container-level `const`, and
/// the public slice is taken from it — a slice escaping into a global
/// must point into constant memory, and a comptime `var` does not
/// qualify.
const ResourceTable = struct { items: [64]ResourceInfo, len: usize };

const resource_table: ResourceTable = blk: {
    var rows: [64]ResourceInfo = undefined;
    var count: usize = 0;
    const all_lists = app.config.tasks.len + 1;
    var li: usize = 0;
    while (li < all_lists) : (li += 1) {
        const list = if (li < app.config.tasks.len)
            app.config.tasks[li].resources
        else
            app.config.idle.resources;
        for (list) |res| {
            var known = false;
            for (rows[0..count]) |row| {
                if (std.mem.eql(u8, row.name, res.name)) known = true;
            }
            if (known) continue;
            rows[count] = .{ .name = res.name, .type_name = res.type_name };
            count += 1;
        }
    }
    break :blk .{ .items = rows, .len = count };
};

pub const resources: []const ResourceInfo = resource_table.items[0..resource_table.len];

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
    // Idle publishes the beat *through* the resources, so all three
    // are access declarations — the ones `context.idle` was emitted
    // from, the ones `makeIdleCtx` fills.
    try std.testing.expectEqual(@as(usize, 3), row.resources.len);
    try std.testing.expectEqualStrings("res_a", row.resources[0]);
    try std.testing.expectEqualStrings("res_b", row.resources[1]);
    try std.testing.expectEqualStrings("res_c", row.resources[2]);
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
