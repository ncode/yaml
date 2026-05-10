//! Purpose: Emit YAML scalar nodes and scalar-related properties.
//! Owns: Scalar style selection, plain/quoted scalar output, Unicode scans, and scalar/collection properties.
//! Does not own: Collection traversal, block scalar layout, tag URI encoding, or schema resolution.
//! Depends on: common/diagnostic.zig, common/style.zig, block.zig, parser/event.zig, tag.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/conformance/yaml_suite_runner.zig, tests/stress/stress.zig.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const event_types = @import("../parser/event.zig");
const block_emit = @import("block.zig");
const tag_emit = @import("tag.zig");
const style_types = @import("../common/style.zig");

const CollectionStart = event_types.CollectionStart;
const Error = common.Error;
const Event = event_types.Event;
const ParseError = common.ParseError;
const Scalar = event_types.Scalar;
const ScalarStyle = style_types.ScalarStyle;

pub const appendEmittedTag = tag_emit.appendEmittedTag;
pub const appendIndent = block_emit.appendIndent;
pub const blockScalarEndsWithWhitespaceOnlyContentLine = block_emit.blockScalarEndsWithWhitespaceOnlyContentLine;
pub const blockScalarHasLeadingTabIndentedLine = block_emit.blockScalarHasLeadingTabIndentedLine;
pub const blockScalarHasTabStartedLine = block_emit.blockScalarHasTabStartedLine;
pub const blockScalarHasTrailingSpaceOnlyContentLine = block_emit.blockScalarHasTrailingSpaceOnlyContentLine;
pub const blockScalarUsesKeepChomping = block_emit.blockScalarUsesKeepChomping;
pub const EmittedBlockScalarIndent = block_emit.Indent;
pub const scalarUsesQuotedBlockFallback = block_emit.scalarUsesQuotedBlockFallback;
pub const validateAnchorName = tag_emit.validateAnchorName;

const appendFoldedBlockScalar = block_emit.appendFolded;
const appendLiteralBlockScalar = block_emit.appendLiteral;
const scalarShouldUseQuotedBlockFallback = block_emit.scalarShouldUseQuotedBlockFallback;

pub fn appendEmittedScalarNode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scalar: Scalar) Error!void {
    try appendEmittedScalarNodeIndented(allocator, out, scalar, .{
        .content = 2,
        .indicator = 2,
    });
}

pub fn appendEmittedScalarNodeIndented(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scalar: Scalar,
    block_indent: EmittedBlockScalarIndent,
) Error!void {
    if (try appendEmittedScalarProperties(allocator, out, scalar)) {
        try out.append(allocator, ' ');
    }
    try appendEmittedScalarIndented(allocator, out, scalar, block_indent);
}

pub fn appendEmittedMappingKey(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scalar: Scalar) Error!void {
    if (isPlainEmptyScalar(scalar) and scalar.anchor == null and scalar.tag == null) return;

    if (try appendEmittedScalarProperties(allocator, out, scalar)) {
        try out.append(allocator, ' ');
    }
    if (isPlainEmptyScalar(scalar)) return;

    if (scalarContainsNonPrintableOutputCodepoint(scalar.value) or
        scalarContainsYamlNonLfLineBreak(scalar.value) or
        std.mem.indexOfScalar(u8, scalar.value, '\r') != null)
    {
        return appendDoubleQuotedScalar(allocator, out, scalar.value);
    }

    return switch (scalar.style) {
        .plain => appendEmittedPlainBlockMappingKey(allocator, out, scalar.value),
        .single_quoted => appendSingleQuotedScalarIndented(allocator, out, scalar.value, 2),
        .double_quoted => appendDoubleQuotedScalar(allocator, out, scalar.value),
        .literal, .folded => appendDoubleQuotedScalar(allocator, out, scalar.value),
    };
}

pub fn isPlainEmptyScalar(scalar: Scalar) bool {
    return scalar.style == .plain and scalar.value.len == 0;
}

pub fn isNonEmptyInlineScalar(scalar: Scalar) bool {
    return switch (scalar.style) {
        .plain, .single_quoted, .double_quoted => scalar.value.len != 0,
        .literal, .folded => false,
    };
}

pub fn isNonEmptyInlineEvent(event: Event) bool {
    return switch (event) {
        .scalar => |scalar| isNonEmptyInlineScalar(scalar),
        .alias => |alias| alias.len != 0,
        else => false,
    };
}

