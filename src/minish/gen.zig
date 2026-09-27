//! Built-in generators for property-based testing.
//!
//! Generators produce random values of specific types. They are composable
//! and support automatic shrinking to find minimal failing inputs.
//!
//! ## Basic Usage
//!
//! ```zig
//! const gen = @import("minish").gen;
//!
//! // Integer generators
//! const int_gen = gen.int(i32);
//! const range_gen = gen.intRange(i32, 0, 100);
//!
//! // Collection generators
//! const list_gen = gen.list(i32, gen.int(i32), 0, 10);
//! const string_gen = gen.string(.{ .min_len = 1, .max_len = 20 });
//! ```

const std = @import("std");
const core = @import("core.zig");
const shrink_mod = @import("shrink.zig");

const TestCase = core.TestCase;

/// A generator produces values of type T from random choices.
/// Each generator has:
/// - `generateFn`: Creates a value from a TestCase
/// - `shrinkFn`: Optional function to produce independently owned shrink candidates
/// - `freeFn`: Optional function to free allocated memory
/// - `cloneFn`: Optional function to create an independently owned copy
pub fn Generator(comptime T: type) type {
    return struct {
        generateFn: *const fn (tc: *TestCase) core.GenError!T,
        shrinkFn: ?*const fn (std.mem.Allocator, T) shrink_mod.Iterator(T),
        freeFn: ?*const fn (std.mem.Allocator, T) void,
        /// Copies must use the supplied allocator and support cleanup with freeFn.
        /// On error, cloneFn must release any allocations it made.
        cloneFn: ?*const fn (std.mem.Allocator, T) std.mem.Allocator.Error!T = null,
    };
}

// ============================================================================
// Integer Generators
// ============================================================================

fn generate_int(comptime T: type) fn (tc: *TestCase) core.GenError!T {
    return struct {
        fn generate(tc: *TestCase) core.GenError!T {
            const type_info = @typeInfo(T);
            if (type_info != .int) {
                @compileError("int() requires an integer type");
            }

            const IntType = type_info.int;
            if (IntType.signedness == .unsigned) {
                const max_val = std.math.maxInt(T);
                const val = try tc.choice(max_val);
                return @intCast(val);
            } else {
                // For signed integers, generate across unsigned range and bitcast
                // This correctly covers the full range including minInt
                const UnsignedT = std.meta.Int(.unsigned, IntType.bits);
                const max_unsigned = std.math.maxInt(UnsignedT);
                const val = try tc.choice(max_unsigned);
                return @bitCast(@as(UnsignedT, @intCast(val)));
            }
        }
    }.generate;
}

/// Generate random integers of any integer type.
///
/// Example:
/// ```zig
/// const my_int_gen = gen.int(u32);
/// ```
pub fn int(comptime T: type) Generator(T) {
    return .{ .generateFn = generate_int(T), .shrinkFn = shrink_mod.intShrinker(T), .freeFn = null };
}

/// Generate integers in a specific range [min, max] (inclusive).
///
/// Example:
/// ```zig
/// const byte_gen = gen.intRange(u8, 0, 10);
/// ```
pub fn intRange(comptime T: type, comptime min: T, comptime max: T) Generator(T) {
    comptime {
        if (max < min) @compileError("intRange: max must be >= min");
    }
    const RangeGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            return tc.choiceInRange(T, min, max);
        }

        fn shrink(allocator: std.mem.Allocator, value: T) shrink_mod.Iterator(T) {
            return shrink_mod.intTowards(T, allocator, value, std.math.clamp(@as(T, 0), min, max));
        }
    };
    return .{ .generateFn = RangeGenerator.generate, .shrinkFn = RangeGenerator.shrink, .freeFn = null };
}

// ============================================================================
// Float Generators
// ============================================================================

fn generate_float(comptime T: type) fn (tc: *TestCase) core.GenError!T {
    return struct {
        fn generate(tc: *TestCase) core.GenError!T {
            const type_info = @typeInfo(T);
            if (type_info != .float) {
                @compileError("float() requires a float type");
            }

            // Generate mantissa and exponent separately for better distribution
            const mantissa = try tc.choice(std.math.maxInt(u32));
            const exponent = try tc.choice(100);
            const sign = if (try tc.choice(1) == 0) @as(f64, -1.0) else @as(f64, 1.0);

            const result = sign * (@as(f64, @floatFromInt(mantissa)) / @as(f64, @floatFromInt(std.math.maxInt(u32)))) *
                std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exponent)) - 50.0);

            return @floatCast(result);
        }
    }.generate;
}

/// Generate random floating point numbers.
///
/// Example:
/// ```zig
/// const valid_float = gen.float(f64);
/// ```
pub fn float(comptime T: type) Generator(T) {
    return .{ .generateFn = generate_float(T), .shrinkFn = shrink_mod.floatShrinker(T), .freeFn = null };
}

/// Generate floating point numbers in a specific range [min, max].
///
/// Example:
/// ```zig
/// const prob = gen.floatRange(f32, 0.0, 1.0);
/// ```
pub fn floatRange(comptime T: type, comptime min: T, comptime max: T) Generator(T) {
    comptime {
        if (max < min) @compileError("floatRange: max must be >= min");
    }
    const RangeGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            // Generate a value in [0, 1] and scale to range
            const mantissa = try tc.choice(std.math.maxInt(u32));
            const normalized: T = @floatCast(@as(f64, @floatFromInt(mantissa)) / @as(f64, @floatFromInt(std.math.maxInt(u32))));
            // Opposite signs can overflow the range width even with finite bounds.
            const value = if (min < 0 and max > 0)
                (1 - normalized) * min + normalized * max
            else
                min + normalized * (max - min);
            return std.math.clamp(value, min, max);
        }

        fn shrink(allocator: std.mem.Allocator, value: T) shrink_mod.Iterator(T) {
            return shrink_mod.floatTowards(T, allocator, value, std.math.clamp(@as(T, 0), min, max));
        }
    };
    return .{ .generateFn = RangeGenerator.generate, .shrinkFn = RangeGenerator.shrink, .freeFn = null };
}

// ============================================================================
// Boolean Generator
// ============================================================================

fn generate_bool(tc: *TestCase) core.GenError!bool {
    return (try tc.choice(1)) == 1;
}

