//! Purpose: Define the public loaded YAML value graph facade.
//! Owns: Node union and stable value-type re-exports.
//! Does not own: Scalar, sequence, mapping payload definitions, document ownership, loading, schema rules, or emitting.
//! Depends on: common/style.zig and focused value payload modules.
//! Tested by: loader, public API, conformance, stress, and emitter tests.

const std = @import("std");
const document = @import("document.zig");
const mapping = @import("mapping.zig");
const scalar = @import("scalar.zig");
const sequence = @import("sequence.zig");
const style = @import("../common/style.zig");
const stream = @import("stream.zig");

pub const CollectionStyle = style.CollectionStyle;
pub const ScalarStyle = scalar.ScalarStyle;
pub const ScalarNode = scalar.ScalarNode;
pub const NullNode = scalar.NullNode;
pub const BoolNode = scalar.BoolNode;
pub const IntNode = scalar.IntNode;
pub const FloatNode = scalar.FloatNode;
pub const MappingPair = mapping.MappingPair;
pub const SequenceNode = sequence.SequenceNode;
pub const MappingNode = mapping.MappingNode;
pub const LoadedDocument = document.LoadedDocument;
pub const LoadedStream = stream.LoadedStream;

/// Loaded YAML node.
///
/// Nodes are owned by a `LoadedDocument` or `LoadedStream` arena. Aliases are
/// resolved to anchored nodes while loading when possible; constructed alias
/// nodes can still be dumped.
pub const Node = union(enum) {
    /// YAML null value after schema resolution.
    null_value: NullNode,
    /// YAML boolean value after schema resolution.
    bool_value: BoolNode,
    /// YAML integer value after schema resolution.
    int_value: IntNode,
    /// YAML floating-point value after schema resolution.
    float_value: FloatNode,
    /// String scalar node.
    scalar: ScalarNode,
    /// Sequence node.
    sequence: SequenceNode,
    /// Mapping node.
    mapping: MappingNode,
    /// Constructed alias node naming an anchor.
    alias: []const u8,
};

test {
    std.testing.refAllDecls(@This());
}
