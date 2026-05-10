//! Purpose: Public YAML loader API.
//! Owns: Single-document and stream loading entry points plus load-time limits.
//! Does not own: Event parsing, composition internals, schema resolution details, or value deinitialization types.
//! Depends on: api/parse.zig, api/options.zig, api/diagnostics.zig, loader/loader.zig, value/value.zig, and common/diagnostic.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig, tests/stress/stress.zig.

const std = @import("std");
const common_diagnostic = @import("../common/diagnostic.zig");
const diagnostics = @import("diagnostics.zig");
const options_api = @import("options.zig");
const parse = @import("parse.zig");
const loader = @import("../loader/loader.zig");
const value = @import("../value/value.zig");

const Error = diagnostics.Error;
const LoadedDocument = value.LoadedDocument;
const LoadedStream = value.LoadedStream;
const LoadOptions = options_api.LoadOptions;
const ParseError = diagnostics.ParseError;

/// Loads a single YAML document into an arena-owned representation graph.
/// Returned node data is owned by the returned `LoadedDocument`; call `deinit`
/// to release it.
pub fn load(allocator: std.mem.Allocator, input: []const u8) Error!LoadedDocument {
    return loadWithOptions(allocator, input, .{});
}

/// Loads a single YAML document using the provided schema options.
/// Returned node data is owned by the returned `LoadedDocument`; call `deinit`
/// to release it.
pub fn loadWithOptions(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedDocument {
    var loaded_stream = try loadStreamWithOptions(allocator, input, options);
    const document_count = loaded_stream.documents.len;
    if (document_count != 1) {
        loaded_stream.deinit();
        if (options.diagnostic) |diagnostic| {
            diagnostic.* = common_diagnostic.atOffset(input, input.len, "loader expected exactly one document");
        }
        return if (document_count == 0) ParseError.InvalidSyntax else ParseError.Unsupported;
    }

    return .{
        .arena = loaded_stream.arena,
        .root = loaded_stream.documents[0],
    };
}

/// Loads all YAML documents in `input` into an arena-owned representation graph.
/// Returned node data is owned by the returned `LoadedStream`; call `deinit` to
/// release it.
pub fn loadStream(allocator: std.mem.Allocator, input: []const u8) Error!LoadedStream {
    return loadStreamWithOptions(allocator, input, .{});
}

/// Loads all YAML documents using the provided schema options.
/// Returned node data is owned by the returned `LoadedStream`; call `deinit` to
/// release it.
pub fn loadStreamWithOptions(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedStream {
    if (try loadStreamFastPath(allocator, input, options)) |loaded_stream| {
        return loaded_stream;
    }

    var event_stream = try parse.parseEventsWithOptions(allocator, input, .{
        .max_input_bytes = options.max_input_bytes,
        .max_event_count = options.max_event_count,
        .max_token_count = options.max_token_count,
        .max_nesting_depth = options.max_nesting_depth,
        .max_scalar_bytes = options.max_scalar_bytes,
        .diagnostic = options.diagnostic,
    });
    defer event_stream.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var load_failure: loader.LoadFailure = .unknown;
    const documents = loader.loadStreamFromEventsWithFailure(
        arena.allocator(),
        event_stream.events,
        options.schema,
        options.duplicate_key_behavior,
        options.unknown_tag_behavior,
        options.max_alias_count,
        options.max_alias_expansion,
        options.max_document_count,
        &load_failure,
        true,
    ) catch |err| {
        if (options.diagnostic) |diagnostic| {
            if (diagnostic.message.len == 0) {
                diagnostic.* = loadDiagnostic(input, load_failure, err);
            }
        }
        return err;
    };

    return .{
        .arena = arena,
        .documents = documents,
    };
}

fn loadStreamFastPath(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    if (std.mem.indexOfScalar(u8, input, '*') != null) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const event_stream = try parse.parseEventsWithOptions(arena_allocator, input, .{
        .max_input_bytes = options.max_input_bytes,
        .max_event_count = options.max_event_count,
        .max_token_count = options.max_token_count,
        .max_nesting_depth = options.max_nesting_depth,
        .max_scalar_bytes = options.max_scalar_bytes,
        .diagnostic = options.diagnostic,
    });

    var load_failure: loader.LoadFailure = .unknown;
    const documents = loader.loadStreamFromEventsWithFailure(
        arena_allocator,
        event_stream.events,
        options.schema,
        options.duplicate_key_behavior,
        options.unknown_tag_behavior,
        options.max_alias_count,
        options.max_alias_expansion,
        options.max_document_count,
        &load_failure,
        false,
    ) catch |err| {
        if (options.diagnostic) |diagnostic| {
            if (diagnostic.message.len == 0) {
                diagnostic.* = loadDiagnostic(input, load_failure, err);
            }
        }
        return err;
    };

    return .{
        .arena = arena,
        .documents = documents,
    };
}

fn loadDiagnostic(input: []const u8, failure: loader.LoadFailure, err: Error) diagnostics.Diagnostic {
    const message = switch (failure) {
        .document_count_limit => "loader exceeded configured document count limit",
        .alias_count_limit => "loader exceeded configured alias count limit",
        .alias_expansion_limit => "loader exceeded configured alias expansion limit",
        .invalid_graph => "loader rejected invalid representation graph",
        .invalid_standard_tag => "loader rejected tag for node kind",
        .invalid_scalar_tag => "loader rejected invalid tagged scalar",
        .unknown_tag => "loader rejected unknown tag",
        .duplicate_key => "loader rejected duplicate mapping key",
        .unknown => switch (err) {
            ParseError.InvalidSyntax => "loader rejected invalid YAML graph",
            ParseError.Unsupported => "loader exceeded configured safety limit",
            else => "loader failed",
        },
    };

    return common_diagnostic.atOffset(input, input.len, message);
}

test "loadWithOptions sets fallback diagnostic for multi-document single load" {
    const input = "---\none\n---\ntwo\n";
    var diagnostic: diagnostics.Diagnostic = .{};

    try std.testing.expectError(ParseError.Unsupported, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
}

test "loadWithOptions sets fallback diagnostic for empty single load" {
    const input = "# no document\n";
    var diagnostic: diagnostics.Diagnostic = .{};

    try std.testing.expectError(ParseError.InvalidSyntax, loadWithOptions(std.testing.allocator, input, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqualStrings("loader expected exactly one document", diagnostic.message);
    try std.testing.expectEqual(input.len, diagnostic.offset);
}

test "load diagnostic maps unknown loader failures by parse error" {
    const input = "key: value\n";

    const invalid = loadDiagnostic(input, .unknown, ParseError.InvalidSyntax);
    try std.testing.expectEqualStrings("loader rejected invalid YAML graph", invalid.message);
    try std.testing.expectEqual(input.len, invalid.offset);

    const unsupported = loadDiagnostic(input, .unknown, ParseError.Unsupported);
    try std.testing.expectEqualStrings("loader exceeded configured safety limit", unsupported.message);
    try std.testing.expectEqual(input.len, unsupported.offset);
}

test "load fast path accepts alias-free input" {
    var loaded = (try loadStreamFastPath(std.testing.allocator,
        \\name: yaml
        \\version: 1
        \\
    , .{})).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.documents.len);
    try std.testing.expect(loaded.documents[0].* == .mapping);
    try std.testing.expectEqual(@as(usize, 2), loaded.documents[0].mapping.pairs.len);
}

test "load fast path declines aliases for fallback" {
    const loaded = try loadStreamFastPath(std.testing.allocator,
        \\base: &base value
        \\again: *base
        \\
    , .{});

    try std.testing.expect(loaded == null);
}
