//! Purpose: Public YAML loader API.
//! Owns: Single-document and stream loading entry points plus load-time limits.
//! Does not own: Event parsing, composition internals, schema resolution details, or value deinitialization types.
//! Depends on: api/parse.zig, api/options.zig, api/diagnostics.zig, loader/loader.zig, value/value.zig, and common/diagnostic.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig, tests/stress/stress.zig.

const std = @import("std");
const common_diagnostic = @import("../common/diagnostic.zig");
const common_limit = @import("../common/limit.zig");
const node_pool = @import("../common/node_pool.zig");
const diagnostics = @import("diagnostics.zig");
const duplicate_key = @import("../loader/duplicate_key.zig");
const options_api = @import("options.zig");
const parse = @import("parse.zig");
const loader = @import("../loader/loader.zig");
const scanner = @import("../scanner/scanner.zig");
const schema = @import("../schema/schema.zig");
const simple_fast_path = @import("../parser/simple_fast_path.zig");
const value = @import("../value/value.zig");

const Error = diagnostics.Error;
const LoadedDocument = value.LoadedDocument;
const LoadedStream = value.LoadedStream;
const LoadOptions = options_api.LoadOptions;
const NodePool = node_pool.Pool(value.Node);
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
    if (try tryStrictSimpleLoadStream(allocator, input, options)) |loaded_stream| {
        return loaded_stream;
    }

    return loadStreamViaEvents(allocator, input, options);
}

fn loadStreamViaEvents(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!LoadedStream {
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
        allocator,
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
    return tryStrictSimpleLoadStream(allocator, input, options);
}

fn tryStrictSimpleLoadStream(allocator: std.mem.Allocator, input: []const u8, options: LoadOptions) Error!?LoadedStream {
    if (options.max_input_bytes) |max_input_bytes| {
        if (input.len > max_input_bytes) {
            setLimitDiagnostic(input, max_input_bytes, options, "input exceeds configured size limit");
            return ParseError.Unsupported;
        }
    }

    if (!mayBeStrictSimpleInput(input)) return null;

    var token_stream = scanner.scan(allocator, input) catch |err| switch (err) {
        error.InvalidSyntax => return null,
        error.OutOfMemory => return err,
    };
    defer token_stream.deinit();

    if (options.max_token_count) |max_token_count| {
        if (token_stream.tokens.len > max_token_count) {
            setLimitDiagnostic(input, input.len, options, "token count exceeds configured limit");
            return ParseError.Unsupported;
        }
    }

    const shape = strictSimpleShape(token_stream.tokens) orelse return null;
    try checkStrictShapeLimits(input, options, shape);

    if (options.max_document_count) |max_document_count| {
        if (max_document_count == 0) {
            setLoadFailureDiagnostic(input, options, .document_count_limit, ParseError.Unsupported);
            return ParseError.Unsupported;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    var builder: StrictSimpleBuilder = .{
        .arena_allocator = arena_allocator,
        .temporary_allocator = allocator,
        .input = input,
        .options = options,
        .nodes = try NodePool.init(arena_allocator, strictShapeStats(shape).node_count),
    };
    const root = try builder.construct(token_stream.tokens, shape);

    const documents = try arena_allocator.alloc(*const value.Node, 1);
    documents[0] = root;

    if (options.diagnostic) |diagnostic| diagnostic.* = .{};
    return .{
        .arena = arena,
        .documents = documents,
    };
}

const StrictSimpleShape = union(enum) {
    scalar: StrictShapeStats,
    mapping: StrictShapeStats,
    sequence: StrictShapeStats,
};

const StrictShapeStats = struct {
    event_count: usize,
    max_nesting_depth: usize,
    max_scalar_bytes: usize,
    node_count: usize,
};

fn mayBeStrictSimpleInput(input: []const u8) bool {
    var start: usize = 0;
    while (start < input.len) {
        var end = start;
        while (end < input.len and input[end] != '\n') : (end += 1) {}
        var line = input[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0) {
            if (trimmed[0] == '#') return false;
            if (trimmed[0] == '%') return false;
            if (std.mem.startsWith(u8, trimmed, "---") or std.mem.startsWith(u8, trimmed, "...")) return false;
            if (std.mem.indexOfAny(u8, trimmed, "&*!'\"[]{}|>%#") != null) return false;
            if (mappingValueIsOmitted(trimmed)) return false;
            if (line.len != trimmed.len and !std.mem.containsAtLeast(u8, trimmed, 1, ":")) return false;
        }

        start = if (end < input.len) end + 1 else end;
    }
    return true;
}

fn mappingValueIsOmitted(line: []const u8) bool {
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        var cursor = colon + 1;
        while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {}
        return cursor == line.len;
    }
    return false;
}

fn strictShapeStats(shape: StrictSimpleShape) StrictShapeStats {
    return switch (shape) {
        inline else => |stats| stats,
    };
}

fn strictSimpleShape(tokens: []const scanner.Token) ?StrictSimpleShape {
    if (strictSimpleScalarShape(tokens)) |stats| return .{ .scalar = stats };
    if (strictSimpleBlockMappingShape(tokens)) |stats| return .{ .mapping = stats };
    if (strictSimpleBlockSequenceShape(tokens)) |stats| return .{ .sequence = stats };
    return null;
}

fn strictSimpleScalarShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len != 4 or tokens[0] != .stream_start or tokens[1] != .indent or tokens[1].indent != 0 or tokens[2] != .scalar or tokens[3] != .stream_end) return null;
    if (!simple_fast_path.isSimplePlainScalarToken(tokens[2].scalar)) return null;

    return .{
        .event_count = 5,
        .max_nesting_depth = 0,
        .max_scalar_bytes = tokens[2].scalar.len,
        .node_count = 1,
    };
}

fn strictSimpleBlockMappingShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 6 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var pair_count: usize = 0;
    var max_scalar_bytes: usize = 0;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
        max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimplePlainScalarToken(tokens[index].scalar)) return null;
        max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
        index += 1;

        pair_count += 1;
    }

    if (pair_count == 0) return null;
    return .{
        .event_count = 6 + pair_count * 2,
        .max_nesting_depth = 1,
        .max_scalar_bytes = max_scalar_bytes,
        .node_count = 1 + pair_count * 2,
    };
}

fn strictSimpleBlockSequenceShape(tokens: []const scanner.Token) ?StrictShapeStats {
    if (tokens.len < 4 or tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return null;

    var item_count: usize = 0;
    var item_event_count: usize = 0;
    var max_nesting_depth: usize = 1;
    var max_scalar_bytes: usize = 0;
    var node_count: usize = 1;
    var index: usize = 1;
    while (index < tokens.len - 1) {
        if (tokens[index] != .indent or tokens[index].indent != 0) return null;
        index += 1;
        if (index >= tokens.len - 1 or tokens[index] != .block_sequence_entry) return null;
        index += 1;

        if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimplePlainScalarToken(tokens[index].scalar)) return null;
        if (index + 1 < tokens.len - 1 and tokens[index + 1] == .block_mapping_value) {
            if (!simple_fast_path.isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
            max_nesting_depth = 2;
            item_event_count += 2;
            node_count += 3;
            max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
            index += 2;

            if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimplePlainScalarToken(tokens[index].scalar)) return null;
            item_event_count += 2;
            max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
            index += 1;

            var mapping_indent: ?usize = null;
            while (index < tokens.len - 1) {
                if (tokens[index] != .indent) return null;
                const indent = tokens[index].indent;
                if (indent == 0) break;
                if (mapping_indent) |expected| {
                    if (indent != expected) return null;
                } else {
                    mapping_indent = indent;
                }
                index += 1;

                if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimpleBlockMappingKeyToken(tokens[index].scalar)) return null;
                max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
                index += 1;
                if (index >= tokens.len - 1 or tokens[index] != .block_mapping_value) return null;
                index += 1;
                if (index >= tokens.len - 1 or tokens[index] != .scalar or !simple_fast_path.isSimplePlainScalarToken(tokens[index].scalar)) return null;
                max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
                item_event_count += 2;
                node_count += 2;
                index += 1;
            }
        } else {
            max_scalar_bytes = @max(max_scalar_bytes, tokens[index].scalar.len);
            item_event_count += 1;
            node_count += 1;
            index += 1;
        }

        item_count += 1;
    }

    if (item_count == 0) return null;
    return .{
        .event_count = 6 + item_event_count,
        .max_nesting_depth = max_nesting_depth,
        .max_scalar_bytes = max_scalar_bytes,
        .node_count = node_count,
    };
}

fn checkStrictShapeLimits(input: []const u8, options: LoadOptions, shape: StrictSimpleShape) Error!void {
    const stats = strictShapeStats(shape);

    if (options.max_event_count) |max_event_count| {
        if (stats.event_count > max_event_count) {
            setLimitDiagnostic(input, input.len, options, "event count exceeds configured limit");
            return ParseError.Unsupported;
        }
    }

    if (options.max_scalar_bytes) |max_scalar_bytes| {
        if (stats.max_scalar_bytes > max_scalar_bytes) {
            setLimitDiagnostic(input, input.len, options, "scalar exceeds configured size limit");
            return ParseError.Unsupported;
        }
    }

    const max_nesting_depth = options.max_nesting_depth orelse common_limit.default_parse_collection_depth;
    if (stats.max_nesting_depth > max_nesting_depth) {
        setLimitDiagnostic(input, input.len, options, "nesting depth exceeds configured limit");
        return ParseError.Unsupported;
    }
}

