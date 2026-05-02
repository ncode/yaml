//! Purpose: Scan YAML node property spellings.
//! Owns: Anchor, alias, and tag token payload bounds.
//! Does not own: Token emission, schema tag resolution, or parser node properties.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const Error = token.Error;

pub fn readName(scanner: anytype, prefix_len: usize) Error![]const u8 {
    const start = scanner.index + prefix_len;
    var cursor = start;
    while (cursor < scanner.input.len) : (cursor += 1) {
        if (std.mem.startsWith(u8, scanner.input[cursor..], lex.utf8_bom)) return error.InvalidSyntax;
        const byte = scanner.input[cursor];
        if (lex.isFlowStartIndicator(byte)) return error.InvalidSyntax;
        if (byte == ' ' or byte == '\t' or lex.isLineBreakByte(byte) or lex.isFlowIndicator(byte)) break;
        if (byte == '#' and lex.isCommentStart(scanner.input, cursor)) break;
    }

    if (cursor == start) return error.InvalidSyntax;
    scanner.index = cursor;
    return scanner.input[start..cursor];
}

pub fn readTag(scanner: anytype) Error![]const u8 {
    if (std.mem.startsWith(u8, scanner.input[scanner.index..], "!<")) {
        var cursor = scanner.index + 2;
        while (cursor < scanner.input.len and scanner.input[cursor] != '>') : (cursor += 1) {
            if (std.mem.startsWith(u8, scanner.input[cursor..], lex.utf8_bom)) return error.InvalidSyntax;
            if (lex.isLineBreakByte(scanner.input[cursor])) return error.InvalidSyntax;
        }
        if (cursor >= scanner.input.len) return error.InvalidSyntax;
        const tag = scanner.input[scanner.index .. cursor + 1];
        scanner.index = cursor + 1;
        return tag;
    }

    const start = scanner.index;
    if (lex.isSeparatedIndicatorAt(scanner.input, start, 1) or
        (start + 1 < scanner.input.len and lex.isFlowIndicator(scanner.input[start + 1])))
    {
        scanner.index += 1;
        return scanner.input[start..scanner.index];
    }

    _ = try readName(scanner, 1);
    return scanner.input[start..scanner.index];
}
