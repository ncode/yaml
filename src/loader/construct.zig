//! Purpose: Construct the public value model from composed representation graph nodes.
//! Owns: Schema scalar construction, value-node allocation, alias identity preservation, and duplicate-key policy.
//! Does not own: Event parsing, event composition, scalar spelling rules, public loading API, or emission.
//! Depends on: common/diagnostic.zig, compose/graph.zig, schema/schema.zig, value/value.zig, loader/options.zig, loader/duplicate_key.zig.
//! Tested by: tests/unit/api/root_api_test.zig, tests/stress/stress.zig, and conformance tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const duplicate_key = @import("duplicate_key.zig");
const failure = @import("failure.zig");
const graph = @import("../compose/graph.zig");
const options = @import("options.zig");
const schema = @import("../schema/schema.zig");
const tag = @import("../schema/tag.zig");
const value_model = @import("../value/value.zig");

const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const Error = diagnostic.Error;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;

pub const LoadFailure = failure.LoadFailure;

/// Constructs public value-model document roots from composed graph roots.
pub fn constructStream(
    allocator: std.mem.Allocator,
    documents: []const *const graph.Node,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
) Error![]const *const Node {
    return constructStreamWithFailure(
        allocator,
        documents,
        selected_schema,
        duplicate_key_behavior,
        unknown_tag_behavior,
        null,
    );
}

/// Constructs public value-model document roots and records load-stage failure
/// categories for diagnostics when construction fails.
pub fn constructStreamWithFailure(
    allocator: std.mem.Allocator,
    documents: []const *const graph.Node,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    var constructor: Constructor = .{
        .allocator = allocator,
        .schema = selected_schema,
        .duplicate_key_behavior = duplicate_key_behavior,
        .unknown_tag_behavior = unknown_tag_behavior,
        .failure = load_failure,
    };
    return constructor.constructStream(documents);
}

const Constructor = struct {
    allocator: std.mem.Allocator,
    schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure = null,
    constructed: std.AutoHashMapUnmanaged(*const graph.Node, *const Node) = .empty,

    fn constructStream(self: *Constructor, documents: []const *const graph.Node) Error![]const *const Node {
        defer self.constructed.deinit(self.allocator);

        var loaded_documents: std.ArrayList(*const Node) = .empty;
        errdefer loaded_documents.deinit(self.allocator);
        try loaded_documents.ensureTotalCapacity(self.allocator, documents.len);

        for (documents) |document| {
            try loaded_documents.append(self.allocator, try self.constructNode(document));
        }

        return loaded_documents.toOwnedSlice(self.allocator);
    }

    fn constructNode(self: *Constructor, graph_node: *const graph.Node) Error!*const Node {
        if (self.constructed.get(graph_node)) |node| return node;

        const node = try self.allocator.create(Node);
        try self.constructed.put(self.allocator, graph_node, node);

        switch (graph_node.*) {
            .scalar => |scalar| {
                try self.validateTag(scalar.tag, .scalar);
                tag.validateStandardBinaryContent(scalar.tag, scalar.value) catch |err| {
                    self.recordFailure(.invalid_standard_tag);
                    return err;
                };
                tag.validateStandardTimestampContent(scalar.tag, scalar.value) catch |err| {
                    self.recordFailure(.invalid_standard_tag);
                    return err;
                };
                node.* = (resolveSchemaScalar(self.allocator, self.schema, scalar) catch |err| {
                    self.recordFailure(.invalid_scalar_tag);
                    return err;
                }) orelse
                    .{ .scalar = .{
                        .value = try self.allocator.dupe(u8, scalar.value),
                        .style = scalar.style,
                        .anchor = try copyOptionalSlice(self.allocator, scalar.anchor),
                        .tag = try copyOptionalSlice(self.allocator, scalar.tag),
                    } };
            },
            .sequence => |sequence| {
                try self.validateTag(sequence.tag, .sequence);
                try self.validateStandardSequenceContent(sequence);

                var items: std.ArrayList(*const Node) = .empty;
                errdefer items.deinit(self.allocator);
                try items.ensureTotalCapacity(self.allocator, sequence.items.len);

                for (sequence.items) |item| {
                    try items.append(self.allocator, try self.constructNode(item));
                }

                const owned_items = try items.toOwnedSlice(self.allocator);
                node.* = .{ .sequence = .{
                    .items = owned_items,
                    .style = sequence.style,
                    .anchor = try copyOptionalSlice(self.allocator, sequence.anchor),
                    .tag = try copyOptionalSlice(self.allocator, sequence.tag),
                } };
                if (tag.isStandardOmapTag(sequence.tag)) {
                    duplicate_key.validateUniqueOrderedMapKeys(owned_items) catch |err| {
                        self.recordFailure(.invalid_standard_tag);
                        return err;
                    };
                }
            },
            .mapping => |mapping| {
                try self.validateTag(mapping.tag, .mapping);
                try self.validateStandardMappingContent(mapping);

                var pairs: std.ArrayList(MappingPair) = .empty;
                errdefer pairs.deinit(self.allocator);
                try pairs.ensureTotalCapacity(self.allocator, mapping.pairs.len);

                for (mapping.pairs) |pair| {
                    try pairs.append(self.allocator, .{
                        .key = try self.constructNode(pair.key),
                        .value = try self.constructNode(pair.value),
                    });
                }

                const owned_pairs = try pairs.toOwnedSlice(self.allocator);
                node.* = .{ .mapping = .{
                    .pairs = owned_pairs,
                    .style = mapping.style,
                    .anchor = try copyOptionalSlice(self.allocator, mapping.anchor),
                    .tag = try copyOptionalSlice(self.allocator, mapping.tag),
                } };
                if (tag.isStandardSetTag(mapping.tag)) {
                    duplicate_key.validateUniqueMappingKeys(self.allocator, owned_pairs) catch |err| {
                        self.recordFailure(.invalid_standard_tag);
                        return err;
                    };
                } else if (self.duplicate_key_behavior == .reject) {
                    duplicate_key.validateUniqueMappingKeys(self.allocator, owned_pairs) catch |err| {
                        self.recordFailure(.duplicate_key);
                        return err;
                    };
                }
            },
        }

        return node;
    }

    fn validateTag(self: *Constructor, node_tag: ?[]const u8, kind: tag.NodeKind) Error!void {
        tag.validateStandardTagKind(node_tag, kind) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        if (self.unknown_tag_behavior == .reject and tag.isUnknownTag(node_tag)) {
            self.recordFailure(.unknown_tag);
            return error.InvalidSyntax;
        }
    }

    fn validateStandardSequenceContent(self: *Constructor, sequence: graph.SequenceNode) Error!void {
        if (!tag.isStandardOmapTag(sequence.tag) and !tag.isStandardPairsTag(sequence.tag)) return;

        for (sequence.items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return error.InvalidSyntax;
            }
        }
    }

    fn validateStandardMappingContent(self: *Constructor, mapping: graph.MappingNode) Error!void {
        if (!tag.isStandardSetTag(mapping.tag)) return;

        for (mapping.pairs) |pair| {
            if (!isSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return error.InvalidSyntax;
            }
        }
    }

    fn isSetNullValue(node: *const graph.Node) bool {
        return switch (node.*) {
            .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
            else => false,
        };
    }

    fn recordFailure(self: *Constructor, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }
};

