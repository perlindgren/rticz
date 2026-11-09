//! The task-context generator.
//!
//! RTIC hands each task a *context*: a struct with one field per
//! accessed resource, so shared state is reached only through what
//! the task declared.  Real RTIC generates these structs in a macro
//! pass, and so does this framework: this tool emits, per declared
//! task, the context struct its handler's signature will name —
//!
//! ```zig
//! pub const t0 = struct {
//!     res_a: rticz.resource.Claim("res_a", @TypeOf(app.res_a), 1),
//!     res_b: rticz.resource.Claim("res_b", @TypeOf(app.res_b), 2),
//! };
//! ```
//!
//! — each a `Claim` proxy over the application's own declaration, so
//! the context always reaches the very instances the task claimed,
//! whatever section or alignment those carry; and each carrying, in
//! its type, the resource's name and priority ceiling — the highest
//! priority of any task that touches it, computed here from the task
//! table with the same analysis the glue runs.  The proxy cannot know
//! either by itself: `claim` is a method on a struct whose only
//! member is a pointer, so what a section must announce (whose
//! resource, behind which mask) is baked into the field type.  On a
//! Cortex-M the ceiling is what BASEPRI takes while the resource is
//! claimed (RTIC raises it at every lock, and `claim` will too);
//! until the runtime implements the masking, `claim` prints the
//! raise and the restore around the section — `-- priority ceiling
//! res_a 1` — and the type arguments are precisely what it prints.
//!
//! The chicken-and-egg this creates, and how it is broken, mirrors
//! the vector generator — one floor deeper:
//!
//! *   a handler's signature names its context (`ctx: context.t0`),
//!     so no handler can compile before the contexts exist;
//! *   therefore this generator must *not* read anything that drags
//!     handlers along.  It reads `app.task_specs` — task names,
//!     interrupt lines, priorities, and named resource accesses — and
//!     `app.idle_spec`, declarations with no function references in
//!     them.  Materializing those lists forces the analysis of
//!     nothing but the resource addresses; the handlers stay
//!     unanalyzed, their unresolvable signatures never looked at.
//!
//! build.zig wires this generator's copy of the app against the
//! committed stubs codegen/context_stub.zig (empty: nothing here resolves
//! a context against it) and codegen/vectors_stub.zig.  The vector
//! generator (codegen/extract.zig) then runs *after* this one, compiling
//! the app against the freshly generated contexts — which is where
//! the handler signatures are finally checked.
//!
//! The contexts are named after the *task*, exactly as RTIC hands
//! `Context<T0>` to the task named `t0` — and the name is read from
//! the spec, where the application declared it as a plain string.
//! The handler's declared name would be the one-stop truth, but
//! reading it means analyzing the handler, the very thing this pass
//! must not do; the vector generator, which does see handlers,
//! checks the two agree.  Idle gets `context.idle`: one idle per
//! system, its resources declared in `app.idle_spec`; and because
//! idle's single activation outlives any trampoline frame — it *is*
//! the runtime loop — the generator emits the one constructor the
//! glue needs, `makeIdleCtx`, so the context literal lives beside the
//! struct it constructs and cannot drift from it.
//!
//! The output is written into the tree at src/generated/context.zig —
//! git-ignored, but visible, so anyone can read exactly what the
//! build emitted.  The build re-runs this tool on every `zig build`,
//! which keeps that visible file honest even if someone edits or
//! deletes it: the next build overwrites or restores it.
//!
//! Usage: `gen_context <output path>` — the build system passes the
//! output path relative to the build root, its own working directory
//! (the one a run step executes in), and this tool creates the parent
//! folder.

const std = @import("std");
const Io = std.Io;

const app = @import("app");
const rticz = @import("rticz");

/// Every resource's priority ceiling for this application, computed
/// with the *same* ceiling analysis the glue runs — over the same
/// facts: priorities and resource names straight from the
/// handler-free `task_specs`, reshaped into the `parser.Task` rows
/// the analysis takes (its `task_id` is here the spec's plain
/// declared name, so reshaping drags no handler along).  The numbers
/// this context bakes into its `Claim` fields and the numbers the
/// glue banner prints cannot disagree, because both derive from the
/// one declaration.  Idle is deliberately not a row: priority 0 is
/// the floor, and when idle shares a resource it is the party *to be
/// protected* — the mask protecting it is the other sharers'
/// ceiling, which is exactly what this table states.
const ceilings: []const rticz.ceiling.ResourceCeiling = table: {
    var total: usize = 0;
    for (app.task_specs) |spec| total += spec.resources.len;
    const Rows = struct {
        tasks: [app.task_specs.len]rticz.parser.Task,
        pool: [total][]const u8,
    };
    const rows: Rows = rows: {
        var r: Rows = .{ .tasks = undefined, .pool = undefined };
        var pos: usize = 0;
        for (app.task_specs, 0..) |spec, i| {
            for (spec.resources, 0..) |res, j| r.pool[pos + j] = res.name;
            r.tasks[i] = .{
                .task_id = spec.name,
                .interrupt_id = spec.interrupt_id,
                .priority = spec.priority,
                .resources = r.pool[pos..][0..spec.resources.len],
            };
            pos += spec.resources.len;
        }
        break :rows r;
    };
    break :table rticz.ceiling.computeAtComptime(&rows.tasks);
};

