//! Purpose: Emit block-style YAML collections from parser events.
//! Owns: Block sequence layout, block mapping layout, compact mapping entries, and mapping value layout.
//! Does not own: Document framing, flow collection layout, scalar escaping, or public emitter API.
//! Depends on: common/diagnostic.zig, emitter.zig, flow.zig, parser/event.zig, scalar.zig.
//! Tested by: tests/unit/api/root_api_test.zig and conformance emitter tests.

const std = @import("std");
const common = @import("../common/diagnostic.zig");
const event_types = @import("../parser/event.zig");
const flow = @import("flow.zig");
const scalar_emit = @import("scalar.zig");
const State = @import("emitter.zig").State;

const CollectionStart = event_types.CollectionStart;
const Error = common.Error;
const ParseError = common.ParseError;
const Scalar = event_types.Scalar;

const appendEmittedAlias = scalar_emit.appendEmittedAlias;
const appendEmittedCollectionProperties = scalar_emit.appendEmittedCollectionProperties;
const appendEmittedMappingKey = scalar_emit.appendEmittedMappingKey;
const appendEmittedScalarNodeIndented = scalar_emit.appendEmittedScalarNodeIndented;
const appendEmittedScalarProperties = scalar_emit.appendEmittedScalarProperties;
const collectionHasProperties = scalar_emit.collectionHasProperties;
const isNonEmptyInlineScalar = scalar_emit.isNonEmptyInlineScalar;
const isPlainEmptyScalar = scalar_emit.isPlainEmptyScalar;

pub const Indent = struct {
    content: usize,
    indicator: usize,
    plain_continuation: usize = 0,
    quote_block_scalar_whitespace_only_lines: bool = false,
    quote_block_scalar_trailing_space_only_line: bool = false,
    quote_block_scalar_tab_indented_lines: bool = false,
    quote_literal_tab_started_lines: bool = false,
    quote_plain_multiline: bool = true,
    indent_indicator_for_newline_only: bool = false,
};

pub const MappingValueLayout = enum {
    after_scalar_key,
    after_explicit_key,
};

pub fn appendIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: usize) std.mem.Allocator.Error!void {
    var count = indent;
    while (count > 0) : (count -= 1) {
        try out.append(allocator, ' ');
    }
}

pub fn emitBlockSequence(self: *State, out: *std.ArrayList(u8)) Error!void {
    try emitBlockSequenceIndented(self, out, 0, null);
}

