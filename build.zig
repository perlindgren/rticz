//! rticz — the library build.
//!
//! This package *is* the library: the config data model, the claim
//! proxy, the ceiling analysis (src/, exported as the `rticz` module),
//! the code generator that reads an application's config as text
//! (codegen/), and the framework's entry points — glue and CLI —
//! which an application wires into its own build.
//!
//! What this build deliberately does not do: build any application.
//! An application is a package of its own that depends on rticz —
//! examples/beats is one, a real Zig package with its own build.zig
//! and build.zig.zon, path-dependent on this one.  Its build compiles
//! the generator from codegen/, runs it over the app's root.zig, and
//! wires the app, the generated contexts and vectors, and the glue
//! into an executable; that build file is the documentation of what
//! depending on rticz costs, because it is what any dependent would
//! write.
//!
//! The conveniences below keep the whole repository in one command:
//! `zig build` builds every example with the same toolchain (a nested
//! `zig build` per package), and `zig build test` runs the library's
//! tests plus each example's.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: config data model, JSON parser (for the CLI),
    // ceiling analysis in both runtime and comptime flavors, claim
    // proxies.  Declared as the module named "rticz" — what a
    // dependent's `b.dependency("rticz", ...).module("rticz")` hands
    // back.  A target is set because a test executable uses this
    // module as its root.
    const mod = b.addModule("rticz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize, // what a dependent's b.dependency(..., .{ .optimize = ... }) resolves to
    });

    // The library's own tests: parser, ceiling analysis, resource
    // declarations, bounded strings.  The tests that need an
    // application — the dispatch tables cross-checked against the
    // generated binding table — belong to the pairing and run in the
    // example package that supplies the app.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Every example is its own package.  The library build does not
    // import them — it shells out to the same zig with each folder as
    // the working directory — so the dependency graph stays exactly
    // what an outside application's would be: example → rticz, never
    // the other way.
    const examples = [_][]const u8{
        "examples/beats",
    };

    const examples_step = b.step("examples", "Build every example (each is its own package)");
    const test_step = b.step("test", "Run library tests, and every example's tests");
    for (examples) |dir| {
        const cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
        cmd.setCwd(b.path(dir));
        examples_step.dependOn(&cmd.step);

        const test_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
        test_cmd.setCwd(b.path(dir));
        test_cmd.stdio = .inherit;
        test_step.dependOn(&test_cmd.step);
    }

    // The default step builds the world: nothing here *installs* (a
    // library installs no artifacts), so without this `zig build`
    // would be a no-op.
    b.getInstallStep().dependOn(examples_step);

    test_step.dependOn(&run_mod_tests.step);
}