const StrictSimpleBuilder = struct {
    arena_allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    input: []const u8,
    options: LoadOptions,
    nodes: NodePool,

    fn construct(self: *StrictSimpleBuilder, tokens: []const scanner.Token, shape: StrictSimpleShape) Error!*const value.Node {
        return switch (shape) {
            .scalar => self.constructPlainScalar(tokens[2].scalar),
            .mapping => self.constructBlockMapping(tokens),
            .sequence => self.constructBlockSequence(tokens),
        };
    }

    fn constructBlockMapping(self: *StrictSimpleBuilder, tokens: []const scanner.Token) Error!*const value.Node {
        const pair_count = (tokens.len - 2) / 4;
        const pairs = try self.arena_allocator.alloc(value.MappingPair, pair_count);

        var pair_index: usize = 0;
        var token_index: usize = 1;
        while (token_index < tokens.len - 1) : (pair_index += 1) {
            token_index += 1;
            const key = try self.constructPlainScalar(tokens[token_index].scalar);
            token_index += 2;
            const node_value = try self.constructPlainScalar(tokens[token_index].scalar);
            token_index += 1;
            pairs[pair_index] = .{ .key = key, .value = node_value };
        }

        try self.validateMappingPairs(pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = pairs } };
        return node;
    }

    fn constructBlockSequence(self: *StrictSimpleBuilder, tokens: []const scanner.Token) Error!*const value.Node {
        const item_count = strictSequenceItemCount(tokens);
        const items = try self.arena_allocator.alloc(*const value.Node, item_count);

        var item_index: usize = 0;
        var token_index: usize = 1;
        while (token_index < tokens.len - 1) : (item_index += 1) {
            token_index += 2;
            if (token_index + 1 < tokens.len - 1 and tokens[token_index + 1] == .block_mapping_value) {
                items[item_index] = try self.constructCompactMappingItem(tokens, &token_index);
            } else {
                items[item_index] = try self.constructPlainScalar(tokens[token_index].scalar);
                token_index += 1;
            }
        }

        const node = try self.nodes.create();
        node.* = .{ .sequence = .{ .items = items } };
        return node;
    }

    fn constructCompactMappingItem(self: *StrictSimpleBuilder, tokens: []const scanner.Token, index: *usize) Error!*const value.Node {
        var pairs: std.ArrayList(value.MappingPair) = .empty;
        errdefer pairs.deinit(self.arena_allocator);

        while (true) {
            const key = try self.constructPlainScalar(tokens[index.*].scalar);
            index.* += 2;
            const node_value = try self.constructPlainScalar(tokens[index.*].scalar);
            index.* += 1;
            try pairs.append(self.arena_allocator, .{ .key = key, .value = node_value });

            if (index.* >= tokens.len - 1 or tokens[index.*] != .indent or tokens[index.*].indent == 0) break;
            index.* += 1;
        }

        const owned_pairs = try pairs.toOwnedSlice(self.arena_allocator);
        try self.validateMappingPairs(owned_pairs);

        const node = try self.nodes.create();
        node.* = .{ .mapping = .{ .pairs = owned_pairs } };
        return node;
    }

    fn constructPlainScalar(self: *StrictSimpleBuilder, scalar_value: []const u8) Error!*const value.Node {
        const node = try self.nodes.create();
        node.* = try self.constructPlainScalarNode(scalar_value);
        return node;
    }

    fn constructPlainScalarNode(self: *StrictSimpleBuilder, scalar_value: []const u8) Error!value.Node {
        const resolved = schema.resolveScalar(self.options.schema, scalar_value, true, null) catch |err| {
            setLoadFailureDiagnostic(self.input, self.options, .invalid_scalar_tag, err);
            return err;
        };

        if (resolved) |resolved_scalar| {
            return switch (resolved_scalar) {
                .null_value => .{ .null_value = .{} },
                .bool_value => |bool_value| .{ .bool_value = .{ .value = bool_value } },
                .int_value => |int_value| .{ .int_value = .{ .value = int_value } },
                .float_value => |float_value| .{ .float_value = .{ .value = float_value } },
            };
        }

        return .{ .scalar = .{
            .value = try self.arena_allocator.dupe(u8, scalar_value),
        } };
    }

    fn validateMappingPairs(self: *StrictSimpleBuilder, pairs: []const value.MappingPair) Error!void {
        if (self.options.duplicate_key_behavior == .allow) return;
        duplicate_key.validateUniqueMappingKeys(self.temporary_allocator, pairs) catch |err| {
            setLoadFailureDiagnostic(self.input, self.options, .duplicate_key, err);
            return err;
        };
    }
};

