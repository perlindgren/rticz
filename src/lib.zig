//! Library root of the rticz package.
//!
//! Re-exports the configuration data models (`Config`/`Task` for name-based
//! JSON input, `ResourceConfig`/`ResourceTask` for the application-root
//! frontend that references resource storage by address), the JSON parser,
//! and the resource ceiling analysis so consumers can `@import("rticz")` and
//! get `rticz.ResourceConfig`, `rticz.parser`, `rticz.ceiling`.
//! (The *application* root — the file declaring `pub const config` and
//! implementing init/idle/tasks — lives in `src/root.zig` and is separate
//! from this library root on purpose.)

const std = @import("std");

pub const parser = @import("parser.zig");
pub const ceiling = @import("ceiling.zig");
pub const resource = @import("resource.zig");
pub const text = @import("text.zig");

/// Shorthand so the CLI can annotate name-based (JSON) task tables.
pub const Config = parser.Config;

/// Shorthand so an application root can write `pub const config: rticz.ResourceConfig`.
pub const ResourceConfig = resource.Config;

/// One task of a `ResourceConfig`, referencing its handler and its resource
/// storage by identity.
pub const ResourceTask = resource.Task;

/// The required signature of the init handler: `fn() void` — it runs
/// before contexts exist.  Interrupt task handlers take their own
/// context struct instead (see `resource.Ctx`), so the task table
/// references them by erased address.
pub const Handler = resource.Handler;

/// The required signature of the idle handler: `fn() noreturn`.
pub const IdleHandler = resource.IdleHandler;

/// The idle task as declared in the system definition: referenced
/// handler and resource list — no priority, since idle *is* logical
/// priority 0.
pub const IdleTask = resource.IdleTask;

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(ceiling);
    std.testing.refAllDecls(resource);
    std.testing.refAllDecls(text);
}
