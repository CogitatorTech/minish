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
                // Register value cleanup first so the iterator closes before it is freed.
                defer if (!minimal_is_original) {
                    if (generator.freeFn) |freeFn| freeFn(allocator, minimal_value);
                };
                var shrink_attempts: u32 = 0;
                var it = shrinker(allocator, minimal_value);
                defer it.deinit();

                while (shrink_attempts < options.max_shrink_attempts) {
                    const next_val = it.next() orelse break;
                    shrink_attempts += 1;

                    // Progress indicator
                    if (shrink_attempts % 50 == 0) {
                        std.debug.print(".", .{});
                    }

                    if (test_fn(next_val)) |_| {
                        if (generator.freeFn) |freeFn| {
                            freeFn(allocator, next_val);
                        }
                    } else |_| {
                        // Order matters: the live iterator may hold a reference
                        // to `minimal_value` via its internal state. Tear down the
                        // iterator before freeing the value it referenced.
                        it.deinit();
                        if (!minimal_is_original) {
                            if (generator.freeFn) |freeFn| {
                                freeFn(allocator, minimal_value);
                            }
                        }
                        minimal_value = next_val;
                        minimal_is_original = false;
                        it = shrinker(allocator, minimal_value);
                    }
                }
                std.debug.print("\nMinimal failing input: {any}\n", .{minimal_value});
                std.debug.print("Shrink attempts: {d}\n", .{shrink_attempts});
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

test "regression: shrink budget evaluates exactly the allowed candidates without leaks" {
    const Property = struct {
        var calls: usize = 0;
        fn checkValue(s: []const u8) !void {
            calls += 1;
            if (s.len == 4) return error.PropertyFailed;
        }
    };
    const Fixed = struct {
        fn generate(tc: *TestCase) core.GenError![]const u8 {
            return tc.allocator.dupe(u8, "abcd");
        }
        fn free(allocator: Allocator, value: []const u8) void {
            allocator.free(value);
        }
    };
    const generator = gen.Generator([]const u8){
        .generateFn = Fixed.generate,
        .shrinkFn = shrink_mod.stringShrinker(),
        .freeFn = Fixed.free,
    };
    for ([_]u32{ 0, 1, 2, 3 }) |budget| {
        Property.calls = 0;
        try testing.expectError(error.PropertyFailed, check(testing.allocator, generator, Property.checkValue, .{
            .seed = 1,
            .num_runs = 1,
            .max_shrink_attempts = budget,
        }));
        try testing.expectEqual(@as(usize, budget) + 1, Property.calls);
    }
}

test "regression: runner closes borrowing iterators before freeing their values" {
    const Borrowing = struct {
        allocator: Allocator,
        value: []const u8,
        done: bool = false,

        fn generate(tc: *TestCase) core.GenError![]const u8 {
            return tc.allocator.dupe(u8, "xxx");
        }
        fn shrink(allocator: Allocator, value: []const u8) shrink_mod.Iterator([]const u8) {
            const context = allocator.create(@This()) catch return shrink_mod.Iterator([]const u8).empty();
            context.* = .{ .allocator = allocator, .value = value };
            return .{ .context = context, .nextFn = next, .deinitFn = deinit };
        }
        fn next(ctx: *anyopaque) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.done or self.value.len <= 1) return null;
            self.done = true;
            return self.allocator.dupe(u8, self.value[0 .. self.value.len - 1]) catch null;
        }
        fn deinit(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(self.value[0] == 'x');
            self.allocator.destroy(self);
        }
        fn free(allocator: Allocator, value: []const u8) void {
            allocator.free(value);
        }
        fn property(_: []const u8) !void {
            return error.PropertyFailed;
        }
    };
    const g = gen.Generator([]const u8){ .generateFn = Borrowing.generate, .shrinkFn = Borrowing.shrink, .freeFn = Borrowing.free };
    for ([_]u32{ 1, 1000 }) |budget| {
        try testing.expectError(error.PropertyFailed, check(testing.allocator, g, Borrowing.property, .{
            .seed = 1,
            .num_runs = 1,
            .max_shrink_attempts = budget,
        }));
    }
}