pub fn emitBlockSequenceIndented(
    self: *State,
    out: *std.ArrayList(u8),
    indent: usize,
    first_prefix: ?[]const u8,
) Error!void {
    try self.enterEmitCollection();
    defer self.leaveEmitCollection();

    var first_item = true;
    while (self.index < self.events.len and self.events[self.index] != .sequence_end) {
        if (first_item) {
            if (first_prefix) |prefix| {
                try out.appendSlice(self.allocator, prefix);
            } else {
                try appendIndent(self.allocator, out, indent);
            }
            first_item = false;
        } else {
            try out.append(self.allocator, '\n');
            try appendIndent(self.allocator, out, indent);
        }

        if (self.index >= self.events.len) return ParseError.InvalidSyntax;
        switch (self.events[self.index]) {
            .scalar => |item| {
                self.index += 1;

                if (isPlainEmptyScalar(item)) {
                    try out.append(self.allocator, '-');
                    if (item.anchor != null or item.tag != null) {
                        try out.append(self.allocator, ' ');
                        _ = try appendEmittedScalarProperties(self.allocator, out, item);
                    }
                } else {
                    try out.appendSlice(self.allocator, "- ");
                    try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedScalar(item), .{
                        .content = indent + 2,
                        .indicator = 2,
                        .plain_continuation = indent + 2,
                        .quote_block_scalar_tab_indented_lines = !self.preserve_collection_style,
                    });
                }
            },
            .alias => |alias| {
                self.index += 1;
                try out.appendSlice(self.allocator, "- ");
                try appendEmittedAlias(self.allocator, out, alias);
            },
            .mapping_start => |collection| {
                self.index += 1;
                if (try flow.emitEmptyMappingIfPresent(self, out, collection, "- ")) {
                    // Empty block mappings are emitted using flow shorthand.
                } else if (collectionHasProperties(collection)) {
                    switch (self.emittedCollectionStyle(collection.style)) {
                        .block => {
                            try out.appendSlice(self.allocator, "- ");
                            _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                            try out.append(self.allocator, '\n');
                            try emitBlockMappingIndented(self, out, indent + 2);
                        },
                        .flow => {
                            try out.appendSlice(self.allocator, "- ");
                            _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                            try out.append(self.allocator, ' ');
                            try flow.emitFlowMapping(self, out);
                        },
                    }
                } else {
                    switch (self.emittedCollectionStyle(collection.style)) {
                        .block => try emitCompactBlockMappingSequenceItem(self, out, indent),
                        .flow => {
                            if (self.preserve_block_sequence_flow_mapping_style) {
                                try out.appendSlice(self.allocator, "- ");
                                try flow.emitFlowMapping(self, out);
                            } else {
                                try emitCompactBlockMappingSequenceItem(self, out, indent);
                            }
                        },
                    }
                }
            },
            .sequence_start => |collection| {
                self.index += 1;
                if (try flow.emitEmptySequenceIfPresent(self, out, collection, "- ")) {
                    // Empty block sequences are emitted using flow shorthand.
                } else switch (self.emittedCollectionStyle(collection.style)) {
                    .block => {
                        if (collectionHasProperties(collection)) {
                            try out.appendSlice(self.allocator, "- ");
                            _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                            try out.append(self.allocator, '\n');
                            try emitBlockSequenceIndented(self, out, indent + 2, null);
                        } else {
                            try emitBlockSequenceIndented(self, out, indent + 2, "- ");
                        }
                    },
                    .flow => {
                        try out.appendSlice(self.allocator, "- ");
                        if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                            try out.append(self.allocator, ' ');
                        }
                        try flow.emitFlowSequence(self, out);
                    },
                }
            },
            else => return ParseError.Unsupported,
        }
    }

    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    if (first_item) return ParseError.Unsupported;
    self.index += 1;
}

pub fn emitBlockMapping(self: *State, out: *std.ArrayList(u8)) Error!void {
    try emitBlockMappingIndented(self, out, 0);
}

pub fn emitBlockMappingIndented(self: *State, out: *std.ArrayList(u8), indent: usize) Error!void {
    try emitBlockMappingEntries(self, out, indent, null, false);
}

fn emitCompactBlockMappingSequenceItem(self: *State, out: *std.ArrayList(u8), indent: usize) Error!void {
    try emitBlockMappingEntries(self, out, indent + 2, "- ", !self.preserve_collection_style);
}

