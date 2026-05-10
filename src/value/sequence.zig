//! Purpose: Define public loaded YAML sequence payload types.
//! Owns: Sequence node payload fields and collection presentation metadata.
//! Does not own: Node union dispatch, mapping pairs, document ownership, or loading.
//! Depends on: common/style.zig and value/value.zig for node references.
//! Tested by: loader, public API, conformance, stress, and emitter tests.

const std = @import("std");
const style = @import("../common/style.zig");
const value = @import("value.zig");

pub const CollectionStyle = style.CollectionStyle;

/// Sequence node in a loaded YAML representation graph.
pub const SequenceNode = struct {
    /// Sequence item nodes, in source order.
    items: []const *const value.Node,
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
