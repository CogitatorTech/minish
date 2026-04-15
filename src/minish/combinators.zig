//! Generator combinators for composing and transforming generators.
//!
//! Combinators build generators from simpler ones:
//! - `map`: Transform generated values with a function
//! - `flatMap`: Chain generators, where the next generator depends on the first value
//! - `filter`: Keep generated values that satisfy a predicate
//! - `sized`: Apply a size parameter to a generator factory
//! - `frequency`: Weighted random choice between generators
//! - `oneOf`: Uniform random choice between generators
//! - `dependent`: Pair a first value with a generator derived from it

const std = @import("std");
const core = @import("core.zig");
const gen = @import("gen.zig");

const TestCase = core.TestCase;
const Generator = gen.Generator;

// ============================================================================
// Map Combinator
// ============================================================================

/// Transform the output of a generator using a mapping function.
///
/// Example:
/// ```zig
/// // Convert generated integers to strings
/// const string_gen = combinators.map(i32, []const u8, gen.int(i32), intToString);
/// ```
///
/// Note: If base_gen allocates memory and map_fn transforms to a different type,
/// the base value is freed after transformation. If map_fn returns a type that
/// also needs freeing, you must provide that through the result generator.
pub fn map(
    comptime T: type,
    comptime U: type,
    comptime base_gen: Generator(T),
    comptime map_fn: fn (T) U,
) Generator(U) {
    const MapGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!U {
            const base_value = try base_gen.generateFn(tc);
            const result = map_fn(base_value);
            // Free the base value after transformation if it was allocated
            if (base_gen.freeFn) |freeFn| {
                freeFn(tc.allocator, base_value);
            }
            return result;
        }
    };
    // Note: freeFn is null because the mapped result U may have different
    // memory semantics. Users should use a wrapper if U needs freeing.
    return .{ .generateFn = MapGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// FlatMap Combinator
// ============================================================================

/// Chain generators - use the output of one generator to create another.
///
/// Example:
/// ```zig
/// // Generate a length, then a list of that length
/// const list_gen = combinators.flatMap(usize, []const u8, gen.intRange(usize, 1, 10), makeListGen);
/// ```
///
/// Note: The base value is freed after the next generator is created and produces a result.
pub fn flatMap(
    comptime T: type,
    comptime U: type,
    comptime base_gen: Generator(T),
    comptime flat_fn: fn (T) Generator(U),
) Generator(U) {
    const FlatMapGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!U {
            const base_value = try base_gen.generateFn(tc);
            const next_gen = flat_fn(base_value);
            const result = try next_gen.generateFn(tc);
            // Free the base value after we're done using it
            if (base_gen.freeFn) |freeFn| {
                freeFn(tc.allocator, base_value);
            }
            return result;
        }

        fn free(allocator: std.mem.Allocator, value: U) void {
            // Try to free using the result generator's freeFn
            // Note: This is a best-effort approach since we don't know which
            // specific generator was used (depends on base_value at runtime)
            _ = allocator;
            _ = value;
        }
    };
    return .{ .generateFn = FlatMapGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Filter Combinator
// ============================================================================

/// Generate values that satisfy a predicate.
/// WARNING: This can loop indefinitely if the predicate is rarely satisfied.
///
/// Example:
/// ```zig
/// const even_gen = combinators.filter(i32, gen.int(i32), isEven, 100);
/// ```
///
/// Memory lifecycle: Generated values that fail the predicate are automatically freed if associated generator has a freeFn.
/// The retained value is owned by the Minish runner.
pub fn filter(
    comptime T: type,
    comptime base_gen: Generator(T),
    comptime predicate: fn (T) bool,
    comptime max_attempts: usize,
) Generator(T) {
    const FilterGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            var attempts: usize = 0;
            while (attempts < max_attempts) : (attempts += 1) {
                const value = try base_gen.generateFn(tc);
                if (predicate(value)) {
                    return value;
                }
                // Free rejected value if generator provides freeFn
                if (base_gen.freeFn) |freeFn| {
                    freeFn(tc.allocator, value);
                }
            }
            return error.Overrun;
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            if (base_gen.freeFn) |freeFn| {
                freeFn(allocator, value);
            }
        }
    };
    return .{ .generateFn = FilterGenerator.generate, .shrinkFn = null, .freeFn = FilterGenerator.free };
}

// ============================================================================
// Sized Combinator
// ============================================================================

/// Control the "size" hint for generators.
/// This is useful for controlling the size of generated collections.
pub fn sized(
    comptime T: type,
    comptime size: usize,
    comptime gen_fn: fn (usize) Generator(T),
) Generator(T) {
    const sized_gen = gen_fn(size);
    return sized_gen;
}

