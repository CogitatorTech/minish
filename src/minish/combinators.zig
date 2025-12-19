//! Generator combinators for composing and transforming generators.
//!
//! Combinators allow you to build complex generators from simpler ones:
//! - `map`: Transform generated values
//! - `flatMap`: Chain generators together
//! - `filter`: Filter generated values by predicate
//! - `frequency`: Weighted random choice between generators

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

// Note: Combinator tests are demonstrated in examples/e5_struct_and_combinators.zig
// They cannot be easily unit tested due to comptime parameter requirements

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

// Note: sized combinator not tested because it requires generators that take
// runtime size parameters, but most generators use comptime parameters.
// It's primarily for custom use cases.
