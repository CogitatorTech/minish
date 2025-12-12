const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;
// const check = minish.check;
// const options = minish.Options{ .num_runs = 1000 };

// A property that will fail for large numbers.
fn sum_is_less_than_1500(tuple: struct { i32, i32 }) !void {
    const x = tuple[0];
    const y = tuple[1];

    // Use wrapping_add to avoid panic on overflow
    const sum = x +| y;
    if (x > 0 and y > 0 and sum >= 1500) {
        return error.AssertionFailed;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Create a generator.
    const tuple_generator = gen.tuple();

    // 2. Pass the generator and test function directly to check.
    minish.check(allocator, tuple_generator, sum_is_less_than_1500, .{}) catch |err| {
        if (err == error.AssertionFailed) {
            std.debug.print("\nTest failed as expected.\n", .{});
            // std.debug.print("\n", .{@TypeOf(gen)});
            // std.debug.print("Generator used: {any}\n", .{@typeInfo(@TypeOf(check))});
            return;
        }
        return err;
    };
}
