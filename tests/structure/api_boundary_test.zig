//! Purpose: Enforce public/internal API boundaries from AGENTS.md.
//! Owns: Compatibility facade and forbidden-import structure checks.
//! Does not own: File-size, docs, or module-comment checks.
//! Depends on: tests/structure/support.zig.
//! Tested by: zig build test-structure.

const support = @import("support.zig");
const std = support.std;

test "structure: public parser uses the scanner/token parser directly" {
    const source = try support.readRepoFile("src/api/parse.zig");
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "parser/source.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "parseEventsFromSource") == null);
}

test "structure: direct parser build and API avoid parser compatibility facade" {
    const parse_api_source = try support.readRepoFile("src/api/parse.zig");
    defer std.testing.allocator.free(parse_api_source);

    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    try std.testing.expect(std.mem.indexOf(u8, parse_api_source, "@import(\"../parser.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, ".root_source_file = b.path(\"src/parser.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_source, ".root_source_file = \"src/parser.zig\"") == null);
}

test "structure: duplicate root compatibility facade is removed" {
    const build_source = try support.readRepoFile("build.zig");
    defer std.testing.allocator.free(build_source);

    try std.testing.expect(std.mem.indexOf(u8, build_source, "src/root.zig") == null);
}

test "structure: implementation modules avoid root compatibility facades" {
    const forbidden_imports = [_][]const u8{
        "@import(\"../types.zig\")",
        "@import(\"../scanner.zig\")",
        "@import(\"../schema.zig\")",
        "@import(\"../parser.zig\")",
        "@import(\"../loader.zig\")",
        "@import(\"../encoding.zig\")",
    };

    try support.expectNoForbiddenImportsUnder("src", &forbidden_imports);
    try support.expectNoForbiddenImportsIn("src/lib.zig", &.{
        "@import(\"types.zig\")",
        "@import(\"scanner.zig\")",
        "@import(\"schema.zig\")",
        "@import(\"parser.zig\")",
        "@import(\"loader.zig\")",
        "@import(\"encoding.zig\")",
    });
    try support.expectNoForbiddenImportsIn("src/internal.zig", &.{
        "@import(\"types.zig\")",
        "@import(\"scanner.zig\")",
        "@import(\"schema.zig\")",
        "@import(\"parser.zig\")",
        "@import(\"loader.zig\")",
        "@import(\"encoding.zig\")",
    });
}

test "structure: parser internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/parser", &.{
        "@import(\"../api/",
    });
}

test "structure: loader internals avoid public aggregate type facade" {
    try support.expectNoForbiddenImportsUnder("src/loader", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: compose internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/compose", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: loader construction imports compose graph directly" {
    try support.expectNoForbiddenImportsIn("src/loader/construct.zig", &.{
        "@import(\"../compose/node.zig\")",
    });
}

test "structure: emitter internals avoid public API facades" {
    try support.expectNoForbiddenImportsUnder("src/emitter", &.{
        "@import(\"../api/types.zig\")",
        "@import(\"../api/options.zig\")",
        "@import(\"../api/",
    });
}

test "structure: API entrypoints avoid aggregate public type facade" {
    const entrypoints = [_][]const u8{
        "src/api/parse.zig",
        "src/api/load.zig",
        "src/api/emit.zig",
    };

    for (entrypoints) |entrypoint| {
        try support.expectNoForbiddenImportsIn(entrypoint, &.{
            "@import(\"../api/types.zig\")",
            "@import(\"types.zig\")",
        });
    }
}
