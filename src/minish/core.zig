const std = @import("std");

const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;

pub const GenError = error{
    Overrun,
    InvalidChoice,
    OutOfMemory,
};

pub const TestCase = struct {
    allocator: Allocator,
    prng: DefaultPrng,
    choices: std.ArrayList(u64),

    prefix: []const u64,
    prefix_idx: usize,
    max_size: usize,

    pub fn init(allocator: Allocator, seed: u64) TestCase {
        return TestCase{
            .allocator = allocator,
            .prng = DefaultPrng.init(seed),
            .choices = std.ArrayList(u64).empty,
            .prefix = &.{},
            .prefix_idx = 0,
            .max_size = 1024,
        };
    }

    pub fn deinit(self: *TestCase) void {
        self.choices.deinit(self.allocator);
    }

    pub fn choice(self: *TestCase, n: u64) GenError!u64 {
        if (self.choices.items.len >= self.max_size) {
            return error.Overrun;
        }

        var result: u64 = undefined;
        if (self.prefix_idx < self.prefix.len) {
            result = self.prefix[self.prefix_idx];
            self.prefix_idx += 1;
        } else {
            result = self.prng.random().intRangeAtMost(u64, 0, n);
        }

        if (self.prefix.len == 0) {
            try self.choices.append(self.allocator, result);
        }

        if (result > n) {
            return error.InvalidChoice;
        }
        return result;
    }
};
