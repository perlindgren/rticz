const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between debug, safe, fast, and small. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // Where did the build-time analysis step go?
    //
    // The task/resource configuration is now `pub const config` in the
    // application root (src/root.zig) — a plain Zig constant living with the
    // code. The ceiling analysis, the config validation, and the dispatch
    // table are computed *at comptime* by the compiler itself (see
    // rticz.ceiling.computeAtComptime and src/glue.zig), which is strictly
    // stronger than a codegen tool: invalid configurations are compile
    // errors pointing at the offending source line. No JSON is parsed
    // anywhere in the compiled binary.
    //
    // The things the compiler genuinely cannot emit are the RTIC
    // context structs — a handler's signature must name them, so they
    // must exist as a module of their own before handlers compile —
    // and the interrupt vector table: on real hardware a task is
    // reached through a function whose *name* is the vector's name,
    // and Zig has no hook to place symbols in a vector table.  Both
    // artifacts are generated — see the codegen section below
    // (codegen/generate.zig).
    // ------------------------------------------------------------------

    // The library: config data model, JSON parser (for the CLI), ceiling
    // analysis in both runtime and comptime flavors.
    const mod = b.addModule("rticz", .{
        .root_source_file = b.path("src/lib.zig"),
        // Later on we'll use this module as the root module of a test
        // executable which requires us to specify a target.
        .target = target,
    });

    // ------------------------------------------------------------------
    // Codegen — the contexts and the interrupt vectors.
    //
    // Two things are beyond what Zig itself will derive from the app,
    // and both are generated into src/generated/ (git-ignored, but in
    // the tree for anyone to read, rewritten on every build):
    //
    //   * `context.zig` — RTIC's per-task context structs, one per
    //     task, named after it (`context.t0`, RTIC's `Context<T0>`),
    //     plus `context.idle` and the `makeIdleCtx` constructor the
    //     glue uses to enter idle.  A handler's signature names its
    //     context, so the contexts must exist before handlers
    //     compile.
    //   * `irq.zig` — one trampoline per interrupt (`pub fn TIMER0()
    //     void { var ctx: context.t0 = .{ .res_a = .{ .ptr = &app.res_a } };
    //     app.t0(&ctx); }`); on hardware these names are the symbols
    //     the linker drops into the vector table, and with them the
    //     handler-binding table (`pub const tasks`) the runtime reads.
    //
    // The chicken-and-egg — the generators need the app's config, the
    // app imports the files they write — is broken by *not compiling
    // the app to read it*: `codegen/generate.zig` reads the single
    // `pub const config` literal with `std.zig.Ast`, the very parser
    // the compiler uses, so the config may reference handlers and
    // resource addresses freely — to a reader of text, a reference is
    // a name, and every name is checked against the declarations of
    // the same file (a task row must name a `pub fn`, a resource
    // access a declared variable; a missing name is the generator's
    // error, before anything is written).  Real RTIC works exactly
    // this way: its `#[app]` macro reads token streams, not compiled
    // code.
    //
    // The application is then compiled exactly once, against the real
    // generated files — the emitted trampoline's context literal and
    // the handler's signature are where the declaration finally meets
    // its types.  (An earlier design compiled the app twice against
    // stub `context`/`vectors` modules so the generators could read
    // `app.config` semantically; it worked only while the config held
    // no function references — and a reference is what makes the
    // config the whole system definition.  Text rendering retired the
    // stubs and the passes with it.)
    //
    // The consequence of writing into plain source paths rather than
    // declared build-graph outputs: the steps that consume the files
    // are ordered after the generator by hand, and with no declared
    // outputs it re-runs on every build — delete src/generated/ and
    // `zig build` puts it right back.
    //
    // The app↔context and app↔vectors module cycles are legal to the
    // compiler: two views of one program.
    // ------------------------------------------------------------------

    const generate_exe = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/generate.zig"),
            .target = target,
            .imports = &.{.{ .name = "rticz", .module = mod }},
        }),
    });
    // Both files are written into the tree; a run step's working
    // directory is the build root, so the paths are relative to that.
    const gen_code = b.addRunArtifact(generate_exe);
    gen_code.setName("gen-code");
    gen_code.addArg("src/root.zig");
    gen_code.addArg("src/generated/context.zig");
    gen_code.addArg("src/generated/irq.zig");

    // The shipped view: the application root plus both real modules —
    // each of which imports "app" to reach the declarations it names,
    // module cycles, so the pairs are created first and tied together
    // after.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "rticz", .module = mod }},
        .link_libc = true,
    });
    const vectors_mod = b.createModule(.{
        .root_source_file = b.path("src/generated/irq.zig"),
        .target = target,
    });
    const contexts_mod = b.createModule(.{
        .root_source_file = b.path("src/generated/context.zig"),
        .target = target,
    });
    vectors_mod.addImport("app", app_mod);
    vectors_mod.addImport("context", contexts_mod); // trampolines name their context type
    vectors_mod.addImport("rticz", mod); // the generated binding table's rows are `rticz.resource.Task`
    contexts_mod.addImport("app", app_mod);
    contexts_mod.addImport("rticz", mod); // its fields are `Claim` proxies carrying name + ceiling
    app_mod.addImport("vectors", vectors_mod);
    app_mod.addImport("context", contexts_mod);

    // The main executable: the RTIC-style glue (framework half) as the root
    // module — its `main` calls app.init() and then app.idle(), which never
    // returns — with the application root imported as "app".
    const glue_module = b.createModule(.{
        .root_source_file = b.path("src/glue.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
            .{ .name = "rticz", .module = mod },
            // The glue enters idle through the generated `makeIdleCtx`:
            // even the runtime's one context literal is generated, from
            // the same idle row of the config the struct was emitted from.
            .{ .name = "context", .module = contexts_mod },
            // The glue's tests cross-check its dispatch table against
            // the generated binding table — an @import only analyzed
            // when read, but read it is.
            .{ .name = "vectors", .module = vectors_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "rticz",
        .root_module = glue_module,
    });

    // A companion CLI that prints the compile-time analysis of the
    // compiled-in config, and can additionally (re)analyze any rticz.json
    // file at runtime. It imports the app root, which uses libc's nanosleep
    // for its idle loop, so the CLI links libc as well.
    const cli = b.addExecutable(.{
        .name = "rticz-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rticz", .module = mod },
                .{ .name = "glue", .module = glue_module },
            },
            .link_libc = true,
        }),
    });

    // Both executables are installed into the install prefix (zig-out/).
    b.installArtifact(exe);
    b.installArtifact(cli);

    // src/generated/irq.zig is a plain source path, not a declared
    // output, so the build graph does not know the generator produces
    // it: every step that compiles the app (or the glue/test module
    // that imports it) must wait for the generator by hand.
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
    // rticz.json-formatted file at runtime instead.
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

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    // Glue tests import the app, which imports the generated vectors.
    exe_tests.step.dependOn(&gen_code.step);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
