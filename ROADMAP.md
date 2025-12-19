## Minish Roadmap

This document outlines the features implemented in Minish and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core Generators

- [x] Integer generators (`int` and `intRange`)
- [x] Float generators (`float` and `floatRange`)
- [x] Boolean generator
- [x] Character generators (`char` and `charFrom`)
- [x] Constant generator
- [x] Enum generator

### Collection Generators

- [x] String generator with charset options
- [x] List generator with min and max length
- [x] Array generator (fixed-size)
- [x] Optional generator
- [x] HashMap generator
- [x] Non-empty wrappers (`nonEmptyList` and `nonEmptyString`)

### Special Generators

- [x] Tuple generators (`tuple2` and `tuple3`)
- [x] Struct generator
- [x] UUID generator (v4)
- [x] Timestamp generator

### Combinators

- [x] Map combinator
- [x] FlatMap combinator
- [x] Filter combinator
- [x] OneOf combinator
- [x] Frequency combinator (weighted choice)
- [x] Dependent combinator
- [x] Sized combinator

### Shrinking

- [x] Integer shrinking (towards zero)
- [x] Float shrinking (towards zero)
- [x] List and string shrinking (multiphase removal)
- [x] Tuple shrinking (element-wise)
- [x] Array shrinking (element-wise)
- [x] Optional shrinking (try null first)
- [ ] Struct shrinking (field-wise)
- [ ] Element-wise list shrinking (shrink elements in place)

### Test Runner

- [x] Configurable test runs
- [x] Reproducible seeds
- [x] Max shrink attempts limit
- [x] Verbose mode
- [x] Improved failure messages with seed output
- [ ] Statistics collection
- [ ] Coverage reporting

### Documentation

- [x] README with examples
- [x] Example files (in `examples/` directory)
- [x] Module-level docstrings (lib, gen, shrink, combinators, runner, core)
- [x] Function-level docstrings for public API
- [x] Generated API docs via `zig build docs`
- [ ] Tutorial guide

### Future Goals

- [ ] Stateful testing (using state machine or model-based)
- [ ] Command sequence generation
- [ ] Test database for reproducibility
- [ ] Integration with Zig's test framework
- [ ] Parallel test execution
- [ ] Custom shrinker DSL
