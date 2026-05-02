//! Purpose: Split token streams into YAML document ranges and append document events.
//! Owns: Document-boundary stream traversal, document event framing, and single-document callback dispatch.
//! Does not own: Node parsing, scanner tokenization, schema resolution, or event ownership.
//! Depends on: scanner/scanner.zig, parser/internal.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const token_cursor = @import("internal.zig");
const types = @import("event.zig");

const Error = types.Error;
const Event = types.Event;
const ParseError = types.ParseError;
const skipComments = token_cursor.skipComments;

pub const AppendSingleDocumentFn = *const fn (
    allocator: std.mem.Allocator,
    document_tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
) Error!bool;

pub fn appendSingleDocumentEvents(
    allocator: std.mem.Allocator,
    document_tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const wrapped = try allocator.alloc(scanner.Token, document_tokens.len + 2);
    defer allocator.free(wrapped);

    wrapped[0] = .stream_start;
    @memcpy(wrapped[1 .. wrapped.len - 1], document_tokens);
    wrapped[wrapped.len - 1] = .stream_end;

    if (try appendScalarDocumentEvents(allocator, wrapped, events, parsers)) return true;
    if (try appendAliasDocumentEvents(allocator, wrapped, events, parsers)) return true;
    if (try appendPlainBlockSequenceDocumentEvents(allocator, wrapped, events, parsers)) return true;
    if (try appendPlainBlockMappingDocumentEvents(allocator, wrapped, events, parsers)) return true;
    if (try appendFlowSequenceDocumentEvents(allocator, wrapped, events, parsers)) return true;
    if (try appendFlowMappingDocumentEvents(allocator, wrapped, events, parsers)) return true;

    return false;
}

fn appendScalarDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = parsers.parse_scalar_document(allocator, tokens) catch |err| switch (err) {
        ParseError.Unsupported => return false,
        else => return err,
    };

    const scalar = parsed.scalar orelse return false;
    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .scalar = scalar });
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendAliasDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_alias_document(allocator, tokens) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .alias = parsed.value });
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendPlainBlockSequenceDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_plain_block_sequence_document(allocator, tokens) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .sequence_start = .{
        .style = .block,
        .anchor = parsed.properties.anchor,
        .tag = parsed.properties.tag,
    } });
    for (parsed.items) |item| {
        try parsers.append_plain_block_node_event(allocator, events, item);
    }
    try events.append(allocator, .sequence_end);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendPlainBlockMappingDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_plain_block_mapping_document(allocator, tokens) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.append(allocator, .{ .mapping_start = .{
        .style = .block,
        .anchor = parsed.properties.anchor,
        .tag = parsed.properties.tag,
    } });
    for (parsed.pairs) |pair| {
        try parsers.append_plain_block_node_event(allocator, events, pair.key);
        try parsers.append_plain_block_node_event(allocator, events, pair.value);
    }
    try events.append(allocator, .mapping_end);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendFlowSequenceDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_flow_sequence_document(allocator, tokens) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.appendSlice(allocator, parsed.events);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendFlowMappingDocumentEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    parsers: anytype,
) Error!bool {
    const parsed = try parsers.parse_flow_mapping_document(allocator, tokens) orelse return false;

    try appendDocumentStart(allocator, events, parsed);
    try events.appendSlice(allocator, parsed.events);
    try appendDocumentEnd(allocator, events, parsed);

    return true;
}

fn appendDocumentStart(allocator: std.mem.Allocator, events: *std.ArrayList(Event), parsed: anytype) Error!void {
    const Parsed = @TypeOf(parsed);
    try events.append(allocator, .{ .document_start = .{
        .explicit = parsed.explicit_start,
        .force_document_start = if (@hasField(Parsed, "force_document_start")) parsed.force_document_start else false,
        .yaml_version = parsed.directives.yaml_version,
        .tag_directives = parsed.directives.tag_directives,
        .has_reserved_directive = parsed.directives.has_reserved_directive,
        .content_same_line = parsed.content_same_line,
        .content_same_line_separated_by_tab = parsed.content_same_line_separated_by_tab,
    } });
}

fn appendDocumentEnd(allocator: std.mem.Allocator, events: *std.ArrayList(Event), parsed: anytype) Error!void {
    try events.append(allocator, .{ .document_end = .{ .explicit = parsed.explicit_end } });
}

pub fn appendImplicitDocumentStartSeparatedStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    const end = tokens.len - 1;
    var boundary: ?usize = null;
    var saw_content = false;

    var index: usize = 1;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment => {},
            .document_start => {
                if (!saw_content) return false;
                boundary = index;
                break;
            },
            .document_end => return false,
            .directive => {
                if (saw_content) return ParseError.InvalidSyntax;
                return false;
            },
            else => saw_content = true,
        }
    }

    const document_boundary = boundary orelse return false;
    if (!try append_single_document(allocator, tokens[1..document_boundary], events)) {
        return ParseError.Unsupported;
    }

    if (try appendRemainingDocumentStreamEvents(allocator, tokens[document_boundary..end], events, append_single_document)) {
        return true;
    }

    return ParseError.Unsupported;
}

