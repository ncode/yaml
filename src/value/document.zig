//! Purpose: Define the public owning container for a single loaded YAML document.
//! Owns: Arena-backed LoadedDocument deinitialization contract.
//! Does not own: Stream ownership, node payload definitions, or loader construction logic.
//! Depends on: value/deinit.zig and value/value.zig.
//! Tested by: public API, conformance, stress, and allocation tests.

const std = @import("std");
const ownership = @import("deinit.zig");
const value = @import("value.zig");

pub const LoadedDocument = struct {
    /// Arena owning `root` and all loaded node data.
    arena: std.heap.ArenaAllocator,
    /// Root node of the single loaded document.
    root: *const value.Node,

    /// Releases all node data owned by this document.
    pub fn deinit(self: *LoadedDocument) void {
        ownership.releaseArena(&self.arena);
        self.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
