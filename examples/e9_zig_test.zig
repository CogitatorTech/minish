const std = @import("std");
const minish = @import("minish");

fn reverseTwiceIsIdentity(value: []const u8) !void {
    const copy = try std.testing.allocator.dupe(u8, value);
    defer std.testing.allocator.free(copy);
    std.mem.reverse(u8, copy);
    std.mem.reverse(u8, copy);
    try std.testing.expectEqualStrings(value, copy);
}

test "Minish properties run inside Zig tests" {
    try minish.check(std.testing.allocator, minish.gen.string(.{
        .min_len = 0,
        .max_len = 64,
        .charset = .alphanumeric,
    }), reverseTwiceIsIdentity, .{ .seed = 42, .num_runs = 100 });
}

fn shortListsOnly(values: []const i32) !void {
    if (values.len >= 3) return error.TooManyItems;
}

test "property failures propagate to Zig tests after shrinking" {
    var statistics: minish.Statistics = .{};
    // This property is intentionally false; expectError keeps the example passing.
    try std.testing.expectError(error.TooManyItems, minish.check(
        std.testing.allocator,
        minish.gen.list(i32, minish.gen.intRange(i32, 0, 100), 0, 8),
        shortListsOnly,
        .{ .seed = 42, .num_runs = 100, .statistics = &statistics },
    ));
    try std.testing.expectEqual(@as(u64, 42), statistics.seed);
    try std.testing.expectEqual(statistics.passed + 1, statistics.runs);
    try std.testing.expect(statistics.shrink_attempts > 0);
    try std.testing.expect(statistics.successful_shrinks > 0);
}
