//! Purpose: Verify parser-event composition into representation graphs.
//! Owns: Composer behavior tests for anchors, aliases, recursion, and stream shape.
//! Does not own: Scanner, parser tokenization, schema construction, or public loading.
//! Depends on: src/compose/composer.zig, src/parser/event.zig, src/common/style.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_internal");

const composer = internal.composer;
const Event = composer.Event;
const ParseError = composer.ParseError;

test "composer: resolves aliases to anchored representation nodes" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .anchor = "item", .value = "one" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .sequence);
    try std.testing.expectEqual(@as(usize, 2), documents[0].sequence.items.len);
    try std.testing.expectEqual(documents[0].sequence.items[0], documents[0].sequence.items[1]);
}

test "composer: resolves aliases to the most recent duplicate anchor" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .scalar = .{ .anchor = "item", .value = "first" } },
        .{ .scalar = .{ .anchor = "item", .value = "second" } },
        .{ .alias = "item" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .sequence);
    try std.testing.expectEqual(@as(usize, 3), documents[0].sequence.items.len);
    try std.testing.expect(documents[0].sequence.items[0] != documents[0].sequence.items[1]);
    try std.testing.expectEqual(documents[0].sequence.items[1], documents[0].sequence.items[2]);
    try std.testing.expectEqualStrings("first", documents[0].sequence.items[0].scalar.value);
    try std.testing.expectEqualStrings("second", documents[0].sequence.items[1].scalar.value);
}

test "composer: rejects undefined aliases" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "missing" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: rejects structural events where nodes are required" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: rejects aliases to anchors from previous documents" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "base", .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .alias = "base" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.InvalidSyntax, composer.composeStream(arena.allocator(), &events, .{}));
}

test "composer: supports recursive aliases to the current anchored node" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow, .anchor = "root" } },
        .{ .scalar = .{ .value = "self" } },
        .{ .alias = "root" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try composer.composeStream(arena.allocator(), &events, .{});

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .mapping);
    try std.testing.expectEqual(@as(usize, 1), documents[0].mapping.pairs.len);
    try std.testing.expectEqual(documents[0], documents[0].mapping.pairs[0].value);
}

test "composer: enforces document and alias count limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .anchor = "base", .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .alias = "base" },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_document_count = 1,
    }));
    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_document_count = 2,
        .max_alias_count = 0,
    }));
}

test "composer: enforces alias expansion limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .sequence_start = .{ .style = .block } },
        .{ .sequence_start = .{ .style = .block, .anchor = "base" } },
        .{ .scalar = .{ .value = "one" } },
        .{ .scalar = .{ .value = "two" } },
        .sequence_end,
        .{ .alias = "base" },
        .{ .alias = "base" },
        .sequence_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const accepted = try composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 6,
    });
    try std.testing.expectEqual(@as(usize, 1), accepted.len);

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 5,
    }));
}

test "composer: finite alias expansion limit rejects recursive aliases" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .mapping_start = .{ .style = .flow, .anchor = "root" } },
        .{ .scalar = .{ .value = "self" } },
        .{ .alias = "root" },
        .mapping_end,
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.Unsupported, composer.composeStream(arena.allocator(), &events, .{
        .max_alias_expansion = 1024,
    }));
}
