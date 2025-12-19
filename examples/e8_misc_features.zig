const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;
const combinators = minish.combinators;

// ============================================================================
// Misc Features Example
// ============================================================================
// This example showcases features not covered in other examples:
// 1. oneOf (Choice generator)
// 2. dependent (Monadic-like sequencing)
// 3. timestamps
// 4. enums

// 1. oneOf: Generate values from mixed sources
fn test_mixed_integers(val: i32) !void {
    // We expect either small ints (0-10) or a specific large constant (1000)
    const is_small = (val >= 0 and val <= 10);
    const is_large = (val == 1000);
    try std.testing.expect(is_small or is_large);
}

// 2. dependent: Generate a boolean, then use it to select a generator
// Dependent generator creates a struct { T, U }
fn test_dependent_logic(pair: struct { bool, i32 }) !void {
    const is_pos = pair[0];
    const val = pair[1];

    if (is_pos) {
        try std.testing.expect(val > 0);
    } else {
        try std.testing.expect(val < 0);
    }
}

// 3. Timestamp generator
fn test_timestamp_range(ts: i64) !void {
    // Check it's within our requested 1-hour window
    // 1672531200 = 2023-01-01 00:00:00 UTC
    // 1672534800 = 2023-01-01 01:00:00 UTC
    try std.testing.expect(ts >= 1672531200);
    try std.testing.expect(ts <= 1672534800);
}

// 4. Enum generator
const Color = enum { Red, Green, Blue };
fn test_enum_colors(c: Color) !void {
    switch (c) {
        .Red, .Green, .Blue => {}, // All valid
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Misc Features Example ===\n\n", .{});

    // 1. oneOf
    std.debug.print("Test 1: oneOf (mixed ranges)\n", .{});
    const mixed_gen = gen.oneOf(i32, &.{
        gen.intRange(i32, 0, 10),
        gen.constant(@as(i32, 1000)),
    });
    try minish.check(allocator, mixed_gen, test_mixed_integers, .{ .num_runs = 50 });

    // 2. dependent
    // Note: dependent is limited to branching/selection logic for runtime values,
    // as Minish generators cannot easily capture runtime state in closures.
    std.debug.print("\nTest 2: dependent (bool -> branching logic)\n", .{});
    const Dep = struct {
        const bool_gen = gen.boolean();
        const make_int_gen = struct {
            fn make(b: bool) gen.Generator(i32) {
                if (b) {
                    return gen.intRange(i32, 1, 100);
                } else {
                    return gen.intRange(i32, -100, -1);
                }
            }
        }.make;
        const dep_gen = gen.dependent(bool, i32, bool_gen, make_int_gen);
    };
    try minish.check(allocator, Dep.dep_gen, test_dependent_logic, .{ .num_runs = 50 });

    // 3. Timestamps
    std.debug.print("\nTest 3: Timestamp (1 hour range)\n", .{});
    const ts_gen = gen.timestampRange(1672531200, 1672534800);
    try minish.check(allocator, ts_gen, test_timestamp_range, .{ .num_runs = 50 });

    // 4. Enums
    std.debug.print("\nTest 4: Enums\n", .{});
    const enum_gen = gen.enumValue(Color);
    try minish.check(allocator, enum_gen, test_enum_colors, .{ .num_runs = 50 });

    std.debug.print("\nAll misc feature tests passed!\n", .{});
}