pub fn emitBlockMappingEntries(
    self: *State,
    out: *std.ArrayList(u8),
    indent: usize,
    first_prefix: ?[]const u8,
    canonicalize_quoted_keys: bool,
) Error!void {
    try self.enterEmitCollection();
    defer self.leaveEmitCollection();

    var first_pair = true;
    while (self.index < self.events.len and self.events[self.index] != .mapping_end) {
        if (first_pair) {
            if (first_prefix) |prefix| {
                try out.appendSlice(self.allocator, prefix);
            } else {
                try appendIndent(self.allocator, out, indent);
            }
            first_pair = false;
        } else {
            try out.append(self.allocator, '\n');
            try appendIndent(self.allocator, out, indent);
        }

        if (self.index >= self.events.len) return ParseError.InvalidSyntax;
        switch (self.events[self.index]) {
            .scalar => |key| {
                self.index += 1;
                switch (key.style) {
                    .plain, .single_quoted, .double_quoted => {
                        if (std.mem.indexOfScalar(u8, key.value, '\n') != null) {
                            try out.appendSlice(self.allocator, "? ");
                            try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedScalar(key), .{
                                .content = indent + 2,
                                .indicator = 2,
                            });
                            try emitBlockMappingValue(self, out, indent, .after_explicit_key);
                        } else {
                            const emitted_key = self.emittedScalar(if (canonicalize_quoted_keys) self.emittedMappingKeyScalar(key) else key);
                            try appendEmittedMappingKey(self.allocator, out, emitted_key);
                            try emitBlockMappingValue(self, out, indent, .after_scalar_key);
                        }
                    },
                    .literal, .folded => {
                        try out.appendSlice(self.allocator, "? ");
                        try appendEmittedScalarNodeIndented(self.allocator, out, key, .{
                            .content = indent + 2,
                            .indicator = 2,
                        });
                        try emitBlockMappingValue(self, out, indent, .after_explicit_key);
                    },
                }
            },
            .alias => |alias| {
                self.index += 1;
                try appendEmittedAlias(self.allocator, out, alias);
                try out.append(self.allocator, ' ');
                try emitBlockMappingValue(self, out, indent, .after_scalar_key);
            },
            .sequence_start => |collection| {
                self.index += 1;
                if (!(try flow.emitEmptySequenceIfPresent(self, out, collection, "? "))) {
                    switch (self.emittedCollectionStyle(collection.style)) {
                        .block => {
                            if (collectionHasProperties(collection)) {
                                try out.appendSlice(self.allocator, "? ");
                                _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                                try out.append(self.allocator, '\n');
                                const sequence_indent = if (self.preserve_collection_style) indent + 2 else indent;
                                try emitBlockSequenceIndented(self, out, sequence_indent, null);
                            } else {
                                try emitBlockSequenceIndented(self, out, indent + 2, "? ");
                            }
                        },
                        .flow => {
                            try out.appendSlice(self.allocator, "? ");
                            if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                                try out.append(self.allocator, ' ');
                            }
                            try flow.emitFlowSequence(self, out);
                        },
                    }
                }
                try emitBlockMappingValue(self, out, indent, .after_explicit_key);
            },
            .mapping_start => |collection| {
                self.index += 1;
                if (!(try flow.emitEmptyMappingIfPresent(self, out, collection, "? "))) {
                    switch (self.emittedCollectionStyle(collection.style)) {
                        .block => {
                            if (collectionHasProperties(collection)) {
                                try out.appendSlice(self.allocator, "? ");
                                _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                                try out.append(self.allocator, '\n');
                                try emitBlockMappingIndented(self, out, indent + 2);
                            } else if (try emitCompactEmptySequenceMappingKey(self, out)) {
                                // The compact key was emitted on this line.
                            } else {
                                try emitBlockMappingEntries(self, out, indent + 2, "? ", false);
                            }
                        },
                        .flow => {
                            try out.appendSlice(self.allocator, "? ");
                            if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                                try out.append(self.allocator, ' ');
                            }
                            try flow.emitFlowMapping(self, out);
                        },
                    }
                }
                try emitBlockMappingValue(self, out, indent, .after_explicit_key);
            },
            else => return ParseError.Unsupported,
        }
    }

    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    self.index += 1;
}

fn emitCompactEmptySequenceMappingKey(self: *State, out: *std.ArrayList(u8)) Error!bool {
    if (self.index + 3 >= self.events.len) return false;
    if (self.events[self.index] != .sequence_start) return false;
    const sequence = self.events[self.index].sequence_start;
    if (collectionHasProperties(sequence)) return false;
    if (self.events[self.index + 1] != .sequence_end) return false;
    if (self.events[self.index + 2] != .scalar) return false;
    const value = self.events[self.index + 2].scalar;
    if (!isNonEmptyInlineScalar(value)) return false;
    if (self.events[self.index + 3] != .mapping_end) return false;

    try out.appendSlice(self.allocator, "? []: ");
    try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedScalar(value), .{
        .content = 2,
        .indicator = 2,
    });
    self.index += 4;
    return true;
}

