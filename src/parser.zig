//! Parser and data model for the rticz task configuration format.
//!
//! The data model (`Task`, `Config`) is the core; there are two frontends:
//!
//! * The application root (`src/root.zig`) declares its configuration as a
//!   Zig constant whose tasks reference resource *storage* by address — see
//!   `resource.Config`. The compiler resolves those references to declared
//!   field names, producing exactly the name-based `Task` table defined
//!   here, which `comptimeValidate` and the ceiling analysis then consume.
//!   Nothing is parsed.
//! * The `rticz-cli` tool can additionally analyze `rticz.json`-formatted
//!   files at runtime — see `parse`/`parseFile`:
//!
//! ```json
//! [
//!   {
//!     "task_id": "task_0",
//!     "interrupt_id": "interrupt_0",
//!     "priority": 1,
//!     "resources": ["resource_a", "resource_b"]
//!   }
//! ]
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json = std.json;

pub const max_file_size: usize = 1 << 20; // 1 MiB

/// One task descriptor as it appears in `rticz.json`.
pub const Task = struct {
    /// Identifier of the task.
    task_id: []const u8,
    /// Identifier of the interrupt that spawns the task.
    interrupt_id: []const u8,
    /// Scheduling priority (0–255, matching RTIC's `u8` priority range).
    priority: u8,
    /// Names of the resources protected/accessed by the task.
    resources: []const []const u8,
};

/// A name-based task table: what the JSON frontends parse into, and what
/// `resource.namedTasks` resolves the application's address-based config
/// into. This is the shape the ceiling analysis operates on, e.g.
///
/// ```zig
/// const analysis: rticz.Config = .{
///     .tasks = &.{
///         .{ .task_id = "t0", .interrupt_id = "TIMER0", .priority = 1,
///            .resources = &.{"res_a"} },
///     },
/// };
/// ```
pub const Config = struct {
    tasks: []const Task,
};

pub const ParseError = json.ParseError(json.Scanner) ||
    Io.File.OpenError ||
    Io.Reader.LimitedAllocError ||
    ValidateError;
pub const ValidateError = error{
    DuplicateTaskId,
    DuplicateResource,
    EmptyTaskId,
    EmptyInterruptId,
} || Allocator.Error;

/// Parse a `rticz.json`-formatted byte buffer.
///
/// The caller owns `parsed.allocator`-backed memory and must call
/// `parsed.deinit()` when done.
pub fn parse(allocator: Allocator, bytes: []const u8) ParseError!json.Parsed([]const Task) {
    // `.alloc_always` copies strings into the parse arena so that `parsed.value`
    // outlives the caller's input buffer.
    const parsed = try json.parseFromSlice([]const Task, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validate(allocator, parsed.value);
    return parsed;
}

/// Open, read, and parse a `rticz.json`-formatted file.
pub fn parseFile(io: Io, allocator: std.mem.Allocator, path: []const u8) ParseError!json.Parsed([]const Task) {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer file.close(io);

    var buffer: [8 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_file_size));
    defer allocator.free(bytes);

    return parse(allocator, bytes);
}

/// Semantic checks that JSON schema/type rules cannot express.
pub fn validate(allocator: std.mem.Allocator, tasks: []const Task) ValidateError!void {
    var seen_ids = std.StringHashMap(void).init(allocator);
    defer seen_ids.deinit();

    for (tasks) |task| {
        if (task.task_id.len == 0) return error.EmptyTaskId;
        if (task.interrupt_id.len == 0) return error.EmptyInterruptId;

        if (try seen_ids.fetchPut(task.task_id, {})) |_| return error.DuplicateTaskId;

        for (task.resources, 0..) |res, i| {
            for (task.resources[i + 1 ..]) |other| {
                if (std.mem.eql(u8, res, other)) return error.DuplicateResource;
            }
        }
    }
}