fn resolveSchemaScalar(
    allocator: std.mem.Allocator,
    selected_schema: Schema,
    scalar_value: graph.ScalarNode,
) Error!?Node {
    const resolved = (try schema.resolveScalar(
        selected_schema,
        scalar_value.value,
        scalar_value.style == .plain,
        scalar_value.tag,
    )) orelse return null;

    return switch (resolved) {
        .null_value => .{ .null_value = .{
            .anchor = try copyOptionalSlice(allocator, scalar_value.anchor),
            .tag = try copyOptionalSlice(allocator, scalar_value.tag),
        } },
        .bool_value => |bool_value| .{ .bool_value = .{
            .value = bool_value,
            .anchor = try copyOptionalSlice(allocator, scalar_value.anchor),
            .tag = try copyOptionalSlice(allocator, scalar_value.tag),
        } },
        .int_value => |int_value| .{ .int_value = .{
            .value = int_value,
            .anchor = try copyOptionalSlice(allocator, scalar_value.anchor),
            .tag = try copyOptionalSlice(allocator, scalar_value.tag),
        } },
        .float_value => |float_value| .{ .float_value = .{
            .value = float_value,
            .anchor = try copyOptionalSlice(allocator, scalar_value.anchor),
            .tag = try copyOptionalSlice(allocator, scalar_value.tag),
        } },
    };
}

fn copyOptionalSlice(allocator: std.mem.Allocator, maybe_value: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (maybe_value) |slice| try allocator.dupe(u8, slice) else null;
}

test {
    std.testing.refAllDecls(@This());
}

test "loader construct: direct stream wrapper constructs scalar documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const scalar = graph.Node{ .scalar = .{ .value = "value" } };
    const documents = [_]*const graph.Node{&scalar};

    const loaded = try constructStream(
        arena.allocator(),
        &documents,
        .core,
        .reject,
        .preserve,
    );

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(loaded[0].* == .scalar);
    try std.testing.expectEqualStrings("value", loaded[0].scalar.value);
}
