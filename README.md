<div align="center">
  <picture>
    <img alt="Minish Logo" src="logo.svg" height="35%" width="35%">
  </picture>
<br>

<h2>Minish</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/habedi/minish/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/habedi/minish/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/habedi/minish/blob/main/LICENSE)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/habedi/minish/tree/main/examples)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.1-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/habedi/minish.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/habedi/minish/releases/latest)

A property-based testing framework for Zig.

</div>

---

Minish is a [property-based testing](https://en.wikipedia.org/wiki/Property_testing) framework for Zig.

You define properties about your code.
Minish then generates hundreds of random test cases to find inputs that break your property.

> [!IMPORTANT]
> This project is in early development, so the API may change without notice and bugs are expected.

---

### Getting Started

This guide shows how to add Minish to your project and write a simple property test.

#### 1. Add Minish as a Dependency

Run this command in your project's root directory.

```sh
zig fetch --save=minish "https://github.com/habedi/minish/archive/main.tar.gz"
```

This command adds Minish to your `build.zig.zon` file.

#### 2. Add the Module to `build.zig`

Next, modify your `build.zig` file.
This change makes the Minish library available to your application.

```zig
pub fn build(b: *std.Build) void {
    // ... standard target and optimize options ...

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
    });

    // Add these lines to use minish
    const minish_dep = b.dependency("minish", .{});
    const minish_module = minish_dep.module("minish");
    exe.root_module.addImport("minish", minish_module);

    b.installArtifact(exe);
}
```

#### 3. Write a Property Test

Finally, you can `@import("minish")` and write a property.
The example below tests a hypothetical `reverse` function.
The property states that reversing a string twice should result in the original string.

```zig
const std = @import("std");
const minish = @import("minish");

// The function we want to test
fn reverse(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const len = s.len;
    const buf = try allocator.alloc(u8, len);
    for (s, 0..) |char, i| {
        buf[len - 1 - i] = char;
    }
    return buf;
}

// The property that tests the function
fn reverse_twice_is_identity(tc: *minish.TestCase) !void {
    // Minish does not yet have a string generator.
    // This is a placeholder for future functionality.
    const original_string = "hello"; _ = tc;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const once = try reverse(allocator, original_string);
    defer allocator.free(once);

    const twice = try reverse(allocator, once);
    defer allocator.free(twice);

    try std.testing.expectEqualStrings(original_string, twice);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run the property test 100 times
    try minish.run(allocator, reverse_twice_is_identity, .{});
}
```

---

### Documentation

To be added.

#### Examples

Check out the [examples](examples) directory for more usage examples.

---

### Contributing

Contributions are always welcome!
Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

Minish is licensed under the Apache License, Version 2.0 (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/532646/hat-witch) with some modifications.
