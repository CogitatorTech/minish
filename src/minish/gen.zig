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
/// - `shrinkFn`: Optional function to produce smaller values for shrinking
/// - `freeFn`: Optional function to free allocated memory
pub fn Generator(comptime T: type) type {
    return struct {
        generateFn: *const fn (tc: *TestCase) core.GenError!T,
        shrinkFn: ?*const fn (std.mem.Allocator, T) shrink_mod.Iterator(T),
        freeFn: ?*const fn (std.mem.Allocator, T) void,
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
                const UnsignedT = @Type(.{ .int = .{ .bits = IntType.bits, .signedness = .unsigned } });
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
    const RangeGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            return tc.choiceInRange(T, min, max);
        }
    };
    return .{ .generateFn = RangeGenerator.generate, .shrinkFn = shrink_mod.intShrinker(T), .freeFn = null };
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
    const RangeGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            // Generate a value in [0, 1] and scale to range
            const mantissa = try tc.choice(std.math.maxInt(u32));
            const normalized: T = @as(T, @floatFromInt(mantissa)) / @as(T, @floatFromInt(std.math.maxInt(u32)));
            return min + normalized * (max - min);
        }
    };
    return .{ .generateFn = RangeGenerator.generate, .shrinkFn = shrink_mod.floatShrinker(T), .freeFn = null };
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
    const CharGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!u8 {
            const val = try tc.choice(94); // 126 - 32 = 94 characters
            return @intCast(32 + val); // Start from space (32)
        }
    };
    return .{ .generateFn = CharGenerator.generate, .shrinkFn = shrink_mod.intShrinker(u8), .freeFn = null };
}

/// Generate a single character from a specific character set.
pub fn charFrom(comptime charset: []const u8) Generator(u8) {
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
                for (0..section_len) |i| {
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
                    _ = i;
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
    const TimestampGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!i64 {
            const range: u64 = @intCast(max - min);
            const offset = try tc.choice(range);
            return min + @as(i64, @intCast(offset));
        }
    };
    return .{ .generateFn = TimestampGenerator.generate, .shrinkFn = shrink_mod.intShrinker(i64), .freeFn = null };
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
    const StringGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![]const u8 {
            const len = config.min_len + try tc.choice(config.max_len - config.min_len);
            const chars = config.charset.getChars(config.custom_chars);

            var result = std.ArrayList(u8).empty;
            errdefer result.deinit(tc.allocator);

            for (0..len) |_| {
                const idx = try tc.choice(chars.len - 1);
                try result.append(tc.allocator, chars[idx]);
            }

            return result.toOwnedSlice(tc.allocator);
        }

        fn free(allocator: std.mem.Allocator, value: []const u8) void {
            allocator.free(value);
        }
    };
    return .{ .generateFn = StringGenerator.generate, .shrinkFn = shrink_mod.stringShrinker(), .freeFn = StringGenerator.free };
}

// ============================================================================
// Collection Generators
// ============================================================================

/// Generate a list of values.
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
    const ListGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![]const T {
            const len = min_len + try tc.choice(max_len - min_len);
            var result = std.ArrayList(T).empty;
            errdefer result.deinit(tc.allocator);
            for (0..len) |_| {
                try result.append(tc.allocator, try element_gen.generateFn(tc));
            }
            return result.toOwnedSlice(tc.allocator);
        }

        fn free(allocator: std.mem.Allocator, value: []const T) void {
            if (element_gen.freeFn) |freeFn| {
                for (value) |item| {
                    freeFn(allocator, item);
                }
            }
            allocator.free(value);
        }
    };
    return .{ .generateFn = ListGenerator.generate, .shrinkFn = shrink_mod.listShrinker(T), .freeFn = ListGenerator.free };
}

// ============================================================================
// HashMap Generator
// ============================================================================