fn appendRemainingDocumentStreamEvents(
    allocator: std.mem.Allocator,
    document_tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    const wrapped = try wrapDocumentTokens(allocator, document_tokens);
    defer allocator.free(wrapped);

    if (try appendDocumentEndSeparatedStreamEvents(allocator, wrapped, events, append_single_document)) return true;
    if (try appendExplicitDocumentStreamEvents(allocator, wrapped, events, append_single_document)) return true;
    if (try append_single_document(allocator, document_tokens, events)) return true;
    return false;
}

pub fn appendDocumentEndSeparatedStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    var index: usize = 1;
    const end = tokens.len - 1;
    var saw_boundary = false;

    while (index < end) {
        skipComments(tokens, &index, end);
        if (index >= end) break;

        if (tokens[index] == .document_end) {
            var next_document = index + 1;
            skipComments(tokens, &next_document, end);
            if (next_document >= end) return saw_boundary;

            switch (tokens[next_document]) {
                .indent, .document_start, .document_end, .directive => {},
                else => return ParseError.InvalidSyntax,
            }

            saw_boundary = true;
            index = next_document;
            continue;
        }

        const document_start = index;
        var document_end = index;
        while (document_end < end and tokens[document_end] != .document_end) : (document_end += 1) {}

        if (document_end >= end) {
            if (!saw_boundary) return false;
            if (!try append_single_document(allocator, tokens[document_start..end], events)) {
                return ParseError.Unsupported;
            }
            return true;
        }

        var next_document = document_end + 1;
        skipComments(tokens, &next_document, end);
        if (next_document >= end) {
            if (!saw_boundary) return false;
            if (!try append_single_document(allocator, tokens[document_start..next_document], events)) {
                return ParseError.Unsupported;
            }
            return true;
        }

        switch (tokens[next_document]) {
            .indent, .document_start, .document_end, .directive => {},
            else => return ParseError.InvalidSyntax,
        }

        saw_boundary = true;
        if (!try append_single_document(allocator, tokens[document_start..next_document], events)) {
            return ParseError.Unsupported;
        }
        index = next_document;
    }

    return saw_boundary;
}

pub fn appendExplicitDocumentStreamEvents(
    allocator: std.mem.Allocator,
    tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
    append_single_document: AppendSingleDocumentFn,
) Error!bool {
    if (explicitDocumentStartCount(tokens) < 2) return false;

    var index: usize = 1;
    const end = tokens.len - 1;

    while (index < end) {
        skipComments(tokens, &index, end);
        if (index >= end) break;

        const document_start = findExplicitDocumentStartAfterPrefix(tokens, index, end) orelse return false;
        const document_prefix_start = index;
        index = document_start + 1;
        var flow_depth: usize = 0;
        while (index < end and tokens[index] != .document_start) : (index += 1) {
            switch (tokens[index]) {
                .flow_sequence_start, .flow_mapping_start => {
                    flow_depth += 1;
                    continue;
                },
                .flow_sequence_end, .flow_mapping_end => {
                    if (flow_depth > 0) flow_depth -= 1;
                    continue;
                },
                else => {},
            }
            if (flow_depth == 0 and isUnindentedDirectiveLikeContent(tokens, index, end)) return ParseError.InvalidSyntax;
        }

        if (!try append_single_document(allocator, tokens[document_prefix_start..index], events)) {
            return ParseError.Unsupported;
        }
    }

    return true;
}

fn wrapDocumentTokens(allocator: std.mem.Allocator, document_tokens: []const scanner.Token) Error![]scanner.Token {
    const wrapped = try allocator.alloc(scanner.Token, document_tokens.len + 2);
    errdefer allocator.free(wrapped);

    wrapped[0] = .stream_start;
    @memcpy(wrapped[1 .. wrapped.len - 1], document_tokens);
    wrapped[wrapped.len - 1] = .stream_end;
    return wrapped;
}

fn findExplicitDocumentStartAfterPrefix(tokens: []const scanner.Token, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index]) {
            .comment, .directive => {},
            .document_start => return index,
            else => return null,
        }
    }
    return null;
}

fn isUnindentedDirectiveLikeContent(tokens: []const scanner.Token, index: usize, end: usize) bool {
    if (index + 1 >= end or tokens[index] != .indent or tokens[index].indent != 0) return false;
    if (tokens[index + 1] != .scalar) return false;
    return std.mem.startsWith(u8, tokens[index + 1].scalar, "%");
}

fn explicitDocumentStartCount(tokens: []const scanner.Token) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (token == .document_start) count += 1;
    }
    return count;
}
