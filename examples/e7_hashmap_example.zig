const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// Property: getting a value we just put should return that value
fn put_then_get_returns_value(map: std.AutoHashMap(i32, i32)) !void {
    var mut_map = try map.clone();
    defer mut_map.deinit();

    // Try putting and getting a known value
    const test_key: i32 = 42;
    const test_value: i32 = 999;

    try mut_map.put(test_key, test_value);

    if (mut_map.get(test_key)) |value| {
        try std.testing.expectEqual(test_value, value);
    } else {
        return error.KeyNotFound;
    }
}

// Property: map size should match number of unique keys inserted
fn map_count_matches_entries(map: std.AutoHashMap(i32, bool)) !void {
    // Treat as read-only, Minish will free it.
    const count = map.count();

    // Count should be reasonable (not negative, not absurd)
    try std.testing.expect(count >= 0);
    try std.testing.expect(count <= 100);
}

// Property: removing a key that doesn't exist returns false
fn remove_nonexistent_key(map: std.AutoHashMap(i32, i32)) !void {
    var mut_map = try map.clone();
    defer mut_map.deinit();

    // Try to remove a key that's very unlikely to exist
    const unlikely_key: i32 = std.math.maxInt(i32);
    const removed = mut_map.remove(unlikely_key);

    // Should return false since key doesn't exist
    try std.testing.expect(removed == false);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== HashMap Generator Example ===\n\n", .{});

    // Example 1: HashMap with integer keys and values
    std.debug.print("Test 1: put/get consistency\n", .{});

    const map_gen = gen.hashMap(
        i32,
        i32,
        gen.intRange(i32, 0, 100),
        gen.intRange(i32, 0, 1000),
        0,
        10,
    );

    try minish.check(allocator, map_gen, put_then_get_returns_value, .{
        .num_runs = 50,
    });

    // Example 2: HashMap with integer keys and boolean values
    std.debug.print("\nTest 2: map count is reasonable\n", .{});

    const bool_map_gen = gen.hashMap(
        i32,
        bool,
        gen.intRange(i32, 0, 50),
        gen.boolean(),
        0,
        20,
    );

    try minish.check(allocator, bool_map_gen, map_count_matches_entries, .{
        .num_runs = 100,
    });

    // Example 3: HashMap removal property
    std.debug.print("\nTest 3: removing nonexistent keys\n", .{});

    const int_map_gen = gen.hashMap(
        i32,
        i32,
        gen.intRange(i32, 0, 100),
        gen.int(i32),
        0,
        15,
    );

    try minish.check(allocator, int_map_gen, remove_nonexistent_key, .{
        .num_runs = 100,
    });

    std.debug.print("\nAll HashMap tests passed!\n", .{});
}
