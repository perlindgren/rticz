//! Parser for the `rticz.json` configuration format.
//!
//! Expected input is a JSON array of task descriptors:
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