fn strictSequenceItemCount(tokens: []const scanner.Token) usize {
    var count: usize = 0;
    var index: usize = 1;
    while (index < tokens.len - 1) : (count += 1) {
        index += 2;
        if (index + 1 < tokens.len - 1 and tokens[index + 1] == .block_mapping_value) {
            index += 3;
            while (index < tokens.len - 1 and tokens[index] == .indent and tokens[index].indent != 0) {
                index += 4;
            }
        } else {
            index += 1;
        }
    }
    return count;
}

fn setLimitDiagnostic(input: []const u8, offset: usize, options: LoadOptions, message: []const u8) void {
    if (options.diagnostic) |diagnostic| {
        diagnostic.* = common_diagnostic.atOffset(input, offset, message);
    }
}

fn setLoadFailureDiagnostic(input: []const u8, options: LoadOptions, failure: loader.LoadFailure, err: Error) void {
    if (options.diagnostic) |diagnostic| {
        if (diagnostic.message.len == 0) {
            diagnostic.* = loadDiagnostic(input, failure, err);
        }
    }
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

test "strict simple load fast path matches forced fallback" {
    const cases = [_][]const u8{
        "plain\n",
        "name: yaml\nversion: 1\n",
        "- one\n- two\n",
        "- id: 1\n  name: record-1\n- id: 2\n  name: record-2\n",
    };

    for (cases) |input| {
        var fast = (try tryStrictSimpleLoadStream(std.testing.allocator, input, .{})).?;
        defer fast.deinit();

        var fallback = try loadStreamViaEvents(std.testing.allocator, input, .{});
        defer fallback.deinit();

        try expectLoadedStreamsEqual(&fast, &fallback);
    }
}

test "strict simple load fast path declines unsupported shapes" {
    const cases = [_][]const u8{
        "*anchor\n",
        "&anchor value\n",
        "!!str value\n",
        "%YAML 1.2\n---\nvalue\n",
        "--- value\n",
        "key: value # comment\n",
        "\"quoted\"\n",
        "literal: |\n  line\n",
        "[one, two]\n",
        "key: first\n  second\n",
        "key:\n",
        "outer:\n  inner: value\n",
        "-\n  - nested\n",
    };

    for (cases) |input| {
        const fast = try tryStrictSimpleLoadStream(std.testing.allocator, input, .{});
        try std.testing.expect(fast == null);
    }
}

test "strict simple load fast path owns accepted strings after input and scan storage release" {
    const input = try std.testing.allocator.dupe(u8, "name: yaml\nversion: 1\n");

    var stream = (try tryStrictSimpleLoadStream(std.testing.allocator, input, .{})).?;
    defer stream.deinit();

    @memset(input, 0xa5);
    std.testing.allocator.free(input);

    try std.testing.expectEqual(@as(usize, 1), stream.documents.len);
    const root = stream.documents[0];
    try std.testing.expect(root.* == .mapping);
    try std.testing.expectEqualStrings("name", root.mapping.pairs[0].key.scalar.value);
    try std.testing.expectEqualStrings("yaml", root.mapping.pairs[0].value.scalar.value);
    try std.testing.expectEqualStrings("version", root.mapping.pairs[1].key.scalar.value);
    try std.testing.expectEqual(@as(i128, 1), root.mapping.pairs[1].value.int_value.value);
}

test "strict simple load fast path cleans up accepted and declined allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkStrictSimpleLoadAllocationFailure, .{});
}

fn checkStrictSimpleLoadAllocationFailure(failing_allocator: std.mem.Allocator) !void {
    var accepted = (try tryStrictSimpleLoadStream(failing_allocator, "name: yaml\nversion: 1\n", .{})).?;
    defer accepted.deinit();

    const declined = try tryStrictSimpleLoadStream(failing_allocator, "name: [yaml]\n", .{});
    try std.testing.expect(declined == null);
}

