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
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // API Documentation
    const docs_step = b.step("docs", "Generate API documentation");
    const doc_path = "docs/api";

    const io = b.graph.io;

    // Zig's `-femit-docs=<path>` writes the leaf dir but does not create
    // intermediate parents, and git does not track empty directories, so a
    // fresh checkout may have no `docs/` at all. Create it portably here
    // (idempotent: makePath is a no-op when the directory already exists).
    const ensure_docs_dir = EnsureDirStep.create(b, "docs");
    const gen_docs_cmd = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe,
        "build-lib",
        "src/lib.zig",
        "-femit-docs=" ++ doc_path,
        "-fno-emit-bin",
    });
    gen_docs_cmd.step.dependOn(&ensure_docs_dir.step);
    docs_step.dependOn(&gen_docs_cmd.step);

    // Examples (only when developing minish itself, not when used as a dependency)
    if (b.build_root.handle.openDir(io, "examples", .{ .iterate = true })) |examples_dir| {
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
    } else |err| switch (err) {
        // Used as a library dependency: no examples directory at the import root.
        error.FileNotFound => {},
        // Surface other errors (permissions, IO) instead of swallowing them.
        else => @panic(@errorName(err)),
    }
}

/// Build step that ensures a directory (relative to the build root) exists.
/// Runs `std.fs.Dir.makePath` at make-time, so it only fires when a step
/// that depends on it is actually being built. Portable across Linux,
/// macOS, and Windows.
const EnsureDirStep = struct {
    step: std.Build.Step,
    sub_path: []const u8,

    fn create(b: *std.Build, sub_path: []const u8) *EnsureDirStep {
        const self = b.allocator.create(EnsureDirStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("ensure {s}/", .{sub_path}),
                .owner = b,
                .makeFn = make,
            }),
            .sub_path = sub_path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *EnsureDirStep = @fieldParentPtr("step", step);
        try step.owner.build_root.handle.createDirPath(step.owner.graph.io, self.sub_path);
    }
};