pub fn boolean() Generator(bool) {
    return .{ .generateFn = generate_bool, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Character Generator
// ============================================================================

/// Generate a single ASCII character (printable range 32-126).
pub fn char() Generator(u8) {
    return intRange(u8, 32, 126);
}

/// Generate a single character from a specific character set.
pub fn charFrom(comptime charset: []const u8) Generator(u8) {
    comptime {
        if (charset.len == 0) @compileError("charFrom requires a non-empty charset");
    }
    const CharFromGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!u8 {
            const idx = try tc.choice(charset.len - 1);
            return charset[idx];
        }
    };
    return .{ .generateFn = CharFromGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Enum Generator
// ============================================================================

/// Generate a random value from any enum type.
pub fn enumValue(comptime E: type) Generator(E) {
    const EnumGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!E {
            const enum_info = @typeInfo(E);
            if (enum_info != .@"enum") {
                @compileError("enumValue() requires an enum type");
            }
            const fields = enum_info.@"enum".fields;
            if (fields.len == 0) {
                return error.InvalidChoice;
            }
            const idx = try tc.choice(fields.len - 1);
            // Return the enum value at index
            // Create a runtime-accessible array of values
            const all_values = blk: {
                var vals: [fields.len]E = undefined;
                inline for (fields, 0..) |f, i| {
                    vals[i] = @enumFromInt(f.value);
                }
                break :blk vals;
            };
            return all_values[idx];
        }
    };
    return .{ .generateFn = EnumGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// UUID Generator
// ============================================================================

/// Generate a random UUID v4 as a 36-character string.
/// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
pub fn uuid() Generator([36]u8) {
    const hex_chars = "0123456789abcdef";
    const UuidGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![36]u8 {
            var result: [36]u8 = undefined;
            var pos: usize = 0;

            // Generate 8-4-4-4-12 pattern
            const sections = [_]usize{ 8, 4, 4, 4, 12 };
            for (sections) |section_len| {
                if (pos > 0) {
                    result[pos] = '-';
                    pos += 1;
                }
                for (0..section_len) |_| {
                    // UUID v4 specific: position 12 is always '4', position 16 is 8/9/a/b
                    if (pos == 14) {
                        result[pos] = '4';
                    } else if (pos == 19) {
                        const variant = try tc.choice(3); // 0-3 maps to 8,9,a,b
                        result[pos] = hex_chars[8 + variant];
                    } else {
                        const hex_val = try tc.choice(15);
                        result[pos] = hex_chars[hex_val];
                    }
                    pos += 1;
                }
            }

            return result;
        }
    };
    return .{ .generateFn = UuidGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Timestamp Generator
// ============================================================================

/// Generate Unix timestamps (seconds since epoch).
/// Default range: 0 to 2^31-1 (valid until year 2038).
pub fn timestamp() Generator(i64) {
    return timestampRange(0, 2147483647);
}

/// Generate Unix timestamps in a specific range.
pub fn timestampRange(comptime min: i64, comptime max: i64) Generator(i64) {
    return intRange(i64, min, max);
}

// ============================================================================
// NonEmpty Wrapper
// ============================================================================

/// Wrapper that generates non-empty lists (min_len >= 1).
pub fn nonEmptyList(comptime T: type, comptime element_gen: Generator(T), comptime max_len: usize) Generator([]const T) {
    return list(T, element_gen, 1, max_len);
}

/// Wrapper that generates non-empty strings (min_len >= 1).
pub fn nonEmptyString(comptime config: StringConfig) Generator([]const u8) {
    const adjusted_config = StringConfig{
        .min_len = if (config.min_len == 0) 1 else config.min_len,
        .max_len = config.max_len,
        .charset = config.charset,
        .custom_chars = config.custom_chars,
    };
    return string(adjusted_config);
}

// ============================================================================
// String Generators
// ============================================================================

pub const CharacterSet = enum {
    ascii,
    alphanumeric,
    alpha,
    numeric,
    printable,
    custom,

    pub fn getChars(self: CharacterSet, custom_chars: ?[]const u8) []const u8 {
        return switch (self) {
            .ascii => "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:',.<>?/~` ",
            .alphanumeric => "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
            .alpha => "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
            .numeric => "0123456789",
            .printable => " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
            .custom => custom_chars orelse "abc",
        };
    }
};

pub const StringConfig = struct {
    min_len: usize = 0,
    max_len: usize = 100,
    charset: CharacterSet = .alphanumeric,
    custom_chars: ?[]const u8 = null,
};

/// Generate a random string based on configuration.
///
/// Example:
/// ```zig
/// const alpha_string = gen.string(.{
///     .min_len = 5,
///     .max_len = 20,
///     .charset = .alpha
/// });
/// ```
///
/// Memory lifecycle: The returned string is owned by the Minish runner and will be
/// freed automatically after the test property returns.
pub fn string(comptime config: StringConfig) Generator([]const u8) {
    comptime {
        if (config.max_len < config.min_len) @compileError("string generator: max_len must be >= min_len");
    }
    const StringGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![]const u8 {
            const len = config.min_len + try tc.choice(config.max_len - config.min_len);
            const chars = config.charset.getChars(config.custom_chars);

            // Guard against empty charset
            if (chars.len == 0) {
                return error.InvalidChoice;
            }

            var result = std.ArrayList(u8).empty;
            errdefer result.deinit(tc.allocator);

            for (0..len) |_| {
                const idx = try tc.choice(chars.len - 1);
                try result.append(tc.allocator, chars[idx]);
            }

            return result.toOwnedSlice(tc.allocator);
        }

        fn shrink(allocator: std.mem.Allocator, value: []const u8) shrink_mod.Iterator([]const u8) {
            return shrink_mod.listAtLeast(u8, allocator, value, config.min_len, null);
        }

        fn free(allocator: std.mem.Allocator, value: []const u8) void {
            allocator.free(value);
        }

        fn clone(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
            return allocator.dupe(u8, value);
        }
    };
    return .{ .generateFn = StringGenerator.generate, .shrinkFn = StringGenerator.shrink, .freeFn = StringGenerator.free, .cloneFn = StringGenerator.clone };
}

// ============================================================================
// Collection Generators
// ============================================================================

/// Generate a list of values.
/// Owned elements require a cloneFn for automatic shrinking.
/// Shrunk lists retain the configured minimum length.
/// Elements are shrunk using the element generator's shrinkFn after removal attempts.
///
/// Example:
/// ```zig
/// // Generate a list of 0 to 100 integers
/// const list_gen = gen.list(i32, gen.int(i32), 0, 100);
/// ```
///
/// Memory lifecycle: The returned slice and its elements (if allocated) are owned by
/// the Minish runner and will be freed automatically after the test property returns.
pub fn list(comptime T: type, comptime element_gen: Generator(T), comptime min_len: usize, comptime max_len: usize) Generator([]const T) {
    comptime {
        if (max_len < min_len) @compileError("list generator: max_len must be >= min_len");
    }
    const ListGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![]const T {
            const len = min_len + try tc.choice(max_len - min_len);
            var result = std.ArrayList(T).empty;
            // On partial failure, free elements already produced by the inner
            // generator before tearing down the list backing storage.
            errdefer {
                if (element_gen.freeFn) |freeFn| {
                    for (result.items) |item| freeFn(tc.allocator, item);
                }
                result.deinit(tc.allocator);
            }
            for (0..len) |_| {
                const elem = try element_gen.generateFn(tc);
                result.append(tc.allocator, elem) catch |err| {
                    if (element_gen.freeFn) |freeFn| freeFn(tc.allocator, elem);
                    return err;
                };
            }
            return result.toOwnedSlice(tc.allocator);
        }

        fn shrink(allocator: std.mem.Allocator, value: []const T) shrink_mod.Iterator([]const T) {
            return shrink_mod.listWithOwnership(T, allocator, value, min_len, element_gen.shrinkFn, element_gen.cloneFn, element_gen.freeFn);
        }

        fn free(allocator: std.mem.Allocator, value: []const T) void {
            if (element_gen.freeFn) |freeFn| {
                for (value) |item| {
                    freeFn(allocator, item);
                }
            }
            allocator.free(value);
        }

        fn clone(allocator: std.mem.Allocator, value: []const T) std.mem.Allocator.Error![]const T {
            return shrink_mod.cloneList(T, allocator, value, element_gen.cloneFn, element_gen.freeFn);
        }
    };
    const can_clone = element_gen.freeFn == null or element_gen.cloneFn != null;
    return .{
        .generateFn = ListGenerator.generate,
        .shrinkFn = if (can_clone) ListGenerator.shrink else null,
        .freeFn = ListGenerator.free,
        .cloneFn = if (can_clone) ListGenerator.clone else null,
    };
}

// ============================================================================
// HashMap Generator
// ============================================================================

/// Generate a HashMap with random keys and values.
/// Retries collisions to reach the chosen entry count, with at most TestCase.max_size
/// insertion attempts. Returns error.Overrun if the count cannot be reached within the budget.
///
/// Example:
/// ```zig
/// const map_gen = gen.hashMap(i32, bool, gen.int(i32), gen.boolean(), 0, 10);
/// ```
///
/// Memory lifecycle: The returned HashMap and its contents are owned by the Minish runner
/// and will be freed automatically. Do NOT manually deinit the map unless you clone it first.
pub fn hashMap(
    comptime K: type,
    comptime V: type,
    comptime key_gen: Generator(K),
    comptime value_gen: Generator(V),
    comptime min_entries: usize,
    comptime max_entries: usize,
) Generator(std.AutoHashMap(K, V)) {
    comptime {
        if (max_entries < min_entries) @compileError("hashMap generator: max_entries must be >= min_entries");
        // std.AutoHashMap hashes the slice header, not its contents, which
        // produces wrong results for content-equal-but-distinct slices. Use
        // std.StringHashMap or write a custom map for slice keys.
        const k_info = @typeInfo(K);
        if (k_info == .pointer) {
            @compileError("hashMap: slice/pointer key types are not supported by std.AutoHashMap (it hashes pointers, not contents). Use a custom hash map for slice keys.");
        }
    }
    const HashMapGenerator = struct {
        fn freeEntries(allocator: std.mem.Allocator, map: *std.AutoHashMap(K, V)) void {
            if (key_gen.freeFn != null or value_gen.freeFn != null) {
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (key_gen.freeFn) |freeKey| freeKey(allocator, entry.key_ptr.*);
                    if (value_gen.freeFn) |freeVal| freeVal(allocator, entry.value_ptr.*);
                }
            }
        }

        fn generate(tc: *TestCase) core.GenError!std.AutoHashMap(K, V) {
            const num_entries = min_entries + try tc.choice(max_entries - min_entries);

            var map = std.AutoHashMap(K, V).init(tc.allocator);
            // On partial failure, free any keys/values already inserted
            // before tearing down the map itself.
            errdefer {
                freeEntries(tc.allocator, &map);
                map.deinit();
            }

            var i: usize = 0;
            while (map.count() < num_entries) : (i += 1) {
                if (i >= tc.max_size) return error.Overrun;
                const key = try key_gen.generateFn(tc);
                const value = value_gen.generateFn(tc) catch |err| {
                    if (key_gen.freeFn) |freeKey| freeKey(tc.allocator, key);
                    return err;
                };
                // Put may fail with OOM; on failure, free the new k/v that
                // were not yet handed off to the map.
                const gop = map.getOrPut(key) catch |err| {
                    if (key_gen.freeFn) |freeKey| freeKey(tc.allocator, key);
                    if (value_gen.freeFn) |freeVal| freeVal(tc.allocator, value);
                    return err;
                };
                if (gop.found_existing) {
                    // Keep the existing key and replace its value.
                    if (key_gen.freeFn) |freeKey| freeKey(tc.allocator, key);
                    if (value_gen.freeFn) |freeVal| freeVal(tc.allocator, gop.value_ptr.*);
                }
                gop.value_ptr.* = value;
            }

            return map;
        }

        fn free(allocator: std.mem.Allocator, map: std.AutoHashMap(K, V)) void {
            var mut_map = map;
            freeEntries(allocator, &mut_map);
            mut_map.deinit();
        }
    };
    return .{ .generateFn = HashMapGenerator.generate, .shrinkFn = null, .freeFn = HashMapGenerator.free };
}

/// Generate a fixed-size array.
///
/// Memory lifecycle: The returned array matches the ownership of its elements.
/// If elements are allocated, they will be freed automatically.
/// Elements shrink independently when owned elements have a cloneFn.
pub fn array(comptime T: type, comptime size: usize, comptime element_gen: Generator(T)) Generator([size]T) {
    const ArrayGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![size]T {
            var result: [size]T = undefined;
            var filled: usize = 0;
            // On partial failure, free elements already produced.
            errdefer {
                if (element_gen.freeFn) |freeFn| {
                    for (result[0..filled]) |item| freeFn(tc.allocator, item);
                }
            }
            while (filled < size) : (filled += 1) {
                result[filled] = try element_gen.generateFn(tc);
            }
            return result;
        }

        fn free(allocator: std.mem.Allocator, value: [size]T) void {
            if (element_gen.freeFn) |freeFn| {
                for (value) |item| {
                    freeFn(allocator, item);
                }
            }
        }

        fn shrink(allocator: std.mem.Allocator, value: [size]T) shrink_mod.Iterator([size]T) {
            return shrink_mod.arrayWithOwnership(T, size, allocator, value, element_gen.shrinkFn, element_gen.cloneFn, element_gen.freeFn);
        }

        fn clone(allocator: std.mem.Allocator, value: [size]T) std.mem.Allocator.Error![size]T {
            return shrink_mod.cloneArray(T, size, allocator, value, element_gen.cloneFn, element_gen.freeFn);
        }
    };
    const can_clone = element_gen.freeFn == null or element_gen.cloneFn != null;
    return .{
        .generateFn = ArrayGenerator.generate,
        .shrinkFn = if (can_clone and size > 0 and element_gen.shrinkFn != null) ArrayGenerator.shrink else null,
        .freeFn = ArrayGenerator.free,
        .cloneFn = if (can_clone) ArrayGenerator.clone else null,
    };
}

// ============================================================================
// Option/Nullable Generator
// ============================================================================

/// Generate an optional value (Some or None).
/// Shrinking tries null first, then uses the element generator's shrinker.
pub fn optional(comptime T: type, comptime element_gen: Generator(T)) Generator(?T) {
    const OptionalGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!?T {
            const is_some = try tc.choice(1) == 1;
            if (is_some) {
                return try element_gen.generateFn(tc);
            }
            return null;
        }

        fn free(allocator: std.mem.Allocator, value: ?T) void {
            if (value) |v| {
                if (element_gen.freeFn) |freeFn| {
                    freeFn(allocator, v);
                }
            }
        }

        fn shrink(allocator: std.mem.Allocator, value: ?T) shrink_mod.Iterator(?T) {
            return shrink_mod.optional(T, allocator, value, element_gen.shrinkFn);
        }

        fn clone(allocator: std.mem.Allocator, value: ?T) std.mem.Allocator.Error!?T {
            if (value) |v| {
                const copy = if (element_gen.cloneFn) |clone_fn| try clone_fn(allocator, v) else v;
                return @as(?T, copy);
            }
            return null;
        }
    };
    return .{
        .generateFn = OptionalGenerator.generate,
        .shrinkFn = OptionalGenerator.shrink,
        .freeFn = OptionalGenerator.free,
        .cloneFn = if (element_gen.freeFn == null or element_gen.cloneFn != null) OptionalGenerator.clone else null,
    };
}

