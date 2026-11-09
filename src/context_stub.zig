//! The empty task-context module.
//!
//! Committed, never written to, and never shipped in a binary.  It
//! is what the *context generator* (src/gen_context.zig) compiles
//! the app against: the generator reads the handler-free task
//! declarations (`app.task_specs`), and that read forces no handler
//! analysis — so no handler's signature, which names a context of
//! this module, is ever resolved against the stub.  The real
//! binaries compile against the generated module at
//! src/generated/context.zig instead; see build.zig.
