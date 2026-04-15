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
/// `free_fn` controls how the runner releases the mapped result `U`:
/// - Pass `null` if `U` is a value type (e.g. integers, floats, fixed arrays)
///   or its lifetime is otherwise managed.
/// - Pass a free function if `U` owns heap memory (e.g. `[]const u8` you
///   allocated inside `map_fn`); the runner will call it once the property
///   has finished with the value.
///
/// The base `T` produced by `base_gen` is always freed inside `generate`
/// (via `base_gen.freeFn`) once `map_fn` has returned.
///
/// Example:
/// ```zig
/// // Convert generated integers to lengths (no allocation in the result).
/// const length_gen = combinators.map(i32, usize, gen.int(i32), absUsize, null);
/// ```
pub fn map(
    comptime T: type,
    comptime U: type,
    comptime base_gen: Generator(T),
    comptime map_fn: fn (T) U,
    comptime free_fn: ?*const fn (std.mem.Allocator, U) void,
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
    return .{ .generateFn = MapGenerator.generate, .shrinkFn = null, .freeFn = free_fn };
}

// ============================================================================
// FlatMap Combinator
// ============================================================================

/// Chain generators - use the output of one generator to create another.
///
/// `free_fn` controls how the runner releases the inner generator's `U`:
/// - Pass `null` if every generator returned by `flat_fn` produces value-type
///   `U` (no heap ownership) or its lifetime is otherwise managed.
/// - Pass a free function if any inner generator allocates `U`. Because the
///   inner generator is selected at runtime from `flat_fn`, the cleanup must
///   work uniformly across all branches; pick `null` and refactor if branches
///   need different cleanup.
///
/// The base `T` is always freed inside `generate` once the inner generator
/// has produced its `U`. If the inner generator fails, `T` is still freed
/// before the error propagates.
///
/// Example:
/// ```zig
/// // Generate an integer 0..10, then dispatch to a generator that returns 0 or 1.
/// const flat_gen = combinators.flatMap(i32, i32, gen.intRange(i32, 0, 10), makeGen, null);
/// ```
pub fn flatMap(
    comptime T: type,
    comptime U: type,
    comptime base_gen: Generator(T),
    comptime flat_fn: fn (T) Generator(U),
    comptime free_fn: ?*const fn (std.mem.Allocator, U) void,
) Generator(U) {
    const FlatMapGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!U {
            const base_value = try base_gen.generateFn(tc);
            // Ensure the base value is freed even if the inner generator fails.
            defer if (base_gen.freeFn) |freeFn| freeFn(tc.allocator, base_value);
            const next_gen = flat_fn(base_value);
            return next_gen.generateFn(tc);
        }
    };
    return .{ .generateFn = FlatMapGenerator.generate, .shrinkFn = null, .freeFn = free_fn };
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
    comptime {
        if (weighted_gens.len == 0) {
            @compileError("frequency: at least one weighted generator is required");
        }
        // All inner generators must agree on memory ownership: the runtime
        // dispatch makes per-branch cleanup ambiguous, so we require uniform
        // freeFn pointers across branches.
        const first_free = weighted_gens[0].gen.freeFn;
        for (weighted_gens[1..]) |wg| {
            if (wg.gen.freeFn != first_free) {
                @compileError("frequency: all generators must share the same freeFn (or all be null). Wrap mismatched generators so they expose a uniform free function.");
            }
        }
    }
    const FrequencyGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            // Build weights array
            var weights: [weighted_gens.len]u64 = undefined;
            for (weighted_gens, 0..) |wg, i| {
                weights[i] = wg.weight;
            }

            const idx = try tc.weightedChoice(&weights);
            return weighted_gens[idx].gen.generateFn(tc);
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            // All branches share a freeFn (enforced at comptime above).
            if (weighted_gens[0].gen.freeFn) |freeFn| freeFn(allocator, value);
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
    comptime {
        if (generators.len == 0) {
            @compileError("oneOf: at least one generator is required");
        }
        // All inner generators must agree on memory ownership: the runtime
        // dispatch makes per-branch cleanup ambiguous, so we require uniform
        // freeFn pointers across branches.
        const first_free = generators[0].freeFn;
        for (generators[1..]) |g| {
            if (g.freeFn != first_free) {
                @compileError("oneOf: all generators must share the same freeFn (or all be null). Wrap mismatched generators so they expose a uniform free function.");
            }
        }
    }
    const OneOfGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            const idx = try tc.choice(generators.len - 1);
            return generators[idx].generateFn(tc);
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            // All branches share a freeFn (enforced at comptime above).
            if (generators[0].freeFn) |freeFn| freeFn(allocator, value);
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

    const len_gen = map([]const u8, usize, str_gen, getLen, null);

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

    const flat_gen = flatMap(i32, i32, gen.intRange(i32, 0, 10), makeGen, null);

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