pub fn emitBlockMappingValue(
    self: *State,
    out: *std.ArrayList(u8),
    indent: usize,
    layout: MappingValueLayout,
) Error!void {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;

    switch (self.events[self.index]) {
        .scalar => |value| {
            self.index += 1;
            if (layout == .after_explicit_key) {
                try out.append(self.allocator, '\n');
                try appendIndent(self.allocator, out, indent);
            }
            try out.append(self.allocator, ':');
            if (isPlainEmptyScalar(value)) {
                if (value.anchor != null or value.tag != null) {
                    try out.append(self.allocator, ' ');
                    _ = try appendEmittedScalarProperties(self.allocator, out, value);
                }
            } else {
                try out.append(self.allocator, ' ');
                try appendEmittedScalarNodeIndented(self.allocator, out, self.emittedScalar(value), .{
                    .content = indent + 2,
                    .indicator = 2,
                    .plain_continuation = indent + 2,
                    .quote_block_scalar_whitespace_only_lines = !self.preserve_collection_style,
                    .quote_block_scalar_trailing_space_only_line = self.preserve_collection_style,
                    .quote_block_scalar_tab_indented_lines = !self.preserve_collection_style,
                    .indent_indicator_for_newline_only = true,
                });
            }
        },
        .sequence_start => |collection| {
            self.index += 1;
            if (try emitEmptySequenceMappingValue(self, out, collection, indent, layout)) return;
            switch (self.emittedCollectionStyle(collection.style)) {
                .block => {
                    if (collectionHasProperties(collection)) {
                        try emitMappingValueIndicator(self, out, indent, layout);
                        try out.append(self.allocator, ' ');
                        _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                        try out.append(self.allocator, '\n');
                        const sequence_indent = if (self.preserve_collection_style) indent + 2 else indent;
                        try emitBlockSequenceIndented(self, out, sequence_indent, null);
                    } else switch (layout) {
                        .after_scalar_key => {
                            try out.append(self.allocator, ':');
                            try out.append(self.allocator, '\n');
                            try emitBlockSequenceIndented(self, out, indent, null);
                        },
                        .after_explicit_key => {
                            try out.append(self.allocator, '\n');
                            try appendIndent(self.allocator, out, indent);
                            try emitBlockSequenceIndented(self, out, indent + 2, ": ");
                        },
                    }
                },
                .flow => {
                    try emitMappingValueIndicator(self, out, indent, layout);
                    try out.append(self.allocator, ' ');
                    if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
                        try out.append(self.allocator, ' ');
                    }
                    try flow.emitFlowSequence(self, out);
                },
            }
        },
        .mapping_start => |collection| {
            self.index += 1;
            if (try emitEmptyMappingValue(self, out, collection, indent, layout)) return;
            if (collectionHasProperties(collection)) {
                switch (self.emittedCollectionStyle(collection.style)) {
                    .block => {
                        try emitMappingValueIndicator(self, out, indent, layout);
                        try out.append(self.allocator, ' ');
                        _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                        try out.append(self.allocator, '\n');
                        try emitBlockMappingIndented(self, out, indent + 2);
                    },
                    .flow => {
                        try emitMappingValueIndicator(self, out, indent, layout);
                        try out.append(self.allocator, ' ');
                        _ = try appendEmittedCollectionProperties(self.allocator, out, collection);
                        try out.append(self.allocator, ' ');
                        try flow.emitFlowMapping(self, out);
                    },
                }
            } else {
                switch (layout) {
                    .after_scalar_key => {
                        try out.append(self.allocator, ':');
                        try out.append(self.allocator, '\n');
                        try emitBlockMappingIndented(self, out, indent + 2);
                    },
                    .after_explicit_key => {
                        try out.append(self.allocator, '\n');
                        try appendIndent(self.allocator, out, indent);
                        try emitBlockMappingEntries(self, out, indent + 2, ": ", false);
                    },
                }
            }
        },
        .alias => |alias| {
            self.index += 1;
            if (layout == .after_explicit_key) {
                try out.append(self.allocator, '\n');
                try appendIndent(self.allocator, out, indent);
            }
            try out.appendSlice(self.allocator, ": ");
            try appendEmittedAlias(self.allocator, out, alias);
        },
        else => return ParseError.Unsupported,
    }
}

