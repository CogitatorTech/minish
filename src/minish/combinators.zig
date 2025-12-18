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
pub fn map(
    comptime T: type,
    comptime U: type,
    comptime base_gen: Generator(T),
    comptime map_fn: fn (T) U,
) Generator(U) {
    const MapGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!U {
            const base_value = try base_gen.generateFn(tc);
            return map_fn(base_value);
        }
    };
    return .{ .generateFn = MapGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// FlatMap Combinator
// ============================================================================

/// Chain generators - use the output of one generator to create another.
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
            return next_gen.generateFn(tc);
        }
    };
    return .{ .generateFn = FlatMapGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Filter Combinator
// ============================================================================

/// Generate values that satisfy a predicate.
/// WARNING: This can loop indefinitely if the predicate is rarely satisfied.
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
            }
            return error.Overrun;
        }
    };
    return .{ .generateFn = FilterGenerator.generate, .shrinkFn = null, .freeFn = null };
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
    };
    return .{ .generateFn = FrequencyGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// Note: Combinator tests are demonstrated in examples/e5_struct_and_combinators.zig
// They cannot be easily unit tested due to comptime parameter requirements
