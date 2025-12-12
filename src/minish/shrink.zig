const std = @import("std");

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

const IntShrinkContext = struct {
    allocator: std.mem.Allocator,
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

fn intShrinkDeinit(ctx: *anyopaque) void {
    const context: *IntShrinkContext = @ptrCast(@alignCast(ctx));
    const allocator = context.allocator;
    allocator.destroy(context);
}

pub fn int(comptime T: type, allocator: std.mem.Allocator, value: T) Iterator(T) {
    const val_i64: i64 = @intCast(value);
    const context = allocator.create(IntShrinkContext) catch unreachable;
    context.* = .{ .allocator = allocator, .val = val_i64, .diff = val_i64 / 2 };
    return .{ .context = context, .nextFn = intShrinkNext, .deinitFn = intShrinkDeinit };
}