// ============================================================================
// Constant Generator
// ============================================================================

pub fn constant(comptime value: anytype) Generator(@TypeOf(value)) {
    const ConstantGenerator = struct {
        fn generate(_: *TestCase) core.GenError!@TypeOf(value) {
            return value;
        }
    };
    return .{ .generateFn = ConstantGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Tuple Generators
// ============================================================================

/// Generate a 2-tuple with generic types.
/// Elements shrink independently when every owned element has a cloneFn.
///
/// Memory lifecycle: The tuple and its elements are owned by the Minish runner
/// and will be freed automatically.
pub fn tuple2(comptime T1: type, comptime T2: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2)) Generator(struct { T1, T2 }) {
    return structure(struct { T1, T2 }, .{ gen1, gen2 });
}

/// Generate a 3-tuple with generic types.
/// Elements shrink independently when every owned element has a cloneFn.
///
/// Memory lifecycle: The tuple and its elements are owned by the Minish runner
/// and will be freed automatically.
pub fn tuple3(comptime T1: type, comptime T2: type, comptime T3: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2), comptime gen3: Generator(T3)) Generator(struct { T1, T2, T3 }) {
    return structure(struct { T1, T2, T3 }, .{ gen1, gen2, gen3 });
}

// ============================================================================
// Struct Generator
// ============================================================================

/// Generate a struct with the given field generators.
/// The field_gens parameter should be an anonymous struct where each field
/// corresponds to a field in T and contains the generator for that field.
///
/// Example:
/// ```zig
/// const User = struct { id: u32, name: []const u8 };
/// const user_gen = gen.structure(User, .{
///     .id = gen.int(u32),
///     .name = gen.string(.{ .min_len = 1 })
/// });
/// ```
///
/// Memory lifecycle-wise, the returned struct and its fields are owned by the Minish runner
/// and will be freed automatically.
/// Fields shrink independently when every owned field has a cloneFn.
pub fn structure(
    comptime T: type,
    comptime field_gens: anytype,
) Generator(T) {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("structure() requires a struct type");
    }
    const can_clone = comptime blk: {
        for (type_info.@"struct".fields) |field| {
            const field_gen = @field(field_gens, field.name);
            if (field_gen.freeFn != null and field_gen.cloneFn == null) break :blk false;
        }
        break :blk true;
    };
    const has_shrinker = comptime blk: {
        for (type_info.@"struct".fields) |field| {
            if (@field(field_gens, field.name).shrinkFn != null) break :blk true;
        }
        break :blk false;
    };
    const StructGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            var result: T = undefined;
            const struct_info = type_info.@"struct";

            // Track how many fields were successfully populated so we can
            // free them on partial failure.
            var filled_idx: usize = 0;
            errdefer {
                inline for (struct_info.fields, 0..) |field, i| {
                    if (i < filled_idx) {
                        const field_gen = @field(field_gens, field.name);
                        if (field_gen.freeFn) |freeFn| {
                            freeFn(tc.allocator, @field(result, field.name));
                        }
                    }
                }
            }

            inline for (struct_info.fields) |field| {
                const field_gen = @field(field_gens, field.name);
                @field(result, field.name) = try field_gen.generateFn(tc);
                filled_idx += 1;
            }

            return result;
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            const struct_info = @typeInfo(T).@"struct";
            inline for (struct_info.fields) |field| {
                const field_gen = @field(field_gens, field.name);
                if (field_gen.freeFn) |freeFn| {
                    freeFn(allocator, @field(value, field.name));
                }
            }
        }

        fn shrink(allocator: std.mem.Allocator, value: T) shrink_mod.Iterator(T) {
            return shrink_mod.structure(T, allocator, value, field_gens);
        }

        fn clone(allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
            return shrink_mod.cloneStruct(T, allocator, value, field_gens);
        }
    };
    return .{
        .generateFn = StructGenerator.generate,
        .shrinkFn = if (can_clone and has_shrinker) StructGenerator.shrink else null,
        .freeFn = StructGenerator.free,
        .cloneFn = if (can_clone) StructGenerator.clone else null,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "int generator produces valid integers" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_i32 = int(i32);
    const value = try gen_i32.generateFn(&tc);

    // Value should be within i32 range
    try testing.expect(value >= std.math.minInt(i32));
    try testing.expect(value <= std.math.maxInt(i32));
}

