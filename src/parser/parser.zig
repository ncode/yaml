//! Purpose: Parse scanner tokens into YAML events.
//! Owns: Direct token-consuming parser state and event construction.
//! Does not own: Scanning, schema resolution, loading, or emitting.
//! Depends on: scanner/scanner.zig, parser/types.zig.
//! Tested by: tests/unit/parser/parser_tokens_test.zig and direct conformance tests.

const std = @import("std");
pub const scanner = @import("../scanner/scanner.zig");
pub const types = @import("event.zig");
const internal = @import("internal.zig");
const implicit_key = internal;
const flow = @import("flow.zig");
const document = @import("document.zig");
const scalar_parser = @import("scalar.zig");
const token_cursor = internal;
const block_sequence = @import("block_sequence.zig");
const block_mapping = @import("block_mapping.zig");
const common_limit = @import("../common/limit.zig");

pub const Error = types.Error;
pub const Event = types.Event;
pub const EventStream = types.EventStream;
pub const ParseError = types.ParseError;
pub const max_block_depth: usize = common_limit.max_parse_collection_depth;
pub const NodeProperties = internal.NodeProperties;
pub const TokenDirectives = internal.TokenDirectives;
pub const PlainBlockNode = internal.PlainBlockNode;
pub const PlainBlockPair = internal.PlainBlockPair;
pub const ScalarDocumentTokens = scalar_parser.ScalarDocumentTokens;
pub const appendCompactExplicitBlockMappingPair = internal.appendCompactExplicitBlockMappingPair;
pub const appendPlainBlockNodeEvent = internal.appendEvent;
pub const appendDocumentEndSeparatedStreamEvents = document.appendDocumentEndSeparatedStreamEvents;
pub const appendExplicitDocumentStreamEvents = document.appendExplicitDocumentStreamEvents;
pub const appendImplicitDocumentStartSeparatedStreamEvents = document.appendImplicitDocumentStartSeparatedStreamEvents;
pub const parseAliasDocumentTokens = scalar_parser.parseAliasTokens;
pub const appendNodeEvents = flow.appendNodeEvents;
pub const appendMappingNodeEvents = flow.appendMappingNodeEvents;
pub const parseFlowMappingDocumentTokens = flow.parseMappingTokens;
pub const parseFlowPlainBlockNode = internal.parseFlowPlainBlockNode;
pub const parseFlowSequenceDocumentTokens = flow.parseSequenceTokens;
pub const parseScalarDocumentTokens = scalar_parser.parseScalarTokens;
pub const consumeBlockCollectionProperties = internal.consumeBlockCollectionProperties;
pub const compactBlockSequenceEntryHasSameLineContent = internal.compactBlockSequenceEntryHasSameLineContent;
pub const consumeNestedBlockCollectionPropertyLine = internal.consumeNestedBlockCollectionPropertyLine;
pub const isBareBlockSequenceEntryScalar = scalar_parser.isBareBlockSequenceEntryScalar;
pub const isBlockSequenceItemScalar = scalar_parser.isBlockSequenceItemScalar;
pub const isFlowIndicatorOrTag = scalar_parser.isFlowIndicatorOrTag;
pub const isPlainScalarContinuationToken = scalar_parser.isPlainScalarContinuationToken;
pub const isPlainScalarToken = scalar_parser.isPlainScalarToken;
pub const isTabSeparatedCompactMappingStart = scalar_parser.isTabSeparatedCompactMappingStart;
pub const parseBlockScalarToken = scalar_parser.parseBlockScalarToken;
pub const parseBlockScalarTokenAt = scalar_parser.parseBlockScalarTokenAt;
pub const parsePlainBlockSequenceItemScalarTokenRun = scalar_parser.parsePlainBlockSequenceItemScalarTokenRun;
pub const parsePlainScalarTokenRun = scalar_parser.parsePlainScalarTokenRun;
pub const parsePlainScalarTokenRunWithIndentedContinuations = scalar_parser.parsePlainScalarTokenRunWithIndentedContinuations;
pub const parseScalarToken = scalar_parser.parseScalarToken;
pub const scalarTokenSpansLines = scalar_parser.scalarTokenSpansLines;
pub const consumeLeadingDirectives = internal.consumeLeadingDirectives;
pub const consumeNodeProperties = internal.consumeNodeProperties;
pub const consumeDocumentStartContent = token_cursor.consumeDocumentStartContent;
pub const emptyScalarNode = internal.emptyScalar;
pub const flowCollectionAtStartSpansLines = token_cursor.flowCollectionAtStartSpansLines;
pub const flowCollectionDescendantSpansLines = token_cursor.flowCollectionDescendantSpansLines;
pub const hasNodeProperties = internal.has;
pub const indentlessBlockSequenceStartsAtIndent = internal.indentlessBlockSequenceStartsAtIndent;
pub const isExplicitBlockMappingValueBoundary = token_cursor.isExplicitBlockMappingValueBoundary;
pub const isFlowStartToken = token_cursor.isFlowStartToken;
pub const isPlainBlockOmittedValueBoundary = token_cursor.isPlainBlockOmittedValueBoundary;
pub const isPlainBlockOmittedValueBoundaryAtIndent = token_cursor.isPlainBlockOmittedValueBoundaryAtIndent;
pub const isNestedBlockCollectionStart = internal.isNestedBlockCollectionStart;
pub const isSingleIndicatorScalarKeyBeforeValue = internal.isSingleIndicatorScalarKeyBeforeValue;
pub const mergeNodeProperties = internal.merge;
pub const multilineScalarCandidateHasNoImmediateMappingValue = internal.multilineScalarCandidateHasNoImmediateMappingValue;
pub const nodePropertyLineStartsNestedBlockMappingKey = internal.nodePropertyLineStartsNestedBlockMappingKey;
pub const parsePropertyOnlyEmptyBlockScalarNode = internal.parsePropertyOnlyEmptyBlockScalarNode;
pub const scalarTokenRunStartsBlockMappingKey = internal.scalarTokenRunStartsBlockMappingKey;
pub const skipComments = token_cursor.skipComments;
pub const tokenRangeSpansLines = implicit_key.tokenRangeSpansLines;
pub const validateAliasFlowCollectionSeparation = token_cursor.validateAliasFlowCollectionSeparation;
pub const validateAliasHasNoFollowingContent = internal.validateAliasHasNoFollowingContent;
pub const validateBlockFlowScalarToken = scalar_parser.validateBlockFlowScalarToken;
pub const validateExplicitMappingAliasKeyHasNoFollowingContent = internal.validateExplicitMappingAliasKeyHasNoFollowingContent;
pub const validateFlowContinuationIndent = token_cursor.validateFlowContinuationIndent;
pub const validateImplicitAliasKeyLength = implicit_key.validateImplicitAliasKeyLength;
pub const validateImplicitScalarKeyLength = implicit_key.validateImplicitScalarKeyLength;
pub const validateImplicitTokenKeyLength = implicit_key.validateImplicitTokenKeyLength;
pub const validateNodePropertiesSeparatedFromScalar = internal.validateNodePropertiesSeparatedFromScalar;
pub const parseCompactPlainBlockSequenceNode = block_sequence.parseCompactPlainBlockSequenceNode;
pub const inferredCompactSequenceIndent = block_sequence.inferredCompactSequenceIndent;
pub const parsePlainBlockSequenceItemAfterIndicator = block_sequence.parsePlainBlockSequenceItemAfterIndicator;
pub const parseIndentedPlainBlockSequenceItemNode = block_sequence.parseIndentedPlainBlockSequenceItemNode;
pub const PlainSequenceDocumentTokens = block_sequence.PlainSequenceDocumentTokens;
pub const parsePlainBlockSequenceDocumentTokens = block_sequence.parsePlainBlockSequenceDocumentTokens;
pub const parseIndentlessPlainBlockSequenceNode = block_sequence.parseIndentlessPlainBlockSequenceNode;
pub const parseNestedPlainBlockSequenceNode = block_sequence.parseNestedPlainBlockSequenceNode;
pub const parsePlainBlockMappingKeyNode = block_mapping.parsePlainBlockMappingKeyNode;
pub const parseExplicitBlockMappingScalarKeyNode = block_mapping.parseExplicitBlockMappingScalarKeyNode;
pub const parseIndentedExplicitBlockMappingScalarKeyNode = block_mapping.parseIndentedExplicitBlockMappingScalarKeyNode;
pub const parseIndentedExplicitBlockMappingBlockScalarKeyNode = block_mapping.parseIndentedExplicitBlockMappingBlockScalarKeyNode;
pub const parseIndentedExplicitBlockMappingFlowKeyNode = block_mapping.parseIndentedExplicitBlockMappingFlowKeyNode;
pub const parseIndentedExplicitBlockMappingAliasKeyNode = block_mapping.parseIndentedExplicitBlockMappingAliasKeyNode;
pub const parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode = block_mapping.parseSeparatedPropertyOnlyExplicitBlockMappingKeyNode;
pub const MultilineScalarKeyBehavior = block_mapping.MultilineScalarKeyBehavior;
pub const parsePlainBlockMappingScalarKey = block_mapping.parsePlainBlockMappingScalarKey;
pub const multilinePlainScalarKeyBeforeValue = block_mapping.multilinePlainScalarKeyBeforeValue;
pub const parseIndentedPlainBlockMappingValueNode = block_mapping.parseIndentedPlainBlockMappingValueNode;
pub const parsePlainBlockMappingValueNode = block_mapping.parsePlainBlockMappingValueNode;
pub const parseNestedBlockCollectionAfterPropertyLine = block_mapping.parseNestedBlockCollectionAfterPropertyLine;
pub const parseCompactExplicitBlockMappingNode = block_mapping.parseCompactExplicitBlockMappingNode;
pub const isCompactExplicitOmittedKeyBoundary = block_mapping.isCompactExplicitOmittedKeyBoundary;
pub const parseCompactExplicitBlockMappingKeyNode = block_mapping.parseCompactExplicitBlockMappingKeyNode;
pub const parseCompactPlainBlockMappingNode = block_mapping.parseCompactPlainBlockMappingNode;
pub const PlainMappingDocumentTokens = block_mapping.PlainMappingDocumentTokens;
pub const parsePlainBlockMappingDocumentTokens = block_mapping.parsePlainBlockMappingDocumentTokens;
pub const parseNestedPlainBlockMappingNode = block_mapping.parseNestedPlainBlockMappingNode;
/// Parses scanner tokens into a YAML event stream.
///
/// This is the public parser path. It handles stream/document framing, block
/// and flow collection roots, scalar and alias roots, directives, node
/// properties, and comments. Unsupported token shapes return `Unsupported`.
pub fn parseTokens(allocator: std.mem.Allocator, tokens: []const scanner.Token) Error!EventStream {
    if (tokens.len < 2) return ParseError.InvalidSyntax;
    if (tokens[0] != .stream_start or tokens[tokens.len - 1] != .stream_end) return ParseError.InvalidSyntax;
    try validateAliasFlowCollectionSeparation(tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const parsed = parseScalarDocumentTokens(arena_allocator, tokens) catch |err| switch (err) {
        ParseError.Unsupported => ScalarDocumentTokens{ .scalar = null },
        else => return err,
    };

    var events: std.ArrayList(Event) = .empty;
    try events.ensureTotalCapacity(arena_allocator, tokens.len);

    try events.append(arena_allocator, .stream_start);

    var content_index: usize = 1;
    skipComments(tokens, &content_index, tokens.len - 1);
    if (content_index == tokens.len - 1) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }
    if (tokens[content_index] == .document_end) {
        content_index += 1;
        skipComments(tokens, &content_index, tokens.len - 1);
        if (content_index == tokens.len - 1) {
            try events.append(arena_allocator, .stream_end);
            return finishEventStream(&arena, arena_allocator, &events);
        }
    }

    if (parsed.scalar) |scalar| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = parsed.explicit_start,
            .yaml_version = parsed.directives.yaml_version,
            .tag_directives = parsed.directives.tag_directives,
            .has_reserved_directive = parsed.directives.has_reserved_directive,
            .content_same_line = parsed.content_same_line,
            .content_same_line_separated_by_tab = parsed.content_same_line_separated_by_tab,
        } });
        try events.append(arena_allocator, .{ .scalar = scalar });
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = parsed.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try parseAliasDocumentTokens(arena_allocator, tokens)) |alias| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = alias.explicit_start,
            .yaml_version = alias.directives.yaml_version,
            .tag_directives = alias.directives.tag_directives,
            .has_reserved_directive = alias.directives.has_reserved_directive,
            .content_same_line = alias.content_same_line,
            .content_same_line_separated_by_tab = alias.content_same_line_separated_by_tab,
        } });
        try events.append(arena_allocator, .{ .alias = alias.value });
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = alias.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try appendImplicitDocumentStartSeparatedStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try appendDocumentEndSeparatedStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try appendExplicitDocumentStreamEvents(arena_allocator, tokens, &events, appendSingleDocumentEvents)) {
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try parsePlainBlockSequenceDocumentTokens(arena_allocator, tokens)) |sequence| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = sequence.explicit_start,
            .force_document_start = sequence.force_document_start,
            .yaml_version = sequence.directives.yaml_version,
            .tag_directives = sequence.directives.tag_directives,
            .has_reserved_directive = sequence.directives.has_reserved_directive,
            .content_same_line = sequence.content_same_line,
            .content_same_line_separated_by_tab = sequence.content_same_line_separated_by_tab,
        } });
        try events.append(arena_allocator, .{ .sequence_start = .{
            .style = .block,
            .anchor = sequence.properties.anchor,
            .tag = sequence.properties.tag,
        } });
        for (sequence.items) |item| {
            try appendPlainBlockNodeEvent(arena_allocator, &events, item);
        }
        try events.append(arena_allocator, .sequence_end);
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = sequence.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try parsePlainBlockMappingDocumentTokens(arena_allocator, tokens)) |mapping| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = mapping.explicit_start,
            .force_document_start = mapping.force_document_start,
            .yaml_version = mapping.directives.yaml_version,
            .tag_directives = mapping.directives.tag_directives,
            .has_reserved_directive = mapping.directives.has_reserved_directive,
            .content_same_line = mapping.content_same_line,
            .content_same_line_separated_by_tab = mapping.content_same_line_separated_by_tab,
        } });
        try events.append(arena_allocator, .{ .mapping_start = .{
            .style = .block,
            .anchor = mapping.properties.anchor,
            .tag = mapping.properties.tag,
        } });
        for (mapping.pairs) |pair| {
            try appendPlainBlockNodeEvent(arena_allocator, &events, pair.key);
            try appendPlainBlockNodeEvent(arena_allocator, &events, pair.value);
        }
        try events.append(arena_allocator, .mapping_end);
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = mapping.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try parseFlowSequenceDocumentTokens(arena_allocator, tokens)) |sequence| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = sequence.explicit_start,
            .yaml_version = sequence.directives.yaml_version,
            .tag_directives = sequence.directives.tag_directives,
            .has_reserved_directive = sequence.directives.has_reserved_directive,
            .content_same_line = sequence.content_same_line,
            .content_same_line_separated_by_tab = sequence.content_same_line_separated_by_tab,
        } });
        try events.appendSlice(arena_allocator, sequence.events);
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = sequence.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    if (try parseFlowMappingDocumentTokens(arena_allocator, tokens)) |mapping| {
        try events.append(arena_allocator, .{ .document_start = .{
            .explicit = mapping.explicit_start,
            .yaml_version = mapping.directives.yaml_version,
            .tag_directives = mapping.directives.tag_directives,
            .has_reserved_directive = mapping.directives.has_reserved_directive,
            .content_same_line = mapping.content_same_line,
            .content_same_line_separated_by_tab = mapping.content_same_line_separated_by_tab,
        } });
        try events.appendSlice(arena_allocator, mapping.events);
        try events.append(arena_allocator, .{ .document_end = .{ .explicit = mapping.explicit_end } });
        try events.append(arena_allocator, .stream_end);
        return finishEventStream(&arena, arena_allocator, &events);
    }

    return ParseError.Unsupported;
}

fn appendSingleDocumentEvents(
    allocator: std.mem.Allocator,
    document_tokens: []const scanner.Token,
    events: *std.ArrayList(Event),
) Error!bool {
    return document.appendSingleDocumentEvents(allocator, document_tokens, events, .{
        .parse_scalar_document = parseScalarDocumentTokens,
        .parse_alias_document = parseAliasDocumentTokens,
        .parse_plain_block_sequence_document = parsePlainBlockSequenceDocumentTokens,
        .parse_plain_block_mapping_document = parsePlainBlockMappingDocumentTokens,
        .parse_flow_sequence_document = parseFlowSequenceDocumentTokens,
        .parse_flow_mapping_document = parseFlowMappingDocumentTokens,
        .append_plain_block_node_event = appendPlainBlockNodeEvent,
    });
}

fn finishEventStream(
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    events: *std.ArrayList(Event),
) std.mem.Allocator.Error!EventStream {
    const owned_events = try events.toOwnedSlice(allocator);
    return .{
        .arena = arena.*,
        .events = owned_events,
    };
}
