//! Purpose: Define public loaded YAML mapping payload types.
//! Owns: Mapping pair and mapping node payload fields plus collection presentation metadata.
//! Does not own: Node union dispatch, sequence payloads, document ownership, or loading.
//! Depends on: common/style.zig and value/value.zig for node references.
//! Tested by: loader, public API, conformance, stress, and emitter tests.

const std = @import("std");
const style = @import("../common/style.zig");
const value = @import("value.zig");

pub const CollectionStyle = style.CollectionStyle;

/// Key/value pair in a loaded mapping node.
pub const MappingPair = struct {
    /// Mapping key node.
    key: *const value.Node,
    /// Mapping value node.
    value: *const value.Node,
};

/// Mapping node in a loaded YAML representation graph.
pub const MappingNode = struct {
    /// Mapping pairs, in source order.
    pairs: []const MappingPair,
    /// Source presentation style.
    style: CollectionStyle = .block,
    /// Optional anchor name without the leading `&`.
    anchor: ?[]const u8 = null,
    /// Optional resolved tag URI or local tag spelling.
    tag: ?[]const u8 = null,
};

test {
    std.testing.refAllDecls(@This());
}
