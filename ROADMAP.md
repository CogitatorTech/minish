## Minish Roadmap

This document outlines the features implemented in Minish and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core Generators

- [x] Integer generators (`int`, `intRange`)
- [x] Float generators (`float`, `floatRange`)
- [x] Boolean generator
- [x] Character generators (`char`, `charFrom`)
- [x] Constant generator
- [x] Enum generator

### Collection Generators

- [x] String generator with charset options
- [x] List generator with min/max length
- [x] Array generator (fixed-size)
- [x] Optional generator
- [x] HashMap generator
- [x] Non-empty wrappers (`nonEmptyList`, `nonEmptyString`)

### Special Generators

- [x] Tuple generators (`tuple2`, `tuple3`)
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
- [x] List/string shrinking (multi-phase removal)
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
- [x] API reference
- [x] Shrinking guide
- [x] Example files (in `examples/` directory)
- [ ] Zig package documentation comments
- [ ] Tutorial guide

### Future Goals

- [ ] Stateful testing (state machine / model-based)
- [ ] Command sequence generation
- [ ] Test database for reproducibility
- [ ] Integration with Zig's test framework
- [ ] Parallel test execution
- [ ] Custom shrinker DSL
