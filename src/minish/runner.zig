const std = @import("std");
const core = @import("core.zig");
const gen = @import("gen.zig");
const shrink_mod = @import("shrink.zig");

const Allocator = std.mem.Allocator;
const TestCase = core.TestCase;

pub const Options = struct {
    num_runs: u32 = 100,
    seed: ?u64 = null,
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
    std.debug.print("Running property tests with seed: {d}\n", .{seed});

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
                \\================================
                \\Property failed on run {d}
                \\Error: {s}
                \\Failing input: {any}
                \\================================
                \\
            , .{ i + 1, @errorName(err), value });

            if (generator.shrinkFn) |shrinker| {
                std.debug.print("Shrinking...\n", .{});
                var minimal_value = value;
                var it = shrinker(allocator, minimal_value);
                defer it.deinit();
                while (it.next()) |next_val| {
                    if (test_fn(next_val)) |_| {} else |_| {
                        minimal_value = next_val;
                        it.deinit();
                        it = shrinker(allocator, minimal_value);
                    }
                }
                std.debug.print("Minimal failing input: {any}\n", .{minimal_value});
            }
            return err;
        };
    }
    std.debug.print("OK. {d} tests passed.\n", .{options.num_runs});
}
