//! The interrupt-vector generator.
//!
//! On real hardware a task is reached through the interrupt vector
//! table: the linker drops a function whose *name* is the vector's
//! name — `TIMER0`, `UART0` — into the table, and the core calls it
//! when the line fires.  Nothing about that placement is expressible
//! in the Zig compiler proper, so it is the piece of the system that
//! genuinely needs codegen beyond the contexts: this tool emits, per
//! config task, a trampoline named after the task's `interrupt_id`
//! that *creates the task's context* — one field per accessed
//! resource, referencing the very declarations the task claimed —
//! and calls the handler with it.
//!
//! The chicken-and-egg this creates, and how it is broken:
//!
//! *   the generator must read the task list of the application, so
//!     it imports the app module and *compiles* it;
//! *   reading the task list materializes the handler references,
//!     which forces the handlers' analysis, which names their context
//!     types — so this pass needs the real contexts, and runs after
//!     src/gen_context.zig wrote them;
//! *   but the application imports the vectors that this tool writes,
//!     so it cannot compile against its real vectors before they
//!     exist.
//!
//! build.zig breaks the cycle by wiring the generator's copy of the
//! app against the committed stub src/vectors_stub.zig instead of the
//! real vectors, and against the freshly generated contexts.  The
//! stub is honest for this tool because it reads `app.tasks`, never
//! `app.config`: materializing the full config materializes idle's
//! address too, and idle's body names the vectors — the compiler
//! would analyze it against the stub and rightly reject it.  The task
//! list materializes only the handlers, whose bodies mention no
//! vectors at all (their comptime self-lookup goes through the
//! hoisted task list for exactly this reason).
//!
//! The real vectors are written into the tree at
//! src/generated/irq.zig — git-ignored, but visible, so anyone can
//! read exactly what the build emitted.  The build re-runs this tool
//! on every `zig build`, which keeps that visible file honest even if
//! someone edits or deletes it: the next build overwrites or restores
//! it.
//!
//! Usage: `extract <output path>` — the build system passes the output
//! path relative to the build root, its own working directory (the one
//! a run step executes in), and this tool creates the parent folder.

const std = @import("std");
const Io = std.Io;

const app = @import("app");
const rticz = @import("rticz");

const header =
    \\//! GENERATED FILE — do not edit.
    \\//!
    \\//! Interrupt vectors for the application in src/root.zig, emitted
    \\//! by src/extract.zig from `pub const tasks` during `zig build`,
    \\//! which rewrites this file on every run.  Git-ignored: here to
    \\//! be read, not to be committed.
    \\//! On real hardware these names are the symbols the linker places
    \\//! in the vector table; on the host they are plain functions the
    \\//! idle task calls in place of firing the interrupt line.
    \\//! Each one builds its interrupt's context struct — from the
    \\//! sibling generated module, src/generated/context.zig — and
    \\//! calls the handler with it: the call type-checks the task's
    \\//! whole declaration, handler signature included.
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
        std.debug.print("extract: expected one argument: the output file path\n", .{});
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

    // One trampoline per declared interrupt.  `app.tasks`, not
    // `app.config` — see the module comment for why that distinction
    // keeps the stub alive.  `inline` because the handler reference
    // must be comptime-known for the name resolution below: it walks
    // the app namespace's declarations and compares addresses, the
    // same resolution the comptime analysis uses, so the generated
    // file reads exactly like the config entry it came from.
    var seen: [app.tasks.len][]const u8 = undefined;
    inline for (app.tasks, 0..) |task, i| {
        if (!rticz.parser.isZigIdentifier(task.interrupt_id)) {
            std.debug.print("extract: interrupt_id '{s}' is not a valid Zig identifier, " ++
                "so no vector function can be generated for it\n", .{task.interrupt_id});
            std.process.exit(1);
        }
        for (seen[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, task.interrupt_id)) {
                std.debug.print("extract: two tasks claim interrupt '{s}'; a vector table has room for one handler per line\n", .{task.interrupt_id});
                std.process.exit(1);
            }
        }
        seen[i] = task.interrupt_id;

        // `comptime` at the call site: inside a runtime block the
        // compiler otherwise falls back to analyzing handlerName as a
        // runtime function, whose probing materializes app-level
        // consts — the resolution is pure compile-time work.
        const handler_name = comptime rticz.resource.handlerName(app, task.task_id) orelse {
            std.debug.print("extract: a task bound to interrupt '{s}' is not a function declared in the app namespace\n", .{task.interrupt_id});
            std.process.exit(1);
        };

        // The context literal's fields: the names the task claimed,
        // carried by its access list — the same list src/gen_context.zig
        // emitted the handler's context struct from, so the literal
        // this hardware entry point constructs is checked, field for
        // field and type for type, against what the handler declares
        // it receives.  This line is where the erased `task_id`
        // reference gets its type checked.
        try w.print("/// interrupt {s} → task {s} (ctx: ", .{ task.interrupt_id, handler_name });
        for (task.resources, 0..) |res, j| {
            try w.print("{s}{s}", .{ if (j != 0) ", " else "", res.name });
        }
        try w.print(")\n", .{});
        try w.print("pub fn {s}() void {{ app.{s}(.{{", .{ task.interrupt_id, handler_name });
        for (task.resources, 0..) |res, j| {
            try w.print("{s} .{s} = &app.{s}", .{ if (j != 0) "," else "", res.name, res.name });
        }
        try w.print(" }}); }}\n\n", .{});
    }

    try w.flush();
}
