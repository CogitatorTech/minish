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

/// Statistics from one check call, including calls that return an error.
pub const Statistics = struct {
    /// Seed used by the runner, including an automatically derived seed.
    seed: u64 = 0,
    /// Generated inputs tested before shrinking, including a failing input.
    runs: u32 = 0,
    /// Generated inputs that passed. Passing shrink candidates are excluded.
    passed: u32 = 0,
    /// Shrink candidates evaluated by the property.
    shrink_attempts: u32 = 0,
    /// Failing shrink candidates accepted as smaller counterexamples.
    successful_shrinks: u32 = 0,
};

/// A named input category for checkWithCoverage. Categories may overlap.
pub fn Coverage(comptime T: type) type {
    return struct {
        label: []const u8,
        /// Borrows the generated input before the property runs.
        predicate: *const fn (T) bool,
        /// Matching generated inputs, including a failing input but excluding shrinking.
        hits: u32 = 0,
        /// Percentage of tested generated inputs matching this category, or zero for no runs.
        percentage: f64 = 0,
    };
}

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
    /// Optional output, replaced with this call's statistics when check returns.
    statistics: ?*Statistics = null,
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
    return checkImpl(allocator, generator, test_fn, options, null);
}

/// Run a property and report counts and percentages for named input categories.
/// Pass a mutable slice or array pointer of Coverage(T), where T is the generator's value type.
/// Results replace previous counts and remain available when the check returns an error.
/// Predicates borrow each generated input before the property runs and must not free it.
/// Shrink candidates are excluded. Categories may overlap or leave inputs unclassified.
pub fn checkWithCoverage(
    allocator: Allocator,
    generator: anytype,
    test_fn: anytype,
    coverage: anytype,
    options: Options,
) !void {
    return checkImpl(allocator, generator, test_fn, options, coverage);
}