// ============================================================================
// Frequency Combinator
// ============================================================================

/// Choose from generators with weighted probabilities.
///
/// Example:
/// ```zig
/// // 90% chance of 0, 10% chance of random int
/// const biased_gen = combinators.frequency(i32, &.{
///     .{ .weight = 90, .gen = gen.constant(@as(i32, 0)) },
///     .{ .weight = 10, .gen = gen.int(i32) }
/// });
/// ```
///
/// Memory lifecycle: The returned value is owned by the Minish runner and will be freed automatically.
/// Assumes all weighted generators share compatible memory management.
pub fn frequency(
    comptime T: type,
    comptime weighted_gens: []const struct { weight: u64, gen: Generator(T) },
) Generator(T) {
    const FrequencyGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            if (weighted_gens.len == 0) return error.InvalidChoice;

            // Build weights array
            var weights: [weighted_gens.len]u64 = undefined;
            for (weighted_gens, 0..) |wg, i| {
                weights[i] = wg.weight;
            }

            const idx = try tc.weightedChoice(&weights);
            return weighted_gens[idx].gen.generateFn(tc);
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            // Assume homogeneity: use first generator's freeFn if available
            if (weighted_gens.len > 0 and weighted_gens[0].gen.freeFn != null) {
                weighted_gens[0].gen.freeFn.?(allocator, value);
            }
        }
    };
    return .{ .generateFn = FrequencyGenerator.generate, .shrinkFn = null, .freeFn = FrequencyGenerator.free };
}

// ============================================================================
// OneOf Combinator
// ============================================================================

/// Choose one generator from a list with equal probability.
///
/// Example:
/// ```zig
/// const mixed_gen = combinators.oneOf(i32, &.{
///     gen.intRange(i32, 0, 10),
///     gen.constant(@as(i32, 100))
/// });
/// ```
///
/// Memory lifecycle: The returned value is owned by the Minish runner and will be freed automatically.
/// Note: This assumes all generators share compatible memory management logic (e.g., typically same type).
pub fn oneOf(comptime T: type, comptime generators: []const Generator(T)) Generator(T) {
    const OneOfGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            if (generators.len == 0) return error.InvalidChoice;
            const idx = try tc.choice(generators.len - 1);
            return generators[idx].generateFn(tc);
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            // We don't know which generator created it, so we can't easily free it recursively
            // without storing which generator was used.
            // However, for OneOf, we assume all generators produce the same type T.
            // If T has a single canonical free strategy (e.g. it's a struct with known fields),
            // we could try to free it.
            // But if T implies different allocation strategies per variant, it's hard.
            // BEST EFFORT: Use the freeFn of the first generator if available?
            // Or iterate generators? No, that's wrong.

            // Correct approach: OneOf should return a wrapper or we accept that strict heterogeneity
            // isn't supported for managed types OR we require all generators to share a freeFn logic.
            // For now, let's assume if the first generator has a freeFn, it works for all
            // (often they are same type generators).
            if (generators.len > 0 and generators[0].freeFn != null) {
                generators[0].freeFn.?(allocator, value);
            }
        }
    };
    return .{ .generateFn = OneOfGenerator.generate, .shrinkFn = null, .freeFn = OneOfGenerator.free };
}

// ============================================================================
// Dependent Combinator
// ============================================================================

/// Create a generator that depends on a previously generated value.
/// Useful for generating related data where one field constrains another.
pub fn dependent(
    comptime T: type,
    comptime U: type,
    comptime first_gen: Generator(T),
    comptime make_gen: fn (T) Generator(U),
) Generator(struct { T, U }) {
    const DependentGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T, U } {
            const first_val = try first_gen.generateFn(tc);
            const second_gen = make_gen(first_val);
            const second_val = try second_gen.generateFn(tc);
            return .{ first_val, second_val };
        }

        fn free(allocator: std.mem.Allocator, value: struct { T, U }) void {
            if (first_gen.freeFn) |freeFn| {
                freeFn(allocator, value[0]);
            }
            // For the dependent value, we need to regenerate the generator to access its freeFn.
            // Ideally core.Generator would be uniform, but here make_gen is a function.
            const second_gen = make_gen(value[0]);
            if (second_gen.freeFn) |freeFn| {
                freeFn(allocator, value[1]);
            }
        }
    };
    return .{ .generateFn = DependentGenerator.generate, .shrinkFn = null, .freeFn = DependentGenerator.free };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "combinator memory leak regression tests" {
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;
    const str_gen = comptime gen.string(.{ .min_len = 1, .max_len = 5 });

    const opts = runner.Options{ .seed = 111, .num_runs = 10 };

    const Props = struct {
        fn prop_no_op(_: []const u8) !void {}
    };

    // Test Frequency
    const freq_gen = frequency([]const u8, &.{
        .{ .weight = 10, .gen = str_gen },
        .{ .weight = 10, .gen = str_gen },
    });
    try runner.check(allocator, freq_gen, Props.prop_no_op, opts);
}