/// The ceiling a claim of `name` raises to: the highest priority of
/// any *interrupt* task that declared the resource.  A resource only
/// idle touches has no ceiling — no preempting task can race idle
/// for it — and gets 0, the mask that blocks nothing; a real RTIC
/// skips the raise for it, and the trace here prints what the
/// register would take.
fn ceilingFor(name: []const u8) u8 {
    for (ceilings) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.ceiling;
    }
    return 0;
}

const header =
    \\//! GENERATED FILE — do not edit.
    \\//!
    \\//! Task contexts for the application in src/root.zig, emitted
    \\//! by codegen/gen_context.zig from `pub const task_specs` during
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
    \\
    \\const app = @import("app");
    \\const rticz = @import("rticz");
    \\
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("gen_context: expected one argument: the output file path\n", .{});
        std.process.exit(2);
    }
    const out_path = args[1];

    // The generated folder exists because this tool writes it; it is
    // not in version control, so on a fresh clone the directory is
    // missing and must be created before the file can land in it.
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(out_path) orelse ".");
    var file = try Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    // The path is relative to the build root, which is also the
    // working directory a build-system run step executes in, so `cwd`
    // is exactly the right anchor.
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buf);
    const w = &file_writer.interface;

    try w.writeAll(header);

    // One context struct per declared task — named after the task —
    // and one for idle.  `app.task_specs` and `app.idle_spec`, not
    // `app.tasks` and never `app.config` — see the module comment for
    // why the handler-free declarations are the only input this pass
    // may read.  Every name written below must be a valid Zig
    // identifier: the task names the struct, the resource names its
    // fields.
    var seen: [app.task_specs.len + 1][]const u8 = undefined;
    var seen_irqs: [app.task_specs.len][]const u8 = undefined;
    for (app.task_specs, 0..) |spec, i| {
        if (!rticz.parser.isZigIdentifier(spec.name)) {
            std.debug.print("gen_context: task name '{s}' is not a valid Zig identifier, " ++
                "so no context struct can be generated for it\n", .{spec.name});
            std.process.exit(1);
        }
        if (!rticz.parser.isZigIdentifier(spec.interrupt_id)) {
            std.debug.print("gen_context: interrupt_id '{s}' is not a valid Zig identifier, " ++
                "so no context struct can be generated for it\n", .{spec.interrupt_id});
            std.process.exit(1);
        }
        for (seen[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, spec.name)) {
                std.debug.print("gen_context: two tasks are named '{s}'; a task name names its " ++
                    "context struct, so it must be unique\n", .{spec.name});
                std.process.exit(1);
            }
        }
        for (seen_irqs[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, spec.interrupt_id)) {
                std.debug.print("gen_context: two tasks claim interrupt '{s}'; one interrupt, one context\n", .{spec.interrupt_id});
                std.process.exit(1);
            }
        }
        seen[i] = spec.name;
        seen_irqs[i] = spec.interrupt_id;

        try w.print("/// ctx for task {s} (interrupt {s}, priority {d})\n", .{ spec.name, spec.interrupt_id, spec.priority });
        try w.print("pub const {s} = struct {{\n", .{spec.name});
        try emitFields(w, spec.name, spec.resources);
        try w.print("}};\n\n", .{});
    }

    // Idle is a task: `context.idle`, emitted from the handler-free
    // `idle_spec` like any other.  Its name is not a declaration to
    // validate — there is one idle and `idle` is its name — but a
    // *task* named `idle` would collide with the idle context, and
    // that is checkable here.
    for (seen[0..app.task_specs.len]) |name| {
        if (std.mem.eql(u8, name, "idle")) {
            std.debug.print("gen_context: a task named 'idle' collides with the idle task's context\n", .{});
            std.process.exit(1);
        }
    }
    try w.print("/// ctx for task idle (no interrupt, logical priority 0)\n", .{});
    try w.print("pub const idle = struct {{\n", .{});
    try emitFields(w, "idle", app.idle_spec.resources);
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
    for (app.idle_spec.resources, 0..) |res, j| {
        try w.print("{s} .{s} = .{{ .ptr = &app.{s} }}", .{ if (j != 0) "," else "", res.name, res.name });
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
fn emitFields(w: *Io.Writer, owner: []const u8, resources: []const rticz.resource.ResourceRef) !void {
    for (resources, 0..) |res, ri| {
        if (!rticz.parser.isZigIdentifier(res.name)) {
            std.debug.print("gen_context: resource '{s}' is not a valid Zig identifier, " ++
                "so it cannot be a field of a context struct\n", .{res.name});
            std.process.exit(1);
        }
        for (resources[0..ri]) |earlier| {
            if (std.mem.eql(u8, earlier.name, res.name)) {
                std.debug.print("gen_context: task '{s}' lists resource '{s}' twice; " ++
                    "a context has one field per resource\n", .{ owner, res.name });
                std.process.exit(1);
            }
        }
        try w.print("    {s}: rticz.resource.Claim(\"{s}\", @TypeOf(app.{s}), {d}),\n", .{ res.name, res.name, res.name, ceilingFor(res.name) });
    }
}
