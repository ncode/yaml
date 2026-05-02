//! Purpose: Verify focused loader-layer entry points.
//! Owns: Loader bridge behavior that is not part of the public root API.
//! Does not own: Parser event generation, schema scalar rules, or public diagnostics.
//! Depends on: src/internal.zig.
//! Tested by: zig build test-unit.

const std = @import("std");
const internal = @import("yaml_internal");

const Event = internal.types.Event;
const loader = internal.loader;

test "loader: loadStreamFromEvents constructs document roots without failure sink" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "value" } },
        .{ .document_end = .{} },
        .stream_end,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const documents = try loader.loadStreamFromEvents(
        arena.allocator(),
        &events,
        .core,
        .reject,
        .preserve,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), documents.len);
    try std.testing.expect(documents[0].* == .scalar);
    try std.testing.expectEqualStrings("value", documents[0].scalar.value);
}
