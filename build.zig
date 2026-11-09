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
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("rticz", .{
        // Library root (parser + ceiling analysis). The *application* root —
        // the file implementing init/idle/tasks — is src/root.zig, wired in
        // below as the "app" module.
        .root_source_file = b.path("src/lib.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // ------------------------------------------------------------------
    // Build-time task configuration analysis.
    //
    // The configuration JSON is parsed, validated, and analyzed (resource
    // priority ceilings) right here at build time by a codegen program that
    // reuses the exact same parser and analysis modules that ship in the
    // library. The results are emitted as a generated Zig module of comptime
    // constants which is baked into the executable, so the shipped binary
    // needs no JSON parsing at runtime. Invalid configurations fail the build.
    // ------------------------------------------------------------------

    // Which configuration to analyze; override with `-Dconfig=path.json`.
    const cfg_path = b.option(
        []const u8,
        "config",
        "task configuration JSON analyzed at build time (default: rticz.json)",
    ) orelse "rticz.json";

    // Host-target copy of the library so the codegen program can import it.
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = b.graph.host,
    });

    const codegen = b.addExecutable(.{
        .name = "analysis-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/analyze_codegen.zig"),
            .target = b.graph.host, // must run on the build machine
            .imports = &.{.{ .name = "rticz", .module = host_mod }},
        }),
    });

    // Run the codegen. The outputs are materialized into the source tree
    // (src/generated/) so the generated sources can be read, reviewed, and
    // versioned like any other file. Run-step children execute with the
    // package root as their working directory, so these paths are relative
    // to build.zig. `addFileArg` records the config as a tracked input, so
    // editing the JSON re-runs the analysis, and a non-zero exit (invalid
    // config) fails the whole build. The step re-runs on every `zig build`,
    // but writing byte-identical content keeps all downstream caches warm.
    const generated_dir = "src/generated";
    const gen_run = b.addRunArtifact(codegen);
    gen_run.addFileArg(b.graph.cwdRelativePath(cfg_path));
    gen_run.addArgs(&.{
        b.pathJoin(&.{ generated_dir, "analysis.zig" }),
        b.pathJoin(&.{ generated_dir, "rtic_glue.zig" }),
    });

    // The generated files, as ordinary source files in the tree.
    const analysis_src = b.path(b.pathJoin(&.{ generated_dir, "analysis.zig" }));
    const glue_src = b.path(b.pathJoin(&.{ generated_dir, "rtic_glue.zig" }));

    // The generated analysis as a module importable by the app and the glue.
    const analysis_mod = b.createModule(.{
        .root_source_file = analysis_src,
        .target = target,
        .imports = &.{.{ .name = "rticz", .module = mod }},
    });

    // The application root: the hand-written half (init, idle, task handlers).
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "analysis", .module = analysis_mod }},
        // The host-simulation idle loop sleeps via libc's nanosleep.
        .link_libc = true,
    });

    // The main executable: the generated RTIC glue (whose `main` calls
    // app.init() and then app.idle(), which never returns) as the root module,
    // with the application root imported as "app".
    const glue_module = b.createModule(.{
        .root_source_file = glue_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app", .module = app_mod },
            .{ .name = "analysis", .module = analysis_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "rticz",
        .root_module = glue_module,
    });
    // The generated sources must exist before anything that imports them is
    // compiled. In-tree outputs are plain files to the build graph, so the
    // ordering is stated explicitly instead of inferred from cache plumbing.
    exe.step.dependOn(&gen_run.step);

    // A companion CLI that can (re)analyze any configuration file at runtime,
    // and print the analysis baked into the build when given no arguments.
    const cli = b.addExecutable(.{
        .name = "rticz-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rticz", .module = mod },
                .{ .name = "analysis", .module = analysis_mod },
            },
        }),
    });
    cli.step.dependOn(&gen_run.step);

    // Both executables are installed into the install prefix (zig-out/).
    b.installArtifact(exe);
    b.installArtifact(cli);

    // `zig build run` boots the generated program. Note: idle never returns,
    // so this runs until you Ctrl-C it.
    const run_step = b.step("run", "Run the generated app (init, then idle forever)");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // `zig build analyze` prints the analysis that was computed at build time.
    const analyze_step = b.step("analyze", "Print the build-time task/resource ceiling analysis");
    const analyze_cmd = b.addRunArtifact(cli);
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
    exe_tests.step.dependOn(&gen_run.step);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
