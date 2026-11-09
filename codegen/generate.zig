//! The code generator: contexts and interrupt vectors, from the app's
//! source text.
//!
//! RTIC hands each task a *context* — a struct with one field per
//! accessed resource, so shared state is reached only through what the
//! task declared — and reaches each task through the interrupt vector
//! table: a function whose *name* is the vector's name (`TIMER0`,
//! `UART0`) that the core calls when the line fires.  Neither is
//! something Zig derives from the application by itself, so both are
//! generated, into src/generated/ (git-ignored, but in the tree for
//! anyone to read, rewritten on every build):
//!
//! *   `context.zig` — one context struct per task, named after it
//!     (`context.t0`, RTIC's `Context<T0>`), each field a `Claim`
//!     proxy carrying the resource's name and priority ceiling in its
//!     type, typed `@TypeOf(app.res_x)` over the application's own
//!     declaration; plus `context.idle` and the `makeIdleCtx`
//!     constructor the glue uses to enter idle, emitted beside the
//!     struct so it can never drift from it.
//! *   `irq.zig` — one trampoline per interrupt, building the task's
//!     context and calling the handler by the name its config row
//!     names; and `tasks`, the handler-binding table the application
//!     used to write by hand, generated where both sides of the
//!     pairing are visible.
//!
//! The chicken-and-egg these create — handlers name contexts, the
//! app imports its vectors, the generators need the app — is broken
//! *without compiling the app at all*: codegen/appsrc.zig reads the
//! `pub const config` literal with the same parser the compiler uses
//! (`std.zig.Ast`), so the config may reference handlers and resource
//! addresses freely — to a reader of text, a reference is a name, and
//! every name is checked against the declarations of the same file.
//! The application then compiles exactly once, against the real
//! generated files: the emitted trampoline calls the handler with a
//! context literal that must type-check against the handler's
//! signature, which is where the whole declaration finally meets its
//! types.  This is the shape of RTIC's own `#[app]` macro, which also
//! works on token streams rather than compiled code.
//!
//! Everything is validated before anything is written: a bad row
//! stops the build with its message, and never leaves half a vector
//! table on disk.
//!
//! Usage: `generate <app source> <context output> <vectors output>` —
//! paths as relative to the build root, which is a run step's working
//! directory; the tool creates the output folder if missing.

const std = @import("std");
const Io = std.Io;

const rticz = @import("rticz");
const appsrc = @import("appsrc.zig");

const context_header =
    \\//! GENERATED FILE — do not edit.
    \\//!
    \\//! Task contexts for the application in src/root.zig, emitted
    \\//! by codegen/generate.zig from `pub const config` during
    \\//! `zig build`, which rewrites this file on every run.
    \\//! Git-ignored: here to be read, not to be committed.
    \\//!
    \\//! One struct per task, named after the task (plus `idle`, the
    \\//! runtime's own context): the fields are that task's declared
    \\//! resources, each a `Claim` proxy over the application's own
    \\//! declaration carrying the resource's name and priority
    \\//! ceiling in its type — so a handler reaches the instance it
    \\//! claimed, only inside a claimed critical section, and under
    \\//! the mask its ceiling names (printed for now; BASEPRI when
    \\//! the runtime can), and the generated vector's context literal
    \\//! is checked against this struct, field for field and type for
    \\//! type.
    \\
    \\const app = @import("app");
    \\const rticz = @import("rticz");
    \\
;

