const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// Helper function to reverse a string
fn reverse(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const len = s.len;
    const buf = try allocator.alloc(u8, len);
    for (s, 0..) |char, i| {
        buf[len - 1 - i] = char;
    }
    return buf;
}

// Property: reversing a string twice should give the original string
fn reverse_twice_is_identity(str: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const once = try reverse(allocator, str);
    defer allocator.free(once);

    const twice = try reverse(allocator, once);
    defer allocator.free(twice);

    try std.testing.expectEqualStrings(str, twice);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== String Generator Example ===\n", .{});
    std.debug.print("Testing property: reverse(reverse(s)) == s\n\n", .{});

    // Create a string generator with alphanumeric characters
    const string_gen = gen.string(.{
        .min_len = 0,
        .max_len = 50,
        .charset = .alphanumeric,
    });

    try minish.check(allocator, string_gen, reverse_twice_is_identity, .{ .num_runs = 100 });

    std.debug.print("\nAll tests passed!\n", .{});
}
