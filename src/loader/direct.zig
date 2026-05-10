//! Purpose: Construct public value nodes directly from parser events when safe.
//! Owns: Alias-free event stream loading, direct value-node allocation, and fallback support checks.
//! Does not own: Event parsing, alias resolution, public API diagnostics, or emission.
//! Depends on: parser/event.zig, schema, loader options, duplicate-key validation, and value/value.zig.
//! Tested by: tests/unit/loader/loader_test.zig and public loader conformance tests.

const std = @import("std");
const diagnostic = @import("../common/diagnostic.zig");
const duplicate_key = @import("duplicate_key.zig");
const failure = @import("failure.zig");
const limit = @import("limit.zig");
const node_pool = @import("../common/node_pool.zig");
const options = @import("options.zig");
const parser_event = @import("../parser/event.zig");
const schema = @import("../schema/schema.zig");
const tag = @import("../schema/tag.zig");
const value_model = @import("../value/value.zig");

const DuplicateKeyBehavior = options.DuplicateKeyBehavior;
const Error = diagnostic.Error;
const Event = parser_event.Event;
const LoadFailure = failure.LoadFailure;
const MappingPair = value_model.MappingPair;
const Node = value_model.Node;
const NodePool = node_pool.Pool(Node);
const ParseError = diagnostic.ParseError;
const Schema = schema.Schema;
const UnknownTagBehavior = options.UnknownTagBehavior;

/// Returns true when the direct loader supports the event stream shape.
pub fn supports(events: []const Event) bool {
    for (events) |event_value| {
        if (event_value == .alias) return false;
    }
    return true;
}

/// Loads alias-free parser events directly into arena-owned public value roots.
pub fn loadStreamFromEvents(
    allocator: std.mem.Allocator,
    events: []const Event,
    selected_schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    max_document_count: ?usize,
    load_failure: ?*LoadFailure,
) Error![]const *const Node {
    try limit.checkEvents(events, .{ .max_document_count = max_document_count }, load_failure);
    if (!supports(events)) return ParseError.Unsupported;

    var loader: DirectLoader = .{
        .allocator = allocator,
        .events = events,
        .schema = selected_schema,
        .duplicate_key_behavior = duplicate_key_behavior,
        .unknown_tag_behavior = unknown_tag_behavior,
        .failure = load_failure,
    };
    return loader.loadStream();
}

