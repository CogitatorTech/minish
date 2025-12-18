const std = @import("std");

pub const version = "0.1.0";

pub const gen = @import("minish/gen.zig");
pub const combinators = @import("minish/combinators.zig");
pub const TestCase = @import("minish/core.zig").TestCase;
pub const check = @import("minish/runner.zig").check;
pub const Options = @import("minish/runner.zig").Options;

// Backwards compatibility alias
pub const run = check;

test "Public API Sanity Check" {
    // Verify modules are accessible and are struct types (namespaces)
    // gen and combinators are types (struct types), so use @typeInfo directly
    try std.testing.expect(@typeInfo(gen) == .@"struct");
    try std.testing.expect(@typeInfo(combinators) == .@"struct");
    try std.testing.expect(@typeInfo(@TypeOf(check)) == .@"fn");
    try std.testing.expect(@TypeOf(Options) == type);
    try std.testing.expect(@TypeOf(TestCase) == type);
    try std.testing.expectEqualStrings("0.1.0", version);
}
