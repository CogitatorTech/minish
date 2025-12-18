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
    /// Optional seed for reproducibility. If null, uses current timestamp.
    seed: ?u64 = null,
    /// Maximum number of shrink attempts before stopping.
    max_shrink_attempts: u32 = 1000,
    /// Whether to print verbose output during testing.
    verbose: bool = false,
};

pub fn check(
    allocator: Allocator,
    generator: anytype,
    test_fn: anytype,
    options: Options,
) !void {
    // Cast the i64 timestamp to u64 to match the seed type.
    const seed = options.seed orelse @as(u64, @intCast(std.time.milliTimestamp()));
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