test "intRange generator respects bounds" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 54321);
    defer tc.deinit();

    const gen_range = intRange(i32, -10, 10);

    for (0..20) |_| {
        const value = try gen_range.generateFn(&tc);
        try testing.expect(value >= -10);
        try testing.expect(value <= 10);
    }
}

test "boolean generator produces both true and false" {
    const allocator = testing.allocator;

    var got_true = false;
    var got_false = false;

    for (0..100) |i| {
        var tc = TestCase.init(allocator, i);
        defer tc.deinit();

        const gen_bool = boolean();
        const value = try gen_bool.generateFn(&tc);

        if (value) got_true = true else got_false = true;

        if (got_true and got_false) break;
    }

    try testing.expect(got_true);
    try testing.expect(got_false);
}

test "string generator produces strings within length bounds" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 98765);
    defer tc.deinit();

    const gen_str = string(.{ .min_len = 5, .max_len = 15 });
    const value = try gen_str.generateFn(&tc);
    defer allocator.free(value);

    try testing.expect(value.len >= 5);
    try testing.expect(value.len <= 15);
}

test "list generator produces lists within length bounds" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 11111);
    defer tc.deinit();

    const gen_list = list(i32, int(i32), 0, 10);
    const value = try gen_list.generateFn(&tc);
    defer allocator.free(value);

    try testing.expect(value.len >= 0);
    try testing.expect(value.len <= 10);
}

test "array generator produces correct size" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 22222);
    defer tc.deinit();

    const gen_arr = array(u8, 5, int(u8));
    const value = try gen_arr.generateFn(&tc);

    try testing.expectEqual(5, value.len);
}

test "optional generator produces both Some and None" {
    const allocator = testing.allocator;

    var got_some = false;
    var got_none = false;

    for (0..100) |i| {
        var tc = TestCase.init(allocator, i * 7);
        defer tc.deinit();

        const gen_opt = optional(i32, int(i32));
        const value = try gen_opt.generateFn(&tc);

        if (value) |_| got_some = true else got_none = true;

        if (got_some and got_none) break;
    }

    try testing.expect(got_some);
    try testing.expect(got_none);
}

test "constant generator always returns same value" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 33333);
    defer tc.deinit();

    const gen_const = constant(@as(i32, 42));

    for (0..10) |_| {
        const value = try gen_const.generateFn(&tc);
        try testing.expectEqual(@as(i32, 42), value);
    }
}

test "tuple2 generator produces valid tuples" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 44444);
    defer tc.deinit();

    const gen_tuple = tuple2(i32, bool, int(i32), boolean());
    const value = try gen_tuple.generateFn(&tc);

    // Just verify it has the right structure
    _ = value[0]; // i32
    _ = value[1]; // bool
}

test "structure generator produces valid structs" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 55555);
    defer tc.deinit();

    const TestStruct = struct {
        x: i32,
        y: bool,
    };

    const gen_struct = structure(TestStruct, .{
        .x = int(i32),
        .y = boolean(),
    });

    const value = try gen_struct.generateFn(&tc);

    // Verify fields exist
    _ = value.x;
    _ = value.y;
}

test "float generator produces valid floats" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 77777);
    defer tc.deinit();

    const gen_float = float(f64);
    const value = try gen_float.generateFn(&tc);

    // Should not be NaN or Inf initially (though it could be)
    // Just verify it's a float
    _ = value;
}

test "memory leak regression tests (generators)" {
    const runner = @import("runner.zig");
    const allocator = std.testing.allocator;
    const str_gen = comptime string(.{ .min_len = 1, .max_len = 5 });
    const int_gen = comptime int(u32);

    const opts = runner.Options{ .seed = 111, .num_runs = 10 };

    // Helper no-ops
    const S = struct { x: []const u8, y: []const u8 };
    const Props = struct {
        fn prop_no_op(_: []const u8) !void {}
        fn prop_no_op_array(_: [3][]const u8) !void {}
        fn prop_no_op_map(_: std.AutoHashMap(u32, []const u8)) !void {}
        fn prop_no_op_opt(_: ?[]const u8) !void {}
        fn prop_no_op_tuple(_: struct { []const u8, []const u8 }) !void {}
        fn prop_no_op_struct(_: S) !void {}
    };

    // Test List
    try runner.check(allocator, str_gen, Props.prop_no_op, opts);

    // Test Array
    try runner.check(allocator, array([]const u8, 3, str_gen), Props.prop_no_op_array, opts);

    // Test HashMap (u32 -> string)
    try runner.check(allocator, hashMap(u32, []const u8, int_gen, str_gen, 1, 5), Props.prop_no_op_map, opts);

    // Test Optional
    try runner.check(allocator, optional([]const u8, str_gen), Props.prop_no_op_opt, opts);

    // Test Tuple
    try runner.check(allocator, tuple2([]const u8, []const u8, str_gen, str_gen), Props.prop_no_op_tuple, opts);

    // Test Structure
    const struct_gen = structure(S, .{ .x = str_gen, .y = str_gen });
    try runner.check(allocator, struct_gen, Props.prop_no_op_struct, opts);
}

// ============================================================================
// Regression Tests for Bug Fixes
// ============================================================================

test "regression: string generator with empty custom charset returns error" {
    // Bug: Empty charset would cause underflow in tc.choice(chars.len - 1)
    // Fix: Added guard to return InvalidChoice for empty charset
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Create a generator with empty custom charset
    const empty_charset_gen = string(.{
        .min_len = 1,
        .max_len = 5,
        .charset = .custom,
        .custom_chars = "",
    });

    // Should return InvalidChoice error, not crash
    const result = empty_charset_gen.generateFn(&tc);
    try testing.expectError(core.GenError.InvalidChoice, result);
}

test "floatRange generator produces floats in range" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_range = floatRange(f32, -1.0, 1.0);
    for (0..10) |_| {
        const value = try gen_range.generateFn(&tc);
        try testing.expect(value >= -1.0 and value <= 1.0);
    }
}

test "char generator produces printable ASCII" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_char = char();
    for (0..20) |_| {
        const c = try gen_char.generateFn(&tc);
        try testing.expect(c >= 32 and c <= 126);
    }
}

test "charFrom generator uses specified charset" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_char = charFrom("abc");
    for (0..20) |_| {
        const c = try gen_char.generateFn(&tc);
        try testing.expect(c == 'a' or c == 'b' or c == 'c');
    }
}

test "enumValue generator produces valid enum values" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const Color = enum { Red, Green, Blue };
    const gen_enum = enumValue(Color);

    var got_red = false;
    var got_green = false;
    var got_blue = false;

    for (0..50) |_| {
        const c = try gen_enum.generateFn(&tc);
        switch (c) {
            .Red => got_red = true,
            .Green => got_green = true,
            .Blue => got_blue = true,
        }
    }
    try testing.expect(got_red or got_green or got_blue);
}