fn appendEmittedScalarIndented(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scalar: Scalar,
    block_indent: EmittedBlockScalarIndent,
) Error!void {
    if (scalarContainsNonPrintableOutputCodepoint(scalar.value) or
        scalarContainsYamlNonLfLineBreak(scalar.value) or
        std.mem.indexOfScalar(u8, scalar.value, '\r') != null)
    {
        return appendDoubleQuotedScalar(allocator, out, scalar.value);
    }

    const style: ScalarStyle = if (scalar.style == .plain and block_indent.quote_plain_multiline and
        std.mem.indexOfScalar(u8, scalar.value, '\n') != null)
        .single_quoted
    else
        scalar.style;

    switch (style) {
        .plain => {
            if (scalar.value.len == 0) {
                try out.appendSlice(allocator, "''");
            } else if (plainScalarNeedsQuoting(scalar.value)) {
                if (std.mem.indexOfScalar(u8, scalar.value, '\n') != null) {
                    try appendSingleQuotedScalarIndented(allocator, out, scalar.value, block_indent.content);
                } else {
                    try appendSingleQuotedScalar(allocator, out, scalar.value);
                }
            } else if (std.mem.indexOfScalar(u8, scalar.value, '\n') != null) {
                try appendPlainScalarWithLineBreaks(allocator, out, scalar.value, block_indent.plain_continuation);
            } else {
                try out.appendSlice(allocator, scalar.value);
            }
        },
        .single_quoted => try appendSingleQuotedScalarIndented(allocator, out, scalar.value, block_indent.content),
        .double_quoted => try appendDoubleQuotedScalar(allocator, out, scalar.value),
        .literal => if (scalarShouldUseQuotedBlockFallback(scalar, block_indent))
            try appendDoubleQuotedScalar(allocator, out, scalar.value)
        else
            try appendLiteralBlockScalar(allocator, out, scalar.value, block_indent),
        .folded => if (scalarShouldUseQuotedBlockFallback(scalar, block_indent))
            try appendDoubleQuotedScalar(allocator, out, scalar.value)
        else
            try appendFoldedBlockScalar(allocator, out, scalar.value, block_indent),
    }
}

pub fn plainScalarNeedsQuoting(value: []const u8) bool {
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (plainScalarLineNeedsQuoting(line)) return true;
    }

    for (value, 0..) |byte, index| {
        switch (byte) {
            '\t' => return true,
            ':' => if (index + 1 == value.len or isSeparationByte(value[index + 1])) return true,
            '#' => if (index == 0 or isSeparationByte(value[index - 1])) return true,
            else => {},
        }
    }

    return false;
}

pub fn flowPlainScalarNeedsQuoting(value: []const u8) bool {
    if (plainScalarNeedsQuoting(value)) return true;

    for (value, 0..) |byte, index| {
        switch (byte) {
            ',', '[', ']', '{', '}' => return true,
            ':' => if (index + 1 < value.len and isFlowMappingSeparatorFollower(value[index + 1])) return true,
            else => {},
        }
    }

    return false;
}

pub fn plainBlockMappingKeyNeedsQuoting(value: []const u8) bool {
    if (plainScalarLineNeedsQuoting(value)) return true;

    for (value, 0..) |byte, index| {
        switch (byte) {
            '\t' => return true,
            ':' => if (index + 1 == value.len or isSeparationByte(value[index + 1])) return true,
            '#' => if (index == 0 or isSeparationByte(value[index - 1])) return true,
            else => {},
        }
    }

    return false;
}

pub fn appendEmittedPlainBlockMappingKey(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) std.mem.Allocator.Error!void {
    if (value.len == 0) {
        try out.appendSlice(allocator, "''");
    } else if (plainBlockMappingKeyNeedsQuoting(value)) {
        if (std.mem.indexOfScalar(u8, value, '\n') != null) {
            try appendSingleQuotedScalarIndented(allocator, out, value, 2);
        } else {
            try appendSingleQuotedScalar(allocator, out, value);
        }
    } else {
        try out.appendSlice(allocator, value);
    }
}

pub fn appendPlainScalarWithLineBreaks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    continuation_indent: usize,
) std.mem.Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try out.appendSlice(allocator, "\n\n");
            if (line.len != 0) try appendIndent(allocator, out, continuation_indent);
        }
        first = false;
        try out.appendSlice(allocator, line);
    }
}

fn plainScalarLineNeedsQuoting(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "---") or std.mem.startsWith(u8, value, "...")) return true;
    if (value[0] == ' ' or value[0] == '\t' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return true;
    if (plainScalarStartsWithIndicator(value)) return true;
    if (value[value.len - 1] == ':') return true;
    return false;
}

