//! Purpose: Scan YAML scalar token payloads.
//! Owns: Plain scalar token bounds and quoted scalar delimiter validation.
//! Does not own: Block scalar header/content scanning or scalar resolution.
//! Depends on: scanner/lex.zig, scanner/token.zig.
//! Tested by: tests/unit/scanner/scanner_test.zig and direct conformance tests.

const std = @import("std");
const lex = @import("lex.zig");
const token = @import("token.zig");

const Error = token.Error;

pub fn appendScalar(scanner: anytype) Error!void {
    const start = scanner.index;
    if (lex.isReservedIndicator(scanner.input[start]) and lex.reservedIndicatorStartsPlainScalar(scanner.input, start)) {
        return error.InvalidSyntax;
    }
    if (std.mem.startsWith(u8, scanner.input[start..], lex.utf8_bom)) return error.InvalidSyntax;

    while (scanner.index < scanner.input.len) {
        if (std.mem.startsWith(u8, scanner.input[scanner.index..], lex.utf8_bom)) return error.InvalidSyntax;
        const byte = scanner.input[scanner.index];
        if (lex.isLineBreakByte(byte) or byte == ' ' or byte == '\t') break;
        if (byte == '#' and lex.isCommentStart(scanner.input, scanner.index)) break;
        if (flowDepth(scanner) != 0 and lex.isFlowIndicator(byte)) break;
        if (byte == ':' and lex.isMappingSeparatorAt(scanner.input, scanner.index, flowDepth(scanner) != 0)) break;
        scanner.index += 1;
    }

    if (scanner.index == start) return error.InvalidSyntax;
    try scanner.tokens.append(scanner.allocator, .{ .scalar = scanner.input[start..scanner.index] });
}

pub fn readQuotedScalar(scanner: anytype, quote: u8) Error![]const u8 {
    const start = scanner.index;
    scanner.index += 1;
    while (scanner.index < scanner.input.len) {
        const byte = scanner.input[scanner.index];
        if (quote == '\'' and byte == '\'' and scanner.index + 1 < scanner.input.len and scanner.input[scanner.index + 1] == '\'') {
            scanner.index += 2;
            continue;
        }
        if (quote == '"' and byte == '\\') {
            scanner.index += 1;
            try lex.consumeDoubleQuoted(scanner);
            continue;
        }
        scanner.index += 1;
        if (byte == quote) return scanner.input[start..scanner.index];
    }

    return error.InvalidSyntax;
}

fn flowDepth(scanner: anytype) usize {
    return scanner.square_depth + scanner.curly_depth;
}