test "filter memory leak regression test" {
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // Generate strings, keep only those starting with 'A'.
    // Rejected strings (allocations) should be freed by filter.
    const str_gen = comptime gen.string(.{ .min_len = 1, .max_len = 5, .charset = .alphanumeric });

    const startsWithA = struct {
        fn func(s: []const u8) bool {
            if (s.len == 0) return false;
            return s[0] == 'A';
        }
    }.func;

    // We filter, max 1000 attempts to allow many rejections without failure.
    const filtered_gen = filter([]const u8, str_gen, startsWithA, 1000);

    const opts = runner.Options{ .seed = 111, .num_runs = 10 };

    const Props = struct {
        fn prop_no_op(_: []const u8) !void {}
    };

    try runner.check(allocator, filtered_gen, Props.prop_no_op, opts);
}

test "regression: map combinator frees base value" {
    // Bug: Map combinator didn't free the base value after transformation
    // Fix: Added freeFn call after map_fn is applied
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // Generate a string (which allocates) and map it to its length (which doesn't)
    const str_gen = comptime gen.string(.{ .min_len = 1, .max_len = 10 });

    const getLen = struct {
        fn func(s: []const u8) usize {
            return s.len;
        }
    }.func;

    const len_gen = map([]const u8, usize, str_gen, getLen);

    const opts = runner.Options{ .seed = 222, .num_runs = 20 };

    const Props = struct {
        fn prop_check_len(len: usize) !void {
            // Just verify the length is in expected range
            try std.testing.expect(len >= 1 and len <= 10);
        }
    };

    // If map doesn't free the base string, this will leak memory
    // and the test allocator will catch it
    try runner.check(allocator, len_gen, Props.prop_check_len, opts);
}

test "flatMap combinator chains generators" {
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // Generate a number, then use it to determine which generator to use
    const makeGen = struct {
        fn make(x: i32) gen.Generator(i32) {
            // If x is even, return 0; if odd, return 1
            if (@mod(x, 2) == 0) {
                return gen.constant(@as(i32, 0));
            } else {
                return gen.constant(@as(i32, 1));
            }
        }
    }.make;

    const flat_gen = flatMap(i32, i32, gen.intRange(i32, 0, 10), makeGen);

    const Props = struct {
        fn prop(x: i32) !void {
            // Result should be either 0 or 1
            try std.testing.expect(x == 0 or x == 1);
        }
    };

    try runner.check(allocator, flat_gen, Props.prop, .{ .seed = 333, .num_runs = 20 });
}

test "sized combinator delegates to the generator factory" {
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // A factory that ignores its size parameter and returns a constant generator.
    // This verifies that `sized` invokes gen_fn and returns the resulting generator.
    const makeGen = struct {
        fn make(_: usize) gen.Generator(i32) {
            return gen.constant(@as(i32, 7));
        }
    }.make;

    const sized_gen = sized(i32, 5, makeGen);

    const Props = struct {
        fn prop(x: i32) !void {
            try std.testing.expectEqual(@as(i32, 7), x);
        }
    };

    try runner.check(allocator, sized_gen, Props.prop, .{ .seed = 444, .num_runs = 10 });
}

test "oneOf generator selects from alternatives" {
    const allocator = std.testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_one = oneOf(i32, &.{
        gen.intRange(i32, 0, 10),
        gen.intRange(i32, 100, 110),
    });

    for (0..20) |_| {
        const value = try gen_one.generateFn(&tc);
        try std.testing.expect((value >= 0 and value <= 10) or (value >= 100 and value <= 110));
    }
}

test "dependent generator creates related values" {
    const allocator = std.testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Generate a bool, then based on it generate 0 or 100
    const makeSecond = struct {
        fn make(first: bool) Generator(i32) {
            return if (first) gen.constant(@as(i32, 100)) else gen.constant(@as(i32, 0));
        }
    }.make;

    const gen_dep = dependent(bool, i32, gen.boolean(), makeSecond);
    const value = try gen_dep.generateFn(&tc);

    // If first is true, second should be 100; if false, second should be 0
    if (value[0]) {
        try std.testing.expectEqual(@as(i32, 100), value[1]);
    } else {
        try std.testing.expectEqual(@as(i32, 0), value[1]);
    }
}
