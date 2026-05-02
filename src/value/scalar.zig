//! Purpose: Define public loaded YAML scalar payload types.
//! Owns: String and schema-resolved scalar node payload structs.
//! Does not own: Collection nodes, node union dispatch, document ownership, or loading.
//! Depends on: common/style.zig.
//! Tested by: loader, public API, conformance, stress, and emitter tests.

const std = @import("std");
const style = @import("../common/style.zig");

pub const ScalarStyle = style.ScalarStyle;

/// String scalar node in a loaded YAML representation graph.
pub const ScalarNode = struct {
    /// Decoded scalar value.
    value: []const u8,
    /// Source presentation style.
    style: ScalarStyle = .plain,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const NullNode = struct {
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const BoolNode = struct {
    /// Resolved boolean value.
    value: bool,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const IntNode = struct {
    /// Resolved integer value.
    value: i128,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

pub const FloatNode = struct {
    /// Resolved floating point value.
    value: f64,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

test {
    std.testing.refAllDecls(@This());
}
