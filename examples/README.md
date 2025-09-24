## Examples

This directory contains various examples of using Element 0, including both running Element 0 code and using its
interpreter from Zig via the FFI.

### Element 0 Examples

The [elz](elz) directory contains examples of Element 0 scripts (`.elz` files).
You can run them using the `elz` interpreter.

For example, to run the factorial example ([e4-factorial.elz](elz/e4-factorial.elz)):

```sh
# Build the Elz binary, if you haven't already
zig build

./zig-out/bin/elz-repl -f examples/elz/e4-factorial.elz
```

### Zig Examples

The [zig](zig) directory contains examples of how to use the FFI to call Zig functions from Element 0 code.

For example, to run the FFI power example ([e1_ffi_pow.zig](zig/e1_ffi_pow.zig)):

```sh
# Build the Elz binary, if you haven't already
zig build

./zig-out/bin/e1_ffi_pow
# Or
zig build run-e1_ffi_pow
```
