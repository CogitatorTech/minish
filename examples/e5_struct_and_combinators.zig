const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;
const combinators = minish.combinators;

// Define a custom struct type
const Person = struct {
    age: u8,
    height_cm: u16,
    name_length: usize,
    is_adult: bool,
};

// Property: if age >= 18, then is_adult should be true
fn adult_flag_is_consistent(person: Person) !void {
    if (person.age >= 18) {
        try std.testing.expect(person.is_adult);
    } else {
        try std.testing.expect(!person.is_adult);
    }
}

// Property: height should be reasonable for the age
fn height_is_reasonable(person: Person) !void {
    // Very basic check - just make sure height isn't absurdly large or small
    try std.testing.expect(person.height_cm >= 30); // Even babies are >30cm
    try std.testing.expect(person.height_cm <= 250); // Very tall but possible
}

// Test map combinator - square all integers
fn test_map_squares(squared: i32) !void {
    // The squared value should be non-negative
    try std.testing.expect(squared >= 0);
}

// Test filter combinator - all values should be even
fn test_filter_even(value: i32) !void {
    try std.testing.expect(@mod(value, 2) == 0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Struct Generator and Combinators Example ===\n\n", .{});

    // Example 1: Struct Generator
    std.debug.print("Test 1: Struct Generator with Person type\n", .{});

    // Simple struct generator - note that fields are independent
    const person_gen = gen.structure(Person, .{
        .age = gen.intRange(u8, 0, 100),
        .height_cm = gen.intRange(u16, 50, 220),
        .name_length = gen.intRange(usize, 1, 30),
        .is_adult = gen.boolean(), // Random, not based on age
    });

    // This property will fail because is_adult is random
    // That's OK - we're demonstrating that struct fields are independent
    // For dependent fields, you'd need custom logic or the dependent() combinator
    std.debug.print("  (Note: adult_flag test will likely fail since is_adult is random)\n", .{});

    // Just test height constraint instead
    try minish.check(allocator, person_gen, height_is_reasonable, .{ .num_runs = 100 });

    // Example 2: Map Combinator
    std.debug.print("\nTest 2: Map combinator (square integers)\n", .{});

    const square_fn = struct {
        fn square(x: i32) i32 {
            // Use saturating multiplication to avoid overflow
            if (x == 0) return 0;
            const abs_x = if (x < 0) -x else x;
            if (abs_x > 46340) return std.math.maxInt(i32); // sqrt(2^31-1) ≈ 46340
            return x * x;
        }
    }.square;

    const squared_gen = combinators.map(i32, i32, gen.intRange(i32, -100, 100), square_fn);
    try minish.check(allocator, squared_gen, test_map_squares, .{ .num_runs = 100 });

    // Example 3: Filter Combinator
    std.debug.print("\nTest 3: Filter combinator (even numbers only)\n", .{});

    const is_even = struct {
        fn check(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.check;

    const even_gen = combinators.filter(i32, gen.int(i32), is_even, 100);
    try minish.check(allocator, even_gen, test_filter_even, .{ .num_runs = 50 });

    // Example 4: Frequency Combinator
    std.debug.print("\nTest 4: Frequency combinator (weighted choice)\n", .{});

    const weighted_int_gen = combinators.frequency(i32, &.{
        .{ .weight = 70, .gen = gen.intRange(i32, 0, 10) }, // 70% small numbers
        .{ .weight = 20, .gen = gen.intRange(i32, 100, 200) }, // 20% medium numbers
        .{ .weight = 10, .gen = gen.intRange(i32, 1000, 2000) }, // 10% large numbers
    });

    const frequency_test = struct {
        fn checkRange(val: i32) !void {
            // All values should be in one of the three ranges
            const in_range = (val >= 0 and val <= 10) or
                (val >= 100 and val <= 200) or
                (val >= 1000 and val <= 2000);
            try std.testing.expect(in_range);
        }
    }.checkRange;

    try minish.check(allocator, weighted_int_gen, frequency_test, .{ .num_runs = 100 });

    std.debug.print("\nAll combinator and struct tests passed!\n", .{});
}
