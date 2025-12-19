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

Minish is a [property-based testing](https://en.wikipedia.org/wiki/Software_testing#Property_testing) framework for Zig.
It is inspired by [QuickCheck](https://hackage.haskell.org/package/QuickCheck)
and [Hypothesis](https://hypothesis.readthedocs.io/en/latest/) frameworks.
Minish allows you to write tests that verify the correctness of your code by checking that certain properties always
hold true instead of writing individual test cases.
It automatically generates random inputs and shrinks failing cases to find minimal counterexamples that break your
assumptions about your code.

### Features

- 25+ built-in generators (integers, floats, strings, lists, structs, UUIDs, timestamps, etc.)
- Composable combinators (map, filter, flatMap, frequency)
- Automatic shrinking for integers, floats, strings, lists, tuples, and arrays
- Configurable max shrink attempts and verbose mode
- Reproducible failures

---

### Quick Start

#### Installation

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

#### A Simple Example

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