fn plainScalarStartsWithIndicator(value: []const u8) bool {
    return switch (value[0]) {
        '#', '[', ']', '{', '}', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => true,
        '-', '?', ':' => value.len == 1 or isSeparationByte(value[1]),
        else => false,
    };
}

fn isFlowMappingSeparatorFollower(byte: u8) bool {
    return switch (byte) {
        '[', '{', '\'', '"' => true,
        else => isSeparationByte(byte),
    };
}

fn isSeparationByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or isLineBreakByte(byte);
}

fn isLineBreakByte(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

pub fn collectionHasProperties(collection: CollectionStart) bool {
    return collection.anchor != null or collection.tag != null;
}

pub fn appendEmittedScalarProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scalar: Scalar) Error!bool {
    var wrote_property = false;

    if (scalar.anchor) |anchor| {
        try validateAnchorName(anchor);
        try out.append(allocator, '&');
        try out.appendSlice(allocator, anchor);
        wrote_property = true;
    }

    if (scalar.tag) |tag| {
        if (wrote_property) try out.append(allocator, ' ');
        try appendEmittedTag(allocator, out, tag);
        wrote_property = true;
    }

    return wrote_property;
}

pub fn appendEmittedCollectionProperties(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    collection: CollectionStart,
) Error!bool {
    var wrote_property = false;

    if (collection.anchor) |anchor| {
        try validateAnchorName(anchor);
        try out.append(allocator, '&');
        try out.appendSlice(allocator, anchor);
        wrote_property = true;
    }

    if (collection.tag) |tag| {
        if (wrote_property) try out.append(allocator, ' ');
        try appendEmittedTag(allocator, out, tag);
        wrote_property = true;
    }

    return wrote_property;
}

pub fn appendEmittedAlias(allocator: std.mem.Allocator, out: *std.ArrayList(u8), alias: []const u8) Error!void {
    try validateAnchorName(alias);
    try out.append(allocator, '*');
    try out.appendSlice(allocator, alias);
}

pub fn appendSingleQuotedScalar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) std.mem.Allocator.Error!void {
    try out.append(allocator, '\'');
    try appendSingleQuotedScalarContent(allocator, out, value);
    try out.append(allocator, '\'');
}

pub fn appendSingleQuotedScalarIndented(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    indent: usize,
) std.mem.Allocator.Error!void {
    if (isAllNewlines(value)) {
        try out.append(allocator, '\'');
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, value);
        try appendIndent(allocator, out, indent);
        try out.append(allocator, '\'');
    } else if (std.mem.indexOfScalar(u8, value, '\n') != null) {
        try appendSingleQuotedScalarWithLineBreaks(allocator, out, value, indent);
    } else {
        try appendSingleQuotedScalar(allocator, out, value);
    }
}

pub fn appendDoubleQuotedScalar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) Error!void {
    try out.append(allocator, '"');
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        switch (byte) {
            '"' => {
                try out.appendSlice(allocator, "\\\"");
                index += 1;
            },
            '\\' => {
                try out.appendSlice(allocator, "\\\\");
                index += 1;
            },
            0x08 => {
                try out.appendSlice(allocator, "\\b");
                index += 1;
            },
            '\t' => {
                try out.appendSlice(allocator, "\\t");
                index += 1;
            },
            '\n' => {
                try out.appendSlice(allocator, "\\n");
                index += 1;
            },
            '\r' => {
                try out.appendSlice(allocator, "\\r");
                index += 1;
            },
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => {
                try appendCodepointEscape(allocator, out, byte);
                index += 1;
            },
            else => {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch return ParseError.InvalidSyntax;
                if (index + len > value.len) return ParseError.InvalidSyntax;
                const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch return ParseError.InvalidSyntax;

                if (codepoint == 0xfeff or codepoint > 0x7e) {
                    try appendCodepointEscape(allocator, out, codepoint);
                } else if (tag_emit.isYamlAllowedCodepoint(codepoint)) {
                    try out.appendSlice(allocator, value[index .. index + len]);
                } else {
                    try appendCodepointEscape(allocator, out, codepoint);
                }
                index += len;
            },
        }
    }
    try out.append(allocator, '"');
}

fn appendSingleQuotedScalarContent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) std.mem.Allocator.Error!void {
    for (value) |byte| {
        if (byte == '\'') try out.append(allocator, '\'');
        try out.append(allocator, byte);
    }
}

