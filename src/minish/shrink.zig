//! Shrinking strategies for finding minimal failing inputs.
//!
//! When a property test fails, shrinking tries to find the smallest input
//! that still causes the failure. This makes debugging much easier.
//!
//! Strategies:
//! - **Integers/Floats**: Uses binary search to efficiently find the boundary between
//!   passing and failing values. This guarantees finding the minimal failure
//!   (e.g., finding 9 if the failure is > 8).
//! - **Collections**: Removes elements from the beginning, end, or middle to reduce size.
//!
//! Each shrinker produces an `Iterator` of progressively smaller values.
//! The test runner tries each candidate until no smaller failing input exists.

const std = @import("std");

// ============================================================================
// Type-Safe Iterator Interface
// ============================================================================

/// A generic shrinking iterator that maintains type safety through comptime.
/// The old design used *anyopaque which required unsafe casts.
pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();
        context: ?*anyopaque,
        nextFn: *const fn (ctx: *anyopaque) ?T,
        deinitFn: ?*const fn (ctx: *anyopaque) void,

        pub fn next(self: *Self) ?T {
            if (self.context) |ctx| {
                return self.nextFn(ctx);
            }
            return null;
        }

        pub fn deinit(self: *Self) void {
            if (self.context) |ctx| {
                if (self.deinitFn) |deinitFunc| {
                    deinitFunc(ctx);
                }
            }
        }

        /// Create an empty iterator that returns null immediately.
        /// Used as a fallback when allocation fails.
        pub fn empty() Self {
            return .{
                .context = null,
                .nextFn = struct {
                    fn noOp(_: *anyopaque) ?T {
                        return null;
                    }
                }.noOp,
                .deinitFn = null,
            };
        }
    };
}

// ============================================================================
// Integer Shrinking
// ============================================================================

fn IntShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        failing_bound: T, // The original failing value (bad)
        current_bound: T, // The current "safe" value (good) (starts at target usually)
        last_tried: T, // The last value returned by next()
        first_call: bool,
    };
}

