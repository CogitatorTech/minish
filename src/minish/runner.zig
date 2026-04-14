//! Property test runner.
//!
//! The runner executes property tests by:
//! 1. Generating random values using a generator
//! 2. Running the property function on each value
//! 3. If a failure is found, shrinking to find a minimal counterexample
//! 4. Reporting results with reproducible seeds

const std = @import("std");
const core = @import("core.zig");
const gen = @import("gen.zig");
const shrink_mod = @import("shrink.zig");

const Allocator = std.mem.Allocator;
const TestCase = core.TestCase;

/// Configuration options for property tests.
pub const Options = struct {
    /// Number of test runs to execute.
    num_runs: u32 = 100,
    /// Optional seed for reproducibility. If null, derives one from ASLR entropy.
    seed: ?u64 = null,
    /// Maximum number of shrink attempts before stopping.
    max_shrink_attempts: u32 = 1000,
    /// Whether to print verbose output during testing.
    verbose: bool = false,
};

/// Run the tests with the given generator and property function.
///
/// Execution details:
/// - Runs the test `options.num_runs` times (default 100).
/// - If `test_fn` returns an error (property failure), shrinking begins.
/// - Shrinking attempts to find a minimal input that still causes failure.
///
/// Memory management:
/// - The generated `value` passed to `test_fn` is owned by the test runner.
/// - The runner will strictly `defer` freeing the value after `test_fn` returns.
/// - **Do not** free/deinit the value inside `test_fn` unless you have cloned it.
/// - If `test_fn` mutates the value destructively (e.g. `deinit`), use a clone.
pub fn check(
    allocator: Allocator,
    generator: anytype,
    test_fn: anytype,
    options: Options,
) !void {
    // Handle seed: use provided seed or derive one from a stack address.
    // ASLR ensures the stack address differs between runs, providing non-determinism.
    const seed = options.seed orelse blk: {
        var anchor: u8 = 0;
        const addr = @intFromPtr(&anchor);
        break :blk @as(u64, @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&addr))));
    };
    var prng = std.Random.DefaultPrng.init(seed);

    if (options.verbose) {
        std.debug.print("Running property tests with seed: {d}\n", .{seed});
    }

    var i: u32 = 0;
    while (i < options.num_runs) : (i += 1) {
        var tc = TestCase.init(allocator, prng.random().int(u64));
        defer tc.deinit();

        const value = generator.generateFn(&tc) catch |err| {
            std.debug.print("Generator failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer if (generator.freeFn) |freeFn| {
            freeFn(allocator, value);
        };

        test_fn(value) catch |err| {
            std.debug.print(
                \\
                \\================================================================================
                \\PROPERTY FAILED
                \\--------------------------------------------------------------------------------
                \\Run:            {d}/{d}
                \\Error:          {s}
                \\Seed:           {d}
                \\Failing input:  {any}
                \\--------------------------------------------------------------------------------
                \\To reproduce: .{{ .seed = {d} }}
                \\================================================================================
                \\
            , .{ i + 1, options.num_runs, @errorName(err), seed, value, seed });

            if (generator.shrinkFn) |shrinker| {
                std.debug.print("Shrinking", .{});
                var minimal_value = value;
                var minimal_is_original = true;
                var shrink_attempts: u32 = 0;
                var it = shrinker(allocator, minimal_value);
                defer it.deinit();

                while (it.next()) |next_val| {
                    shrink_attempts += 1;

                    // Limit shrink attempts
                    if (shrink_attempts >= options.max_shrink_attempts) {
                        std.debug.print("\nMax shrink attempts ({d}) reached.\n", .{options.max_shrink_attempts});
                        break;
                    }

                    // Progress indicator
                    if (shrink_attempts % 50 == 0) {
                        std.debug.print(".", .{});
                    }

                    if (test_fn(next_val)) |_| {
                        if (generator.freeFn) |freeFn| {
                            freeFn(allocator, next_val);
                        }
                    } else |_| {
                        if (!minimal_is_original) {
                            if (generator.freeFn) |freeFn| {
                                freeFn(allocator, minimal_value);
                            }
                        }
                        minimal_value = next_val;
                        minimal_is_original = false;
                        it.deinit();
                        it = shrinker(allocator, minimal_value);
                    }
                }
                std.debug.print("\nMinimal failing input: {any}\n", .{minimal_value});
                std.debug.print("Shrink attempts: {d}\n", .{shrink_attempts});

                if (!minimal_is_original) {
                    if (generator.freeFn) |freeFn| {
                        freeFn(allocator, minimal_value);
                    }
                }
            }
            return err;
        };
    }
    std.debug.print("OK. {d} tests passed.\n", .{options.num_runs});
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "runner: zero runs completes immediately" {
    const allocator = testing.allocator;
    const int_gen = gen.int(i32);

    const alwaysFail = struct {
        fn prop(_: i32) !void {
            return error.ShouldNotRun;
        }
    }.prop;

    // With num_runs = 0, the property should never be called
    try check(allocator, int_gen, alwaysFail, .{
        .num_runs = 0,
        .seed = 12345,
    });
}

test "runner: passing property completes successfully" {
    const allocator = testing.allocator;
    const int_gen = gen.intRange(i32, 0, 100);

    const alwaysPass = struct {
        fn prop(x: i32) !void {
            // This always passes
            try testing.expect(x >= 0);
        }
    }.prop;

    try check(allocator, int_gen, alwaysPass, .{
        .num_runs = 10,
        .seed = 12345,
    });
}

test "runner: failing property returns error" {
    const allocator = testing.allocator;
    const int_gen = gen.intRange(i32, 10, 100);

    const alwaysFail = struct {
        fn prop(_: i32) !void {
            return error.PropertyFailed;
        }
    }.prop;

    const result = check(allocator, int_gen, alwaysFail, .{
        .num_runs = 10,
        .seed = 12345,
    });

    try testing.expectError(error.PropertyFailed, result);
}

test "runner: generator error propagates" {
    const allocator = testing.allocator;

    // Create a generator that always fails
    const FailingGenerator = struct {
        fn generate(_: *TestCase) core.GenError!i32 {
            return error.InvalidChoice;
        }
    };

    const failing_gen = gen.Generator(i32){
        .generateFn = FailingGenerator.generate,
        .shrinkFn = null,
        .freeFn = null,
    };

    const anyProp = struct {
        fn prop(_: i32) !void {}
    }.prop;

    const result = check(allocator, failing_gen, anyProp, .{
        .num_runs = 10,
        .seed = 12345,
    });

    try testing.expectError(core.GenError.InvalidChoice, result);
}

test "runner: seed produces reproducible results" {
    const allocator = testing.allocator;
    const int_gen = gen.int(i32);

    var values1 = std.ArrayList(i32).empty;
    defer values1.deinit(allocator);
    var values2 = std.ArrayList(i32).empty;
    defer values2.deinit(allocator);

    const collectValues1 = struct {
        var list: *std.ArrayList(i32) = undefined;
        var alloc: std.mem.Allocator = undefined;
        fn prop(x: i32) !void {
            try list.append(alloc, x);
        }
    };
    collectValues1.list = &values1;
    collectValues1.alloc = allocator;

    const collectValues2 = struct {
        var list: *std.ArrayList(i32) = undefined;
        var alloc: std.mem.Allocator = undefined;
        fn prop(x: i32) !void {
            try list.append(alloc, x);
        }
    };
    collectValues2.list = &values2;
    collectValues2.alloc = allocator;

    // Run with same seed twice
    try check(allocator, int_gen, collectValues1.prop, .{ .num_runs = 5, .seed = 99999 });
    try check(allocator, int_gen, collectValues2.prop, .{ .num_runs = 5, .seed = 99999 });

    // Should produce identical sequences
    try testing.expectEqualSlices(i32, values1.items, values2.items);
}

test "runner: memory management with allocated values" {
    const allocator = testing.allocator;
    const str_gen = gen.string(.{ .min_len = 1, .max_len = 10 });

    const checkString = struct {
        fn prop(s: []const u8) !void {
            // Just verify the string is valid
            try testing.expect(s.len >= 1 and s.len <= 10);
        }
    }.prop;

    // If memory isn't properly managed, this will leak and test allocator will catch it
    try check(allocator, str_gen, checkString, .{
        .num_runs = 20,
        .seed = 12345,
    });
}

test "regression: signed integer generation covers full range (std.meta.Int)" {
    // Regression: @Type(.{ .int = ... }) was replaced with std.meta.Int in 0.16.0.
    // Verify signed integer generation still works correctly.
    const allocator = testing.allocator;
    const i8_gen = gen.int(i8);

    var saw_negative = false;
    var saw_positive = false;

    const checkRange = struct {
        var neg_ptr: *bool = undefined;
        var pos_ptr: *bool = undefined;
        fn prop(x: i8) !void {
            if (x < 0) neg_ptr.* = true;
            if (x > 0) pos_ptr.* = true;
        }
    };
    checkRange.neg_ptr = &saw_negative;
    checkRange.pos_ptr = &saw_positive;

    try check(allocator, i8_gen, checkRange.prop, .{
        .num_runs = 100,
        .seed = 42,
    });

    // With 100 runs over the full i8 range, we should see both signs
    try testing.expect(saw_negative);
    try testing.expect(saw_positive);
}

test "regression: auto seed produces deterministic run with fixed seed" {
    // Verify that the Wyhash-based seed generation doesn't break
    // the fixed-seed reproducibility guarantee.
    const allocator = testing.allocator;
    const int_gen = gen.int(u16);

    var values1 = std.ArrayList(u16).empty;
    defer values1.deinit(allocator);
    var values2 = std.ArrayList(u16).empty;
    defer values2.deinit(allocator);

    const collect1 = struct {
        var list: *std.ArrayList(u16) = undefined;
        var alloc: std.mem.Allocator = undefined;
        fn prop(x: u16) !void {
            try list.append(alloc, x);
        }
    };
    collect1.list = &values1;
    collect1.alloc = allocator;

    const collect2 = struct {
        var list: *std.ArrayList(u16) = undefined;
        var alloc: std.mem.Allocator = undefined;
        fn prop(x: u16) !void {
            try list.append(alloc, x);
        }
    };
    collect2.list = &values2;
    collect2.alloc = allocator;

    // Same fixed seed = same sequence
    try check(allocator, int_gen, collect1.prop, .{ .num_runs = 10, .seed = 77777 });
    try check(allocator, int_gen, collect2.prop, .{ .num_runs = 10, .seed = 77777 });

    try testing.expectEqualSlices(u16, values1.items, values2.items);
}