fn appendSingleQuotedScalarWithLineBreaks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    continuation_indent: usize,
) std.mem.Allocator.Error!void {
    try out.append(allocator, '\'');
    var lines = std.mem.splitScalar(u8, value, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try out.appendSlice(allocator, "\n\n");
            if (line.len != 0) try appendIndent(allocator, out, continuation_indent);
        }
        first = false;
        try appendSingleQuotedScalarContent(allocator, out, line);
    }
    try out.append(allocator, '\'');
}

fn appendCodepointEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) std.mem.Allocator.Error!void {
    if (codepoint <= 0xff) {
        try out.appendSlice(allocator, "\\x");
        try tag_emit.appendFixedHex(allocator, out, codepoint, 2);
    } else if (codepoint <= 0xffff) {
        try out.appendSlice(allocator, "\\u");
        try tag_emit.appendFixedHex(allocator, out, codepoint, 4);
    } else {
        try out.appendSlice(allocator, "\\U");
        try tag_emit.appendFixedHex(allocator, out, codepoint, 8);
    }
}

fn isAllNewlines(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte != '\n') return false;
    }
    return true;
}

pub fn scalarContainsNonAsciiCodepoint(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[index]) catch return true;
        if (index + len > value.len) return true;
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch return true;
        if (codepoint > 0x7e) return true;
        index += len;
    }

    return false;
}

pub fn scalarContainsNonPrintableOutputCodepoint(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[index]) catch return true;
        if (index + len > value.len) return true;
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch return true;
        if (codepoint == 0xfeff) return true;
        if (!tag_emit.isYamlAllowedCodepoint(codepoint)) return true;
        index += len;
    }

    return false;
}

pub fn scalarContainsYamlNonLfLineBreak(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[index]) catch return false;
        if (index + len > value.len) return false;
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch return false;
        switch (codepoint) {
            0x85, 0x2028, 0x2029 => return true,
            else => {},
        }
        index += len;
    }

    return false;
}

test "emitter: escapes constructed YAML non-LF line breaks" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        value: []const u8,
        expected: []const u8,
    }{
        .{ .value = "before\xC2\x85after", .expected = "\"before\\x85after\"" },
        .{ .value = "before\xE2\x80\xA8after", .expected = "\"before\\u2028after\"" },
        .{ .value = "before\xE2\x80\xA9after", .expected = "\"before\\u2029after\"" },
    };

    for (cases) |case| {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        try appendEmittedScalarNode(allocator, &out, .{ .value = case.value });
        try std.testing.expectEqualStrings(case.expected, out.items);
    }
}

test "emitter: double-quotes unsafe mapping keys" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendEmittedMappingKey(allocator, &out, .{
        .value = "before\x07after",
        .style = .single_quoted,
    });
    try std.testing.expectEqualStrings("\"before\\x07after\"", out.items);
}

test "emitter: double-quotes block-style inline mapping keys" {
    const allocator = std.testing.allocator;

    const cases = [_]ScalarStyle{ .literal, .folded };
    for (cases) |style| {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        try appendEmittedMappingKey(allocator, &out, .{
            .value = "line\nkey",
            .style = style,
        });
        try std.testing.expectEqualStrings("\"line\\nkey\"", out.items);
    }
}

test "emitter: plain scalar quoting policy covers block separators" {
    try std.testing.expect(plainScalarNeedsQuoting("--- document marker"));
    try std.testing.expect(plainScalarNeedsQuoting("... document end"));
    try std.testing.expect(plainScalarNeedsQuoting("key: value"));
    try std.testing.expect(plainScalarNeedsQuoting("value # comment"));
    try std.testing.expect(!plainScalarNeedsQuoting("http://example.test"));
    try std.testing.expect(!plainScalarNeedsQuoting("hash#inside"));
}

test "emitter: flow plain scalar quoting policy covers flow separators" {
    try std.testing.expect(flowPlainScalarNeedsQuoting("one,two"));
    try std.testing.expect(flowPlainScalarNeedsQuoting("key: value"));
    try std.testing.expect(flowPlainScalarNeedsQuoting("key:[value]"));
    try std.testing.expect(flowPlainScalarNeedsQuoting("key:\"value\""));
    try std.testing.expect(!flowPlainScalarNeedsQuoting("key:value"));
}

test "emitter: plain scalar line-break writer preserves empty continuation lines" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendPlainScalarWithLineBreaks(std.testing.allocator, &out, "one\n\ntwo", 4);

    try std.testing.expectEqualStrings("one\n\n\n\n    two", out.items);
}

