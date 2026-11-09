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

/// Shorthand so an application root can annotate its system definition
/// `pub const config: rticz.ResourceConfig(context.idle)` — generic
/// over the idle context type because the runtime *calls* idle.
pub const ResourceConfig = resource.Config;

/// One task of a `ResourceConfig`, referencing its handler and its resource
/// storage by identity.
pub const ResourceTask = resource.Task;

/// The required signature of the init handler: `fn() void` — it runs
/// before contexts exist.  Interrupt task handlers take their own
/// context struct instead — a plain struct named after the task,
/// generated into src/generated/context.zig — so the task table
/// references them by erased address.
pub const Handler = resource.Handler;

/// What the idle task declares before its handler is attached: its
/// resource accesses — the handler-free input the context generator
/// emits `context.idle` from.
pub const IdleSpec = resource.IdleSpec;

/// The idle task as declared in the system definition: referenced
/// handler and resource list — no priority, since idle *is* logical
/// priority 0.  Generic over the idle context type: the glue calls
/// idle, so its reference stays typed (`*const fn (*IdleCtx) noreturn`).
pub const IdleTask = resource.IdleTask;

/// A claimed-for-the-moment resource proxy — the type of a context
/// field.  An app handler names it only through its context
/// (`ctx.res.claim(...)`); the shorthand is here so a signature or
/// helper can spell the type if it needs to.
pub const Claim = resource.Claim;

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(ceiling);
    std.testing.refAllDecls(resource);
    std.testing.refAllDecls(text);
}
