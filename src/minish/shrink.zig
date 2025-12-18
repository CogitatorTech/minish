const std = @import("std");

// ============================================================================
// Type-Safe Iterator Interface
// ============================================================================

/// A generic shrinking iterator that maintains type safety through comptime.
/// The old design used *anyopaque which required unsafe casts.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        nextFn: *const fn (ctx: *anyopaque) ?T,
        deinitFn: ?*const fn (ctx: *anyopaque) void,

        pub fn next(self: *Self) ?T {
            return self.nextFn(self.context);
        }

        pub fn deinit(self: *Self) void {
            if (self.deinitFn) |deinitFunc| {
                deinitFunc(self.context);
            }
        }
    };
}

// ============================================================================
// Integer Shrinking
// ============================================================================

fn IntShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        val: T,
        target: T,
        diff: T,
    };
}

fn makeIntShrinkNext(comptime T: type) *const fn (*anyopaque) ?T {
    return struct {
        fn next(ctx: *anyopaque) ?T {
            const context: *IntShrinkContext(T) = @ptrCast(@alignCast(ctx));
            if (context.diff == 0) return null;

            // Move value towards target
            const result = if (context.val > context.target)
                context.val - context.diff
            else
                context.val + context.diff;

            context.val = result;
            context.diff = @divTrunc(context.diff, 2);
            return result;
        }
    }.next;
}

fn makeIntShrinkDeinit(comptime T: type) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *IntShrinkContext(T) = @ptrCast(@alignCast(ctx));
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink an integer value towards a target (default 0) using binary search.
/// Works with any signed or unsigned integer type.
pub fn int(comptime T: type, allocator: std.mem.Allocator, value: T) Iterator(T) {
    return intTowards(T, allocator, value, 0);
}

/// Shrink an integer value towards a specific target using binary search.
pub fn intTowards(comptime T: type, allocator: std.mem.Allocator, value: T, target: T) Iterator(T) {
    const Context = IntShrinkContext(T);
    const context = allocator.create(Context) catch unreachable;

    // Calculate initial diff (distance to target, halved)
    const diff = if (value > target)
        @divTrunc(value - target, 2)
    else if (value < target)
        @divTrunc(target - value, 2)
    else
        0;

    context.* = .{
        .allocator = allocator,
        .val = value,
        .target = target,
        .diff = diff,
    };

    return .{
        .context = context,
        .nextFn = makeIntShrinkNext(T),
        .deinitFn = makeIntShrinkDeinit(T),
    };
}

/// Wrapper for generators - returns a shrink function with the right signature.
pub fn intShrinker(comptime T: type) *const fn (std.mem.Allocator, T) Iterator(T) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: T) Iterator(T) {
            return int(T, allocator, value);
        }
    }.shrink;
}

// ============================================================================
// Float Shrinking
// ============================================================================

fn FloatShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        val: T,
        target: T,
        diff: T,
    };
}

fn makeFloatShrinkNext(comptime T: type) *const fn (*anyopaque) ?T {
    return struct {
        fn next(ctx: *anyopaque) ?T {
            const context: *FloatShrinkContext(T) = @ptrCast(@alignCast(ctx));

            // Stop when diff is very small
            if (@abs(context.diff) < 1e-10) return null;

            // Move value towards target
            const result = if (context.val > context.target)
                context.val - context.diff
            else
                context.val + context.diff;

            context.val = result;
            context.diff = context.diff / 2.0;
            return result;
        }
    }.next;
}

fn makeFloatShrinkDeinit(comptime T: type) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *FloatShrinkContext(T) = @ptrCast(@alignCast(ctx));
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink a float value towards 0.0 using binary search.
pub fn float(comptime T: type, allocator: std.mem.Allocator, value: T) Iterator(T) {
    return floatTowards(T, allocator, value, 0.0);
}

