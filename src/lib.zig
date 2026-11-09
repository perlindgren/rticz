//! Library root of the rticz package.
//!
//! Re-exports the JSON parser and the resource ceiling analysis so consumers
//! can `@import("rticz")` and get `rticz.parser` / `rticz.ceiling`.
//! (The *application* root — the file implementing init/idle/tasks — lives in
//! `src/root.zig` and is separate from this library root on purpose.)

const std = @import("std");

pub const parser = @import("parser.zig");
pub const ceiling = @import("ceiling.zig");

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(ceiling);
}