const irq_header =
    \\//! GENERATED FILE — do not edit.
    \\//!
    \\//! Interrupt vectors for the application in src/root.zig, emitted
    \\//! by codegen/generate.zig from `pub const config` during `zig build`,
    \\//! which rewrites this file on every run.  Git-ignored: here to
    \\//! be read, not to be committed.
    \\//! On real hardware these names are the symbols the linker places
    \\//! in the vector table; on the host they are plain functions the
    \\//! idle task calls in place of firing the interrupt line.
    \\//! Each one builds its task's context struct — the sibling
    \\//! generated module names contexts after their task, so this is
    \\//! `context.t0`, not `context.TIMER0` — filling each field with
    \\//! a `Claim` proxy over the application's declaration, then
    \\//! calls the handler with a pointer to it: the call type-checks
    \\//! the task's whole declaration, handler signature included, and
    \\//! the handler reaches each resource only by `claim`ing its
    \\//! proxy.  Above the trampolines: `tasks`, the handler-binding
    \\//! table the application used to write by hand — generated here,
    \\//! where both sides of the pairing are visible, from the config
    \\//! rows and the names they name.
    \\
    \\const app = @import("app");
    \\const context = @import("context");
    \\const rticz = @import("rticz");
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("generate: expected three arguments: the app source, the context output, the vectors output\n", .{});
        std.process.exit(2);
    }
    const app_path = args[1];
    const ctx_path = args[2];
    const irq_path = args[3];

    const source = Io.Dir.cwd().readFileAllocOptions(io, app_path, arena, .unlimited, .of(u8), 0) catch |err| {
        std.debug.print("generate: cannot read the application source '{s}': {t}\n", .{ app_path, err });
        std.process.exit(1);
    };
    const app = appsrc.read(arena, source) catch |err| switch (err) {
        error.Malformed => std.process.exit(1),
        error.OutOfMemory => {
            std.debug.print("generate: out of memory reading the app\n", .{});
            std.process.exit(1);
        },
    };

    // The priority ceilings, computed with the *same* analysis the
    // glue runs — over the same facts: priorities and resource names
    // straight from the config's task rows.  The numbers this tool
    // bakes into its `Claim` fields and the numbers the glue banner
    // prints cannot disagree, because both derive from the one
    // declaration.  Idle is deliberately not a row: priority 0 is the
    // floor, and when idle shares a resource it is the party *to be
    // protected* — the mask protecting it is the other sharers'
    // ceiling, which is exactly what this table states.
    const tasks = try arena.alloc(rticz.parser.Task, app.tasks.len);
    for (app.tasks, tasks) |task, *row| {
        row.* = .{
            .task_id = task.name,
            .interrupt_id = task.interrupt_id,
            .priority = task.priority,
            .resources = task.resources,
        };
    }
    const ceilings = try rticz.ceiling.compute(arena, tasks);

    try emitContexts(io, arena, ctx_path, &app, ceilings);
    try emitVectors(io, irq_path, &app);
}

/// The ceiling a claim of `name` raises to: the highest priority of
/// any *interrupt* task that declared the resource.  A resource only
/// idle touches has no ceiling — no preempting task can race idle
/// for it — and gets 0, the mask that blocks nothing; a real RTIC
/// skips the raise for it, and the trace here prints what the
/// register would take.
fn ceilingFor(ceilings: []const rticz.ceiling.ResourceCeiling, name: []const u8) u8 {
    for (ceilings) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.ceiling;
    }
    return 0;
}

/// Create (the generated folder exists because this tool writes it;
/// it is not in version control, so on a fresh clone it is missing)
/// and open an output, in a build run step's working directory — the
/// build root.
fn openOut(io: Io, path: []const u8) !Io.File {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse ".");
    return Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}

