//! Purpose: Normalize YAML reader line breaks.
//! Owns: YAML line-break normalization for prepared UTF-8 input.
//! Does not own: Character encoding detection, UTF decoding, or scanner line tokenization.
//! Depends on: std.
//! Tested by: in-file tests and scanner/parser integration tests.

const std = @import("std");

pub const NormalizedInput = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: NormalizedInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

/// Returns YAML source bytes after line-break normalization.
///
/// YAML 1.2.2 line breaks are LF, CR, CRLF, NEL, LS, and PS. All non-LF
/// variants are normalized to LF. The returned bytes borrow `input` when no
/// normalization is needed.
pub fn normalizeYamlLineBreaks(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!NormalizedInput {
    if (!needsNormalization(input)) {
        return .{ .bytes = input };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\r') {
            try out.append(allocator, '\n');
            index += 1;
            if (index < input.len and input[index] == '\n') index += 1;
            continue;
        }

        if (std.mem.startsWith(u8, input[index..], "\xc2\x85")) {
            try out.append(allocator, '\n');
            index += 2;
            continue;
        }

        if (std.mem.startsWith(u8, input[index..], "\xe2\x80\xa8") or
            std.mem.startsWith(u8, input[index..], "\xe2\x80\xa9"))
        {
            try out.append(allocator, '\n');
            index += 3;
            continue;
        }

        try out.append(allocator, input[index]);
        index += 1;
    }

    const owned = try out.toOwnedSlice(allocator);
    return .{ .bytes = owned, .owned = owned };
}

fn needsNormalization(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (input[index] == '\r') return true;
        if (std.mem.startsWith(u8, input[index..], "\xc2\x85")) return true;
        if (std.mem.startsWith(u8, input[index..], "\xe2\x80\xa8")) return true;
        if (std.mem.startsWith(u8, input[index..], "\xe2\x80\xa9")) return true;
    }
    return false;
}

test normalizeYamlLineBreaks {
    var normalized = try normalizeYamlLineBreaks(std.testing.allocator, "one\r\ntwo\rthree\nfour\xc2\x85five\xe2\x80\xa8six\xe2\x80\xa9seven");
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expect(normalized.owned != null);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix\nseven", normalized.bytes);
}

test "normalizeYamlLineBreaks borrows input when no normalization is needed" {
    const input = "one\ntwo\xc2\xa0three";

    const normalized = try normalizeYamlLineBreaks(std.testing.allocator, input);
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expect(normalized.owned == null);
    try std.testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(normalized.bytes.ptr));
    try std.testing.expectEqualStrings(input, normalized.bytes);
}

test "normalizeYamlLineBreaks cleans up after allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkNormalizeYamlLineBreaksAllocationFailure, .{});
}

fn checkNormalizeYamlLineBreaksAllocationFailure(allocator: std.mem.Allocator) !void {
    var normalized = try normalizeYamlLineBreaks(allocator, "one\r\ntwo\xc2\x85three\xe2\x80\xa8four");
    defer normalized.deinit(allocator);

    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", normalized.bytes);
}
