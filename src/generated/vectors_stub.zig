//! The empty interrupt-vector module.
//!
//! Committed, never written to, and never shipped in a binary.  It is
//! what the *vector generator* (src/generated/extract.zig) compiles the app
//! against: reading the task list needs the handlers compiled, and
//! the handlers do not touch the vectors — only idle does, and idle
//! is deliberately left unanalyzed by the generator (it reads
//! `app.tasks`, not `app.config`).  The real binaries link against the
//! generated module at src/generated/irq.zig instead; see build.zig.