/// Shrink a float value towards a specific target.
pub fn floatTowards(comptime T: type, allocator: std.mem.Allocator, value: T, target: T) Iterator(T) {
    const Context = FloatShrinkContext(T);
    const context = allocator.create(Context) catch unreachable;

    // Calculate initial diff
    const diff = if (value > target)
        (value - target) / 2.0
    else
        (target - value) / 2.0;

    context.* = .{
        .allocator = allocator,
        .val = value,
        .target = target,
        .diff = diff,
    };

    return .{
        .context = context,
        .nextFn = makeFloatShrinkNext(T),
        .deinitFn = makeFloatShrinkDeinit(T),
    };
}

/// Wrapper for generators - returns a shrink function with the right signature.
pub fn floatShrinker(comptime T: type) *const fn (std.mem.Allocator, T) Iterator(T) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: T) Iterator(T) {
            return float(T, allocator, value);
        }
    }.shrink;
}

// ============================================================================
// List Shrinking (Type-Safe)
// ============================================================================

fn ListShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        original: []const T,
        current_len: usize,
        remove_count: usize,
        phase: Phase,
        // Track allocated slices for cleanup
        last_result: ?[]T,

        const Phase = enum { RemoveChunks, RemoveOne, Done };
    };
}

fn makeListShrinkNext(comptime T: type) *const fn (*anyopaque) ?[]const T {
    return struct {
        fn next(ctx: *anyopaque) ?[]const T {
            const context: *ListShrinkContext(T) = @ptrCast(@alignCast(ctx));

            // Free the previous result if any
            if (context.last_result) |prev| {
                context.allocator.free(prev);
                context.last_result = null;
            }

            while (true) {
                switch (context.phase) {
                    .RemoveChunks => {
                        if (context.remove_count > context.current_len) {
                            context.phase = .RemoveOne;
                            context.remove_count = 1;
                            continue;
                        }

                        if (context.remove_count == 0) {
                            context.phase = .Done;
                            return null;
                        }

                        const new_len = context.current_len - context.remove_count;
                        if (new_len == 0) {
                            context.remove_count /= 2;
                            continue;
                        }

                        // Create shrunken list by removing elements from the end
                        const shrunken = context.allocator.alloc(T, new_len) catch return null;
                        @memcpy(shrunken, context.original[0..new_len]);

                        context.current_len = new_len;
                        context.remove_count /= 2;
                        context.last_result = shrunken;

                        return shrunken;
                    },
                    .RemoveOne => {
                        if (context.current_len <= 1) {
                            context.phase = .Done;
                            return null;
                        }

                        const new_len = context.current_len - 1;
                        const shrunken = context.allocator.alloc(T, new_len) catch return null;
                        @memcpy(shrunken, context.original[0..new_len]);

                        context.current_len = new_len;

                        if (new_len <= 1) {
                            context.phase = .Done;
                        }

                        context.last_result = shrunken;
                        return shrunken;
                    },
                    .Done => return null,
                }
            }
        }
    }.next;
}

fn makeListShrinkDeinit(comptime T: type) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *ListShrinkContext(T) = @ptrCast(@alignCast(ctx));
            // Free any remaining allocated slice
            if (context.last_result) |prev| {
                context.allocator.free(prev);
            }
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink a list by progressively removing elements.
/// Uses binary search on removal count, then single element removal.
pub fn list(comptime T: type, allocator: std.mem.Allocator, value: []const T) Iterator([]const T) {
    const Context = ListShrinkContext(T);
    const context = allocator.create(Context) catch unreachable;

    context.* = .{
        .allocator = allocator,
        .original = value,
        .current_len = value.len,
        .remove_count = value.len / 2,
        .phase = if (value.len == 0) .Done else .RemoveChunks,
        .last_result = null,
    };

    return .{
        .context = context,
        .nextFn = makeListShrinkNext(T),
        .deinitFn = makeListShrinkDeinit(T),
    };
}

// ============================================================================
// String Shrinking
// ============================================================================

