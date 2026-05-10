//! Purpose: Define the public owning container for loaded YAML streams.
//! Owns: Arena-backed LoadedStream deinitialization contract.
//! Does not own: Single-document ownership, node payload definitions, or loader construction logic.
//! Depends on: value/deinit.zig and value/value.zig.
//! Tested by: public API, conformance, stress, and allocation tests.

const std = @import("std");
const ownership = @import("deinit.zig");
const value = @import("value.zig");

pub const LoadedStream = struct {
    /// Arena owning `documents` and all loaded node data.
    arena: std.heap.ArenaAllocator,
    /// Root nodes for all documents in the stream.
    documents: []const *const value.Node,

    /// Releases all node data owned by this stream.
    pub fn deinit(self: *LoadedStream) void {
        ownership.releaseArena(&self.arena);
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