const DirectLoader = struct {
    allocator: std.mem.Allocator,
    events: []const Event,
    schema: Schema,
    duplicate_key_behavior: DuplicateKeyBehavior,
    unknown_tag_behavior: UnknownTagBehavior,
    failure: ?*LoadFailure,
    index: usize = 0,
    nodes: NodePool = .{},

    fn loadStream(self: *DirectLoader) Error![]const *const Node {
        self.nodes = try NodePool.init(self.allocator, countValueNodes(self.events));
        errdefer self.nodes.deinit(self.allocator);

        try self.expectStreamStart();

        var documents: std.ArrayList(*const Node) = .empty;
        errdefer documents.deinit(self.allocator);
        try documents.ensureTotalCapacity(self.allocator, countDocumentStarts(self.events));

        while (self.index < self.events.len and self.events[self.index] == .document_start) {
            self.index += 1;

            const root = try self.constructNode();

            if (self.index >= self.events.len or self.events[self.index] != .document_end) return self.invalidGraph();
            self.index += 1;

            try documents.append(self.allocator, root);
        }

        if (self.index >= self.events.len or self.events[self.index] != .stream_end) return self.invalidGraph();
        self.index += 1;
        if (self.index != self.events.len) return self.invalidGraph();

        return documents.toOwnedSlice(self.allocator);
    }

    fn expectStreamStart(self: *DirectLoader) Error!void {
        if (self.index >= self.events.len or self.events[self.index] != .stream_start) return self.invalidGraph();
        self.index += 1;
    }

    fn constructNode(self: *DirectLoader) Error!*const Node {
        if (self.index >= self.events.len) return self.invalidGraph();

        const current = self.events[self.index];
        self.index += 1;

        return switch (current) {
            .scalar => |scalar| self.constructScalar(scalar),
            .sequence_start => |collection| self.constructSequence(collection),
            .mapping_start => |collection| self.constructMapping(collection),
            .alias => ParseError.Unsupported,
            else => self.invalidGraph(),
        };
    }

    fn constructScalar(self: *DirectLoader, scalar: parser_event.Scalar) Error!*const Node {
        const node = try self.nodes.create();
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
        }) orelse .{ .scalar = .{
            .value = try self.allocator.dupe(u8, scalar.value),
            .style = scalar.style,
            .anchor = try copyOptionalSlice(self.allocator, scalar.anchor),
            .tag = try copyOptionalSlice(self.allocator, scalar.tag),
        } };
        return node;
    }

    fn constructSequence(self: *DirectLoader, collection: parser_event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        try self.validateTag(collection.tag, .sequence);

        var items: std.ArrayList(*const Node) = .empty;
        errdefer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, countDirectCollectionNodes(self.events, self.index, false));

        while (self.index < self.events.len and self.events[self.index] != .sequence_end) {
            try items.append(self.allocator, try self.constructNode());
        }
        if (self.index >= self.events.len) return self.invalidGraph();
        self.index += 1;

        const owned_items = try items.toOwnedSlice(self.allocator);
        node.* = .{ .sequence = .{
            .items = owned_items,
            .style = collection.style,
            .anchor = try copyOptionalSlice(self.allocator, collection.anchor),
            .tag = try copyOptionalSlice(self.allocator, collection.tag),
        } };
        if (tag.isStandardOmapTag(collection.tag)) {
            duplicate_key.validateUniqueOrderedMapKeys(owned_items) catch |err| {
                self.recordFailure(.invalid_standard_tag);
                return err;
            };
        } else if (tag.isStandardPairsTag(collection.tag)) {
            try self.validateStandardSequenceContent(owned_items);
        }
        return node;
    }

    fn constructMapping(self: *DirectLoader, collection: parser_event.CollectionStart) Error!*const Node {
        const node = try self.nodes.create();
        try self.validateTag(collection.tag, .mapping);

        var pairs: std.ArrayList(MappingPair) = .empty;
        errdefer pairs.deinit(self.allocator);
        try pairs.ensureTotalCapacity(self.allocator, countDirectCollectionNodes(self.events, self.index, true) / 2);

        while (self.index < self.events.len and self.events[self.index] != .mapping_end) {
            const key = try self.constructNode();
            if (self.index >= self.events.len or self.events[self.index] == .mapping_end) return self.invalidGraph();
            try pairs.append(self.allocator, .{
                .key = key,
                .value = try self.constructNode(),
            });
        }
        if (self.index >= self.events.len) return self.invalidGraph();
        self.index += 1;

        const owned_pairs = try pairs.toOwnedSlice(self.allocator);
        node.* = .{ .mapping = .{
            .pairs = owned_pairs,
            .style = collection.style,
            .anchor = try copyOptionalSlice(self.allocator, collection.anchor),
            .tag = try copyOptionalSlice(self.allocator, collection.tag),
        } };
        if (tag.isStandardSetTag(collection.tag)) {
            try self.validateStandardSetContent(owned_pairs);
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
        return node;
    }

    fn validateTag(self: *DirectLoader, node_tag: ?[]const u8, kind: tag.NodeKind) Error!void {
        tag.validateStandardTagKind(node_tag, kind) catch |err| {
            self.recordFailure(.invalid_standard_tag);
            return err;
        };

        if (self.unknown_tag_behavior == .reject and tag.isUnknownTag(node_tag)) {
            self.recordFailure(.unknown_tag);
            return ParseError.InvalidSyntax;
        }
    }

    fn validateStandardSequenceContent(self: *DirectLoader, items: []const *const Node) Error!void {
        for (items) |item| {
            if (item.* != .mapping or item.mapping.pairs.len != 1) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    fn validateStandardSetContent(self: *DirectLoader, pairs: []const MappingPair) Error!void {
        for (pairs) |pair| {
            if (!isSetNullValue(pair.value)) {
                self.recordFailure(.invalid_standard_tag);
                return ParseError.InvalidSyntax;
            }
        }
    }

    fn invalidGraph(self: *DirectLoader) Error {
        self.recordFailure(.invalid_graph);
        return ParseError.InvalidSyntax;
    }

    fn recordFailure(self: *DirectLoader, load_failure: LoadFailure) void {
        if (self.failure) |target| {
            if (target.* == .unknown) target.* = load_failure;
        }
    }
};

fn resolveSchemaScalar(
    allocator: std.mem.Allocator,
    selected_schema: Schema,
    scalar_value: parser_event.Scalar,
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

fn isSetNullValue(node: *const Node) bool {
    return switch (node.*) {
        .null_value => true,
        .scalar => |scalar| schema.isCoreNullScalar(scalar.value, scalar.style == .plain, scalar.tag),
        else => false,
    };
}

fn countDocumentStarts(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event_value| {
        if (event_value == .document_start) count += 1;
    }
    return count;
}

fn countValueNodes(events: []const Event) usize {
    var count: usize = 0;
    for (events) |event_value| switch (event_value) {
        .scalar, .sequence_start, .mapping_start => count += 1,
        else => {},
    };
    return count;
}

fn countDirectCollectionNodes(events: []const Event, start: usize, mapping: bool) usize {
    var count: usize = 0;
    var depth: usize = 0;
    var index = start;
    while (index < events.len) : (index += 1) {
        const event_value = events[index];
        if (depth == 0 and collectionEnded(event_value, mapping)) return count;
        if (depth == 0 and eventStartsNode(event_value)) count += 1;
        switch (event_value) {
            .sequence_start, .mapping_start => depth += 1,
            .sequence_end, .mapping_end => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return count;
}

fn collectionEnded(event_value: Event, mapping: bool) bool {
    return if (mapping) event_value == .mapping_end else event_value == .sequence_end;
}

fn eventStartsNode(event_value: Event) bool {
    return switch (event_value) {
        .scalar, .sequence_start, .mapping_start => true,
        else => false,
    };
}

fn copyOptionalSlice(allocator: std.mem.Allocator, maybe_value: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (maybe_value) |slice| try allocator.dupe(u8, slice) else null;
}

test {
    std.testing.refAllDecls(@This());
}