test "uuid generator produces valid v4 format" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_uuid = uuid();
    const value = try gen_uuid.generateFn(&tc);

    // Check format: 8-4-4-4-12 with dashes at positions 8, 13, 18, 23
    try testing.expect(value[8] == '-');
    try testing.expect(value[13] == '-');
    try testing.expect(value[18] == '-');
    try testing.expect(value[23] == '-');
    // UUID v4: position 14 should be '4'
    try testing.expect(value[14] == '4');
}

test "timestamp generator produces valid timestamps" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_ts = timestamp();
    const value = try gen_ts.generateFn(&tc);
    try testing.expect(value >= 0 and value <= 2147483647);
}

test "timestampRange generator respects bounds" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_ts = timestampRange(1000, 2000);
    for (0..20) |_| {
        const value = try gen_ts.generateFn(&tc);
        try testing.expect(value >= 1000 and value <= 2000);
    }
}

test "nonEmptyList generator produces non-empty lists" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_list = nonEmptyList(i32, int(i32), 5);
    const value = try gen_list.generateFn(&tc);
    defer allocator.free(value);

    try testing.expect(value.len >= 1);
    try testing.expect(value.len <= 5);
}

test "nonEmptyString generator produces non-empty strings" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_str = nonEmptyString(.{ .max_len = 10 });
    const value = try gen_str.generateFn(&tc);
    defer allocator.free(value);

    try testing.expect(value.len >= 1);
    try testing.expect(value.len <= 10);
}

test "hashMap generator produces valid maps" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_map = hashMap(i32, bool, int(i32), boolean(), 1, 5);
    var value = try gen_map.generateFn(&tc);
    defer value.deinit();

    try testing.expect(value.count() >= 1);
    try testing.expect(value.count() <= 5);
}

test "tuple3 generator produces valid tuples" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    const gen_tuple = tuple3(i32, bool, u8, int(i32), boolean(), int(u8));
    const value = try gen_tuple.generateFn(&tc);

    _ = value[0]; // i32
    _ = value[1]; // bool
    _ = value[2]; // u8
}

test "regression: signed int generator uses std.meta.Int correctly" {
    // Regression: @Type(.{ .int = ... }) was replaced with std.meta.Int(.unsigned, bits)
    // in Zig 0.16.0. Verify signed integers still generate across the full range.
    const allocator = testing.allocator;

    // i8 range: -128 to 127
    {
        var tc = TestCase.init(allocator, 99);
        defer tc.deinit();
        const gen_i8 = generate_int(i8);

        var saw_negative = false;
        var saw_positive = false;
        for (0..50) |_| {
            const val = try gen_i8(&tc);
            if (val < 0) saw_negative = true;
            if (val > 0) saw_positive = true;
        }
        try testing.expect(saw_negative);
        try testing.expect(saw_positive);
    }

    // i16 range: -32768 to 32767
    {
        var tc = TestCase.init(allocator, 42);
        defer tc.deinit();
        const gen_i16 = generate_int(i16);

        var saw_negative = false;
        for (0..50) |_| {
            const val = try gen_i16(&tc);
            if (val < 0) saw_negative = true;
        }
        try testing.expect(saw_negative);
    }

    // u8 should still work (unsigned path unchanged)
    {
        var tc = TestCase.init(allocator, 12345);
        defer tc.deinit();
        const gen_u8 = generate_int(u8);
        const val = try gen_u8(&tc);
        try testing.expect(val <= 255);
    }
}

// ============================================================================
// Regression Tests for Container Partial-Failure Leaks
// ============================================================================
//
// Each container generator (list, hashMap, array, tuple2, tuple3, structure)
// must free elements that have already been produced by an inner generator
// when a later inner generation fails. Without that cleanup, the items
// leaked silently. These tests use `testing.allocator`, which panics on leak.

/// A generator over `[]const u8` that allocates its first `remaining`
/// values normally and then returns `error.InvalidChoice` on every
/// subsequent call. The countdown is module-level so the closures used
/// inside container tests (which the container generators capture at
/// comptime) can reach it.
const FailingStringGen = struct {
    var remaining: usize = 0;

    fn reset(succeed_count: usize) void {
        remaining = succeed_count;
    }

    fn generate_fn(tc: *TestCase) core.GenError![]const u8 {
        if (remaining == 0) return error.InvalidChoice;
        remaining -= 1;
        const buf = try tc.allocator.alloc(u8, 3);
        @memset(buf, 'a');
        return buf;
    }

    fn free_fn(allocator: std.mem.Allocator, value: []const u8) void {
        allocator.free(value);
    }

    const generator: Generator([]const u8) = .{
        .generateFn = generate_fn,
        .shrinkFn = null,
        .freeFn = free_fn,
    };
};

const FailingIntGen = struct {
    fn generate_fn(_: *TestCase) core.GenError!i32 {
        return error.InvalidChoice;
    }

    const generator: Generator(i32) = .{
        .generateFn = generate_fn,
        .shrinkFn = null,
        .freeFn = null,
    };
};

test "regression: list generator frees produced elements on partial failure" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Inner generator succeeds 3 times then fails; list asks for 5 items.
    FailingStringGen.reset(3);
    const list_gen = list([]const u8, FailingStringGen.generator, 5, 5);
    try testing.expectError(core.GenError.InvalidChoice, list_gen.generateFn(&tc));
}

test "regression: hashMap generator frees produced entries on partial failure" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Use the failing string generator as the value side; key uses i32.
    // Produce 2 successful values, fail on the 3rd; ask for 5 entries.
    FailingStringGen.reset(2);
    const map_gen = hashMap(
        i32,
        []const u8,
        intRange(i32, 0, 1_000_000),
        FailingStringGen.generator,
        5,
        5,
    );
    try testing.expectError(core.GenError.InvalidChoice, map_gen.generateFn(&tc));
}

test "regression: array generator frees produced elements on partial failure" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    FailingStringGen.reset(2);
    const arr_gen = array([]const u8, 5, FailingStringGen.generator);
    try testing.expectError(core.GenError.InvalidChoice, arr_gen.generateFn(&tc));
}

test "regression: tuple2 frees first value when second generator fails" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // First generator always succeeds (allocates), second always fails.
    FailingStringGen.reset(1);
    const t = tuple2([]const u8, i32, FailingStringGen.generator, FailingIntGen.generator);
    try testing.expectError(core.GenError.InvalidChoice, t.generateFn(&tc));
}

test "regression: structure frees populated fields when later field fails" {
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    FailingStringGen.reset(1);
    const S = struct { name: []const u8, count: i32 };
    const s_gen = structure(S, .{
        .name = FailingStringGen.generator,
        .count = FailingIntGen.generator,
    });

    try testing.expectError(core.GenError.InvalidChoice, s_gen.generateFn(&tc));
}

test "regression: hashMap with collisions does not leak duplicate keys/values" {
    // With a tiny key range, every put attempt collides with an existing key.
    // The new key and the displaced value must both be freed.
    const allocator = testing.allocator;
    var tc = TestCase.init(allocator, 12345);
    defer tc.deinit();

    // Ten attempts cannot fill ten entries from a two-key domain.
    tc.max_size = 11;
    FailingStringGen.reset(10);
    const map_gen = hashMap(
        i32,
        []const u8,
        intRange(i32, 0, 1),
        FailingStringGen.generator,
        10,
        10,
    );
    try testing.expectError(error.Overrun, map_gen.generateFn(&tc));
}

test "hashMap retries collisions until the requested size is reached" {
    var tc = TestCase.init(testing.allocator, 42);
    defer tc.deinit();
    tc.prefix = &.{ 0, 0, 0, 1 };
    const g = hashMap(u8, bool, intRange(u8, 0, 1), constant(true), 2, 2);
    const value = try g.generateFn(&tc);
    defer g.freeFn.?(testing.allocator, value);
    try testing.expectEqual(@as(u32, 2), value.count());
    try testing.expect(value.contains(0) and value.contains(1));
    try testing.expectEqual(@as(usize, 4), tc.choices.items.len);
}

test "hashMap bounds retries even when generators make no random choices" {
    var tc = TestCase.init(testing.allocator, 42);
    defer tc.deinit();
    tc.max_size = 4;
    const g = hashMap(u8, bool, constant(@as(u8, 0)), constant(true), 2, 2);
    try testing.expectError(error.Overrun, g.generateFn(&tc));
    try testing.expectEqual(@as(usize, 1), tc.choices.items.len);
}

