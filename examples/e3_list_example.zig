const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// Property: sorting a list twice gives the same result as sorting once
fn sort_is_idempotent(list: []const i32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Make a copy for first sort
    const copy1 = try allocator.dupe(i32, list);
    defer allocator.free(copy1);
    std.mem.sort(i32, copy1, {}, comptime std.sort.asc(i32));

    // Make a copy for second sort
    const copy2 = try allocator.dupe(i32, copy1);
    defer allocator.free(copy2);
    std.mem.sort(i32, copy2, {}, comptime std.sort.asc(i32));

    try std.testing.expectEqualSlices(i32, copy1, copy2);
}

// Property: sorted list should be in ascending order
fn sorted_list_is_ordered(list: []const i32) !void {
    if (list.len <= 1) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sorted = try allocator.dupe(i32, list);
    defer allocator.free(sorted);
    std.mem.sort(i32, sorted, {}, comptime std.sort.asc(i32));

    for (0..sorted.len - 1) |i| {
        if (sorted[i] > sorted[i + 1]) {
            std.debug.print("Not ordered at index {d}: {d} > {d}\n", .{ i, sorted[i], sorted[i + 1] });
            return error.NotOrdered;
        }
    }
}

// Property: sorted list should have the same length as original
fn sort_preserves_length(list: []const i32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_len = list.len;
    const sorted = try allocator.dupe(i32, list);
    defer allocator.free(sorted);
    std.mem.sort(i32, sorted, {}, comptime std.sort.asc(i32));

    try std.testing.expectEqual(original_len, sorted.len);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== List Generator Example ===\n", .{});
    std.debug.print("Testing multiple properties of sorting\n\n", .{});

    // Create a list generator with i32 elements
    const list_gen = gen.list(i32, gen.int(i32), 0, 100);

    std.debug.print("Property 1: sort(sort(list)) == sort(list)\n", .{});
    try minish.check(allocator, list_gen, sort_is_idempotent, .{ .num_runs = 100 });

    std.debug.print("\nProperty 2: sorted list is in ascending order\n", .{});
    try minish.check(allocator, list_gen, sorted_list_is_ordered, .{ .num_runs = 100 });

    std.debug.print("\nProperty 3: sorting preserves length\n", .{});
    try minish.check(allocator, list_gen, sort_preserves_length, .{ .num_runs = 100 });

    std.debug.print("\nAll properties verified!\n", .{});
}
