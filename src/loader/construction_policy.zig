//! Purpose: Centralize loader construction semantics shared by construction adapters.
//! Owns: Schema scalar resolution, standard scalar tag validation, unknown-tag policy, and failure classification for tag/scalar construction.
//! Does not own: Event traversal, graph traversal, duplicate-key comparison, collection allocation, alias identity, or public diagnostics.
//! Depends on: common/diagnostic.zig, loader/failure.zig, loader/options.zig, schema/schema.zig, schema/tag.zig, and value/value.zig.
//! Tested by: tests/structure/api_boundary_test.zig and focused loader parity tests.

const std = @import("std");
const duplicate_key = @import("duplicate_key.zig");
const diagnostic = @import("../common/diagnostic.zig");
const failure = @import("failure.zig");
const graph = @import("../compose/graph.zig");
const options = @import("options.zig");
const schema = @import("../schema/schema.zig");
const tag = @import("../schema/tag.zig");
const value_model = @import("../value/value.zig");

const Error = diagnostic.Error;
const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const LoadFailure = failure.LoadFailure;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const ParseError = diagnostic.ParseError;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;

pub const ScalarInput = struct {
    value: []const u8,
    is_plain: bool,
    tag: ?[]const u8,
};

pub const Policy = struct {
    schema: Schema,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure = null,

    pub inline fn validateTag(self: Policy, node_tag: ?[]const u8, kind: tag.NodeKind) Error!void {
        tag.validateStandardTagKind(node_tag, kind) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        if (self.unknown_tag_behavior == .reject and tag.isUnknownTag(node_tag)) {
            self.recordFailure(.unknown_tag);
            return ParseError.InvalidSyntax;
        }
    }

    pub inline fn validateAndResolveScalar(self: Policy, scalar: ScalarInput) Error!?schema.ResolvedScalar {
        try self.validateTag(scalar.tag, .scalar);
        tag.validateStandardBinaryContent(scalar.tag, scalar.value) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };
        tag.validateStandardTimestampContent(scalar.tag, scalar.value) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        return schema.resolveScalar(
            self.schema,
            scalar.value,
            scalar.is_plain,
            scalar.tag,
        ) catch |err| {
            self.recordFailure(.invalid_scalar_tag);
            return err;
        };
    }

    pub inline fn validateGraphSequence(self: Policy, sequence: graph.SequenceNode) Error!void {
        if (!tag.isStandardOmapTag(sequence.tag) and !tag.isStandardPairsTag(sequence.tag)) return;

        for (sequence.items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    pub inline fn validateGraphMapping(self: Policy, mapping: graph.MappingNode) Error!void {
        if (!tag.isStandardSetTag(mapping.tag)) return;

        for (mapping.pairs) |pair| {
            if (!isGraphSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    pub inline fn validateConstructedSequence(self: Policy, items: []const *const Node, node_tag: ?[]const u8) Error!void {
        if (tag.isStandardOmapTag(node_tag)) {
            duplicate_key.validateUniqueOrderedMapKeys(items) catch |err| {
                self.recordFailure(.invalid_standard_tag);
                return err;
            };
        } else if (tag.isStandardPairsTag(node_tag)) {
            try self.validateStandardSequenceItems(items);
        }
    }

    pub inline fn validateConstructedMapping(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        node_tag: ?[]const u8,
        duplicate_key_behavior: DuplicateKeyBehavior,
    ) Error!void {
        if (tag.isStandardSetTag(node_tag)) {
            try self.validateStandardSetPairs(pairs);
            try self.validateUniqueMappingKeys(temporary_allocator, pairs, .invalid_standard_tag);
        } else if (duplicate_key_behavior == .reject) {
            try self.validateUniqueMappingKeys(temporary_allocator, pairs, .duplicate_key);
        }
    }

    pub inline fn validateDuplicateMappingKeys(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        duplicate_key_behavior: DuplicateKeyBehavior,
    ) Error!void {
        if (duplicate_key_behavior == .allow) return;
        try self.validateUniqueMappingKeys(temporary_allocator, pairs, .duplicate_key);
    }

    inline fn recordFailure(self: Policy, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }

    inline fn validateUniqueMappingKeys(
        self: Policy,
        temporary_allocator: std.mem.Allocator,
        pairs: []const MappingPair,
        load_failure: LoadFailure,
    ) Error!void {
        duplicate_key.validateUniqueMappingKeys(temporary_allocator, pairs) catch |err| {
            self.recordFailure(load_failure);
            return err;
        };
    }

    inline fn validateStandardSequenceItems(self: Policy, items: []const *const Node) Error!void {
        for (items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    inline fn validateStandardSetPairs(self: Policy, pairs: []const MappingPair) Error!void {
        for (pairs) |pair| {
            if (!isSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }
};

pub inline fn nodeFromResolvedScalar(resolved: schema.ResolvedScalar, anchor: ?[]const u8, node_tag: ?[]const u8) Node {
    return switch (resolved) {
        .null_value => .{ .null_value = .{
            .anchor = anchor,
            .tag = node_tag,
        } },
        .bool_value => |bool_value| .{ .bool_value = .{
            .value = bool_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
        .int_value => |int_value| .{ .int_value = .{
            .value = int_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
        .float_value => |float_value| .{ .float_value = .{
            .value = float_value,
            .anchor = anchor,
            .tag = node_tag,
        } },
    };
}

inline fn isSetNullValue(node: *const Node) bool {
    return switch (node.*) {
        .null_value => true,
        .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
        else => false,
    };
}

inline fn isGraphSetNullValue(node: *const graph.Node) bool {
    return switch (node.*) {
        .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