/// Generate a HashMap with random keys and values.
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
    const HashMapGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!std.AutoHashMap(K, V) {
            const num_entries = min_entries + try tc.choice(max_entries - min_entries);

            var map = std.AutoHashMap(K, V).init(tc.allocator);
            errdefer map.deinit();

            var i: usize = 0;
            while (i < num_entries) : (i += 1) {
                const key = try key_gen.generateFn(tc);
                const value = try value_gen.generateFn(tc);
                try map.put(key, value);
            }

            return map;
        }

        fn free(allocator: std.mem.Allocator, map: std.AutoHashMap(K, V)) void {
            // We need to free keys and values if they have freeFn
            if (key_gen.freeFn != null or value_gen.freeFn != null) {
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (key_gen.freeFn) |freeKey| {
                        freeKey(allocator, entry.key_ptr.*);
                    }
                    if (value_gen.freeFn) |freeVal| {
                        freeVal(allocator, entry.value_ptr.*);
                    }
                }
            }
            var mut_map = map;
            mut_map.deinit();
        }
    };
    return .{ .generateFn = HashMapGenerator.generate, .shrinkFn = null, .freeFn = HashMapGenerator.free };
}

/// Generate a fixed-size array.
///
/// Memory lifecycle: The returned array matches the ownership of its elements.
/// If elements are allocated, they will be freed automatically.
pub fn array(comptime T: type, comptime size: usize, comptime element_gen: Generator(T)) Generator([size]T) {
    const ArrayGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![size]T {
            var result: [size]T = undefined;
            for (0..size) |i| {
                result[i] = try element_gen.generateFn(tc);
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
    };
    return .{ .generateFn = ArrayGenerator.generate, .shrinkFn = null, .freeFn = ArrayGenerator.free };
}

// ============================================================================
// Option/Nullable Generator
// ============================================================================

/// Generate an optional value (Some or None).
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
    };
    return .{ .generateFn = OptionalGenerator.generate, .shrinkFn = null, .freeFn = OptionalGenerator.free };
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
///
/// Memory lifecycle: The tuple and its elements are owned by the Minish runner
/// and will be freed automatically.
pub fn tuple2(comptime T1: type, comptime T2: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2)) Generator(struct { T1, T2 }) {
    const TupleGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T1, T2 } {
            return .{
                try gen1.generateFn(tc),
                try gen2.generateFn(tc),
            };
        }

        fn free(allocator: std.mem.Allocator, value: struct { T1, T2 }) void {
            if (gen1.freeFn) |freeFn| freeFn(allocator, value[0]);
            if (gen2.freeFn) |freeFn| freeFn(allocator, value[1]);
        }
    };
    return .{ .generateFn = TupleGenerator.generate, .shrinkFn = null, .freeFn = TupleGenerator.free };
}

/// Generate a 3-tuple with generic types.
///
/// Memory lifecycle: The tuple and its elements are owned by the Minish runner
/// and will be freed automatically.
pub fn tuple3(comptime T1: type, comptime T2: type, comptime T3: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2), comptime gen3: Generator(T3)) Generator(struct { T1, T2, T3 }) {
    const TupleGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T1, T2, T3 } {
            return .{
                try gen1.generateFn(tc),
                try gen2.generateFn(tc),
                try gen3.generateFn(tc),
            };
        }

        fn free(allocator: std.mem.Allocator, value: struct { T1, T2, T3 }) void {
            if (gen1.freeFn) |freeFn| freeFn(allocator, value[0]);
            if (gen2.freeFn) |freeFn| freeFn(allocator, value[1]);
            if (gen3.freeFn) |freeFn| freeFn(allocator, value[2]);
        }
    };
    return .{ .generateFn = TupleGenerator.generate, .shrinkFn = null, .freeFn = TupleGenerator.free };
}

// Legacy tuple function for backwards compatibility
fn generate_tuple(tc: *TestCase) core.GenError!struct { i32, i32 } {
    return .{
        try generate_int(i32)(tc),
        try generate_int(i32)(tc),
    };
}

