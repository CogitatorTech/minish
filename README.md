<div align="center">
  <picture>
    <img alt="Minish Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Minish</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/CogitatorTech/minish/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/minish/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/CogitatorTech/minish/blob/main/LICENSE)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/CogitatorTech/minish/tree/main/examples)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://CogitatorTech.github.io/minish/)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/CogitatorTech/minish.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/minish/releases/latest)

A property-based testing framework for Zig

</div>

---

Minish is a small [property-based testing](https://en.wikipedia.org/wiki/Software_testing#Property_testing) framework
for Zig,
inspired by [QuickCheck](https://hackage.haskell.org/package/QuickCheck)
and [Hypothesis](https://hypothesis.readthedocs.io/en/latest/).

### What is Property-based Testing?

Property-based testing is a way of testing software by defining properties that should always hold.
Compared to typical example-based testing (like unit tests), instead of writing individual test cases with specific
inputs and expected outputs, you define general properties about your code's behavior.
The testing framework then generates a wide range of random inputs to verify that these properties hold for all cases.

Given a piece of code like a function and its property, a property-based testing workflow normally involves the
following steps:

1. Generating a lot of random inputs.
2. Finding cases where the input causes the property to fail.
3. Finding smaller subsets of the failing input that still cause the failure (this is called "shrinking").

For example, consider the property of a `reverse(s: []const u8)` function that states that reversing
a string twice should return the original string.
In property-based testing, you would define this property and let the framework generate a lot of random strings to
test it.
If it finds a string that makes the property fail (due to a bug in the reverse function, for example), it will then try
to shrink that string to a simpler or shorter case that still makes the property fail.

Here is a brief comparison between example-based testing and property-based testing paradigms:

| Criterion | Example-based Testing          | Property-based Testing                     |
|-----------|--------------------------------|--------------------------------------------|
| Input     | Hand-written specific values   | Auto-generated random values               |
| Coverage  | Only cases you can think of    | Discovers edge cases automatically         |
| Debugging | Exact failing inputs are known | Shrinks to minimal failing case            |
| Effort    | Write a lot of test cases      | Define one property, test with many inputs |

### Why Minish?

- Written in pure Zig with no external dependencies
- Includes over 25 built-in generators (like for integers, floats, strings, lists, structs, UUIDs, timestamps, etc.)
- Combinators to build complex generators from simple ones (map, filter, flatMap, frequency)
- Supports automatic shrinking for integers, floats, strings, lists, tuples, and arrays
- Supports reproducible failures and verbose mode
- Configurable and easy to integrate into existing Zig projects

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> Minish is in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/CogitatorTech/minish/issues) to report bugs or request features.

---

### Getting Started

You can add Minish to your project and start using it by following the steps below.

#### Installation

Run the following command in the root directory of your project to download Minish:

```sh
zig fetch --save=minish "https://github.com/CogitatorTech/minish/archive/<branch_or_tag>.tar.gz"
```

Replace `<branch_or_tag>` with the desired branch or release tag, like `main` (for the development version) or `v0.1.0`.
This command will download Minish and add it to Zig's global cache and update your project's `build.zig.zon` file.

> [!NOTE]
> Minsih is developed and tested with Zig version 0.15.2.

#### Adding to Build Script

Next, modify your `build.zig` file to make Minish available to your build target as a module.

```zig
pub fn build(b: *std.Build) void {
    // ... the existing setup ...

    const minish_dep = b.dependency("minish", .{});
    const minish_module = minish_dep.module("minish");
    exe.root_module.addImport("minish", minish_module);
}
```

#### A Simple Example

Finally, you can `@import("minish")` and start using it in your Zig project.

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

### Documentation

You can find the API documentation for the latest release of Minish [here](https://CogitatorTech.github.io/minish/).

Alternatively, you can use the `make docs` command to generate the documentation for the current version of Minish.
This will generate HTML documentation in the `docs/api` directory, which you can serve locally with `make serve-docs`
and view in a web browser.

### Examples

Check out the [examples](examples) directory for example usages of Minish.

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

Minish is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/426957/hat) with some modifications.