fn makeIntShrinkNext(comptime T: type) *const fn (*anyopaque) ?T {
    return struct {
        fn next(ctx: *anyopaque) ?T {
            const context: *IntShrinkContext(T) = @ptrCast(@alignCast(ctx));

            // If we are called, it means the *previous* value passed the test (was not a failure).
            // So the previous value is our new "safe" bound.
            // UNLESS this is the very first call (indicated by first_call flag).

            if (!context.first_call) {
                context.current_bound = context.last_tried;
            }
            context.first_call = false;

            // We search between current_bound (safe) and failing_bound (known failure).
            // Calculate mid point.

            // Check if bounds are adjacent or same
            const dist = if (context.failing_bound > context.current_bound)
                context.failing_bound - context.current_bound
            else
                context.current_bound - context.failing_bound;

            if (dist < 2) return null;

            const half_dist = @divTrunc(dist, 2);

            const next_val = if (context.failing_bound > context.current_bound)
                context.current_bound + half_dist
            else
                context.current_bound - half_dist;

            // If we generated the same value again (due to truncation), stop.
            if (next_val == context.current_bound or next_val == context.failing_bound) return null;
            if (next_val == context.last_tried) return null;

            context.last_tried = next_val;
            return next_val;
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
    const context = allocator.create(Context) catch return Iterator(T).empty();

    context.* = .{
        .allocator = allocator,
        .failing_bound = value,
        .current_bound = target,
        .last_tried = target, // Doesn't matter, just init
        .first_call = true,
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
        failing_bound: T,
        current_bound: T,
        last_tried: T,
        first_call: bool,
    };
}

fn makeFloatShrinkNext(comptime T: type) *const fn (*anyopaque) ?T {
    return struct {
        fn next(ctx: *anyopaque) ?T {
            const context: *FloatShrinkContext(T) = @ptrCast(@alignCast(ctx));

            if (!context.first_call) {
                context.current_bound = context.last_tried;
            }
            context.first_call = false;

            const diff = if (context.failing_bound > context.current_bound)
                context.failing_bound - context.current_bound
            else
                context.current_bound - context.failing_bound;

            if (diff < 1e-10) return null; // Precision limit

            const next_val = if (context.failing_bound > context.current_bound)
                context.current_bound + (diff / 2.0)
            else
                context.current_bound - (diff / 2.0);

            // Check for stagnation due to float precision
            if (next_val == context.current_bound or next_val == context.failing_bound) return null;

            context.last_tried = next_val;
            return next_val;
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
    const context = allocator.create(Context) catch return Iterator(T).empty();

    context.* = .{
        .allocator = allocator,
        .failing_bound = value,
        .current_bound = target,
        .last_tried = target,
        .first_call = true,
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
// List Shrinking (Type-Safe) - Improved
// ============================================================================

fn ListShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        original: []const T,
        current_len: usize,
        remove_count: usize,
        remove_pos: usize,
        phase: Phase,

        const Phase = enum {
            TryEmpty, // First try returning empty list
            RemoveFromEnd, // Remove chunks from end (binary search)
            RemoveFromStart, // Remove chunks from start (binary search)
            RemoveOneAt, // Remove single element at each position
            Done,
        };
    };
}

fn makeListShrinkNext(comptime T: type) *const fn (*anyopaque) ?[]const T {
    return struct {
        fn next(ctx: *anyopaque) ?[]const T {
            const context: *ListShrinkContext(T) = @ptrCast(@alignCast(ctx));

            // Note: The runner handles memory management via freeFn
            // so we don't track last_result here

            while (true) {
                switch (context.phase) {
                    .TryEmpty => {
                        context.phase = .RemoveFromEnd;
                        // Return empty list as first shrink attempt
                        const shrunken = context.allocator.alloc(T, 0) catch return null;
                        return shrunken;
                    },
                    .RemoveFromEnd => {
                        if (context.remove_count == 0) {
                            // Move to next phase
                            context.phase = .RemoveFromStart;
                            context.remove_count = context.original.len / 2;
                            context.current_len = context.original.len; // Reset for next phase
                            continue;
                        }

                        if (context.remove_count > context.current_len) {
                            context.remove_count /= 2;
                            continue;
                        }

                        const new_len = context.current_len - context.remove_count;
                        if (new_len == 0) {
                            context.remove_count /= 2;
                            continue;
                        }

                        // Remove from end: keep first new_len elements
                        const shrunken = context.allocator.alloc(T, new_len) catch return null;
                        @memcpy(shrunken, context.original[0..new_len]);

                        context.current_len = new_len;
                        context.remove_count /= 2;

                        return shrunken;
                    },
                    .RemoveFromStart => {
                        if (context.remove_count == 0) {
                            // Move to next phase
                            context.phase = .RemoveOneAt;
                            context.remove_pos = 0;
                            context.current_len = context.original.len;
                            continue;
                        }

                        if (context.remove_count > context.current_len) {
                            context.remove_count /= 2;
                            continue;
                        }

                        const new_len = context.current_len - context.remove_count;
                        if (new_len == 0) {
                            context.remove_count /= 2;
                            continue;
                        }

                        // Remove from start: skip first remove_count elements
                        const shrunken = context.allocator.alloc(T, new_len) catch return null;
                        @memcpy(shrunken, context.original[context.remove_count..context.current_len]);

                        context.current_len = new_len;
                        context.remove_count /= 2;

                        return shrunken;
                    },
                    .RemoveOneAt => {
                        if (context.remove_pos >= context.original.len or context.original.len <= 1) {
                            context.phase = .Done;
                            return null;
                        }

                        const new_len = context.original.len - 1;
                        const shrunken = context.allocator.alloc(T, new_len) catch return null;

                        // Copy elements before remove_pos
                        if (context.remove_pos > 0) {
                            @memcpy(shrunken[0..context.remove_pos], context.original[0..context.remove_pos]);
                        }
                        // Copy elements after remove_pos
                        if (context.remove_pos < new_len) {
                            @memcpy(shrunken[context.remove_pos..], context.original[context.remove_pos + 1 ..]);
                        }

                        context.remove_pos += 1;

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
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

pub fn list(comptime T: type, allocator: std.mem.Allocator, value: []const T) Iterator([]const T) {
    const Context = ListShrinkContext(T);
    const context = allocator.create(Context) catch return Iterator([]const T).empty();

    context.* = .{
        .allocator = allocator,
        .original = value,
        .current_len = value.len,
        .remove_count = value.len / 2,
        .remove_pos = 0,
        .phase = if (value.len == 0) .Done else .TryEmpty,
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
// Array Shrinking
// ============================================================================

fn ArrayShrinkContext(comptime T: type, comptime size: usize) type {
    return struct {
        allocator: std.mem.Allocator,
        original: [size]T,
        current_idx: usize,
        element_iterator: ?Iterator(T),
        element_shrinker: ?*const fn (std.mem.Allocator, T) Iterator(T),
    };
}

fn makeArrayShrinkNext(comptime T: type, comptime size: usize) *const fn (*anyopaque) ?[size]T {
    return struct {
        fn next(ctx: *anyopaque) ?[size]T {
            const context: *ArrayShrinkContext(T, size) = @ptrCast(@alignCast(ctx));

            while (context.current_idx < size) {
                // Try to get next shrunk value for current element
                if (context.element_iterator) |*it| {
                    if (it.next()) |shrunk_elem| {
                        // Build new array with shrunk element at current position
                        var result = context.original;
                        result[context.current_idx] = shrunk_elem;
                        return result;
                    } else {
                        // Element iterator exhausted, move to next element
                        it.deinit();
                        context.element_iterator = null;
                    }
                }

                // Move to next element
                context.current_idx += 1;
                if (context.current_idx < size) {
                    if (context.element_shrinker) |shrinker| {
                        context.element_iterator = shrinker(context.allocator, context.original[context.current_idx]);
                    }
                }
            }

            return null;
        }
    }.next;
}

fn makeArrayShrinkDeinit(comptime T: type, comptime size: usize) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *ArrayShrinkContext(T, size) = @ptrCast(@alignCast(ctx));
            if (context.element_iterator) |*it| {
                it.deinit();
            }
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink a fixed-size array by shrinking each element independently.
pub fn array(
    comptime T: type,
    comptime size: usize,
    allocator: std.mem.Allocator,
    value: [size]T,
    element_shrinker: ?*const fn (std.mem.Allocator, T) Iterator(T),
) Iterator([size]T) {
    if (size == 0) return Iterator([size]T).empty();

    const Context = ArrayShrinkContext(T, size);
    const context = allocator.create(Context) catch return Iterator([size]T).empty();

    context.* = .{
        .allocator = allocator,
        .original = value,
        .current_idx = 0,
        .element_iterator = if (element_shrinker) |s| s(allocator, value[0]) else null,
        .element_shrinker = element_shrinker,
    };

    return .{
        .context = context,
        .nextFn = makeArrayShrinkNext(T, size),
        .deinitFn = makeArrayShrinkDeinit(T, size),
    };
}

/// Wrapper for array generators with int element shrinker.
pub fn arrayIntShrinker(comptime T: type, comptime size: usize) *const fn (std.mem.Allocator, [size]T) Iterator([size]T) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: [size]T) Iterator([size]T) {
            return array(T, size, allocator, value, intShrinker(T));
        }
    }.shrink;
}

// ============================================================================
// Optional Shrinking
// ============================================================================

fn OptionalShrinkContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        inner_value: T,
        tried_null: bool,
        done: bool,
        inner_iterator: ?Iterator(T),
    };
}

fn makeOptionalShrinkNext(comptime T: type) *const fn (*anyopaque) ??T {
    return struct {
        fn next(ctx: *anyopaque) ??T {
            const context: *OptionalShrinkContext(T) = @ptrCast(@alignCast(ctx));

            if (context.done) return null; // End of iteration (outer null)

            // First try null as a shrink candidate
            if (!context.tried_null) {
                context.tried_null = true;
                // Return ?T = null wrapped in outer optional
                // We return a "some" containing the value "null"
                return @as(?T, null);
            }

            // Then try shrinking the inner value
            if (context.inner_iterator) |*inner_it| {
                if (inner_it.next()) |shrunk_inner| {
                    return shrunk_inner;
                }
            }

            context.done = true;
            return null; // End of iteration (outer null)
        }
    }.next;
}

fn makeOptionalShrinkDeinit(comptime T: type) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *OptionalShrinkContext(T) = @ptrCast(@alignCast(ctx));
            if (context.inner_iterator) |*inner_it| {
                inner_it.deinit();
            }
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink an optional value. Tries null first, then shrinks the inner value.
pub fn optional(comptime T: type, allocator: std.mem.Allocator, value: ?T, inner_shrinker: ?*const fn (std.mem.Allocator, T) Iterator(T)) Iterator(?T) {
    const Context = OptionalShrinkContext(T);
    const context = allocator.create(Context) catch return Iterator(?T).empty();

    // If value is null, nothing to shrink
    if (value == null) {
        context.* = .{
            .allocator = allocator,
            .inner_value = undefined,
            .tried_null = true,
            .done = true,
            .inner_iterator = null,
        };
    } else {
        context.* = .{
            .allocator = allocator,
            .inner_value = value.?,
            .tried_null = false,
            .done = false,
            .inner_iterator = if (inner_shrinker) |shrinker| shrinker(allocator, value.?) else null,
        };
    }

    return .{
        .context = context,
        .nextFn = makeOptionalShrinkNext(T),
        .deinitFn = makeOptionalShrinkDeinit(T),
    };
}

// ============================================================================
// Tuple Shrinking
// ============================================================================

fn Tuple2ShrinkContext(comptime T1: type, comptime T2: type) type {
    return struct {
        allocator: std.mem.Allocator,
        original: struct { T1, T2 },
        it1: ?Iterator(T1),
        it2: ?Iterator(T2),
        phase: enum { ShrinkFirst, ShrinkSecond, Done },
    };
}

fn makeTuple2ShrinkNext(comptime T1: type, comptime T2: type) *const fn (*anyopaque) ?struct { T1, T2 } {
    return struct {
        fn next(ctx: *anyopaque) ?struct { T1, T2 } {
            const context: *Tuple2ShrinkContext(T1, T2) = @ptrCast(@alignCast(ctx));

            while (true) {
                switch (context.phase) {
                    .ShrinkFirst => {
                        if (context.it1) |*it| {
                            if (it.next()) |shrunk| {
                                return .{ shrunk, context.original[1] };
                            }
                        }
                        context.phase = .ShrinkSecond;
                        continue;
                    },
                    .ShrinkSecond => {
                        if (context.it2) |*it| {
                            if (it.next()) |shrunk| {
                                return .{ context.original[0], shrunk };
                            }
                        }
                        context.phase = .Done;
                        return null;
                    },
                    .Done => return null,
                }
            }
        }
    }.next;
}

fn makeTuple2ShrinkDeinit(comptime T1: type, comptime T2: type) *const fn (*anyopaque) void {
    return struct {
        fn deinitFn(ctx: *anyopaque) void {
            const context: *Tuple2ShrinkContext(T1, T2) = @ptrCast(@alignCast(ctx));
            if (context.it1) |*it| it.deinit();
            if (context.it2) |*it| it.deinit();
            context.allocator.destroy(context);
        }
    }.deinitFn;
}

/// Shrink a 2-tuple by shrinking each element independently.
pub fn tuple2(
    comptime T1: type,
    comptime T2: type,
    allocator: std.mem.Allocator,
    value: struct { T1, T2 },
    shrinker1: ?*const fn (std.mem.Allocator, T1) Iterator(T1),
    shrinker2: ?*const fn (std.mem.Allocator, T2) Iterator(T2),
) Iterator(struct { T1, T2 }) {
    const Context = Tuple2ShrinkContext(T1, T2);
    const context = allocator.create(Context) catch return Iterator(struct { T1, T2 }).empty();

    context.* = .{
        .allocator = allocator,
        .original = value,
        .it1 = if (shrinker1) |s| s(allocator, value[0]) else null,
        .it2 = if (shrinker2) |s| s(allocator, value[1]) else null,
        .phase = .ShrinkFirst,
    };

    return .{
        .context = context,
        .nextFn = makeTuple2ShrinkNext(T1, T2),
        .deinitFn = makeTuple2ShrinkDeinit(T1, T2),
    };
}

/// Wrapper for tuple2 generators with int shrinkers.
pub fn tuple2IntShrinker(comptime T1: type, comptime T2: type) *const fn (std.mem.Allocator, struct { T1, T2 }) Iterator(struct { T1, T2 }) {
    return struct {
        fn shrink(allocator: std.mem.Allocator, value: struct { T1, T2 }) Iterator(struct { T1, T2 }) {
            return tuple2(T1, T2, allocator, value, intShrinker(T1), intShrinker(T2));
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

    var count: usize = 0;
    while (it.next()) |val| {
        // With binary search, values might not be strictly monotonic if we assume "pass".
        // But they should be between target (0) and start (100).
        try testing.expect(val >= 0);
        try testing.expect(val <= 100);
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

    var count: usize = 0;
    var saw_empty = false;
    while (it.next()) |shrunk| {
        defer allocator.free(shrunk); // Free each shrunk value
        // All shrunk values should be shorter than original
        try testing.expect(shrunk.len < original.len);
        if (shrunk.len == 0) saw_empty = true;
        count += 1;
        if (count > 30) break; // Safety limit
    }
    try testing.expect(count > 0);
    // Should try empty list first
    try testing.expect(saw_empty);
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
    if (it.next()) |shrunk| {
        allocator.free(shrunk);
    }
}

test "string shrinking produces shorter strings" {
    const allocator = testing.allocator;

    const original = "hello world";
    var it = string(allocator, original);
    defer it.deinit();

    var count: usize = 0;
    var saw_empty = false;
    while (it.next()) |shrunk| {
        defer allocator.free(shrunk); // Free each shrunk value
        // All shrunk values should be shorter than original
        try testing.expect(shrunk.len < original.len);
        if (shrunk.len == 0) saw_empty = true;
        count += 1;
        if (count > 30) break; // Safety limit
    }
    try testing.expect(count > 0);
    // Should try empty string first
    try testing.expect(saw_empty);
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

    var count: usize = 0;
    while (it.next()) |val| {
        try testing.expect(val >= 0.0);
        try testing.expect(val <= 100.0);
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

// ============================================================================
// Regression Tests for Bug Fixes
// ============================================================================

test "regression: optional shrinking produces null as shrink candidate" {
    // Bug: Optional shrinking couldn't distinguish between "try null" and "end of iteration"
    // Both returned the same value, making it impossible to shrink to null.
    const allocator = testing.allocator;

    // Shrink an optional with value 100
    var it = optional(i32, allocator, @as(?i32, 100), intShrinker(i32));
    defer it.deinit();

    // First shrink candidate should be null (trying to shrink to null)
    const first = it.next();
    try testing.expect(first != null); // Outer optional is some (not end of iteration)
    try testing.expectEqual(@as(?i32, null), first.?); // Inner optional is null
}

test "regression: list shrinking removes from both ends correctly" {
    // Bug: current_len wasn't reset when transitioning from RemoveFromEnd to RemoveFromStart
    // causing RemoveFromStart to use wrong indices.
    const allocator = testing.allocator;

    const original = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var it = list(i32, allocator, &original);
    defer it.deinit();

    var shrunk_count: usize = 0;
    var all_valid = true;

    while (it.next()) |shrunk| {
        defer allocator.free(shrunk);
        shrunk_count += 1;

        // All shrunk lists must be subsets of the original (elements must exist in original)
        for (shrunk) |elem| {
            var found = false;
            for (original) |orig_elem| {
                if (elem == orig_elem) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_valid = false;
            }
        }

        if (shrunk_count > 50) break; // Safety limit
    }

    try testing.expect(shrunk_count > 0);
    try testing.expect(all_valid);
}

test "array shrinking produces smaller element values" {
    const allocator = testing.allocator;

    const original = [_]i32{ 100, 200, 300 };
    var it = array(i32, 3, allocator, original, intShrinker(i32));
    defer it.deinit();

    var count: usize = 0;
    while (it.next()) |shrunk| {
        count += 1;
        // At least one element should be smaller
        var any_smaller = false;
        for (0..3) |i| {
            if (@abs(shrunk[i]) < @abs(original[i])) {
                any_smaller = true;
            }
        }
        try testing.expect(any_smaller);
        if (count > 20) break;
    }
    try testing.expect(count > 0);
}

test "tuple2 shrinking produces smaller values" {
    const allocator = testing.allocator;

    const original: struct { i32, i32 } = .{ 100, 200 };
    var it = tuple2(i32, i32, allocator, original, intShrinker(i32), intShrinker(i32));
    defer it.deinit();

    var count: usize = 0;
    while (it.next()) |shrunk| {
        count += 1;
        // At least one element should be smaller
        const smaller_first = @abs(shrunk[0]) < @abs(original[0]);
        const smaller_second = @abs(shrunk[1]) < @abs(original[1]);
        try testing.expect(smaller_first or smaller_second);
        if (count > 20) break;
    }
    try testing.expect(count > 0);
}
