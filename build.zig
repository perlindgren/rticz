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
    // (src/gen_context.zig, src/extract.zig).
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
    //     interrupt, named after it (`context.TIMER0`).  A handler's
    //     signature names its context, so no handler can compile
    //     before the contexts exist: the context generator must read
    //     a handler-free view of the app — `pub const task_specs`
    //     (interrupt lines, priorities, named resource accesses; no
    //     function references in it, so reading it forces no handler
    //     analysis).  `src/gen_context.zig` emits the structs, typed
    //     `*@TypeOf(app.res_x)` over the application's own resource
    //     declarations.
    //   * `irq.zig` — one trampoline per interrupt (`pub fn TIMER0()
    //     void { app.t0(.{ .res_a = &app.res_a }); }`); on hardware
    //     these names are the symbols the linker drops into the
    //     vector table.  `src/extract.zig` emits them from
    //     `pub const tasks` — reading that list materializes the
    //     handlers, which is fine now: the contexts exist by then,
    //     and the trampoline's context literal is checked against
    //     the handler's signature.
    //
    // The two loops — generators need a compiled app, the app needs
    // their output — are broken by handing each compilation its own
    // `context`/`vectors` modules:
    //
    //   * the context generator's copy of the app is wired against
    //     both committed stubs (src/context_stub.zig,
    //     src/vectors_stub.zig): nothing in the handler-free pass
    //     resolves a name against either;
    //   * the vector generator's copy gets the freshly generated
    //     contexts and the stub vectors — its pass analyzes the
    //     handlers, whose bodies are vector-free; their comptime
    //     self-lookup goes through the hoisted task list precisely so
    //     it needs nothing from the stub;
    //   * the real binaries link both generated files.
    //
    // Two consequences of writing into a plain source path rather
    // than a declared build-graph output: the steps that consume the
    // files are ordered after their producers by hand, and neither
    // generator declares outputs, so both re-run on every build —
    // delete src/generated/ and `zig build` puts it right back.
    //
    // The app↔context and app↔vectors module cycles are legal to the
    // compiler: two views of one program.
    // ------------------------------------------------------------------

    // The context generator's view of the app: root with both stubs.
    const app_for_ctxgen = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "rticz", .module = mod },
            .{ .name = "context", .module = b.createModule(.{
                .root_source_file = b.path("src/context_stub.zig"),
                .target = target,
            }) },
            .{ .name = "vectors", .module = b.createModule(.{
                .root_source_file = b.path("src/vectors_stub.zig"),
                .target = target,
            }) },
        },
        // The host-simulation idle loop sleeps via libc's nanosleep.
        .link_libc = true,
    });

    const gen_context_exe = b.addExecutable(.{
        .name = "gen_context",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_context.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "app", .module = app_for_ctxgen },
                .{ .name = "rticz", .module = mod },
            },
        }),
    });
    // The contexts are written into the tree.  A run step's working
    // directory is the build root, so the path is relative to that;
    // with no declared output the step re-runs on every build, which
    // is what makes the visible file self-healing.
    const gen_context = b.addRunArtifact(gen_context_exe);
    gen_context.setName("gen-context");
    gen_context.addArg("src/generated/context.zig");

    // The vector generator's view of the app: stub vectors, real
    // contexts — which import "app" themselves (the handler-free pass
    // above has written them by now, ordered below), so the pair is
    // created first and tied together after.
    const app_for_extract = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "rticz", .module = mod },
            .{ .name = "vectors", .module = b.createModule(.{
                .root_source_file = b.path("src/vectors_stub.zig"),
                .target = target,
            }) },
        },
        // The host-simulation idle loop sleeps via libc's nanosleep.
        .link_libc = true,
    });
    const contexts_for_extract = b.createModule(.{
        .root_source_file = b.path("src/generated/context.zig"),
        .target = target,
    });
    contexts_for_extract.addImport("app", app_for_extract);
    app_for_extract.addImport("context", contexts_for_extract);

    const extract = b.addExecutable(.{
        .name = "extract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extract.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "app", .module = app_for_extract },
                .{ .name = "rticz", .module = mod },
            },
        }),
    });
    // Compiling extract compiles its copy of the app, which imports
    // the generated contexts: wait for the context generator first.
    extract.step.dependOn(&gen_context.step);
    // The vectors are written into the tree, same mechanics as the
    // contexts: relative path, no declared outputs, self-healing.
    const gen_vectors = b.addRunArtifact(extract);
    gen_vectors.setName("gen-vectors");
    gen_vectors.addArg("src/generated/irq.zig");

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
    contexts_mod.addImport("app", app_mod);
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
    exe.step.dependOn(&gen_vectors.step);
    cli.step.dependOn(&gen_vectors.step);

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
    exe_tests.step.dependOn(&gen_vectors.step);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