test "emitter: block mapping key writer quotes empty keys" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendEmittedPlainBlockMappingKey(std.testing.allocator, &out, "");

    try std.testing.expectEqualStrings("''", out.items);
}

test "emitter: block mapping key writer quotes multiline unsafe keys" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendEmittedPlainBlockMappingKey(std.testing.allocator, &out, "key: value\nnext");

    try std.testing.expectEqualStrings("'key: value\n\n  next'", out.items);
}

test "emitter: scalar properties append anchor and tag" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(!try appendEmittedScalarProperties(std.testing.allocator, &out, .{ .value = "plain" }));
    try std.testing.expectEqualStrings("", out.items);

    try std.testing.expect(try appendEmittedScalarProperties(std.testing.allocator, &out, .{
        .value = "plain",
        .anchor = "a1",
        .tag = "tag:yaml.org,2002:str",
    }));
    try std.testing.expectEqualStrings("&a1 !!str", out.items);
}

test "emitter: collection properties append anchor and tag" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(!collectionHasProperties(.{ .style = .block }));
    try std.testing.expect(collectionHasProperties(.{ .style = .flow, .anchor = "items" }));

    try std.testing.expect(!try appendEmittedCollectionProperties(std.testing.allocator, &out, .{ .style = .block }));
    try std.testing.expectEqualStrings("", out.items);

    try std.testing.expect(try appendEmittedCollectionProperties(std.testing.allocator, &out, .{
        .style = .flow,
        .anchor = "items",
        .tag = "!local",
    }));
    try std.testing.expectEqualStrings("&items !local", out.items);
}

test "emitter: alias emission validates anchor names" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendEmittedAlias(std.testing.allocator, &out, "target");
    try std.testing.expectEqualStrings("*target", out.items);

    out.clearRetainingCapacity();
    try std.testing.expectError(common.ParseError.InvalidSyntax, appendEmittedAlias(std.testing.allocator, &out, "bad,name"));
    try std.testing.expectEqualStrings("", out.items);
}

test "emitter: single quoted scalar doubles embedded quotes" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendSingleQuotedScalar(allocator, &out, "can't stop");

    try std.testing.expectEqualStrings("'can''t stop'", out.items);
}

test "emitter: single quoted scalar preserves all-newline content" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendSingleQuotedScalarIndented(allocator, &out, "\n\n", 4);

    try std.testing.expectEqualStrings("'\n\n\n    '", out.items);
}

test "emitter: single quoted scalar indents multiline content" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendSingleQuotedScalarIndented(allocator, &out, "first\nsecond\n", 2);

    try std.testing.expectEqualStrings("'first\n\n  second\n\n'", out.items);
}

test "emitter: double quoted scalar uses YAML escape forms" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendDoubleQuotedScalar(allocator, &out, "\"\\\x08\t\n\r\x01\xC2\x85\xEF\xBB\xBF\xF0\x9F\x98\x80");

    try std.testing.expectEqualStrings("\"\\\"\\\\\\b\\t\\n\\r\\x01\\x85\\uFEFF\\U0001F600\"", out.items);
}

test "emitter: double quoted scalar rejects malformed UTF-8" {
    const allocator = std.testing.allocator;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try std.testing.expectError(ParseError.InvalidSyntax, appendDoubleQuotedScalar(allocator, &out, "bad\xC2"));
}

test "emitter: scalar Unicode classification handles malformed UTF-8" {
    try std.testing.expect(scalarContainsNonAsciiCodepoint("caf\xc3"));
    try std.testing.expect(scalarContainsNonPrintableOutputCodepoint("\xf0\x9f"));
    try std.testing.expect(!scalarContainsYamlNonLfLineBreak("line\xe2"));
}

test "emitter: scalar Unicode classification detects YAML non-LF line breaks" {
    try std.testing.expect(scalarContainsNonAsciiCodepoint("\xc2\x85"));
    try std.testing.expect(!scalarContainsNonPrintableOutputCodepoint("\xe2\x80\xa8"));
    try std.testing.expect(scalarContainsYamlNonLfLineBreak("next\xc2\x85line"));
    try std.testing.expect(scalarContainsYamlNonLfLineBreak("next\xe2\x80\xa8line"));
    try std.testing.expect(scalarContainsYamlNonLfLineBreak("next\xe2\x80\xa9line"));
    try std.testing.expect(!scalarContainsYamlNonLfLineBreak("next\nline"));
}
