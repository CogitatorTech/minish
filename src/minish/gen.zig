const std = @import("std");
const core = @import("core.zig");
const shrink_mod = @import("shrink.zig");

const TestCase = core.TestCase;

pub fn Generator(comptime T: type) type {
    return struct {
        generateFn: *const fn (tc: *TestCase) core.GenError!T,
        shrinkFn: ?*const fn (T) shrink_mod.Iterator(T),
    };
}

fn generate_int(tc: *TestCase) core.GenError!i32 {
    const val = try tc.choice(std.math.maxInt(i32));
    const sign = if (try tc.choice(1) == 0) @as(i32, -1) else @as(i32, 1);
    return @as(i32, @intCast(val)) * sign;
}

pub fn int(comptime T: type) Generator(T) {
    return .{ .generateFn = generate_int, .shrinkFn = shrink_mod.int };
}

fn generate_bool(tc: *TestCase) core.GenError!bool {
    return (try tc.choice(1)) == 1;
}

pub fn boolean() Generator(bool) {
    return .{ .generateFn = generate_bool, .shrinkFn = null };
}

pub fn list(comptime T: type, element_gen: Generator(T), len_range: anytype) Generator([]const T) {
    const ListGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![]const T {
            const len = len_range.start + (try tc.choice(len_range.end - len_range.start));
            var result = std.ArrayList(T).init(tc.allocator);
            errdefer result.deinit();
            for (0..len) |_| {
                try result.append(try element_gen.generateFn(tc));
            }
            return result.toOwnedSlice();
        }
    };
    return .{ .generateFn = ListGenerator.generate, .shrinkFn = null };
}

pub fn constant(comptime value: anytype) Generator(@TypeOf(value)) {
    const ConstantGenerator = struct {
        fn generate(_: *TestCase) !@TypeOf(value) {
            return value;
        }
    };
    return .{ .generateFn = ConstantGenerator.generate, .shrinkFn = null };
}

fn generate_tuple(tc: *TestCase) core.GenError!struct { i32, i32 } {
    return .{
        try generate_int(tc),
        try generate_int(tc),
    };
}

pub fn tuple() Generator(struct { i32, i32 }) {
    return .{ .generateFn = generate_tuple, .shrinkFn = null };
}