fn emitMappingValueIndicator(
    self: *State,
    out: *std.ArrayList(u8),
    indent: usize,
    layout: MappingValueLayout,
) std.mem.Allocator.Error!void {
    if (layout == .after_explicit_key) {
        try out.append(self.allocator, '\n');
        try appendIndent(self.allocator, out, indent);
    }
    try out.append(self.allocator, ':');
}

test "emitter block value: sequence properties preserve nested indent" {
    const events = [_]event_types.Event{
        .{ .sequence_start = .{ .style = .block, .anchor = "items" } },
        .{ .scalar = .{ .value = "one" } },
        .sequence_end,
    };
    var state = State{
        .allocator = std.testing.allocator,
        .events = &events,
        .preserve_collection_style = true,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try emitBlockMappingValue(&state, &out, 0, .after_scalar_key);

    try std.testing.expectEqualStrings(
        \\: &items
        \\  - one
    , out.items);
}

fn emitEmptySequenceMappingValue(
    self: *State,
    out: *std.ArrayList(u8),
    collection: CollectionStart,
    indent: usize,
    layout: MappingValueLayout,
) Error!bool {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    if (self.events[self.index] != .sequence_end) return false;

    try emitMappingValueIndicator(self, out, indent, layout);
    try out.append(self.allocator, ' ');
    if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
        try out.append(self.allocator, ' ');
    }
    try out.appendSlice(self.allocator, "[]");
    self.index += 1;
    return true;
}

fn emitEmptyMappingValue(
    self: *State,
    out: *std.ArrayList(u8),
    collection: CollectionStart,
    indent: usize,
    layout: MappingValueLayout,
) Error!bool {
    if (self.index >= self.events.len) return ParseError.InvalidSyntax;
    if (self.events[self.index] != .mapping_end) return false;

    try emitMappingValueIndicator(self, out, indent, layout);
    try out.append(self.allocator, ' ');
    if (try appendEmittedCollectionProperties(self.allocator, out, collection)) {
        try out.append(self.allocator, ' ');
    }
    try out.appendSlice(self.allocator, "{}");
    self.index += 1;
    return true;
}

pub fn scalarUsesQuotedBlockFallback(scalar: Scalar) bool {
    return switch (scalar.style) {
        .literal, .folded => blockScalarEndsWithWhitespaceOnlyContentLine(scalar.value),
        .plain, .single_quoted, .double_quoted => false,
    };
}

pub fn scalarShouldUseQuotedBlockFallback(scalar: Scalar, options: Indent) bool {
    if (scalar.value.len == 0) return true;
    if (options.quote_block_scalar_whitespace_only_lines and scalarUsesQuotedBlockFallback(scalar)) return true;
    if (options.quote_block_scalar_trailing_space_only_line and
        blockScalarHasTrailingSpaceOnlyContentLine(scalar.value)) return true;
    if (options.quote_block_scalar_tab_indented_lines and
        (blockScalarHasLeadingTabIndentedLine(scalar.value) or
            (scalar.style == .folded and blockScalarHasTabStartedLine(scalar.value)))) return true;
    if (options.quote_literal_tab_started_lines and scalar.style == .literal and
        blockScalarHasTabStartedLine(scalar.value)) return true;
    return false;
}

pub fn blockScalarEndsWithWhitespaceOnlyContentLine(value: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];
        if (line.len != 0 and std.mem.trim(u8, line, " \t").len == 0 and
            std.mem.indexOfScalar(u8, line, ' ') != null) return true;

        if (line_end == value.len) break;
        line_start = line_end + 1;
    }

    return false;
}

pub fn blockScalarHasTrailingSpaceOnlyContentLine(value: []const u8) bool {
    if (value.len == 0) return false;

    const content_end = if (value[value.len - 1] == '\n') value.len - 1 else value.len;
    if (content_end == 0) return false;

    const line_start = if (std.mem.lastIndexOfScalar(u8, value[0..content_end], '\n')) |newline|
        newline + 1
    else
        0;
    const line = value[line_start..content_end];
    return line.len != 0 and std.mem.trim(u8, line, " \t").len == 0 and
        std.mem.indexOfScalar(u8, line, ' ') != null;
}

