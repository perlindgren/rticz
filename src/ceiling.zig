//! Resource ceiling analysis (Immediate Ceiling Priority Protocol).
//!
//! The priority ceiling of a resource is the highest priority of any task
//! that accesses it. At runtime, whenever a task locks such a resource, it
//! immediately inherits the ceiling, blocking any lower-priority task that
//! could contend for the same resource.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("parser.zig");

pub const ResourceCeiling = struct {
    /// Resource name as it appears in `rticz.json`.
    name: []const u8,
    /// Highest priority of any task referencing this resource.
    ceiling: u8,
};

pub const Error = Allocator.Error;

/// Compute the priority ceiling for every resource referenced by `tasks`.
///
/// The returned slice is sorted by resource name; entries are only created
/// for resources that are actually used by at least one task. The caller
/// owns the slice and must free it with the same allocator.
pub fn compute(allocator: Allocator, tasks: []const parser.Task) Error![]ResourceCeiling {
    var ceilings = std.StringHashMap(u8).init(allocator);
    defer ceilings.deinit();

    for (tasks) |task| {
        for (task.resources) |res| {
            const gop = try ceilings.getOrPut(res);
            // New entries start uninitialized; assign in both cases where
            // the task's priority sets a new maximum.
            if (!gop.found_existing or task.priority > gop.value_ptr.*) {
                gop.value_ptr.* = task.priority;
            }
        }
    }

    const list = try allocator.alloc(ResourceCeiling, ceilings.count());
    errdefer allocator.free(list);

    var it = ceilings.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        list[i] = .{ .name = entry.key_ptr.*, .ceiling = entry.value_ptr.* };
    }

    std.mem.sort(ResourceCeiling, list, {}, lessByName);
    return list;
}

fn lessByName(_: void, a: ResourceCeiling, b: ResourceCeiling) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;

test "ceiling is the max priority of accessing tasks" {
    const gpa = testing.allocator;
    const tasks = [_]parser.Task{
        .{ .task_id = "t0", .interrupt_id = "TIMER0", .priority = 1,
           .resources = &.{ "res_a", "res_b" } },
        .{ .task_id = "t1", .interrupt_id = "TIMER1", .priority = 2,
           .resources = &.{ "res_b", "res_c" } },
    };

    const ceilings = try compute(gpa, &tasks);
    defer gpa.free(ceilings);

    try testing.expectEqual(@as(usize, 3), ceilings.len);
    try testing.expectEqualStrings("res_a", ceilings[0].name);
    try testing.expectEqual(@as(u8, 1), ceilings[0].ceiling);
    try testing.expectEqualStrings("res_b", ceilings[1].name);
    try testing.expectEqual(@as(u8, 2), ceilings[1].ceiling); // max(1, 2)
    try testing.expectEqualStrings("res_c", ceilings[2].name);
    try testing.expectEqual(@as(u8, 2), ceilings[2].ceiling);
}

test "higher-priority task listed second still wins" {
    const gpa = testing.allocator;
    const tasks = [_]parser.Task{
        .{ .task_id = "hi", .interrupt_id = "A", .priority = 7, .resources = &.{"r"} },
        .{ .task_id = "lo", .interrupt_id = "B", .priority = 3, .resources = &.{"r"} },
    };

    const ceilings = try compute(gpa, &tasks);
    defer gpa.free(ceilings);

    try testing.expectEqual(@as(usize, 1), ceilings.len);
    try testing.expectEqual(@as(u8, 7), ceilings[0].ceiling);
}

test "tasks without resources contribute nothing" {
    const gpa = testing.allocator;
    const tasks = [_]parser.Task{
        .{ .task_id = "t0", .interrupt_id = "A", .priority = 5, .resources = &.{} },
    };

    const ceilings = try compute(gpa, &tasks);
    defer gpa.free(ceilings);

    try testing.expectEqual(@as(usize, 0), ceilings.len);
}
