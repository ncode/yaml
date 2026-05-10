//! Purpose: Scan YAML block scalar headers and raw content ranges.
//! Owns: Literal/folded header validation, chomping, indentation indicators, and content bounds.
//! Does not own: Folding or chomping application in parsed scalar values.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const BlockScalar = token.BlockScalar;
const BlockScalarChomping = token.BlockScalarChomping;
const Error = token.Error;

pub fn indicatorStartsNode(scanner: anytype) bool {
    if (flowDepth(scanner) != 0) return false;
    if (scanner.index == scanner.line_content_start) return true;
    if (scanner.tokens.items.len == 0) return false;

    return switch (scanner.tokens.items[scanner.tokens.items.len - 1]) {
        .document_start,
        .document_start_content,
        .block_sequence_entry,
        .block_mapping_key,
        .block_mapping_value,
        .anchor,
        .tag,
        => true,
        .scalar => |value| std.mem.eql(u8, value, "?") and compactSequenceExplicitKeyParentIndent(scanner, 0) != null,
        else => false,
    };
}

pub fn readBlockScalar(scanner: anytype, indicator: u8) Error!BlockScalar {
    if (flowDepth(scanner) != 0) return error.InvalidSyntax;

    const header_line = lex.lineAt(scanner.input, scanner.index);
    const header = lex.stripLineComment(scanner.input[scanner.index + 1 .. header_line.end]);

    var chomping: BlockScalarChomping = .clip;
    var indent_indicator: ?usize = null;
    var saw_chomping = false;
    var saw_indent = false;
    var cursor: usize = 0;
    while (cursor < header.len) : (cursor += 1) {
        switch (header[cursor]) {
            ' ', '\t', '\r' => {},
            '-' => {
                if (saw_chomping) return error.InvalidSyntax;
                saw_chomping = true;
                chomping = .strip;
            },
            '+' => {
                if (saw_chomping) return error.InvalidSyntax;
                saw_chomping = true;
                chomping = .keep;
            },
            '1'...'9' => {
                if (saw_indent) return error.InvalidSyntax;
                saw_indent = true;
                indent_indicator = header[cursor] - '0';
            },
            else => return error.InvalidSyntax,
        }
    }

    const line_start = lex.lineStartAt(scanner.input, scanner.index);
    const base_parent_indent = if (lex.startsDocumentMarker(scanner.input[line_start..], "---"))
        0
    else if (scanner.line_content_start >= line_start)
        lex.countIndentSpaces(scanner.input[line_start..scanner.line_content_start])
    else
        0;
    const parent_indent = compactSequenceMappingValueParentIndent(scanner, base_parent_indent) orelse
        compactSequenceExplicitKeyParentIndent(scanner, base_parent_indent) orelse
        base_parent_indent;
    const content_start = header_line.next;
    const content_end = lex.findBlockScalarContentEnd(
        scanner.input,
        content_start,
        parent_indent,
        indent_indicator,
        canReadZeroIndentedBlockScalar(scanner.tokens.items),
    );

    scanner.index = content_end;
    scanner.line_start = true;

    return .{
        .style = if (indicator == '|') .literal else .folded,
        .chomping = chomping,
        .indent_indicator = indent_indicator,
        .content = scanner.input[content_start..content_end],
    };
}

pub fn compactSequenceExplicitKeyParentIndent(scanner: anytype, base_parent_indent: usize) ?usize {
    var cursor = scanner.tokens.items.len;
    while (cursor > 0) {
        switch (scanner.tokens.items[cursor - 1]) {
            .anchor, .tag => cursor -= 1,
            else => break,
        }
    }
    if (cursor == 0) return null;

    switch (scanner.tokens.items[cursor - 1]) {
        .scalar => |value| if (!std.mem.eql(u8, value, "?")) return null,
        else => return null,
    }

    cursor -= 1;
    while (cursor > 0) {
        cursor -= 1;
        switch (scanner.tokens.items[cursor]) {
            .anchor, .tag => continue,
            .block_sequence_entry => return base_parent_indent + 2,
            else => return null,
        }
    }

    return null;
}

fn compactSequenceMappingValueParentIndent(scanner: anytype, base_parent_indent: usize) ?usize {
    if (scanner.tokens.items.len == 0 or scanner.tokens.items[scanner.tokens.items.len - 1] != .block_mapping_value) {
        return null;
    }

    var cursor = scanner.line_content_start;
    var compact_sequence_entries: usize = 0;
    while (cursor < scanner.index and scanner.input[cursor] == '-' and lex.isSeparatedIndicatorAt(scanner.input, cursor, 1)) {
        compact_sequence_entries += 1;
        cursor += 1;
        while (cursor < scanner.index and scanner.input[cursor] == ' ') : (cursor += 1) {}
    }

    if (compact_sequence_entries == 0) return null;
    return base_parent_indent + compact_sequence_entries * 2;
}

fn flowDepth(scanner: anytype) usize {
    return scanner.square_depth + scanner.curly_depth;
}

fn canReadZeroIndentedBlockScalar(tokens: []const token.Token) bool {
    if (tokens.len == 0) return false;
    return switch (std.meta.activeTag(tokens[tokens.len - 1])) {
        .document_start, .document_start_content, .indent => true,
        else => false,
    };
}

test "scanner block scalar: compact explicit key parent indent rejects non-sequence prefixes" {
    const ScannerStub = struct {
        square_depth: usize = 0,
        curly_depth: usize = 0,
        index: usize = 0,
        line_content_start: usize = 0,
        tokens: std.ArrayList(token.Token) = .empty,
    };

    var scalar_only = ScannerStub{};
    defer scalar_only.tokens.deinit(std.testing.allocator);
    try scalar_only.tokens.append(std.testing.allocator, .{ .scalar = "?" });
    try std.testing.expectEqual(@as(?usize, null), compactSequenceExplicitKeyParentIndent(&scalar_only, 4));

    var wrong_prefix = ScannerStub{};
    defer wrong_prefix.tokens.deinit(std.testing.allocator);
    try wrong_prefix.tokens.appendSlice(std.testing.allocator, &.{
        .{ .scalar = "prefix" },
        .{ .scalar = "?" },
    });
    try std.testing.expectEqual(@as(?usize, null), compactSequenceExplicitKeyParentIndent(&wrong_prefix, 4));
}
