//! The beats example's build — a complete application build, and the
//! reference for what using rticz as a library costs: nothing but
//! module wiring.
//!
//! The rticz package (one directory up, a path dependency declared in
//! build.zig.zon) ships three things an application needs, and this
//! file consumes all three *through the dependency*, never by reaching
//! into the rticz tree:
//!
//!   * `rticz.module("rticz")` — the library: the config data model,
//!     the claim proxy, the ceiling analysis;
//!   * `rticz.path("codegen/generate.zig")` — the code generator,
//!     compiled here against the library module and run over this
//!     package's root.zig;
//!   * `rticz.path("src/glue.zig")` and `rticz.path("src/cli.zig")` —
//!     the framework's entry points, which name their modules
//!     "app", "context" and "vectors" by convention; the edges are
//!     wired here, because those names belong to *this* program.
//!
//! ------------------------------------------------------------------
//! Where did the build-time analysis step go?
//!
//! The task/resource configuration is `pub const config` in the
//! application root (root.zig) — a plain Zig constant living with the
//! code. The ceiling analysis, the config validation, and the dispatch
//! table are computed *at comptime* by the compiler itself (see
//! rticz.ceiling.computeAtComptime and rticz's src/glue.zig), which is
//! strictly stronger than a codegen tool: invalid configurations are
//! compile errors pointing at the offending source line. No JSON is
//! parsed anywhere in the compiled binary.
//!
//! The things the compiler genuinely cannot emit are the RTIC context
//! structs — a handler's signature must name them, so they must exist
//! as a module of their own before handlers compile — and the
//! interrupt vector table: on real hardware a task is reached through
//! a function whose *name* is the vector's name, and Zig has no hook
//! to place symbols in a vector table. Both artifacts are generated
//! into this package's generated/ folder (git-ignored, but in the tree
//! for anyone to read, rewritten on every build):
//!
//!   * `storage.zig` — one `pub var` per resource, emitted from the
//!     declarations in `config.resources`.  This module is wired to
//!     the generated modules only — never to the app — so the
//!     application cannot import it, and the resource instances are
//!     out of its reach by module graph, not by convention.
//!   * `context.zig` — RTIC's per-task context structs, one per task,
//!     named after it (`context.t0`, RTIC's `Context<T0>`), plus
//!     `context.idle` and the `makeIdleCtx` constructor the glue uses
//!     to enter idle.
//!   * `irq.zig` — one trampoline per interrupt, and with it the
//!     handler-binding table (`pub const tasks`) the runtime reads.
//!
//! The chicken-and-egg — the generator needs the app's config, the app
//! imports the files it writes — is broken by *not compiling the app
//! to read it*: generate.zig reads the single `pub const config`
//! literal with `std.zig.Ast`, the very parser the compiler uses, so
//! the config may reference handlers and spell resource declarations
//! freely — to a reader of text, a reference is a name, and every name
//! is checked against the declarations of the same file (a task row
//! must name a `pub fn`, a resource access must name a declared
//! resource; a missing name is the generator's error, before anything
//! is written).  Real
//! RTIC works exactly this way: its `#[app]` macro reads token
//! streams, not compiled code.
//!
//! The application is then compiled exactly once, against the real
//! generated files — the emitted trampoline's context literal and the
//! handler's signature are where the declaration finally meets its
//! types.
//!
//! The consequence of writing into plain source paths rather than
//! declared build-graph outputs: the steps that consume the files are
//! ordered after the generator by hand, and with no declared outputs
//! it re-runs on every build — delete generated/ and `zig build` puts
//! it right back.
//!
//! The app↔context and app↔vectors module cycles are legal to the
//! compiler: two views of one program.
//! ------------------------------------------------------------------

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The rticz package, built with this package's settings and handed
    // over as modules and paths.  A path dependency resolves the same
    // machinery a URL dependency would: this file would not change if
    // rticz were fetched from a registry.
    const rticz = b.dependency("rticz", .{ .target = target, .optimize = optimize });
    const rticz_mod = rticz.module("rticz");

    // The generator is just another program that uses the library —
    // compiled here, from the dependency's source, against the
    // dependency's module.
    const generate_exe = b.addExecutable(.{
        .name = "rticz-generate",
        .root_module = b.createModule(.{
            .root_source_file = rticz.path("codegen/generate.zig"),
            .target = target,
            .imports = &.{.{ .name = "rticz", .module = rticz_mod }},
        }),
    });
    // A run step's working directory is this package's root, and all
    // three files are written into the tree relative to it.
    const gen_code = b.addRunArtifact(generate_exe);
    gen_code.setName("gen-code");
    gen_code.addArg("root.zig");
    gen_code.addArg("generated/storage.zig");
    gen_code.addArg("generated/context.zig");
    gen_code.addArg("generated/irq.zig");

    // The application root plus the three generated modules.  The
    // storage module imports "app" to reach the application's types;
    // the contexts and vectors import "storage" to reach the
    // instances.  The application imports "context" and "vectors" —
    // but *not* "storage": that edge does not exist, and it is the
    // wall.  Module cycles (app→vectors→context→storage→app) are
    // legal to the compiler: several views of one program.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .imports = &.{.{ .name = "rticz", .module = rticz_mod }},
        .link_libc = true, // idle's sleep stands in for a WFI with libc's nanosleep
    });
    const storage_mod = b.createModule(.{
        .root_source_file = b.path("generated/storage.zig"),
        .target = target,
    });
    const vectors_mod = b.createModule(.{
        .root_source_file = b.path("generated/irq.zig"),
        .target = target,
    });
    const contexts_mod = b.createModule(.{
        .root_source_file = b.path("generated/context.zig"),
        .target = target,
    });
    storage_mod.addImport("app", app_mod); // types and initializers name the app
    vectors_mod.addImport("app", app_mod);
    vectors_mod.addImport("context", contexts_mod); // trampolines name their context type
    vectors_mod.addImport("rticz", rticz_mod); // the generated binding table's rows are `rticz.resource.Task`
    vectors_mod.addImport("storage", storage_mod); // trampolines fill proxies with instance addresses
    contexts_mod.addImport("storage", storage_mod); // @TypeOf over the instances
    contexts_mod.addImport("rticz", rticz_mod); // its fields are `Claim` proxies carrying name + ceiling
    app_mod.addImport("vectors", vectors_mod);
    app_mod.addImport("context", contexts_mod);

    // The main executable: the rticz glue (framework half, from the
    // dependency) as the root module — its `main` calls app.init() and
    // then app.idle(), which never returns — with this package's root
    // imported as "app", the generated `context` (idle is entered
    // through the generated `makeIdleCtx`), and `vectors` for the
    // glue's tests to cross-check against.
    const glue_module = b.createModule(.{
        .root_source_file = rticz.path("src/glue.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
            .{ .name = "rticz", .module = rticz_mod },
            .{ .name = "context", .module = contexts_mod },
            .{ .name = "vectors", .module = vectors_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "beats",
        .root_module = glue_module,
    });

    // The companion CLI: prints the compile-time analysis of *this*
    // app's compiled-in config, and can additionally analyze any
    // rticz.json-formatted file at runtime.  It is glue over the same
    // tables, so it is wired like the executable.
    const cli = b.addExecutable(.{
        .name = "beats-cli",
        .root_module = b.createModule(.{
            .root_source_file = rticz.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rticz", .module = rticz_mod },
                .{ .name = "glue", .module = glue_module },
            },
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);
    b.installArtifact(cli);

    // generated/ holds plain source paths, not declared outputs, so
    // every step that compiles the app must wait for the generator by
    // hand.
    exe.step.dependOn(&gen_code.step);
    cli.step.dependOn(&gen_code.step);

    // `zig build run` boots the program. Note: idle never returns,
    // so this runs until you Ctrl-C it.
    const run_step = b.step("run", "Run the app (init, then idle forever)");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // `zig build analyze` prints the compile-time analysis of the
    // compiled-in config; pass `-Dconfig=file.json` to have it analyze an
    // rticz.json file at runtime instead.
    const cfg_path = b.option(
        []const u8,
        "config",
        "for `zig build analyze`: analyze this rticz.json file instead of the compiled-in config",
    );
    const analyze_step = b.step("analyze", "Print the task/resource ceiling analysis");
    const analyze_cmd = b.addRunArtifact(cli);
    if (cfg_path) |path| analyze_cmd.addFileArg(b.graph.cwdRelativePath(path));
    analyze_cmd.step.dependOn(b.getInstallStep());
    analyze_cmd.stdio = .inherit;
    analyze_step.dependOn(&analyze_cmd.step);

    // The framework's own tests, instantiated against this app: the
    // dispatch tables, the reference resolution, the ceilings derived
    // from this config, the cross-check against the generated binding
    // table.  The library's unit tests live with the library (run them
    // from the rticz package root); these belong to the pairing.
    const exe_tests = b.addTest(.{
        .root_module = glue_module,
    });
    exe_tests.step.dependOn(&gen_code.step);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run the app-vs-framework tests");
    test_step.dependOn(&run_exe_tests.step);
}