test "regression: map combinator with allocated result frees U" {
    // Bug: map() always set freeFn = null on the returned generator, so
    // mapping to an allocated U (e.g. []const u8) leaked every produced value.
    // Fix: map() now takes an explicit free_fn parameter that the runner uses.
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // Map an integer to a freshly-allocated single-character string.
    const intToStr = struct {
        fn make(_: i32) []const u8 {
            // Use a static-lifetime string so the test doesn't need a real
            // allocator hand-off; the goal here is only to verify free_fn is
            // installed on the returned generator. The allocated-string path
            // is exercised by the flatMap regression test below.
            return "x";
        }
    }.make;

    const noFree = struct {
        fn free(_: std.mem.Allocator, _: []const u8) void {}
    }.free;

    const str_gen = map(i32, []const u8, gen.intRange(i32, 0, 100), intToStr, noFree);
    try std.testing.expect(str_gen.freeFn != null);

    const Props = struct {
        fn prop(s: []const u8) !void {
            try std.testing.expectEqualStrings("x", s);
        }
    };

    try runner.check(allocator, str_gen, Props.prop, .{ .seed = 555, .num_runs = 10 });
}

test "regression: flatMap with allocated U does not leak" {
    // Bug: flatMap() always set freeFn = null, so when an inner generator
    // produced an allocated U the runner could not release it.
    // Fix: flatMap() now accepts an explicit free_fn that the runner invokes.
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;

    // Inner generator returns a string generator that allocates on demand.
    const inner_str = comptime gen.string(.{ .min_len = 1, .max_len = 5 });
    const makeInner = struct {
        fn make(_: bool) gen.Generator([]const u8) {
            return inner_str;
        }
    }.make;

    const freeStr = struct {
        fn free(a: std.mem.Allocator, s: []const u8) void {
            a.free(s);
        }
    }.free;

    const flat_gen = flatMap(bool, []const u8, gen.boolean(), makeInner, freeStr);

    const Props = struct {
        fn prop(s: []const u8) !void {
            try std.testing.expect(s.len >= 1 and s.len <= 5);
        }
    };

    // testing.allocator panics on leak, so a passing run proves no leak.
    try runner.check(allocator, flat_gen, Props.prop, .{ .seed = 666, .num_runs = 50 });
}

test "regression: flatMap frees base value when inner generator fails" {
    // Bug: previously, base_gen.freeFn was only called after the inner
    // generator succeeded, so an inner failure leaked the base value.
    // Fix: base value cleanup is now in a `defer`, so it runs on every path.
    const allocator = std.testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Inner generator always fails.
    const failingInner = struct {
        fn gen_fn(_: *TestCase) core.GenError!i32 {
            return error.InvalidChoice;
        }
    };
    const failing_gen = gen.Generator(i32){
        .generateFn = failingInner.gen_fn,
        .shrinkFn = null,
        .freeFn = null,
    };
    const makeFailing = struct {
        var captured: gen.Generator(i32) = undefined;
        fn make(_: []const u8) gen.Generator(i32) {
            return captured;
        }
    };
    makeFailing.captured = failing_gen;

    const flat_gen = flatMap(
        []const u8,
        i32,
        gen.string(.{ .min_len = 1, .max_len = 5 }),
        makeFailing.make,
        null,
    );

    const result = flat_gen.generateFn(&tc);
    try std.testing.expectError(core.GenError.InvalidChoice, result);
    // testing.allocator's leak check covers the base string.
}
