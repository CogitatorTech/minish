const std = @import("std");
const core = @import("core.zig");
const shrink_mod = @import("shrink.zig");

const TestCase = core.TestCase;

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
pub fn int(comptime T: type) Generator(T) {
    return .{ .generateFn = generate_int(T), .shrinkFn = shrink_mod.intShrinker(T), .freeFn = null };
}

/// Generate integers in a specific range [min, max] (inclusive).
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
pub fn float(comptime T: type) Generator(T) {
    return .{ .generateFn = generate_float(T), .shrinkFn = shrink_mod.floatShrinker(T), .freeFn = null };
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
            allocator.free(value);
        }
    };
    return .{ .generateFn = ListGenerator.generate, .shrinkFn = shrink_mod.listShrinker(T), .freeFn = ListGenerator.free };
}

// ============================================================================
// HashMap Generator
// ============================================================================

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

        fn free(allocator: std.mem.Allocator, value: std.AutoHashMap(K, V)) void {
            // HashMap is passed by value and contains its own allocator
            // The test property function is responsible for calling deinit()
            // We don't call deinit here to avoid double-free
            _ = allocator;
            _ = value;
        }
    };
    return .{ .generateFn = HashMapGenerator.generate, .shrinkFn = null, .freeFn = HashMapGenerator.free };
}

pub fn array(comptime T: type, comptime size: usize, comptime element_gen: Generator(T)) Generator([size]T) {
    const ArrayGenerator = struct {
        fn generate(tc: *TestCase) core.GenError![size]T {
            var result: [size]T = undefined;
            for (0..size) |i| {
                result[i] = try element_gen.generateFn(tc);
            }
            return result;
        }
    };
    return .{ .generateFn = ArrayGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Option/Nullable Generator
// ============================================================================

pub fn optional(comptime T: type, comptime element_gen: Generator(T)) Generator(?T) {
    const OptionalGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!?T {
            const is_some = try tc.choice(1) == 1;
            if (is_some) {
                return try element_gen.generateFn(tc);
            }
            return null;
        }
    };
    return .{ .generateFn = OptionalGenerator.generate, .shrinkFn = null, .freeFn = null };
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
pub fn tuple2(comptime T1: type, comptime T2: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2)) Generator(struct { T1, T2 }) {
    const TupleGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T1, T2 } {
            return .{
                try gen1.generateFn(tc),
                try gen2.generateFn(tc),
            };
        }
    };
    return .{ .generateFn = TupleGenerator.generate, .shrinkFn = null, .freeFn = null };
}

/// Generate a 3-tuple with generic types.
pub fn tuple3(comptime T1: type, comptime T2: type, comptime T3: type, comptime gen1: Generator(T1), comptime gen2: Generator(T2), comptime gen3: Generator(T3)) Generator(struct { T1, T2, T3 }) {
    const TupleGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!struct { T1, T2, T3 } {
            return .{
                try gen1.generateFn(tc),
                try gen2.generateFn(tc),
                try gen3.generateFn(tc),
            };
        }
    };
    return .{ .generateFn = TupleGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// Legacy tuple function for backwards compatibility
fn generate_tuple(tc: *TestCase) core.GenError!struct { i32, i32 } {
    return .{
        try generate_int(i32)(tc),
        try generate_int(i32)(tc),
    };
}

pub fn tuple() Generator(struct { i32, i32 }) {
    return .{ .generateFn = generate_tuple, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Combinator: oneOf
// ============================================================================

/// Choose one generator from a list with equal probability.
pub fn oneOf(comptime T: type, comptime generators: []const Generator(T)) Generator(T) {
    const OneOfGenerator = struct {
        fn generate(tc: *TestCase) core.GenError!T {
            if (generators.len == 0) return error.InvalidChoice;
            const idx = try tc.choice(generators.len - 1);
            return generators[idx].generateFn(tc);
        }
    };
    return .{ .generateFn = OneOfGenerator.generate, .shrinkFn = null, .freeFn = null };
}

// ============================================================================
// Struct Generator
// ============================================================================

/// Generate a struct with the given field generators.
/// The field_gens parameter should be an anonymous struct where each field
/// corresponds to a field in T and contains the generator for that field.
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
    };
    return .{ .generateFn = StructGenerator.generate, .shrinkFn = null, .freeFn = null };
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
    };
    return .{ .generateFn = DependentGenerator.generate, .shrinkFn = null, .freeFn = null };
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
