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
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests and property test examples");
    test_step.dependOn(&run_tests.step);

    // API Documentation
    const docs_step = b.step("docs", "Generate API documentation");
    const docs_lib = b.addLibrary(.{
        .name = "minish",
        .root_module = minish_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = b.root.joinString(b.allocator, "docs") catch @panic("OOM") },
        .install_subdir = "api",
    });
    docs_step.dependOn(&install_docs.step);

    const io = b.graph.io;

    // Examples (only when developing minish itself, not when used as a dependency)
    b.dependOnDirectoryContents(b.path(""));
    if (b.root.openDir(io, "examples", .{ .iterate = true })) |examples_dir| {
        b.dependOnDirectoryContents(b.path("examples"));
        var dir = examples_dir;
        defer dir.close(io);
        const run_all_step = b.step("run-all", "Run all examples");

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

            const stem = entry.name[0 .. entry.name.len - 4];
            const src_rel = b.fmt("examples/{s}", .{entry.name});

            const example_mod = b.addModule(stem, .{
                .root_source_file = b.path(src_rel),
                .target = target,
                .optimize = optimize,
            });
            example_mod.addImport("minish", minish_mod);

            const run_cmd = if (std.mem.endsWith(u8, entry.name, "_test.zig")) blk: {
                const example_tests = b.addTest(.{ .root_module = example_mod });
                const run_example_tests = b.addRunArtifact(example_tests);
                test_step.dependOn(&run_example_tests.step);
                break :blk run_example_tests;
            } else blk: {
                const exe = b.addExecutable(.{
                    .name = stem,
                    .root_module = example_mod,
                });
                b.installArtifact(exe);
                break :blk b.addRunArtifact(exe);
            };

            const step_name = b.fmt("run-{s}", .{stem});
            const run_example_step = b.step(step_name, b.fmt("Run example {s}", .{stem}));
            run_example_step.dependOn(&run_cmd.step);

            run_all_step.dependOn(run_example_step);
        }
    } else |err| switch (err) {
        // Used as a library dependency: no examples directory at the import root.
        error.FileNotFound => {},
        // Surface other errors (permissions, IO) instead of swallowing them.
        else => @panic(@errorName(err)),
    }
}
