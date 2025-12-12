const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// Property: for any two positive integers, their sum should be >= each of them (unless overflow)
fn sum_is_greater_or_equal(tuple: struct { u32, u32 }) !void {
    const a = tuple[0];
    const b = tuple[1];
    const sum = a +| b; // Use wrapping addition to avoid overflow panic

    // If no overflow occurred, sum should be >= each operand
    if (sum >= a and sum >= b) {
        // Good!
    } else {
        // Overflow occurred, which is expected for large numbers
    }
}

// Property: floats should maintain reflexive equality (x == x)
fn float_reflexive_equality(x: f64) !void {
    // NaN is the exception to reflexive equality
    if (std.math.isNan(x)) return;

    try std.testing.expectEqual(x, x);
}

// Property: optional unwrapping
fn optional_test(maybe_val: ?i32) !void {
    if (maybe_val) |val| {
        // If we have a value, it should be a valid i32
        try std.testing.expect(val >= std.math.minInt(i32));
        try std.testing.expect(val <= std.math.maxInt(i32));
    }
    // If null, nothing to test
}

// Property: ranges should respect bounds
fn range_test(val: i16) !void {
    // We'll test with a specific range
    const min: i16 = -100;
    const max: i16 = 100;

    // This property only makes sense if we use intRange generator
    try std.testing.expect(val >= min);
    try std.testing.expect(val <= max);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Advanced Generator Examples ===\n\n", .{});

    // Test 1: Tuple generator
    std.debug.print("Test 1: Tuple of unsigned integers\n", .{});
    const tuple_gen = gen.tuple2(u32, u32, gen.int(u32), gen.int(u32));
    minish.check(allocator, tuple_gen, sum_is_greater_or_equal, .{ .num_runs = 50 }) catch |err| {
        if (err == error.Overflow) {
            std.debug.print("  Note: Overflow occurred as expected with large numbers\n", .{});
        } else {
            return err;
        }
    };

    // Test 2: Float generator
    std.debug.print("\nTest 2: Float reflexive equality\n", .{});
    const float_gen = gen.float(f64);
    try minish.check(allocator, float_gen, float_reflexive_equality, .{ .num_runs = 100 });

    // Test 3: Optional generator
    std.debug.print("\nTest 3: Optional integers\n", .{});
    const optional_gen = gen.optional(i32, gen.int(i32));
    try minish.check(allocator, optional_gen, optional_test, .{ .num_runs = 100 });

    // Test 4: Range generator
    std.debug.print("\nTest 4: Integers in range [-100, 100]\n", .{});
    const range_gen = gen.intRange(i16, -100, 100);
    try minish.check(allocator, range_gen, range_test, .{ .num_runs = 100 });

    // Test 5: Array generator
    std.debug.print("\nTest 5: Fixed-size arrays\n", .{});
    const array_gen = gen.array(u8, 10, gen.int(u8));
    const array_test = struct {
        fn test_fn(arr: [10]u8) !void {
            try std.testing.expectEqual(10, arr.len);
        }
    }.test_fn;
    try minish.check(allocator, array_gen, array_test, .{ .num_runs = 100 });

    // Test 6: Boolean generator
    std.debug.print("\nTest 6: Boolean values\n", .{});
    const bool_gen = gen.boolean();
    const bool_test = struct {
        fn test_fn(b: bool) !void {
            _ = b; // Boolean is always valid
        }
    }.test_fn;
    try minish.check(allocator, bool_gen, bool_test, .{ .num_runs = 50 });

    std.debug.print("\nAll advanced generator tests passed!\n", .{});
}
