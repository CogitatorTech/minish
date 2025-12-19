### Minish Examples

#### List of Examples

| # | File                                                           | Description                                            |
|---|----------------------------------------------------------------|--------------------------------------------------------|
| 1 | [e1_simple_example.zig](e1_simple_example.zig)                 | Basic tuple generator                                  |
| 2 | [e2_string_example.zig](e2_string_example.zig)                 | String property testing                                |
| 3 | [e3_list_example.zig](e3_list_example.zig)                     | List property testing (sorting)                        |
| 4 | [e4_advanced_generators.zig](e4_advanced_generators.zig)       | Multiple generator types                               |
| 5 | [e5_struct_and_combinators.zig](e5_struct_and_combinators.zig) | Struct generation and combinators                      |
| 6 | [e6_shrinking_demo.zig](e6_shrinking_demo.zig)                 | Shrinking demonstration                                |
| 7 | [e7_hashmap_example.zig](e7_hashmap_example.zig)               | HashMap property testing                               |
| 8 | [e8_misc_features.zig](e8_misc_features.zig)                   | Show cases for oneOf, dependent, timestamps, and enums |

#### Running Examples

To execute an example, run the following command from the root of the repository:

```sh
zig build run-{FILE_NAME_WITHOUT_EXTENSION}
```

For example:

```sh
zig build run-e1_simple_example
```

To run all examples:

```sh
zig build run-all
```
