//! The task-context generator.
//!
//! RTIC hands each task a *context*: a struct with one field per
//! accessed resource, so shared state is reached only through what
//! the task declared.  Real RTIC generates these structs in a macro
//! pass, and so does this framework: this tool emits, per declared
//! task, the context struct its handler's signature will name —
//!
//! ```zig
//! pub const TIMER0 = struct {
//!     res_a: *@TypeOf(app.res_a),
//!     res_b: *@TypeOf(app.res_b),
//! };
//! ```
//!
//! — typed as pointers into the application's own declarations, so
//! the context always reaches the very instances the task claimed,
//! whatever section or alignment those carry.
//!
//! The chicken-and-egg this creates, and how it is broken, mirrors
//! the vector generator — one floor deeper:
//!
//! *   a handler's signature names its context (`ctx: context.TIMER0`),
//!     so no handler can compile before the contexts exist;
//! *   therefore this generator must *not* read anything that drags
//!     handlers along.  It reads `app.task_specs` — interrupt lines,
//!     priorities, and named resource accesses, a declaration with no
//!     function references in it.  Materializing that list forces the
//!     analysis of nothing but the resource addresses; the handlers
//!     stay unanalyzed, their unresolvable signatures never looked at.
//!
//! build.zig wires this generator's copy of the app against the
//! committed stubs codegen/context_stub.zig (empty: nothing here resolves
//! a context against it) and codegen/vectors_stub.zig.  The vector
//! generator (codegen/extract.zig) then runs *after* this one, compiling
//! the app against the freshly generated contexts — which is where
//! the handler signatures are finally checked.
//!
//! The contexts are named after the *interrupt*, not the handler:
//! from `task_specs` a generator sees `TIMER0` before any handler is
//! bound to it, and naming by handler would require reading the
//! bound task list — dragging handlers back into the pass that must
//! not see them.
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

const header =
    \\//! GENERATED FILE — do not edit.
    \\//!
    \\//! Task contexts for the application in src/root.zig, emitted
    \\//! by codegen/gen_context.zig from `pub const task_specs` during
    \\//! `zig build`, which rewrites this file on every run.
    \\//! Git-ignored: here to be read, not to be committed.
    \\//!
    \\//! One struct per interrupt, named after it: the fields are the
    \\//! resources that interrupt's task declared, typed as pointers
    \\//! into the application's own declarations — so a handler
    \\//! reaches exactly the instances it claimed, and the generated
    \\//! vector's context literal is checked against this struct,
    \\//! field for field and type for type.
    \\
    \\
    \\const app = @import("app");
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

    // One context struct per declared task.  `app.task_specs`, not
    // `app.tasks` and never `app.config` — see the module comment for
    // why the handler-free list is the only input this pass may read.
    // Every name written below must be a valid Zig identifier: the
    // interrupt names the struct, the resource names its fields.
    var seen: [app.task_specs.len][]const u8 = undefined;
    for (app.task_specs, 0..) |spec, i| {
        if (!rticz.parser.isZigIdentifier(spec.interrupt_id)) {
            std.debug.print("gen_context: interrupt_id '{s}' is not a valid Zig identifier, " ++
                "so no context struct can be generated for it\n", .{spec.interrupt_id});
            std.process.exit(1);
        }
        for (seen[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, spec.interrupt_id)) {
                std.debug.print("gen_context: two tasks claim interrupt '{s}'; one interrupt, one context\n", .{spec.interrupt_id});
                std.process.exit(1);
            }
        }
        seen[i] = spec.interrupt_id;

        try w.print("/// ctx for interrupt {s} (priority {d})\n", .{ spec.interrupt_id, spec.priority });
        try w.print("pub const {s} = struct {{\n", .{spec.interrupt_id});
        for (spec.resources, 0..) |res, ri| {
            if (!rticz.parser.isZigIdentifier(res.name)) {
                std.debug.print("gen_context: resource '{s}' is not a valid Zig identifier, " ++
                    "so it cannot be a field of a context struct\n", .{res.name});
                std.process.exit(1);
            }
            for (spec.resources[0..ri]) |earlier| {
                if (std.mem.eql(u8, earlier.name, res.name)) {
                    std.debug.print("gen_context: task on interrupt '{s}' lists resource '{s}' twice; " ++
                        "a context has one field per resource\n", .{ spec.interrupt_id, res.name });
                    std.process.exit(1);
                }
            }
            // The field type names the application's declaration by
            // `@TypeOf`, not by a type name printed here: whatever
            // the programmer writes at the declaration — a generic
            // instance, a typedef — flows into the context without
            // this file ever going stale.
            try w.print("    {s}: *@TypeOf(app.{s}),\n", .{ res.name, res.name });
        }
        try w.print("}};\n\n", .{});
    }

    try w.flush();
}
