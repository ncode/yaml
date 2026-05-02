//! Purpose: Apply loader preflight limits to parser event streams.
//! Owns: Event-count checks that happen before composition and construction.
//! Does not own: Parser limits, compose-time alias expansion limits, value construction, or diagnostics formatting.
//! Depends on: common/diagnostic.zig, loader/failure.zig, parser/event.zig.
//! Tested by: tests/unit/loader/loader_test.zig and in-file tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const event = @import("../parser/event.zig");
const failure = @import("failure.zig");

const Error = diagnostic.Error;
const Event = event.Event;
const LoadFailure = failure.LoadFailure;
const ParseError = diagnostic.ParseError;

/// Loader preflight limits that can be checked directly from parser events.
pub const Options = struct {
    max_alias_count: ?usize = null,
    max_document_count: ?usize = null,
};

/// Checks event-stream limits before the composer allocates representation nodes.
pub fn checkEvents(events: []const Event, options: Options, load_failure: ?*LoadFailure) Error!void {
    if (options.max_document_count) |limit| {
        if (countEvents(events, .document_start) > limit) {
            recordFailure(load_failure, .document_count_limit);
            return ParseError.Unsupported;
        }
    }

    if (options.max_alias_count) |limit| {
        if (countEvents(events, .alias) > limit) {
            recordFailure(load_failure, .alias_count_limit);
            return ParseError.Unsupported;
        }
    }
}

fn countEvents(events: []const Event, comptime tag: std.meta.Tag(Event)) usize {
    var count: usize = 0;
    for (events) |yaml_event| {
        if (yaml_event == tag) count += 1;
    }
    return count;
}

fn recordFailure(load_failure: ?*LoadFailure, failure_value: LoadFailure) void {
    if (load_failure) |target| {
        if (target.* == .unknown) target.* = failure_value;
    }
}

test "loader limit: rejects streams over document count limit" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "one" } },
        .{ .document_end = .{} },
        .{ .document_start = .{} },
        .{ .scalar = .{ .value = "two" } },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_document_count = 1 }, &load_failure));
    try std.testing.expectEqual(LoadFailure.document_count_limit, load_failure);
}

test "loader limit: rejects streams over alias count limit" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_alias_count = 0 }, &load_failure));
    try std.testing.expectEqual(LoadFailure.alias_count_limit, load_failure);
}

test "loader limit: accepts counts exactly at configured limits" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };
    var load_failure: LoadFailure = .unknown;

    try checkEvents(&events, .{
        .max_document_count = 1,
        .max_alias_count = 1,
    }, &load_failure);
    try std.testing.expectEqual(LoadFailure.unknown, load_failure);
}

test "loader limit: can reject without recording failure details" {
    const events = [_]Event{
        .stream_start,
        .{ .document_start = .{} },
        .{ .alias = "anchor" },
        .{ .document_end = .{} },
        .stream_end,
    };

    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_document_count = 0 }, null));
    try std.testing.expectError(ParseError.Unsupported, checkEvents(&events, .{ .max_alias_count = 0 }, null));
}
