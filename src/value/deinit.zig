//! Purpose: Centralize loaded-value arena release helpers.
//! Owns: Shared deinitialization primitives for public value ownership containers.
//! Does not own: Node payload definitions, document/stream APIs, or loader allocation.
//! Depends on: std heap arena allocator.
//! Tested by: public API, conformance, stress, allocation, and structure tests.

const std = @import("std");

/// Releases a loaded YAML arena.
pub fn releaseArena(arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