pub fn blockScalarHasLeadingTabIndentedLine(value: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];

        var saw_space = false;
        for (line) |byte| {
            switch (byte) {
                '\t' => return saw_space,
                ' ' => saw_space = true,
                else => break,
            }
        }

        if (line_end == value.len) break;
        line_start = line_end + 1;
    }

    return false;
}

pub fn blockScalarUsesKeepChomping(value: []const u8) bool {
    if (value.len == 0 or value[value.len - 1] != '\n') return false;
    return value.len == 1 or value[value.len - 2] == '\n';
}

pub fn blockScalarHasTabStartedLine(value: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];
        if (line.len != 0 and line[0] == '\t') return true;

        if (line_end == value.len) break;
        line_start = line_end + 1;
    }

    return false;
}

pub fn appendLiteral(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    indent: Indent,
) Error!void {
    try appendBlockScalar(allocator, out, '|', value, indent);
}

pub fn appendFolded(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    indent: Indent,
) Error!void {
    try out.append(allocator, '>');
    if (value.len == 0) return;
    if (blockScalarNeedsIndentIndicatorWithOptions(value, indent)) {
        if (indent.indicator == 0 or indent.indicator > 9) return ParseError.Unsupported;
        const digit: u8 = @intCast(indent.indicator);
        try out.append(allocator, '0' + digit);
    }
    if (value[value.len - 1] != '\n') {
        try out.append(allocator, '-');
    } else if (blockScalarUsesKeepChomping(value)) {
        try out.append(allocator, '+');
    }

    try out.append(allocator, '\n');

    var line_start: usize = 0;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];

        if (line.len != 0) {
            try appendIndent(allocator, out, indent.content);
            try out.appendSlice(allocator, line);
        }

        if (line_end == value.len) break;

        var newline_end = line_end;
        while (newline_end < value.len and value[newline_end] == '\n') : (newline_end += 1) {}

        const newline_count = newline_end - line_end;
        const output_newline_count = if (newline_end == value.len) newline_count - 1 else blk: {
            const next_line_end = std.mem.indexOfScalarPos(u8, value, newline_end, '\n') orelse value.len;
            const next_line = value[newline_end..next_line_end];
            break :blk if (line.len == 0 or lineStartsWhitespace(line) or lineStartsWhitespace(next_line)) newline_count else newline_count + 1;
        };
        for (0..output_newline_count) |_| try out.append(allocator, '\n');

        line_start = newline_end;
    }
}

fn appendBlockScalar(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indicator: u8,
    value: []const u8,
    indent: Indent,
) Error!void {
    try out.append(allocator, indicator);
    if (value.len == 0) return;
    if (blockScalarNeedsIndentIndicatorWithOptions(value, indent)) {
        if (indent.indicator == 0 or indent.indicator > 9) return ParseError.Unsupported;
        const digit: u8 = @intCast(indent.indicator);
        try out.append(allocator, '0' + digit);
    }
    if (value[value.len - 1] != '\n') {
        try out.append(allocator, '-');
    } else if (blockScalarUsesKeepChomping(value)) {
        try out.append(allocator, '+');
    }

    try out.append(allocator, '\n');

    var line_start: usize = 0;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];

        if (line.len != 0) {
            try appendIndent(allocator, out, indent.content);
            try out.appendSlice(allocator, line);
        }

        if (line_end == value.len) break;
        line_start = line_end + 1;
        if (line_start < value.len) try out.append(allocator, '\n');
    }
}

fn blockScalarNeedsIndentIndicator(value: []const u8) bool {
    var line_start: usize = 0;
    var saw_leading_empty_line = false;
    while (line_start < value.len) {
        const line_end = std.mem.indexOfScalarPos(u8, value, line_start, '\n') orelse value.len;
        const line = value[line_start..line_end];
        if (line.len != 0) {
            return line[0] == ' ' or (saw_leading_empty_line and line[0] == '#');
        }
        saw_leading_empty_line = true;
        if (line_end == value.len) return false;
        line_start = line_end + 1;
    }
    return false;
}