/// Shrink a string by progressively removing characters.
/// This is a specialized version of list shrinking for u8.
pub fn string(allocator: std.mem.Allocator, value: []const u8) Iterator([]const u8) {
    return list(u8, allocator, value);
}

/// Wrapper for generators - returns a shrink function with the right signature.
pub fn listShrinker(comptime T: type) *const fn (std.mem.Allocator, []const T) Iterator([]const T) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: []const T) Iterator([]const T) {
            return list(T, allocator, value);
        }
    }.shrink;
}

/// Wrapper for string generators.
pub fn stringShrinker() *const fn (std.mem.Allocator, []const u8) Iterator([]const u8) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: []const u8) Iterator([]const u8) {
            return string(allocator, value);
        }
    }.shrink;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "int shrinking moves values towards zero" {
    const allocator = testing.allocator;

    var it = int(i32, allocator, 100);
    defer it.deinit();

    var prev: i32 = 100;
    var count: usize = 0;
    while (it.next()) |val| {
        // Values should move closer to zero (target)
        try testing.expect(@abs(val) <= @abs(prev));
        prev = val;
        count += 1;
        if (count > 20) break; // Safety limit
    }
    try testing.expect(count > 0);
}

test "int shrinking with different integer types" {
    const allocator = testing.allocator;

    // Test u8
    {
        var it = int(u8, allocator, 200);
        defer it.deinit();
        const first = it.next();
        try testing.expect(first != null);
        try testing.expect(first.? < 200);
    }

    // Test i64
    {
        var it = int(i64, allocator, 1000000);
        defer it.deinit();
        const first = it.next();
        try testing.expect(first != null);
        try testing.expect(first.? < 1000000);
    }
}

test "list shrinking produces shorter lists" {
    const allocator = testing.allocator;

    const original = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var it = list(i32, allocator, &original);
    defer it.deinit();

    var prev_len: usize = original.len;
    var count: usize = 0;
    while (it.next()) |shrunk| {
        try testing.expect(shrunk.len < prev_len);
        prev_len = shrunk.len;
        count += 1;
        if (count > 20) break; // Safety limit
    }
    try testing.expect(count > 0);
}

test "list shrinking with empty list returns null immediately" {
    const allocator = testing.allocator;

    const empty = [_]i32{};
    var it = list(i32, allocator, &empty);
    defer it.deinit();

    try testing.expect(it.next() == null);
}

test "list shrinking with single element" {
    const allocator = testing.allocator;

    const single = [_]i32{42};
    var it = list(i32, allocator, &single);
    defer it.deinit();

    // May or may not produce results depending on implementation
    // but should not crash
    _ = it.next();
}

test "string shrinking produces shorter strings" {
    const allocator = testing.allocator;

    const original = "hello world";
    var it = string(allocator, original);
    defer it.deinit();

    var prev_len: usize = original.len;
    var count: usize = 0;
    while (it.next()) |shrunk| {
        try testing.expect(shrunk.len < prev_len);
        prev_len = shrunk.len;
        count += 1;
        if (count > 20) break; // Safety limit
    }
    try testing.expect(count > 0);
}

test "string shrinking with empty string" {
    const allocator = testing.allocator;

    var it = string(allocator, "");
    defer it.deinit();

    try testing.expect(it.next() == null);
}

test "float shrinking moves towards zero" {
    const allocator = testing.allocator;

    var it = float(f64, allocator, 100.0);
    defer it.deinit();

    var prev: f64 = 100.0;
    var count: usize = 0;
    while (it.next()) |val| {
        try testing.expect(@abs(val) <= @abs(prev));
        prev = val;
        count += 1;
        if (count > 30) break; // Safety limit
    }
    try testing.expect(count > 0);
}

test "float shrinking with f32" {
    const allocator = testing.allocator;

    var it = float(f32, allocator, -50.0);
    defer it.deinit();

    const first = it.next();
    try testing.expect(first != null);
    try testing.expect(@abs(first.?) < 50.0);
}
