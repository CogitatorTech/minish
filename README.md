<div align="center">
  <picture>
    <img alt="Minish Logo" src="logo.svg" height="30%" width="30%">
  </picture>
<br>

<h2>Minish</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/CogitatorTech/minish/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/minish/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/CogitatorTech/minish/blob/main/LICENSE)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/CogitatorTech/minish/tree/main/examples)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.1-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/CogitatorTech/minish.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/minish/releases/latest)

A property-based testing framework for Zig

</div>

---

## Overview

Minish is a [property-based testing](https://en.wikipedia.org/wiki/Property_testing) framework for Zig, inspired by QuickCheck and Hypothesis.

Instead of writing individual test cases, you define **properties** that should always hold true for your code. Minish then generates hundreds of random inputs to find edge cases that break your assumptions.

**Features:**
- 20+ built-in generators (integers, floats, strings, lists, structs, etc.)
- Composable combinators (map, filter, flatMap, frequency)
- Automatic shrinking for integers, floats, strings, and lists
- Zero memory leaks
- Comprehensive test coverage

---

## Quick Start

### Installation

Add Minish to your project:

```sh
zig fetch --save=minish "https://github.com/CogitatorTech/minish/archive/main.tar.gz"
```

Update your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    // ... your existing setup ...

    const minish_dep = b.dependency("minish", .{});
    const minish_module = minish_dep.module("minish");
    exe.root_module.addImport("minish", minish_module);
}
```

### Basic Example

```zig
const std = @import("std");
const minish = @import("minish");
const gen = minish.gen;

// Property: reversing a string twice returns the original
fn reverse_twice_is_identity(s: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const once = try reverse(allocator, s);
    defer allocator.free(once);
    
    const twice = try reverse(allocator, once);
    defer allocator.free(twice);

    try std.testing.expectEqualStrings(s, twice);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate random strings and test the property
    const string_gen = gen.string(.{
        .min_len = 0,
        .max_len = 100,
        .charset = .alphanumeric,
    });

    try minish.check(allocator, string_gen, reverse_twice_is_identity, .{
        .num_runs = 100,
    });
}
```

---

## Generators

Minish provides generators for common data types:

### Basic Types

```zig
const gen = minish.gen;

// Integers
gen.int(i32)                    // Any i32 value
gen.int(u64)                    // Any u64 value
gen.intRange(i32, -10, 10)      // Integers in range [-10, 10]

// Floats
gen.float(f32)                  // f32 values
gen.float(f64)                  // f64 values

// Booleans
gen.boolean()                   // true or false

// Constants
gen.constant(42)                // Always returns 42
```

### Strings

```zig
// Default alphanumeric string
gen.string(.{ .min_len = 5, .max_len = 20 })

// Custom character set
gen.string(.{
    .min_len = 1,
    .max_len = 10,
    .charset = .ascii,
})

// Available charsets: .ascii, .alphanumeric, .alpha, .numeric, .printable, .custom
```

### Collections

```zig
// Lists (dynamic slices)
gen.list(i32, gen.int(i32), 0, 10)  // List of 0-10 integers

// Fixed-size arrays
gen.array(u8, 5, gen.int(u8))       // Array of exactly 5 u8 values

// Optional values
gen.optional(i32, gen.int(i32))     // ?i32 (Some or None)
```

### Tuples

```zig
// 2-tuples
gen.tuple2(i32, bool, gen.int(i32), gen.boolean())

// 3-tuples
gen.tuple3(i32, bool, f32, gen.int(i32), gen.boolean(), gen.float(f32))
```

### Structs

```zig
const Person = struct {
    age: u8,
    height_cm: u16,
    is_student: bool,
};

const person_gen = gen.structure(Person, .{
    .age = gen.intRange(u8, 0, 120),
    .height_cm = gen.intRange(u16, 50, 250),
    .is_student = gen.boolean(),
});
```

---

## Combinators

Compose generators for more complex data:

```zig
const combinators = minish.combinators;

// Map: transform generated values
const squared = combinators.map(i32, i32, gen.int(i32), square_fn);

// Filter: only generate values matching a predicate
const positive = combinators.filter(i32, gen.int(i32), is_positive, 100);

// Frequency: weighted choice between generators
const weighted = combinators.frequency(i32, &.{
    .{ .weight = 70, .gen = gen.intRange(i32, 0, 10) },
    .{ .weight = 30, .gen = gen.intRange(i32, 100, 200) },
});

// OneOf: choose one generator uniformly
const choice = gen.oneOf(i32, &.{
    gen.constant(1),
    gen.constant(2),
    gen.constant(3),
});
```

---

## Configuration Options

```zig
try minish.check(allocator, generator, property_fn, .{
    .num_runs = 100,        // Number of test cases
    .seed = 12345,          // Optional: fixed seed for reproducibility
});
```

---

## Examples

See the [examples](examples) directory for complete examples:

- **e1_simple_example.zig** - Basic tuple generator
- **e2_string_example.zig** - String property testing
- **e3_list_example.zig** - List property testing (sorting)
- **e4_advanced_generators.zig** - Multiple generator types
- **e5_struct_and_combinators.zig** - Struct generation and combinators

Run all examples:

```sh
zig build run-all
```

---

## Testing

Run the test suite:

```sh
zig build test
```

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

## License

Minish is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

---

## Acknowledgements

- Logo from [SVG Repo](https://www.svgrepo.com/svg/532646/hat-witch) with modifications
- Inspired by QuickCheck, Hypothesis, and other property-based testing frameworks
