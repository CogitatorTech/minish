const std = @import("std");

pub const gen = @import("minish/gen.zig");
pub const check = @import("minish/runner.zig").check;
pub const Options = @import("minish/runner.zig").Options;

test "Public API Sanity Check" {
    try std.testing.expect(@TypeOf(gen) == type);
    try std.testing.expect(@typeInfo(@TypeOf(check)) == .@"fn");
    try std.testing.expect(@TypeOf(Options) == type);
}
