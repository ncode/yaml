//! Purpose: Centralize public API diagnostic message policy.
//! Owns: Limit, parse, and loader diagnostic selection for API entrypoints.
//! Does not own: Parsing, loading, source location calculation internals, or public diagnostic types.
//! Depends on: api/diagnostics.zig, common/diagnostic.zig, loader/failure.zig, parser/diagnostics.zig.
//! Tested by: tests/unit/api/root_api_test.zig and tests/structure/api_boundary_test.zig.

const common_diagnostic = @import("../common/diagnostic.zig");
const diagnostics = @import("diagnostics.zig");
const loader_failure = @import("../loader/failure.zig");
const parser_diagnostics = @import("../parser/diagnostics.zig");

const Diagnostic = diagnostics.Diagnostic;
const Error = diagnostics.Error;
const LoadFailure = loader_failure.LoadFailure;
const ParseError = diagnostics.ParseError;

pub const LimitFailure = union(enum) {
    input_size: usize,
    token_count,
    event_count,
    scalar_size,
    nesting_depth,
};

const SelectedLimitDiagnostic = struct {
    offset: usize,
    message: []const u8,
};

pub fn clear(target: ?*Diagnostic) void {
    if (target) |diagnostic| {
        diagnostic.* = .{};
    }
}

pub fn setLimit(target: ?*Diagnostic, input: []const u8, failure: LimitFailure) void {
    if (target) |diagnostic| {
        diagnostic.* = limitDiagnostic(input, failure);
    }
}

pub fn setParseFailure(target: ?*Diagnostic, input: []const u8, err: Error) void {
    if (target) |diagnostic| {
        if (diagnostic.message.len == 0) {
            diagnostic.* = parser_diagnostics.diagnosticForParseError(input, err);
        }
    }
}

pub fn setLoadFailure(target: ?*Diagnostic, input: []const u8, failure: LoadFailure, err: Error) void {
    if (target) |diagnostic| {
        if (diagnostic.message.len == 0) {
            diagnostic.* = loadFailureDiagnostic(input, failure, err);
        }
    }
}

pub fn setSingleDocumentCountFailure(target: ?*Diagnostic, input: []const u8) void {
    if (target) |diagnostic| {
        diagnostic.* = diagnosticAt(input, input.len, "loader expected exactly one document");
    }
}

pub fn limitDiagnostic(input: []const u8, failure: LimitFailure) Diagnostic {
    const selected: SelectedLimitDiagnostic = switch (failure) {
        .input_size => |max_input_bytes| .{ .offset = max_input_bytes, .message = "input exceeds configured size limit" },
        .token_count => .{ .offset = input.len, .message = "token count exceeds configured limit" },
        .event_count => .{ .offset = input.len, .message = "event count exceeds configured limit" },
        .scalar_size => .{ .offset = input.len, .message = "scalar exceeds configured size limit" },
        .nesting_depth => .{ .offset = input.len, .message = "nesting depth exceeds configured limit" },
    };

    return diagnosticAt(input, selected.offset, selected.message);
}

pub fn loadFailureDiagnostic(input: []const u8, failure: LoadFailure, err: Error) Diagnostic {
    const message = switch (failure) {
        .document_count_limit => "loader exceeded configured document count limit",
        .alias_count_limit => "loader exceeded configured alias count limit",
        .alias_expansion_limit => "loader exceeded configured alias expansion limit",
        .invalid_graph => "loader rejected invalid representation graph",
        .invalid_standard_tag => "loader rejected tag for node kind",
        .invalid_scalar_tag => "loader rejected invalid tagged scalar",
        .unknown_tag => "loader rejected unknown tag",
        .duplicate_key => "loader rejected duplicate mapping key",
        .unknown => switch (err) {
            ParseError.InvalidSyntax => "loader rejected invalid YAML graph",
            ParseError.Unsupported => "loader exceeded configured safety limit",
            else => "loader failed",
        },
    };

    return diagnosticAt(input, input.len, message);
}

fn diagnosticAt(input: []const u8, offset: usize, message: []const u8) Diagnostic {
    return common_diagnostic.atOffset(input, offset, message);
}
