//! rticz-cli — command-line tool: print the resource ceiling analysis of
//! the task configuration compiled into the binary (the application
//! root it was wired against), or of
//! any `rticz.json`-formatted file given as an argument.

const std = @import("std");
const Io = std.Io;

const rticz = @import("rticz");
const glue = @import("glue");

const usage =
    \\rticz — resource ceiling analysis for RTIC task configurations
    \\
    \\usage: rticz [OPTIONS] [FILE]
    \\
    \\With no FILE, prints the task table and resource priority ceilings
    \\computed at compile time from `pub const config` in the application
    \\root this binary was built with.
    \\
    \\With a FILE, parses and analyzes an rticz.json-formatted configuration
    \\at runtime instead.
    \\
    \\Arguments:
    \\  FILE          configuration file to analyze at runtime
    \\
    \\Options:
    \\  -h, --help    print this help and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // Argument parsing.
    var path: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return;
        }
        if (arg.len > 1 and arg[0] == '-') {
            try stderr.print("rticz: unrecognized option '{s}'\n\n", .{arg});
            try stderr.writeAll(usage);
            try stderr.flush();
            std.process.exit(2);
        }
        if (path != null) {
            try stderr.print("rticz: unexpected extra argument '{s}'\n", .{arg});
            try stderr.flush();
            std.process.exit(2);
        }
        path = arg;
    }

    if (path) |file| {
        // Runtime mode: analyze an arbitrary file with no build involvement.
        const parsed = rticz.parser.parseFile(io, arena, file) catch |err| fail(stderr, file, err);
        const ceilings = rticz.ceiling.compute(arena, parsed.value) catch |err| fail(stderr, file, err);
        try printReport(stdout, file, parsed.value, ceilings);
    } else {
        // Default mode: zero-parse report. `glue.named_tasks` and
        // `glue.ceilings` are constants the compiler derived from
        // `pub const config` in the application root — this binary
        // just prints the tables that are already baked into it.
        try printReport(stdout, "compiled-in config (root.zig)", glue.named_tasks, glue.ceilings);
    }

    try stdout.flush();
}

/// Print the tasks table followed by the resource ceilings table.
fn printReport(
    stdout: *Io.Writer,
    source: []const u8,
    tasks: []const rticz.parser.Task,
    ceilings: []const rticz.ceiling.ResourceCeiling,
) !void {
    try stdout.print("analysis of {s} — {d} task(s), {d} resource(s)\n\n", .{
        source, tasks.len, ceilings.len,
    });

    try stdout.print("tasks ({d}):\n", .{tasks.len});
    for (tasks) |task| {
        try stdout.print("  {s:<8} interrupt={s:<8} priority={d} resources=[", .{
            task.task_id, task.interrupt_id, task.priority,
        });
        for (task.resources, 0..) |res, j| {
            if (j != 0) try stdout.print(", ", .{});
            try stdout.print("{s}", .{res});
        }
        try stdout.print("]\n", .{});
    }

    try stdout.print("\nresource ceilings ({d}):\n", .{ceilings.len});
    for (ceilings) |c| {
        try stdout.print("  {s:<8} ceiling={d}\n", .{ c.name, c.ceiling });
    }
}

fn fail(stderr: *Io.Writer, path: []const u8, err: anyerror) noreturn {
    stderr.print("rticz: {s}: {s}\n", .{ path, describeError(err) }) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "expected a file but found a directory",
        error.StreamTooLong => "file too large (limit 1 MiB)",
        error.SyntaxError, error.UnexpectedToken, error.UnexpectedEndOfInput => "invalid JSON syntax",
        error.MissingField => "missing required field (task_id, interrupt_id, priority, resources)",
        error.UnknownField => "unknown field in task object",
        error.DuplicateField => "duplicate field in task object",
        error.Overflow => "priority out of range (must fit a u8, 0–255)",
        error.InvalidNumber => "invalid number literal",
        error.DuplicateTaskId => "duplicate task_id",
        error.DuplicateResource => "duplicate resource within a task",
        error.EmptyTaskId => "empty task_id",
        error.EmptyInterruptId => "empty interrupt_id",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}
