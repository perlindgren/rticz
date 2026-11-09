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
    // errors pointing at the offending source line, and there is no
    // generated file that could drift from the config. No JSON is parsed
    // anywhere in the compiled binary; build.zig only wires modules.
    // ------------------------------------------------------------------

    // The library: config data model, JSON parser (for the CLI), ceiling
    // analysis in both runtime and comptime flavors.
    const mod = b.addModule("rticz", .{
        .root_source_file = b.path("src/lib.zig"),
        // Later on we'll use this module as the root module of a test
        // executable which requires us to specify a target.
        .target = target,
    });

    // The application root: `pub const config` plus init, idle, and the
    // task handlers — the hand-written half.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "rticz", .module = mod }},
        // The host-simulation idle loop sleeps via libc's nanosleep.
        .link_libc = true,
    });

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

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