test "regression: nested lists retain ownership when properties fail" {
    const runner = @import("runner.zig");
    const g = list([]const u8, string(.{ .min_len = 1, .max_len = 1 }), 2, 2);
    try testing.expect(g.shrinkFn != null);
    const Property = struct {
        fn checkValue(_: []const []const u8) !void {
            return error.PropertyFailed;
        }
    };
    try testing.expectError(error.PropertyFailed, runner.check(testing.allocator, g, Property.checkValue, .{
        .seed = 1,
        .num_runs = 1,
    }));
    try testing.expect(list(i32, int(i32), 0, 10).shrinkFn != null);

    const uncloneable = comptime Generator([]const u8){
        .generateFn = string(.{}).generateFn,
        .shrinkFn = string(.{}).shrinkFn,
        .freeFn = string(.{}).freeFn,
    };
    const uncloneable_list = list([]const u8, uncloneable, 0, 2);
    try testing.expect(uncloneable_list.shrinkFn == null);
    try testing.expect(uncloneable_list.cloneFn == null);
}

test "owned string elements shrink through the runner without leaking" {
    const runner = @import("runner.zig");
    const Strings = struct {
        fn generate(tc: *TestCase) core.GenError![]const u8 {
            return tc.allocator.dupe(u8, "xxxx");
        }
    };
    const element_gen = comptime Generator([]const u8){
        .generateFn = Strings.generate,
        .shrinkFn = string(.{ .min_len = 1 }).shrinkFn,
        .freeFn = string(.{}).freeFn,
        .cloneFn = string(.{}).cloneFn,
    };
    const Property = struct {
        var last_failure: [2]usize = undefined;
        var passing_candidates: usize = 0;
        fn checkValue(value: []const []const u8) !void {
            try testing.expectEqual(@as(usize, 2), value.len);
            for (value) |s| try testing.expect(s.len >= 1);
            if (value[0].len + value[1].len > 2) {
                last_failure = .{ value[0].len, value[1].len };
                return error.PropertyFailed;
            }
            passing_candidates += 1;
        }
    };
    for ([_]u32{ 0, 1, 2, 1000 }) |budget| {
        Property.passing_candidates = 0;
        try testing.expectError(error.PropertyFailed, runner.check(
            testing.allocator,
            list([]const u8, element_gen, 2, 2),
            Property.checkValue,
            .{ .seed = 1, .num_runs = 1, .max_shrink_attempts = budget },
        ));
    }
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, &Property.last_failure);
    try testing.expect(Property.passing_candidates > 0);
}

test "nested list clones and shrink candidates own independent elements" {
    const g = list([]const []const u8, list([]const u8, string(.{ .min_len = 1 }), 1, 2), 1, 2);
    const original = try g.cloneFn.?(testing.allocator, &.{ &.{ "abc", "def" }, &.{ "ghi", "jkl" } });
    defer g.freeFn.?(testing.allocator, original);

    const copy = try g.cloneFn.?(testing.allocator, original);
    @constCast(copy[0][0])[0] = 'z';
    try testing.expectEqualStrings("abc", original[0][0]);
    g.freeFn.?(testing.allocator, copy);

    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    var saw_removal = false;
    var saw_element = false;
    while (it.next()) |candidate| {
        defer g.freeFn.?(testing.allocator, candidate);
        if (candidate.len < original.len) saw_removal = true else saw_element = true;
        try testing.expect(candidate.len >= 1);
        for (candidate) |inner| {
            try testing.expect(inner.len >= 1);
            for (inner) |s| {
                try testing.expect(s.len >= 1);
                for (original) |previous_inner| {
                    for (previous_inner) |previous| try testing.expect(s.ptr != previous.ptr);
                }
            }
        }
    }
    try testing.expect(saw_removal and saw_element);
    try testing.expectEqualStrings("abc", original[0][0]);
    try testing.expectEqualStrings("jkl", original[1][1]);
}

test "nested list cloning cleans up partial allocation failures" {
    const Test = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const g = list([]const []const u8, list([]const u8, string(.{}), 0, 2), 0, 2);
            const copy = try g.cloneFn.?(allocator, &.{ &.{ "abc", "def" }, &.{ "ghi", "jkl" } });
            defer g.freeFn.?(allocator, copy);
            try testing.expectEqualStrings("jkl", copy[1][1]);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Test.run, .{});
}

test "struct shrinking changes one field and copies unchanged owned fields" {
    const S = struct { id: i32, name: []const u8, enabled: bool };
    const g = comptime structure(S, .{
        .id = intRange(i32, 10, 100),
        .name = string(.{ .min_len = 1 }),
        .enabled = boolean(),
    });
    const original = try g.cloneFn.?(testing.allocator, .{ .id = 100, .name = "abcd", .enabled = true });
    defer g.freeFn.?(testing.allocator, original);
    const copy = try g.cloneFn.?(testing.allocator, original);
    @constCast(copy.name)[0] = 'z';
    try testing.expectEqualStrings("abcd", original.name);
    g.freeFn.?(testing.allocator, copy);

    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    var saw_id = false;
    var saw_name = false;
    while (it.next()) |candidate| {
        defer g.freeFn.?(testing.allocator, candidate);
        try testing.expect(candidate.enabled);
        try testing.expect(candidate.name.ptr != original.name.ptr);
        try testing.expect(candidate.id >= 10 and candidate.id <= 100);
        try testing.expect(candidate.name.len >= 1);
        if (candidate.id != original.id) {
            try testing.expect(!saw_name);
            try testing.expectEqualStrings(original.name, candidate.name);
            saw_id = true;
        } else {
            try testing.expect(candidate.name.len < original.name.len);
            saw_name = true;
        }
    }
    try testing.expect(saw_id and saw_name);
    try testing.expectEqualStrings("abcd", original.name);

    const outer = list(S, g, 1, 2);
    const items = try outer.cloneFn.?(testing.allocator, &.{ original, original });
    defer outer.freeFn.?(testing.allocator, items);
    var lists = outer.shrinkFn.?(testing.allocator, items);
    defer lists.deinit();
    while (lists.next()) |candidate| {
        defer outer.freeFn.?(testing.allocator, candidate);
        for (candidate) |item| try testing.expect(item.name.ptr != original.name.ptr);
    }
}

test "struct shrinking minimizes integer and string fields through the runner" {
    const runner = @import("runner.zig");
    const S = struct { id: i32, name: []const u8, enabled: bool };
    const Strings = struct {
        fn generate(tc: *TestCase) core.GenError![]const u8 {
            return tc.allocator.dupe(u8, "xxxx");
        }
    };
    const g = structure(S, .{
        .id = Generator(i32){
            .generateFn = constant(@as(i32, 100)).generateFn,
            .shrinkFn = int(i32).shrinkFn,
            .freeFn = null,
        },
        .name = Generator([]const u8){
            .generateFn = Strings.generate,
            .shrinkFn = string(.{ .min_len = 1 }).shrinkFn,
            .freeFn = string(.{}).freeFn,
            .cloneFn = string(.{}).cloneFn,
        },
        .enabled = constant(true),
    });
    const Property = struct {
        var last_id: i32 = undefined;
        var last_name_len: usize = undefined;
        var passing_candidates: usize = 0;
        fn checkValue(value: S) !void {
            try testing.expect(value.enabled and value.name.len >= 1);
            if (value.id > 8 or value.name.len > 2) {
                last_id = value.id;
                last_name_len = value.name.len;
                return error.PropertyFailed;
            }
            passing_candidates += 1;
        }
    };
    for ([_]u32{ 0, 1, 1000 }) |budget| {
        Property.passing_candidates = 0;
        try testing.expectError(error.PropertyFailed, runner.check(testing.allocator, g, Property.checkValue, .{
            .seed = 1,
            .num_runs = 1,
            .max_shrink_attempts = budget,
        }));
    }
    try testing.expectEqual(@as(i32, 0), Property.last_id);
    try testing.expectEqual(@as(usize, 3), Property.last_name_len);
    try testing.expect(Property.passing_candidates > 0);
}

