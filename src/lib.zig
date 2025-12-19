//! # Minish
//!
//! A property-based testing framework for Zig, inspired by [QuickCheck](https://hackage.haskell.org/package/QuickCheck) and [Hypothesis](https://hypothesis.readthedocs.io/en/latest/).
//!
//! Minish automatically generates random test cases and, on failure, minimises (or shrinks)
//! the input to the smallest value that still reproduces the failure. This makes debugging
//! property violations a lot easier.
//!
//! ## Quick Start
//!
//! ```zig
//! const minish = @import("minish");
//! const gen = minish.gen;
//!
//! fn my_property(value: i32) !void {
//!     // Test that some property holds for all values
//!     try std.testing.expect(value * 2 == value + value);
//! }
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     try minish.check(gpa.allocator(), gen.int(i32), my_property, .{
//!         .num_runs = 100,
//!     });
//! }
//! ```
//!
//! ## Main Components
//!
//! - `gen`: Built-in generators for common types (integers, floats, strings, lists, etc.)
//! - `combinators`: Functions to compose and transform generators
//! - `check`: The main function to run property tests
//! - `Options`: Configuration for test runs (num_runs, seed, etc.)

const std = @import("std");

/// Built-in generators for common data types.
/// See `gen.int`, `gen.float`, `gen.string`, `gen.list`, etc.
pub const gen = @import("minish/gen.zig");

/// Combinators for composing and transforming generators.
/// See `combinators.map`, `combinators.filter`, `combinators.flatMap`, etc.
pub const combinators = @import("minish/combinators.zig");

/// Internal test case state. Used by generators to make random choices.
pub const TestCase = @import("minish/core.zig").TestCase;

/// Errors that can occur during generation.
pub const GenError = @import("minish/core.zig").GenError;

/// Run the tests with the given generator and property function.
pub const check = @import("minish/runner.zig").check;

/// Configuration options for property tests.
pub const Options = @import("minish/runner.zig").Options;

// Backwards compatibility alias
pub const run = check;

test "Public API Sanity Check" {
    // Check modules are accessible and are struct types (namespaces)
    try std.testing.expect(@typeInfo(gen) == .@"struct");
    try std.testing.expect(@typeInfo(combinators) == .@"struct");
    try std.testing.expect(@typeInfo(@TypeOf(check)) == .@"fn");
    try std.testing.expect(@TypeOf(Options) == type);
    try std.testing.expect(@TypeOf(TestCase) == type);
}