fn checkImpl(
    allocator: Allocator,
    generator: anytype,
    test_fn: anytype,
    options: Options,
    coverage: anytype,
) !void {
    // Handle seed: use provided seed or derive one from a stack address.
    // ASLR ensures the stack address differs between runs, providing non-determinism.
    const seed = options.seed orelse blk: {
        var anchor: u8 = 0;
        const addr = @intFromPtr(&anchor);
        break :blk @as(u64, @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&addr))));
    };
    var statistics = Statistics{ .seed = seed };
    if (@TypeOf(coverage) != @TypeOf(null)) {
        for (coverage) |*category| category.hits = 0;
    }
    defer if (@TypeOf(coverage) != @TypeOf(null)) {
        if (coverage.len > 0) std.debug.print("Coverage:\n", .{});
        for (coverage) |*category| {
            category.percentage = if (statistics.runs == 0) 0 else 100.0 * @as(f64, @floatFromInt(category.hits)) / @as(f64, @floatFromInt(statistics.runs));
            std.debug.print("  {s}: {d}/{d} ({d:.1}%)\n", .{
                category.label, category.hits, statistics.runs, category.percentage,
            });
        }
    };
    defer if (options.statistics) |output| {
        output.* = statistics;
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
        statistics.runs += 1;
        if (@TypeOf(coverage) != @TypeOf(null)) {
            for (coverage) |*category| {
                if (category.predicate(value)) category.hits += 1;
            }
        }

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
                var it = shrinker(allocator, minimal_value);
                defer it.deinit();

                while (statistics.shrink_attempts < options.max_shrink_attempts) {
                    const next_val = it.next() orelse break;
                    statistics.shrink_attempts += 1;

                    // Progress indicator
                    if (statistics.shrink_attempts % 50 == 0) {
                        std.debug.print(".", .{});
                    }

                    if (test_fn(next_val)) |_| {
                        if (generator.freeFn) |freeFn| {
                            freeFn(allocator, next_val);
                        }
                    } else |_| {
                        statistics.successful_shrinks += 1;
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
                std.debug.print("Shrink attempts: {d}\n", .{statistics.shrink_attempts});
            }
            return err;
        };
        statistics.passed += 1;
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
    var statistics = Statistics{ .runs = 10, .passed = 5, .shrink_attempts = 3, .successful_shrinks = 2 };
    try check(allocator, int_gen, alwaysFail, .{
        .num_runs = 0,
        .seed = 12345,
        .statistics = &statistics,
    });
    try testing.expectEqualDeep(Statistics{ .seed = 12345 }, statistics);
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

    var statistics: Statistics = .{};
    try check(allocator, int_gen, alwaysPass, .{
        .num_runs = 10,
        .seed = 12345,
        .statistics = &statistics,
    });
    try testing.expectEqualDeep(Statistics{ .seed = 12345, .runs = 10, .passed = 10 }, statistics);
    try check(allocator, int_gen, alwaysPass, .{ .num_runs = 2, .seed = 42, .statistics = &statistics });
    try testing.expectEqualDeep(Statistics{ .seed = 42, .runs = 2, .passed = 2 }, statistics);
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

    var statistics = Statistics{ .runs = 10, .passed = 10 };
    const result = check(allocator, failing_gen, anyProp, .{
        .num_runs = 10,
        .seed = 12345,
        .statistics = &statistics,
    });

    try testing.expectError(core.GenError.InvalidChoice, result);
    try testing.expectEqualDeep(Statistics{ .seed = 12345 }, statistics);
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

test "runner statistics retain passing runs before a failure" {
    const Property = struct {
        var calls: u32 = 0;

        fn prop(_: i32) !void {
            calls += 1;
            if (calls == 3) return error.PropertyFailed;
        }
    };
    Property.calls = 0;
    var generator = gen.int(i32);
    generator.shrinkFn = null;
    var statistics: Statistics = .{};
    try testing.expectError(error.PropertyFailed, check(testing.allocator, generator, Property.prop, .{
        .num_runs = 10,
        .seed = 42,
        .statistics = &statistics,
    }));
    try testing.expectEqualDeep(Statistics{ .seed = 42, .runs = 3, .passed = 2 }, statistics);
}

test "runner statistics distinguish shrink attempts from accepted candidates" {
    const Property = struct {
        var calls: u32 = 0;
        var failures: u32 = 0;
        fn checkValue(value: i32) !void {
            calls += 1;
            if (value > 8) {
                failures += 1;
                return error.PropertyFailed;
            }
        }
    };
    const generator = gen.Generator(i32){
        .generateFn = gen.constant(@as(i32, 100)).generateFn,
        .shrinkFn = gen.int(i32).shrinkFn,
        .freeFn = null,
    };
    for ([_]u32{ 0, 1, 3, 1000 }) |budget| {
        Property.calls = 0;
        Property.failures = 0;
        var statistics: Statistics = .{};
        try testing.expectError(error.PropertyFailed, check(testing.allocator, generator, Property.checkValue, .{
            .seed = 42,
            .num_runs = 10,
            .max_shrink_attempts = budget,
            .statistics = &statistics,
        }));
        try testing.expectEqualDeep(Statistics{
            .seed = 42,
            .runs = 1,
            .passed = 0,
            .shrink_attempts = Property.calls - 1,
            .successful_shrinks = Property.failures - 1,
        }, statistics);
        try testing.expect(statistics.shrink_attempts <= budget);
        if (budget == 1000) {
            try testing.expect(statistics.successful_shrinks > 0);
            try testing.expect(statistics.successful_shrinks < statistics.shrink_attempts);
        }
    }
}

test "coverage counts overlapping categories and resets on success and errors" {
    const Fixture = struct {
        var generated: u32 = 0;
        var generator_error_at: ?u32 = null;
        var property_error_at: ?i32 = null;
        var classified: u32 = 0;

        fn generate(_: *TestCase) core.GenError!i32 {
            if (generator_error_at) |limit| {
                if (generated == limit) return error.InvalidChoice;
            }
            const value: i32 = @intCast(generated);
            generated += 1;
            return value;
        }
        fn property(value: i32) !void {
            if (property_error_at) |limit| {
                if (value >= limit) return error.PropertyFailed;
            }
        }
        fn all(_: i32) bool {
            classified += 1;
            return true;
        }
        fn even(value: i32) bool {
            return @mod(value, 2) == 0;
        }
        fn never(_: i32) bool {
            return false;
        }
    };
    const generator = gen.Generator(i32){
        .generateFn = Fixture.generate,
        .shrinkFn = gen.int(i32).shrinkFn,
        .freeFn = null,
    };
    var coverage = [_]Coverage(i32){
        .{ .label = "all", .predicate = Fixture.all, .hits = 99, .percentage = 99 },
        .{ .label = "even", .predicate = Fixture.even },
        .{ .label = "never", .predicate = Fixture.never },
    };
    const Scenario = struct {
        num_runs: u32 = 5,
        generator_error_at: ?u32 = null,
        property_error_at: ?i32 = null,
        expected_error: ?anyerror = null,
        expected_runs: u32,
        expected_even: u32,
    };
    for ([_]Scenario{
        .{ .expected_runs = 5, .expected_even = 3 },
        .{ .property_error_at = 2, .expected_error = error.PropertyFailed, .expected_runs = 3, .expected_even = 2 },
        .{ .generator_error_at = 3, .expected_error = error.InvalidChoice, .expected_runs = 3, .expected_even = 2 },
        .{ .generator_error_at = 0, .expected_error = error.InvalidChoice, .expected_runs = 0, .expected_even = 0 },
        .{ .num_runs = 0, .expected_runs = 0, .expected_even = 0 },
    }) |scenario| {
        Fixture.generated = 0;
        Fixture.classified = 0;
        Fixture.generator_error_at = scenario.generator_error_at;
        Fixture.property_error_at = scenario.property_error_at;
        var statistics: Statistics = .{};
        const result = checkWithCoverage(testing.allocator, generator, Fixture.property, coverage[0..], .{
            .num_runs = scenario.num_runs,
            .seed = 42,
            .statistics = &statistics,
        });
        if (scenario.expected_error) |err| {
            try testing.expectError(err, result);
        } else {
            try result;
        }
        try testing.expectEqual(scenario.expected_runs, statistics.runs);
        try testing.expectEqual(scenario.expected_runs, Fixture.classified);
        try testing.expectEqual(scenario.expected_runs, coverage[0].hits);
        try testing.expectEqual(scenario.expected_even, coverage[1].hits);
        try testing.expectEqual(@as(u32, 0), coverage[2].hits);
        try testing.expectEqual(@as(f64, if (scenario.expected_runs == 0) 0 else 100), coverage[0].percentage);
        const expected_percentage: f64 = if (scenario.expected_runs == 0) 0 else 100.0 * @as(f64, @floatFromInt(scenario.expected_even)) / @as(f64, @floatFromInt(scenario.expected_runs));
        try testing.expectApproxEqAbs(expected_percentage, coverage[1].percentage, 0.000001);
        try testing.expectEqual(@as(f64, 0), coverage[2].percentage);
        if (scenario.property_error_at != null) try testing.expect(statistics.shrink_attempts > 0);
    }
}

test "coverage borrows owned inputs and accepts an empty category list" {
    const Fixture = struct {
        fn lengthThree(value: []const u8) bool {
            return value.len == 3;
        }
        fn property(value: []const u8) !void {
            try testing.expectEqual(@as(usize, 3), value.len);
        }
    };
    const generator = gen.string(.{ .min_len = 3, .max_len = 3 });
    var coverage = [_]Coverage([]const u8){.{ .label = "length three", .predicate = Fixture.lengthThree }};
    try checkWithCoverage(testing.allocator, generator, Fixture.property, &coverage, .{ .seed = 42, .num_runs = 5 });
    try testing.expectEqual(@as(u32, 5), coverage[0].hits);
    try testing.expectEqual(@as(f64, 100), coverage[0].percentage);
    var empty: [0]Coverage([]const u8) = .{};
    try checkWithCoverage(testing.allocator, generator, Fixture.property, &empty, .{ .seed = 42, .num_runs = 5 });
}