test "struct cloning supports nested structs and partial allocation failures" {
    const Inner = struct { name: []const u8, count: i32 };
    const Outer = struct { inner: Inner, label: []const u8 };
    const g = comptime structure(Outer, .{
        .inner = structure(Inner, .{ .name = string(.{}), .count = int(i32) }),
        .label = string(.{}),
    });
    const Test = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const copy = try g.cloneFn.?(allocator, .{ .inner = .{ .name = "abcd", .count = 100 }, .label = "efgh" });
            defer g.freeFn.?(allocator, copy);
            try testing.expectEqualStrings("abcd", copy.inner.name);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Test.run, .{});
    const original = try g.cloneFn.?(testing.allocator, .{ .inner = .{ .name = "abcd", .count = 100 }, .label = "efgh" });
    defer g.freeFn.?(testing.allocator, original);
    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    var saw_nested_field = false;
    while (it.next()) |candidate| {
        defer g.freeFn.?(testing.allocator, candidate);
        try testing.expect(candidate.inner.name.ptr != original.inner.name.ptr);
        try testing.expect(candidate.label.ptr != original.label.ptr);
        if (candidate.inner.count != original.inner.count) saw_nested_field = true;
    }
    try testing.expect(saw_nested_field);
}

test "struct generators handle empty structs and fields without clone support" {
    const empty = structure(struct {}, .{});
    try testing.expect(empty.shrinkFn == null);
    var tc = TestCase.init(testing.allocator, 1);
    defer tc.deinit();
    _ = try empty.generateFn(&tc);
    _ = try empty.cloneFn.?(testing.allocator, .{});

    const S = struct { id: i32, name: []const u8 };
    const uncloneable = structure(S, .{
        .id = int(i32),
        .name = Generator([]const u8){
            .generateFn = string(.{ .min_len = 1, .max_len = 1 }).generateFn,
            .shrinkFn = string(.{}).shrinkFn,
            .freeFn = string(.{}).freeFn,
        },
    });
    try testing.expect(uncloneable.shrinkFn == null and uncloneable.cloneFn == null);
    const value = try uncloneable.generateFn(&tc);
    uncloneable.freeFn.?(testing.allocator, value);
}

test "arrays tuples and optionals shrink through the runner" {
    const runner = @import("runner.zig");
    const element = comptime Generator(i32){
        .generateFn = constant(@as(i32, 100)).generateFn,
        .shrinkFn = int(i32).shrinkFn,
        .freeFn = null,
    };
    const Some = struct {
        fn generate(_: *TestCase) core.GenError!?i32 {
            return 100;
        }
    };
    const some = comptime blk: {
        var g = optional(i32, element);
        g.generateFn = Some.generate;
        break :blk g;
    };
    inline for (.{
        .{ array(i32, 2, element), @as([2]i32, .{ 0, 9 }) },
        .{ tuple2(i32, i32, element, element), @as(struct { i32, i32 }, .{ 0, 9 }) },
        .{ tuple3(i32, bool, i32, element, constant(true), element), @as(struct { i32, bool, i32 }, .{ 0, true, 9 }) },
        .{ some, @as(?i32, 9) },
    }) |case| {
        const V = @TypeOf(case[1]);
        const Property = struct {
            var last_failure: V = undefined;
            var passing_candidates: usize = 0;
            fn checkValue(value: V) !void {
                const fails = switch (@typeInfo(V)) {
                    .optional => if (value) |v| v > 8 else false,
                    .array => value[0] + value[1] > 8,
                    .@"struct" => value[0] + value[std.meta.fields(V).len - 1] > 8,
                    else => unreachable,
                };
                if (fails) {
                    last_failure = value;
                    return error.PropertyFailed;
                }
                passing_candidates += 1;
            }
        };
        Property.passing_candidates = 0;
        try testing.expectError(error.PropertyFailed, runner.check(testing.allocator, case[0], Property.checkValue, .{
            .seed = 1,
            .num_runs = 1,
        }));
        try testing.expectEqualDeep(case[1], Property.last_failure);
        try testing.expect(Property.passing_candidates > 0);
    }
}

test "owned array and tuple candidates change one element without aliasing" {
    inline for (.{
        .{ array([]const u8, 2, string(.{ .min_len = 1 })), @as([2][]const u8, .{ "abcd", "efgh" }) },
        .{ tuple2([]const u8, []const u8, string(.{ .min_len = 1 }), string(.{ .min_len = 1 })), @as(struct { []const u8, []const u8 }, .{ "abcd", "efgh" }) },
        .{ tuple3([]const u8, []const u8, []const u8, string(.{ .min_len = 1 }), string(.{ .min_len = 1 }), string(.{ .min_len = 1 })), @as(struct { []const u8, []const u8, []const u8 }, .{ "abcd", "efgh", "ijkl" }) },
    }) |case| {
        const g = case[0];
        const V = @TypeOf(case[1]);
        const size = if (@typeInfo(V) == .array) @typeInfo(V).array.len else std.meta.fields(V).len;
        const original = try g.cloneFn.?(testing.allocator, case[1]);
        defer g.freeFn.?(testing.allocator, original);
        const copy = try g.cloneFn.?(testing.allocator, original);
        @constCast(copy[0])[0] = 'z';
        try testing.expectEqualStrings("abcd", original[0]);
        g.freeFn.?(testing.allocator, copy);
        var it = g.shrinkFn.?(testing.allocator, original);
        defer it.deinit();
        var saw_element = [_]bool{false} ** size;
        while (it.next()) |candidate| {
            defer g.freeFn.?(testing.allocator, candidate);
            var changed: usize = 0;
            inline for (0..size) |i| {
                try testing.expect(candidate[i].ptr != original[i].ptr);
                try testing.expect(candidate[i].len >= 1);
                if (candidate[i].len < original[i].len) {
                    changed += 1;
                    saw_element[i] = true;
                } else try testing.expectEqualStrings(original[i], candidate[i]);
            }
            try testing.expectEqual(@as(usize, 1), changed);
        }
        for (saw_element) |seen| try testing.expect(seen);
        try testing.expectEqualStrings("abcd", original[0]);
    }
}

test "nested optional shrinking preserves each null level" {
    const inner = comptime optional(i32, int(i32));
    const g = optional(?i32, inner);
    const original: ??i32 = @as(?i32, 100);
    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    const none = it.next();
    try testing.expect(none != null);
    try testing.expect(none.? == null);
    const some_none = it.next();
    try testing.expect(some_none != null and some_none.? != null);
    try testing.expect(some_none.?.? == null);
    const some_zero = it.next();
    try testing.expectEqual(@as(i32, 0), some_zero.?.?.?);

    var null_it = g.shrinkFn.?(testing.allocator, null);
    defer null_it.deinit();
    try testing.expect(null_it.next() == null);
    const clone = try g.cloneFn.?(testing.allocator, @as(?i32, null));
    try testing.expect(clone != null and clone.? == null);
}

test "owned optional shrinking transfers independent candidates" {
    const g = optional([]const u8, string(.{ .min_len = 1 }));
    const original = try g.cloneFn.?(testing.allocator, "abcd");
    defer g.freeFn.?(testing.allocator, original);
    const copy = try g.cloneFn.?(testing.allocator, original);
    @constCast(copy.?)[0] = 'z';
    try testing.expectEqualStrings("abcd", original.?);
    g.freeFn.?(testing.allocator, copy);
    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    const none = it.next();
    try testing.expect(none != null and none.? == null);
    var count: usize = 0;
    while (it.next()) |candidate| {
        defer g.freeFn.?(testing.allocator, candidate);
        try testing.expect(candidate.?.ptr != original.?.ptr);
        try testing.expect(candidate.?.len >= 1 and candidate.?.len < original.?.len);
        count += 1;
    }
    try testing.expect(count > 0);
    try testing.expectEqualStrings("abcd", original.?);
}

