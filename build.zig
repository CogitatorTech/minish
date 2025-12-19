const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The target and optimize mode must be passed when creating the module.
    const minish_mod = b.addModule("minish", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const tests = b.addExecutable(.{
        .name = "minish-tests",
        .root_module = minish_mod,
    });
    tests.kind = .@"test";

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // API Documentation
    const docs_step = b.step("docs", "Generate API documentation");
    const doc_path = "docs/api";

    // Create docs directory if it doesn't exist
    std.fs.cwd().makePath("docs") catch {};

    const gen_docs_cmd = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe,
        "build-lib",
        "src/lib.zig",
        "-femit-docs=" ++ doc_path,
        "-fno-emit-bin",
    });
    docs_step.dependOn(&gen_docs_cmd.step);

    // Examples (only when developing minish itself, not when used as a dependency)
    if (std.fs.cwd().openDir("examples", .{ .iterate = true })) |examples_dir| {
        var dir = examples_dir;
        const run_all_step = b.step("run-all", "Run all examples");

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

            const stem = entry.name[0 .. entry.name.len - 4];
            const src_rel = b.fmt("examples/{s}", .{entry.name});

            const example_mod = b.addModule(stem, .{
                .root_source_file = b.path(src_rel),
                .target = target,
                .optimize = optimize,
            });

            const exe = b.addExecutable(.{
                .name = stem,
                .root_module = example_mod,
            });
            exe.root_module.addImport("minish", minish_mod);
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            const step_name = b.fmt("run-{s}", .{stem});
            const run_example_step = b.step(step_name, b.fmt("Run example {s}", .{stem}));
            run_example_step.dependOn(&run_cmd.step);

            run_all_step.dependOn(run_example_step);
        }
    } else |_| {
        // examples directory doesn't exist (e.g., when used as a library dependency)
    }
}
