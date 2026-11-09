//! Library root of the rticz package.
//!
//! `rticz.Config` is the application's system definition — the one
//! `pub const config` a root writes, its interrupt-task rows naming
//! handlers and referencing resource storage by address — alongside
//! the name-based (JSON) data model, which lives at `rticz.parser`,
//! the JSON parser, and the resource ceiling analysis.
//! (The *application* root — the file declaring `pub const config` and
//! implementing init/idle/tasks — lives in `src/root.zig` and is separate
//! from this library root on purpose.)

const std = @import("std");

pub const parser = @import("parser.zig");
pub const ceiling = @import("ceiling.zig");
pub const resource = @import("resource.zig");
pub const text = @import("text.zig");

/// The application's system definition: `pub const config:
/// rticz.Config(context.idle)` — generic over the idle context type
/// because the runtime *calls* idle.  Its `tasks` field holds
/// `TaskSpec` rows that *name* their handlers; init and idle are
/// references.
pub const Config = resource.Config;

/// The required signature of the init handler: `fn() void` — it runs
/// before contexts exist.  Interrupt task handlers take their own
/// context struct instead — a plain struct named after the task,
/// generated into src/generated/context.zig — which is why task rows
/// name them rather than referencing them.
pub const Handler = resource.Handler;

/// The idle task as declared in the system definition: referenced
/// handler and resource list — no priority, since idle *is* logical
/// priority 0.  Generic over the idle context type: the glue calls
/// idle, so its reference stays typed (`*const fn (*IdleCtx) noreturn`).
pub const IdleTask = resource.IdleTask;

/// A claimed-for-the-moment resource proxy — the type of a context
/// field: `Claim(name, T, ceiling)`, the resource's name and priority
/// ceiling baked into the type by the context generator (the ceiling
/// is the BASEPRI value the section will one day run behind; a trace
/// line until then).  An app
/// handler names it only through its context (`ctx.res.claim(...)`);
/// the shorthand is here so a signature or helper can spell the type
/// if it needs to.
pub const Claim = resource.Claim;

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(ceiling);
    std.testing.refAllDecls(resource);
    std.testing.refAllDecls(text);
}
