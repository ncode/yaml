# yaml

A native Zig library for reading and writing YAML 1.2.2.

It provides parser events, loaded value graphs, schema-aware scalar resolution, and
YAML emission through allocating and writer-based APIs.

## Features

- UTF-8, UTF-16, and UTF-32 input with YAML line-break normalization.
- Pull-style parsing with `Parser` and bulk event parsing with `parseEvents`.
- Single-document loading with `load` and stream loading with `loadStream`.
- Typed loading into caller-specified Zig structs, slices, enums, and scalars.
- Failsafe, JSON, and core schema selection.
- Configurable duplicate-key, unknown-tag, and safety-limit behavior.
- Event emission and value dumping through allocating and `std.Io.Writer` APIs.
- Diagnostics with byte offset and 1-based line/column for parser and loader failures.

## Quick Examples

Parse events:

```zig
const std = @import("std");
const yaml = @import("yaml");

pub fn parseExample(allocator: std.mem.Allocator, input: []const u8) !void {
    var events = try yaml.parseEvents(allocator, input);
    defer events.deinit();

    for (events.events) |event| {
        _ = event;
    }
}
```

Load one document:

```zig
var document = try yaml.load(allocator, "name: yaml\nactive: true\n");
defer document.deinit();

switch (document.root.*) {
    .mapping => |mapping| _ = mapping.pairs,
    else => {},
}
```

Use options and diagnostics:

```zig
var diagnostic: yaml.Diagnostic = .{};
var document = try yaml.loadWithOptions(allocator, input, .{
    .schema = .core,
    .duplicate_key_behavior = .reject,
    .unknown_tag_behavior = .preserve,
    .max_input_bytes = 1024 * 1024,
    .max_nesting_depth = 128,
    .diagnostic = &diagnostic,
});
defer document.deinit();
```

Load typed values:

```zig
const Config = struct {
    name: []const u8,
    ports: []const u16,
};

var typed = try yaml.loadTyped(Config, allocator,
    \\name: service
    \\ports: [80, 443]
    \\
);
defer typed.deinit();
```

Emit YAML:

```zig
const output = try yaml.dump(allocator, document.root);
defer allocator.free(output);

var buffer: [4096]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buffer);
try yaml.dumpToWriter(allocator, &writer, document.root);
```

## Build And Test

Common commands:

```sh
zig build
zig build test
zig build test-unit
zig build test-conformance
zig build conformance-report
zig build coverage
zig build docs
```

Focused checks are also available for structure, schema, stress, allocation,
leak, Valgrind, and direct conformance testing:

```sh
zig build test-structure
zig build test-schema
zig build test-stress
zig build test-allocation
zig build test-leaks
zig build test-valgrind
zig build test-direct-conformance
```

## Validation

The conformance harness validates behavior against the vendored pinned
`yaml/yaml-test-suite` release under `vendor/yaml-test-suite/`. The exact
repository, tag, and commit are recorded in `vendor/yaml-test-suite.PIN`.

Run `zig build conformance-report` to generate current parser, loader,
expected-error, and emitter coverage for the configured pinned suite. The README
intentionally does not copy snapshot counts or percentages; the build target is
the source for current metrics.

Use `-Dyaml-test-suite-dir=/path/to/yaml-test-suite-data` with conformance build
steps to check another generated suite data directory without replacing the
vendored pin.

## Documentation

- `docs/api.md`: public API examples, options, diagnostics, and ownership details.
- `docs/architecture.md`: processing pipeline and dependency direction.
- `docs/memory.md`: allocator, borrowing, cleanup, error, and limit contracts.

The package root is `src/lib.zig`; files below it are internal unless re-exported
there.

## Scope And Non-Goals

- Native Zig implementation only.
- Library API only; it does not provide a command-line YAML tool.
- Correctness and memory safety take priority over performance shortcuts.
- YAML 1.2.2 conformance is tracked through the pinned test suite, not README
  status snapshots.