fn blockScalarNeedsIndentIndicatorWithOptions(value: []const u8, indent: Indent) bool {
    return blockScalarNeedsIndentIndicator(value) or
        (indent.indent_indicator_for_newline_only and isAllNewlines(value));
}

fn lineStartsWhitespace(line: []const u8) bool {
    return line.len != 0 and (line[0] == ' ' or line[0] == '\t');
}

fn isAllNewlines(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte != '\n') return false;
    }
    return true;
}

test appendIndent {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendIndent(std.testing.allocator, &out, 0);
    try std.testing.expectEqualStrings("", out.items);

    try appendIndent(std.testing.allocator, &out, 3);
    try std.testing.expectEqualStrings("   ", out.items);
}

test "emitter: block scalar fallback predicates cover whitespace-only lines" {
    try std.testing.expect(!blockScalarEndsWithWhitespaceOnlyContentLine("plain\ntext"));
    try std.testing.expect(blockScalarEndsWithWhitespaceOnlyContentLine("plain\n  \n"));
    try std.testing.expect(!blockScalarHasTrailingSpaceOnlyContentLine("plain\n\t"));
    try std.testing.expect(blockScalarHasTrailingSpaceOnlyContentLine("plain\n  "));

    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = "",
        .style = .literal,
    }, .{ .content = 2, .indicator = 2 }));
    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = "plain\n  \n",
        .style = .literal,
    }, .{ .content = 2, .indicator = 2, .quote_block_scalar_whitespace_only_lines = true }));
    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = "plain\n  ",
        .style = .folded,
    }, .{ .content = 2, .indicator = 2, .quote_block_scalar_trailing_space_only_line = true }));
}

test "emitter: block scalar fallback predicates cover tab-indented lines" {
    try std.testing.expect(!blockScalarHasLeadingTabIndentedLine("\tstarted"));
    try std.testing.expect(blockScalarHasLeadingTabIndentedLine(" \tindented"));
    try std.testing.expect(blockScalarHasTabStartedLine("plain\n\tstarted"));

    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = " \tindented",
        .style = .literal,
    }, .{ .content = 2, .indicator = 2, .quote_block_scalar_tab_indented_lines = true }));
    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = "plain\n\tstarted",
        .style = .folded,
    }, .{ .content = 2, .indicator = 2, .quote_block_scalar_tab_indented_lines = true }));
    try std.testing.expect(scalarShouldUseQuotedBlockFallback(.{
        .value = "\tstarted",
        .style = .literal,
    }, .{ .content = 2, .indicator = 2, .quote_literal_tab_started_lines = true }));
}

test "emitter: block scalar chomping and indent indicator edge predicates" {
    try std.testing.expect(!blockScalarUsesKeepChomping("plain"));
    try std.testing.expect(blockScalarUsesKeepChomping("\n"));
    try std.testing.expect(!blockScalarUsesKeepChomping("plain\n"));
    try std.testing.expect(blockScalarUsesKeepChomping("plain\n\n"));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendLiteral(std.testing.allocator, &out, "\n", .{
        .content = 2,
        .indent_indicator_for_newline_only = true,
        .indicator = 2,
    });
    try std.testing.expectEqualStrings("|2+\n", out.items);

    out.clearRetainingCapacity();
    try appendFolded(std.testing.allocator, &out, " leading\n", .{
        .content = 2,
        .indicator = 2,
    });
    try std.testing.expectEqualStrings(">2\n   leading", out.items);
}

test "emitter: block scalar rejects unsupported indent indicator" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try std.testing.expectError(ParseError.Unsupported, appendFolded(std.testing.allocator, &out, " leading", .{ .content = 2, .indicator = 0 }));
    out.clearRetainingCapacity();
    try std.testing.expectError(ParseError.Unsupported, appendLiteral(std.testing.allocator, &out, " leading", .{ .content = 2, .indicator = 10 }));
}