fn emitContexts(io: Io, arena: std.mem.Allocator, path: []const u8, app: *const appsrc.App, ceilings: []const rticz.ceiling.ResourceCeiling) !void {
    var file = try openOut(io, path);
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buf);
    const w = &file_writer.interface;

    try w.writeAll(context_header);

    // Validate before emitting: a bad row stops the build, it does
    // not leave half a file on disk.  (Vectors get the same pass in
    // emitVectors; both halves read the same rows, and each states
    // what *its* artifact needs the names to be.)
    const seen = try arena.alloc([]const u8, app.tasks.len + 1);
    const seen_irqs = try arena.alloc([]const u8, app.tasks.len);
    for (app.tasks, 0..) |task, i| {
        if (!rticz.parser.isZigIdentifier(task.name)) {
            std.debug.print("generate: task name '{s}' is not a valid Zig identifier, " ++
                "so no context struct can be generated for it\n", .{task.name});
            std.process.exit(1);
        }
        if (!rticz.parser.isZigIdentifier(task.interrupt_id)) {
            std.debug.print("generate: interrupt_id '{s}' is not a valid Zig identifier, " ++
                "so no context struct can be generated for it\n", .{task.interrupt_id});
            std.process.exit(1);
        }
        for (seen[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, task.name)) {
                std.debug.print("generate: two tasks are named '{s}'; a task name names its " ++
                    "context struct, so it must be unique\n", .{task.name});
                std.process.exit(1);
            }
        }
        for (seen_irqs[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, task.interrupt_id)) {
                std.debug.print("generate: two tasks claim interrupt '{s}'; one interrupt, one context\n", .{task.interrupt_id});
                std.process.exit(1);
            }
        }
        seen[i] = task.name;
        seen_irqs[i] = task.interrupt_id;

        try w.print("/// ctx for task {s} (interrupt {s}, priority {d})\n", .{ task.name, task.interrupt_id, task.priority });
        try w.print("pub const {s} = struct {{\n", .{task.name});
        try emitFields(w, task.name, task.resources, ceilings);
        try w.print("}};\n\n", .{});
    }

    // Idle is a task: `context.idle`, emitted from its config row
    // like any other.  Its name is not a declaration to validate —
    // there is one idle and `idle` is its name — but a *task* named
    // `idle` would collide with the idle context, and that is
    // checkable here.
    for (seen[0..app.tasks.len]) |name| {
        if (std.mem.eql(u8, name, "idle")) {
            std.debug.print("generate: a task named 'idle' collides with the idle task's context\n", .{});
            std.process.exit(1);
        }
    }
    try w.print("/// ctx for task idle (no interrupt, logical priority 0)\n", .{});
    try w.print("pub const idle = struct {{\n", .{});
    try emitFields(w, "idle", app.idle_resources, ceilings);
    try w.print("}};\n\n", .{});

    // Idle's activation is not a trampoline frame — it is the whole
    // runtime loop — so its context is built once, by whoever enters
    // idle.  The constructor is emitted rather than handwritten by
    // the glue for the same reason the structs are: it names the
    // application's declarations by address (`&app.res_x`), so it can
    // never drift from the declaration that claimed them.  The
    // proxies come fresh with it, and live exactly as long as idle
    // runs — which is forever.
    try w.print("pub fn makeIdleCtx() idle {{\n    return .{{", .{});
    for (app.idle_resources, 0..) |res, j| {
        try w.print("{s} .{s} = .{{ .ptr = &app.{s} }}", .{ if (j != 0) "," else "", res, res });
    }
    try w.print(" }};\n}}\n", .{});

    try w.flush();
}

/// One context's fields: the resources the task declared, each a
/// `Claim` proxy.  The pointee type is the application's declaration
/// itself speaking — `@TypeOf(app.res_x)`, not a type name printed
/// here: whatever the programmer writes at the declaration — a
/// generic instance, a typedef — flows into the context without this
/// file ever going stale.  The name and `ceilingFor(res)` ride in
/// beside it because the proxy cannot introspect either — it is a
/// struct whose only member is a pointer — yet `claim` must announce
/// both, so the generator tells it: `Claim("res_a", …, 1)`.
/// Wrapped in `Claim`, the field hands the handler a proxy, not the
/// reference: only `claim` opens it, only for a critical section, and
/// only behind the mask its ceiling names.
fn emitFields(w: *Io.Writer, owner: []const u8, resources: []const []const u8, ceilings: []const rticz.ceiling.ResourceCeiling) !void {
    for (resources, 0..) |res, ri| {
        if (!rticz.parser.isZigIdentifier(res)) {
            std.debug.print("generate: resource '{s}' is not a valid Zig identifier, " ++
                "so it cannot be a field of a context struct\n", .{res});
            std.process.exit(1);
        }
        for (resources[0..ri]) |earlier| {
            if (std.mem.eql(u8, earlier, res)) {
                std.debug.print("generate: task '{s}' lists resource '{s}' twice; " ++
                    "a context has one field per resource\n", .{ owner, res });
                std.process.exit(1);
            }
        }
        try w.print("    {s}: rticz.resource.Claim(\"{s}\", @TypeOf(app.{s}), {d}),\n", .{ res, res, res, ceilingFor(ceilings, res) });
    }
}

