//! Purpose: Aggregate focused public root API unit-test shards.
//! Owns: Importing root API regression modules into the build step.
//! Does not own: Individual public API behavior assertions.
//! Depends on: tests/unit/api/*_test.zig.
//! Tested by: zig build test-unit.

comptime {
    _ = @import("parse_test.zig");
    _ = @import("load_test.zig");
    _ = @import("load_memory_test.zig");
    _ = @import("tags_test.zig");
    _ = @import("emit_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("limits_test.zig");
    _ = @import("dump_test.zig");
    _ = @import("typed_test.zig");
}