test "strict simple load fast path preserves schema duplicate key and limit behavior" {
    var core = (try tryStrictSimpleLoadStream(std.testing.allocator, "truth: TRUE\nnothing: ~\n", .{ .schema = .core })).?;
    defer core.deinit();
    try std.testing.expect(core.documents[0].mapping.pairs[0].value.* == .bool_value);
    try std.testing.expectEqual(true, core.documents[0].mapping.pairs[0].value.bool_value.value);
    try std.testing.expect(core.documents[0].mapping.pairs[1].value.* == .null_value);

    var failsafe = (try tryStrictSimpleLoadStream(std.testing.allocator, "truth: TRUE\n", .{ .schema = .failsafe })).?;
    defer failsafe.deinit();
    try std.testing.expect(failsafe.documents[0].mapping.pairs[0].value.* == .scalar);
    try std.testing.expectEqualStrings("TRUE", failsafe.documents[0].mapping.pairs[0].value.scalar.value);

    var json = (try tryStrictSimpleLoadStream(std.testing.allocator, "true\n", .{ .schema = .json })).?;
    defer json.deinit();
    try std.testing.expect(json.documents[0].* == .bool_value);
    try std.testing.expectEqual(true, json.documents[0].bool_value.value);

    var diagnostic: diagnostics.Diagnostic = .{};
    try std.testing.expectError(ParseError.InvalidSyntax, tryStrictSimpleLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader rejected duplicate mapping key", diagnostic.message);

    var duplicate_allowed = (try tryStrictSimpleLoadStream(std.testing.allocator, "name: first\nname: second\n", .{
        .duplicate_key_behavior = .allow,
    })).?;
    defer duplicate_allowed.deinit();
    try std.testing.expectEqual(@as(usize, 2), duplicate_allowed.documents[0].mapping.pairs.len);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: bb\n", .{
        .max_scalar_bytes = 1,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("scalar exceeds configured size limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_token_count = 5,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("token count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_event_count = 7,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("event count exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_nesting_depth = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("nesting depth exceeds configured limit", diagnostic.message);

    diagnostic = .{};
    try std.testing.expectError(ParseError.Unsupported, tryStrictSimpleLoadStream(std.testing.allocator, "a: b\n", .{
        .max_document_count = 0,
        .diagnostic = &diagnostic,
    }));
    try std.testing.expectEqualStrings("loader exceeded configured document count limit", diagnostic.message);
}

fn expectLoadedStreamsEqual(actual: *const LoadedStream, expected: *const LoadedStream) !void {
    try std.testing.expectEqual(expected.documents.len, actual.documents.len);
    for (actual.documents, expected.documents) |actual_document, expected_document| {
        try expectNodesEqual(actual_document, expected_document);
    }
}

fn expectNodesEqual(actual: *const value.Node, expected: *const value.Node) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected.*), std.meta.activeTag(actual.*));
    switch (expected.*) {
        .null_value => |expected_value| try expectOptionalStringEqual(expected_value.tag, actual.null_value.tag),
        .bool_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.bool_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.bool_value.tag);
        },
        .int_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.int_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.int_value.tag);
        },
        .float_value => |expected_value| {
            try std.testing.expectEqual(expected_value.value, actual.float_value.value);
            try expectOptionalStringEqual(expected_value.tag, actual.float_value.tag);
        },
        .scalar => |expected_value| {
            try std.testing.expectEqualStrings(expected_value.value, actual.scalar.value);
            try std.testing.expectEqual(expected_value.style, actual.scalar.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.scalar.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.scalar.tag);
        },
        .sequence => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.sequence.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.sequence.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.sequence.tag);
            try std.testing.expectEqual(expected_value.items.len, actual.sequence.items.len);
            for (actual.sequence.items, expected_value.items) |actual_item, expected_item| {
                try expectNodesEqual(actual_item, expected_item);
            }
        },
        .mapping => |expected_value| {
            try std.testing.expectEqual(expected_value.style, actual.mapping.style);
            try expectOptionalStringEqual(expected_value.anchor, actual.mapping.anchor);
            try expectOptionalStringEqual(expected_value.tag, actual.mapping.tag);
            try std.testing.expectEqual(expected_value.pairs.len, actual.mapping.pairs.len);
            for (actual.mapping.pairs, expected_value.pairs) |actual_pair, expected_pair| {
                try expectNodesEqual(actual_pair.key, expected_pair.key);
                try expectNodesEqual(actual_pair.value, expected_pair.value);
            }
        },
        .alias => |expected_alias| try std.testing.expectEqualStrings(expected_alias, actual.alias),
    }
}

fn expectOptionalStringEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |expected_value| {
        try std.testing.expectEqualStrings(expected_value, actual.?);
    }
}
