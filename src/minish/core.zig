//! Core types for property-based testing.
//!
//! This module provides the fundamental building blocks:
//! - `GenError`: Errors that can occur during value generation
//! - `TestCase`: Manages random choices and enables shrinking

const std = @import("std");

const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;

/// Errors that can occur during value generation.
pub const GenError = error{
    /// Generation exceeded the maximum allowed choices.
    Overrun,
    /// An invalid choice was requested (e.g., empty range).
    InvalidChoice,
    /// Memory allocation failed.
    OutOfMemory,
};

/// TestCase manages the state for a single property test run.
/// It tracks random choices made during generation to enable shrinking.
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

    /// Make a choice uniformly from 0 to n (inclusive).
    /// This is the core primitive for all randomness in property tests.
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

    /// Make a choice in the given range [min, max] (inclusive).
    pub fn choiceInRange(self: *TestCase, comptime T: type, min: T, max: T) GenError!T {
        if (min > max) return error.InvalidChoice;
        // Use wider arithmetic to avoid overflow when computing range
        const min_wide: i128 = @intCast(min);
        const max_wide: i128 = @intCast(max);
        const range: u64 = @intCast(max_wide - min_wide);
        const choice_val = try self.choice(range);
        return @intCast(@as(i128, @intCast(choice_val)) + min_wide);
    }

    /// Make a weighted choice from a list of weights.
    /// Returns the index of the chosen item.
    pub fn weightedChoice(self: *TestCase, weights: []const u64) GenError!usize {
        if (weights.len == 0) return error.InvalidChoice;

        var total: u64 = 0;
        for (weights) |w| {
            total += w;
        }
        if (total == 0) return error.InvalidChoice;

        const chosen = try self.choice(total - 1);
        var sum: u64 = 0;
        for (weights, 0..) |w, i| {
            sum += w;
            if (chosen < sum) {
                return i;
            }
        }
        return weights.len - 1;
    }
};
