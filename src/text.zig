//! Fixed-capacity mutable strings, suitable for embedding in statically
//! allocated resources: no allocator, no indirection, capacity checked at
//! every write (and at compile time for literals).

const std = @import("std");

/// A mutable byte string holding at most `max` bytes.
pub fn BoundedString(comptime max: usize) type {
    return struct {
        const Self = @This();

        pub const capacity: usize = max;
        pub const Error = error{StringTooLong};

        buffer: [max]u8 = undefined,
        len: usize = 0,

        /// Initialize from a literal; exceeding capacity is a COMPILE error.
        pub fn init(comptime s: []const u8) Self {
            if (s.len > max) @compileError("BoundedString literal of " ++
                std.fmt.comptimePrint("{d}", .{s.len}) ++
                " bytes exceeds capacity of " ++ std.fmt.comptimePrint("{d}", .{max}));
            var self: Self = .{};
            @memcpy(self.buffer[0..s.len], s);
            self.len = s.len;
            return self;
        }

        /// Runtime write; too-long input is an error, never an overflow.
        pub fn set(self: *Self, bytes: []const u8) Error!void {
            if (bytes.len > max) return error.StringTooLong;
            @memcpy(self.buffer[0..bytes.len], bytes);
            self.len = bytes.len;
        }

        /// The current contents.
        pub fn slice(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}

const testing = std.testing;

test "BoundedString literal init and runtime set" {
    var s = BoundedString(32).init("rticz");
    try testing.expectEqualStrings("rticz", s.slice());

    try s.set("replaced");
    try testing.expectEqualStrings("replaced", s.slice());

    try testing.expectError(error.StringTooLong, s.set("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")); // 33 bytes
    // Rejected writes leave the previous contents intact.
    try testing.expectEqualStrings("replaced", s.slice());

    // Exactly-full is legal.
    try s.set("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"); // 32 bytes
    try testing.expectEqual(@as(usize, 32), s.len);
}