test "array tuple and optional ownership cleans up allocation failures" {
    inline for (comptime .{
        .{ array([]const u8, 3, string(.{ .min_len = 1 })), @as([3][]const u8, .{ "abcd", "efgh", "ijkl" }) },
        .{ tuple2([]const u8, []const u8, string(.{ .min_len = 1 }), string(.{ .min_len = 1 })), @as(struct { []const u8, []const u8 }, .{ "abcd", "efgh" }) },
        .{ tuple3([]const u8, []const u8, []const u8, string(.{ .min_len = 1 }), string(.{ .min_len = 1 }), string(.{ .min_len = 1 })), @as(struct { []const u8, []const u8, []const u8 }, .{ "abcd", "efgh", "ijkl" }) },
        .{ optional([]const u8, string(.{ .min_len = 1 })), @as(?[]const u8, "abcd") },
    }) |case| {
        const g = comptime case[0];
        const original = comptime case[1];
        const Test = struct {
            fn clone(allocator: std.mem.Allocator) !void {
                const copy = try g.cloneFn.?(allocator, original);
                defer g.freeFn.?(allocator, copy);
            }
            fn shrink(allocator: std.mem.Allocator) void {
                var it = g.shrinkFn.?(allocator, original);
                defer it.deinit();
                while (it.next()) |candidate| g.freeFn.?(allocator, candidate);
            }
        };
        try testing.checkAllAllocationFailures(testing.allocator, Test.clone, .{});
        var counter = testing.FailingAllocator.init(testing.allocator, .{});
        Test.shrink(counter.allocator());
        try testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
        for (0..counter.alloc_index) |fail_index| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            Test.shrink(failing.allocator());
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "containers preserve fallback behavior without clone support" {
    const uncloneable = comptime Generator([]const u8){
        .generateFn = string(.{}).generateFn,
        .shrinkFn = string(.{}).shrinkFn,
        .freeFn = string(.{}).freeFn,
    };
    inline for (.{ array([]const u8, 2, uncloneable), tuple2(i32, []const u8, int(i32), uncloneable), tuple3(i32, bool, []const u8, int(i32), boolean(), uncloneable) }) |g| {
        try testing.expect(g.shrinkFn == null and g.cloneFn == null);
    }
    const opt = optional([]const u8, uncloneable);
    try testing.expect(opt.shrinkFn != null and opt.cloneFn == null);
    var it = opt.shrinkFn.?(testing.allocator, "abcd");
    defer it.deinit();
    while (it.next()) |candidate| opt.freeFn.?(testing.allocator, candidate);

    const empty = array(i32, 0, int(i32));
    try testing.expect(empty.shrinkFn == null);
    _ = try empty.cloneFn.?(testing.allocator, .{});
    try testing.expect(array(i32, 2, constant(@as(i32, 1))).shrinkFn == null);
}

test "new container clones compose with struct shrinking" {
    const S = struct { values: [2]?[]const u8, pair: struct { i32, []const u8 } };
    const g = structure(S, .{
        .values = array(?[]const u8, 2, optional([]const u8, string(.{ .min_len = 1 }))),
        .pair = tuple2(i32, []const u8, int(i32), string(.{ .min_len = 1 })),
    });
    const original = try g.cloneFn.?(testing.allocator, .{ .values = .{ "abcd", null }, .pair = .{ 100, "efgh" } });
    defer g.freeFn.?(testing.allocator, original);
    var it = g.shrinkFn.?(testing.allocator, original);
    defer it.deinit();
    var saw_null = false;
    var saw_number = false;
    while (it.next()) |candidate| {
        defer g.freeFn.?(testing.allocator, candidate);
        try testing.expect(candidate.values[1] == null);
        if (candidate.values[0]) |s| {
            try testing.expect(s.ptr != original.values[0].?.ptr and s.len >= 1);
        } else saw_null = true;
        try testing.expect(candidate.pair[1].ptr != original.pair[1].ptr);
        try testing.expect(candidate.pair[1].len >= 1);
        if (candidate.pair[0] != original.pair[0]) saw_number = true;
    }
    try testing.expect(saw_null and saw_number);
    try testing.expectEqualStrings("abcd", original.values[0].?);
    try testing.expectEqualStrings("efgh", original.pair[1]);
}

test "regression: constrained generators preserve bounds while shrinking" {
    inline for (.{ .{ 10, 100 }, .{ -100, -10 }, .{ -10, 10 }, .{ 10, 10 } }) |bounds| {
        const g = intRange(i32, bounds[0], bounds[1]);
        inline for (.{ bounds[0], bounds[1] }) |value| {
            var it = g.shrinkFn.?(testing.allocator, value);
            defer it.deinit();
            while (it.next()) |candidate| {
                try testing.expect(candidate >= bounds[0] and candidate <= bounds[1]);
            }
        }
        const f = floatRange(f64, bounds[0], bounds[1]);
        var it = f.shrinkFn.?(testing.allocator, bounds[0]);
        defer it.deinit();
        while (it.next()) |candidate| {
            try testing.expect(candidate >= bounds[0] and candidate <= bounds[1]);
        }
    }
    var chars = char().shrinkFn.?(testing.allocator, 126);
    defer chars.deinit();
    while (chars.next()) |candidate| try testing.expect(candidate >= 32 and candidate <= 126);

    var timestamps = timestampRange(100, 200).shrinkFn.?(testing.allocator, 200);
    defer timestamps.deinit();
    while (timestamps.next()) |candidate| try testing.expect(candidate >= 100 and candidate <= 200);

    inline for (.{ string(.{ .min_len = 3 }), list(u8, int(u8), 3, 10) }) |g| {
        var it = g.shrinkFn.?(testing.allocator, "abcdef");
        defer it.deinit();
        var count: usize = 0;
        while (it.next()) |candidate| {
            defer g.freeFn.?(testing.allocator, candidate);
            try testing.expect(candidate.len >= 3 and candidate.len <= 6);
            count += 1;
        }
        try testing.expect(count > 0);
        var minimum = g.shrinkFn.?(testing.allocator, "abc");
        defer minimum.deinit();
        while (minimum.next()) |candidate| {
            defer g.freeFn.?(testing.allocator, candidate);
            try testing.expectEqual(@as(usize, 3), candidate.len);
        }
    }
}

test "regression: finite float ranges do not overflow" {
    inline for (.{ f16, f32, f64 }) |T| {
        const bound = std.math.floatMax(T);
        const g = floatRange(T, -bound, bound);
        for ([_]u64{ 0, std.math.maxInt(u32) / 2, std.math.maxInt(u32) }) |choice| {
            var tc = TestCase.init(testing.allocator, 1);
            defer tc.deinit();
            tc.prefix = &.{choice};
            const value = try g.generateFn(&tc);
            try testing.expect(std.math.isFinite(value));
            try testing.expect(value >= -bound and value <= bound);
            if (choice == 0) try testing.expectEqual(-bound, value);
            if (choice == std.math.maxInt(u32)) try testing.expectEqual(bound, value);
        }
    }
}

test "f16 ranges retain endpoints and interior values" {
    const g = floatRange(f16, 0, 1);
    for ([_]u64{ 0, 1073741824, 2147483648, std.math.maxInt(u32) }, [_]f16{ 0, 0.25, 0.5, 1 }) |choice, expected| {
        var tc = TestCase.init(testing.allocator, 42);
        defer tc.deinit();
        tc.prefix = &.{choice};
        try testing.expectEqual(expected, try g.generateFn(&tc));
    }
}

test "list shrinking minimizes elements through the runner" {
    const runner = @import("runner.zig");
    const Property = struct {
        var last_failure: [2]i32 = undefined;
        fn checkValue(value: []const i32) !void {
            try testing.expectEqual(@as(usize, 2), value.len);
            if (value[0] + value[1] > 8) {
                @memcpy(&last_failure, value);
                return error.PropertyFailed;
            }
        }
    };
    const element_gen = comptime Generator(i32){
        .generateFn = constant(@as(i32, 100)).generateFn,
        .shrinkFn = int(i32).shrinkFn,
        .freeFn = null,
    };
    try testing.expectError(error.PropertyFailed, runner.check(
        testing.allocator,
        list(i32, element_gen, 2, 2),
        Property.checkValue,
        .{ .seed = 1, .num_runs = 1 },
    ));
    try testing.expectEqualSlices(i32, &.{ 0, 9 }, &Property.last_failure);
}

test "regression: timestamps support the full signed range" {
    const g = timestampRange(std.math.minInt(i64), std.math.maxInt(i64));
    for ([_]u64{ 0, std.math.maxInt(u64) }) |choice| {
        var tc = TestCase.init(testing.allocator, 1);
        defer tc.deinit();
        tc.prefix = &.{choice};
        const value = try g.generateFn(&tc);
        const expected: i64 = if (choice == 0) std.math.minInt(i64) else std.math.maxInt(i64);
        try testing.expectEqual(expected, value);
    }
}
