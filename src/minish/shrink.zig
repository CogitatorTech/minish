const std = @import("std");

pub fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        nextFn: *const fn (ctx: *anyopaque) ?T,

        pub fn next(self: *Self) ?T {
            return self.nextFn(self.context);
        }
    };
}

const IntShrinkContext = struct {
    val: i64,
    diff: i64,
};

fn intShrinkNext(ctx: *anyopaque) ?i64 {
    const context: *IntShrinkContext = @ptrCast(@alignCast(ctx));
    if (context.diff == 0) return null;
    const result = context.val - context.diff;
    context.diff /= 2;
    return result;
}

pub fn int(comptime T: type, value: T) Iterator(T) {
    const val_i64: i64 = @intCast(value);
    const context = std.heap.c_allocator.create(IntShrinkContext) catch unreachable;
    context.* = .{ .val = val_i64, .diff = val_i64 / 2 };
    return .{ .context = context, .nextFn = intShrinkNext };
}