fn emitVectors(io: Io, path: []const u8, app: *const appsrc.App) !void {
    var file = try openOut(io, path);
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buf);
    const w = &file_writer.interface;

    try w.writeAll(irq_header);

    // The vector's own checks: the trampoline's name is the interrupt
    // line, and one line means one function.  (The row's names naming
    // real functions was already proven by appsrc.read — against the
    // app's own declarations, from the same text.)
    var seen_buf: [64][]const u8 = undefined;
    if (app.tasks.len > seen_buf.len) {
        std.debug.print("generate: internal: too many tasks for the duplicate check buffer\n", .{});
        std.process.exit(1);
    }
    const seen = seen_buf[0..app.tasks.len];
    for (app.tasks, 0..) |task, i| {
        if (!rticz.parser.isZigIdentifier(task.interrupt_id)) {
            std.debug.print("generate: interrupt_id '{s}' is not a valid Zig identifier, " ++
                "so no vector function can be generated for it\n", .{task.interrupt_id});
            std.process.exit(1);
        }
        for (seen[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, task.interrupt_id)) {
                std.debug.print("generate: two tasks claim interrupt '{s}'; a vector table has room for one handler per line\n", .{task.interrupt_id});
                std.process.exit(1);
            }
        }
        seen[i] = task.interrupt_id;
    }

    // The handler-binding table the application used to write by hand
    // (`bindHandlers` over a spec list), now generated: rows are the
    // config's facts, `task_id` is the address of the function its
    // name names — the erased addresses exist exactly once, here,
    // emitted from names proven to resolve.  `priorityOf` reads this
    // table.
    try w.writeAll(
        \\/// The handler-binding table: the config's rows, each paired
        \\/// with the function its name names.  Generated — the
        \\/// application writes names, this is what they mean.
        \\pub const tasks = [_]rticz.resource.Task{
        \\
    );
    for (app.tasks, 0..) |task, i| {
        try w.print("    .{{ .task_id = app.{s}, .name = \"{s}\", .interrupt_id = \"{s}\", " ++
            ".priority = {d}, .resources = app.config.tasks[{d}].resources }},\n", .{
            task.name,
            task.name,
            task.interrupt_id,
            task.priority,
            i,
        });
    }
    try w.writeAll("};\n");

    // One trampoline per declared interrupt.  The context literal's
    // fields: the names the task claimed, carried by its access list
    // — the same list the context struct was emitted from, so the
    // literal this hardware entry point constructs is checked, field
    // for field and type for type, against what the handler declares
    // it receives.
    for (app.tasks) |task| {
        try w.writeAll("\n");
        try w.print("/// interrupt {s} → task {s} (ctx: ", .{ task.interrupt_id, task.name });
        for (task.resources, 0..) |res, j| {
            try w.print("{s}{s}", .{ if (j != 0) ", " else "", res });
        }
        try w.print(")\n", .{});
        try w.print("pub fn {s}() void {{\n", .{task.interrupt_id});
        // The proxies live inside this activation's context: their
        // `claimed` guards therefore live exactly as long as the run,
        // and the handler — reached through a pointer — shares the
        // one guard per resource with every copy of the context.
        // Annotated with the generated type, so the literal and the
        // handler's signature close over each other: naming a
        // mismatched handler is a type error, here.
        try w.print("    var ctx: context.{s} = .{{", .{task.name});
        for (task.resources, 0..) |res, j| {
            try w.print("{s} .{s} = .{{ .ptr = &app.{s} }}", .{ if (j != 0) "," else "", res, res });
        }
        try w.print(" }};\n    app.{s}(&ctx);\n}}\n", .{task.name});
    }

    try w.flush();
}