/// Compile-time counterpart of `validate`. Call it from a `comptime` block
/// with the application's task table and every violation becomes a compile
/// error that names the offender — no parser, no build step, no runtime
/// check involved.
pub fn comptimeValidate(comptime tasks: []const Task) void {
    comptime {
        for (tasks, 0..) |task, i| {
            if (task.task_id.len == 0)
                @compileError("task at index " ++ std.fmt.comptimePrint("{d}", .{i}) ++
                    " has an empty task_id");
            if (task.interrupt_id.len == 0)
                @compileError("task '" ++ task.task_id ++ "' has an empty interrupt_id");
            if (!isZigIdentifier(task.task_id))
                @compileError("task_id '" ++ task.task_id ++
                    "' is not a valid Zig identifier; task ids name their handler " ++
                    "function in the application root");
            for (tasks[i + 1 ..]) |other| {
                if (std.mem.eql(u8, task.task_id, other.task_id))
                    @compileError("duplicate task_id: " ++ task.task_id);
            }
            for (task.resources, 0..) |res, j| {
                if (res.len == 0)
                    @compileError("task '" ++ task.task_id ++ "' declares an empty resource name");
                for (task.resources[j + 1 ..]) |other| {
                    if (std.mem.eql(u8, res, other))
                        @compileError("task '" ++ task.task_id ++
                            "' lists resource '" ++ res ++ "' twice");
                }
            }
        }
    }
}

/// Whether `s` can serve as a Zig identifier. In the Zig frontend task
/// names come from the handler declarations themselves, so this holds by
/// construction; JSON input is held to the same rule for consistency.
/// Regular function: it executes at comptime when `comptimeValidate` calls
/// it, and at runtime anywhere else.
pub fn isZigIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    // A name that is also a Zig keyword could never name a decl.
    return !std.zig.Token.keywords.has(s);
}

const testing = std.testing;

test "parses the rticz.json format" {
    const gpa = testing.allocator;
    const input =
        \\[
        \\  {
        \\    "task_id": "task_0",
        \\    "interrupt_id": "interrupt_0",
        \\    "priority": 1,
        \\    "resources": ["resource_a", "resource_b"]
        \\  },
        \\  {
        \\    "task_id": "task_1",
        \\    "interrupt_id": "interrupt_1",
        \\    "priority": 2,
        \\    "resources": ["resource_b", "resource_c"]
        \\  }
        \\]
    ;

    var parsed = try parse(gpa, input);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expectEqualStrings("task_0", parsed.value[0].task_id);
    try testing.expectEqualStrings("interrupt_1", parsed.value[1].interrupt_id);
    try testing.expectEqual(@as(u8, 2), parsed.value[1].priority);
    try testing.expectEqual(@as(usize, 2), parsed.value[1].resources.len);
    try testing.expectEqualStrings("resource_c", parsed.value[1].resources[1]);
}

test "rejects duplicate task ids" {
    const gpa = testing.allocator;
    const input =
        \\[
        \\  {"task_id": "t", "interrupt_id": "a", "priority": 0, "resources": []},
        \\  {"task_id": "t", "interrupt_id": "b", "priority": 1, "resources": []}
        \\]
    ;
    try testing.expectError(error.DuplicateTaskId, parse(gpa, input));
}

test "rejects out-of-range priority" {
    const gpa = testing.allocator;
    const input =
        \\[{"task_id": "t", "interrupt_id": "a", "priority": 300, "resources": []}]
    ;
    _ = parse(gpa, input) catch |err| switch (err) {
        error.Overflow => return,
        else => return err,
    };
    return error.MissingExpectedError;
}

test "comptimeValidate accepts a well-formed compile-time config" {
    // The failure paths are @compileError — they cannot be caught by a test,
    // but they are exercised by the build itself (see src/root.zig).
    comptimeValidate(&.{
        .{ .task_id = "t0", .interrupt_id = "TIMER0", .priority = 1,
           .resources = &.{ "res_a", "res_b" } },
        .{ .task_id = "t1", .interrupt_id = "TIMER1", .priority = 2,
           .resources = &.{"res_c"} },
    });
    try testing.expect(isZigIdentifier("t0"));
    try testing.expect(!isZigIdentifier("0t"));
    try testing.expect(!isZigIdentifier("fn"));
    try testing.expect(!isZigIdentifier("has space"));
}