pub fn tuple() Generator(struct { i32, i32 }) {
    return .{ .generateFn = generate_tuple, .shrinkFn = shrink_mod.tuple2IntShrinker(i32, i32), .freeFn = null };
}

// ============================================================================
// Combinator: oneOf
// ============================================================================

/// Choose one generator from a list with equal probability.
///
/// Example:
/// ```zig
/// const mixed_gen = gen.oneOf(i32, &.{
///     gen.intRange(i32, 0, 10),
///     gen.constant(@as(i32, 100))
/// });
/// ```
///
/// Memory lifecycle: The returned value is owned by the Minish runner and will be freed automatically.
/// Note: This assumes all generators share compatible memory management logic (e.g., typically same type).
pub fn oneOf(comptime T: type, comptime generators: []const Generator(T)) Generator(T) {
    const OneOfGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            if (generators.len == 0) return error.InvalidChoice;
            const idx = try tc.choice(generators.len - 1);
            return generators[idx].generateFn(tc);
        }

        fn free(allocator: std.mem.Allocator, value: T) void {
            // We don't know which generator created it, so we can't easily free it recursively
            // without storing which generator was used.
            // However, for OneOf, we assume all generators produce the same type T.
            // If T has a single canonical free strategy (e.g. it's a struct with known fields),
            // we could try to free it.
            // But if T implies different allocation strategies per variant, it's hard.
            // BEST EFFORT: Use the freeFn of the first generator if available?
            // Or iterate generators? No, that's wrong.

            // Correct approach: OneOf should return a wrapper or we accept that strict heterogeneity
            // isn't supported for managed types OR we require all generators to share a freeFn logic.
            // For now, let's assume if the first generator has a freeFn, it works for all
            // (often they are same type generators).
            if (generators.len > 0 and generators[0].freeFn != null) {
                generators[0].freeFn.?(allocator, value);
            }
        }
    };
    return .{ .generateFn = OneOfGenerator.generate, .shrinkFn = null, .freeFn = OneOfGenerator.free };
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
/// Memory lifecycle: The returned struct and its fields are owned by the Minish runner
/// and will be freed automatically.
pub fn structure(
    comptime T: type,
    comptime field_gens: anytype,
) Generator(T) {
    const StructGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            const type_info = @typeInfo(T);
            if (type_info != .@"struct") {
                @compileError("structure() requires a struct type");
            }

            var result: T = undefined;
            const struct_info = type_info.@"struct";

            inline for (struct_info.fields) |field| {
                const field_gen = @field(field_gens, field.name);
                @field(result, field.name) = try field_gen.generateFn(tc);
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
    };
    return .{ .generateFn = StructGenerator.generate, .shrinkFn = null, .freeFn = StructGenerator.free };
}

// ============================================================================
// Dependent Generator
// ============================================================================

/// Create a generator that depends on a previously generated value.
/// Useful for generating related data where one field constrains another.
pub fn dependent(
    comptime T: type,
    comptime U: type,
    comptime first_gen: Generator(T),
    comptime make_gen: fn (T) Generator(U),
) Generator(struct { T, U }) {
    const DependentGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T, U } {
            const first_val = try first_gen.generateFn(tc);
            const second_gen = make_gen(first_val);
            const second_val = try second_gen.generateFn(tc);
            return .{ first_val, second_val };
        }

        fn free(allocator: std.mem.Allocator, value: struct { T, U }) void {
            if (first_gen.freeFn) |freeFn| {
                freeFn(allocator, value[0]);
            }
            // For the dependent value, we need to regenerate the generator to access its freeFn.
            // Ideally core.Generator would be uniform, but here make_gen is a function.
            const second_gen = make_gen(value[0]);
            if (second_gen.freeFn) |freeFn| {
                freeFn(allocator, value[1]);
            }
        }
    };
    return .{ .generateFn = DependentGenerator.generate, .shrinkFn = null, .freeFn = DependentGenerator.free };
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
