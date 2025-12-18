const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// ============================================================================
// Shrinking Demonstration
// ============================================================================
// This example demonstrates minish's shrinking capabilities.
// When a property fails, minish automatically finds minimal counterexamples.

// Property 1: Sum greater than 1000 fails
// Shows how tuple shrinking minimizes both values
fn sum_below_1000(tuple: struct { i32, i32 }) !void {
    const a = tuple[0];
    const b = tuple[1];
    const sum = a +| b; // Wrapping add to avoid overflow

    if (a > 0 and b > 0 and sum > 1000) {
        return error.SumTooLarge;
    }
}

// Property 2: List length must be under 5
// Shows how list shrinking finds minimal failing list
fn list_too_short(items: []const i32) !void {
    if (items.len >= 5) {
        return error.ListTooLong;
    }
}

// Property 3: String contains forbidden character
// Shows how string shrinking minimizes the failing string
fn no_letter_x(s: []const u8) !void {
    for (s) |c| {
        if (c == 'x' or c == 'X') {
            return error.FoundForbiddenChar;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Shrinking Demonstration ===\n\n", .{});

    // Demo 1: Tuple Shrinking
    std.debug.print("Demo 1: Tuple Shrinking\n", .{});
    std.debug.print("Property: a + b <= 1000 for positive a, b\n", .{});
    std.debug.print("Watch how the failing input is minimized:\n\n", .{});

    const tuple_gen = gen.tuple();
    _ = minish.check(allocator, tuple_gen, sum_below_1000, .{ .num_runs = 100 }) catch |err| {
        std.debug.print("\nProperty failed with: {s}\n", .{@errorName(err)});
        std.debug.print("The shrinker found a minimal counterexample!\n\n", .{});
    };

    // Demo 2: List Shrinking
    std.debug.print("Demo 2: List Shrinking\n", .{});
    std.debug.print("Property: list.len < 5\n", .{});
    std.debug.print("Watch how the failing list is minimized:\n\n", .{});

    const list_gen = gen.list(i32, gen.int(i32), 0, 20);
    _ = minish.check(allocator, list_gen, list_too_short, .{ .num_runs = 100 }) catch |err| {
        std.debug.print("\nProperty failed with: {s}\n", .{@errorName(err)});
        std.debug.print("The shrinker found a minimal list!\n\n", .{});
    };

    // Demo 3: String Shrinking
    std.debug.print("Demo 3: String Shrinking\n", .{});
    std.debug.print("Property: string contains no 'x' or 'X'\n", .{});
    std.debug.print("Watch how the failing string is minimized:\n\n", .{});

    const string_gen = gen.string(.{
        .min_len = 1,
        .max_len = 50,
        .charset = .alphanumeric,
    });
    _ = minish.check(allocator, string_gen, no_letter_x, .{ .num_runs = 200 }) catch |err| {
        std.debug.print("\nProperty failed with: {s}\n", .{@errorName(err)});
        std.debug.print("The shrinker found the minimal string containing 'x'!\n\n", .{});
    };

    std.debug.print("=== Shrinking Demo Complete ===\n", .{});
}
