const std = @import("std");

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
};

pub fn render(
    allocator: std.mem.Allocator,
    template: []const u8,
    variables: []const Variable,
) ![]const u8 {
    var rendered = std.ArrayList(u8).empty;
    errdefer rendered.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        const start = std.mem.indexOfPos(u8, template, index, "{{") orelse {
            try rendered.appendSlice(allocator, template[index..]);
            break;
        };

        try rendered.appendSlice(allocator, template[index..start]);
        const end = std.mem.indexOfPos(u8, template, start + 2, "}}") orelse return error.InvalidTemplate;
        const inner = std.mem.trim(u8, template[start + 2 .. end], " \t\r\n");
        if (inner.len == 0) return error.InvalidTemplate;

        var parts = std.mem.splitScalar(u8, inner, '|');
        const name_raw = parts.next().?;
        const name = std.mem.trim(u8, name_raw, " \t\r\n");
        if (name.len == 0) return error.InvalidTemplate;

        var value = try lookupVariable(allocator, variables, name);
        defer allocator.free(value);

        while (parts.next()) |filter_raw| {
            const filter = std.mem.trim(u8, filter_raw, " \t\r\n");
            if (filter.len == 0) return error.InvalidTemplate;

            const next = try applyFilter(allocator, filter, value);
            allocator.free(value);
            value = next;
        }

        try rendered.appendSlice(allocator, value);
        index = end + 2;
    }

    return rendered.toOwnedSlice(allocator);
}

fn lookupVariable(
    allocator: std.mem.Allocator,
    variables: []const Variable,
    name: []const u8,
) ![]u8 {
    for (variables) |variable| {
        if (std.mem.eql(u8, variable.name, name)) {
            return allocator.dupe(u8, variable.value);
        }
    }

    return error.UnknownVariable;
}

fn applyFilter(
    allocator: std.mem.Allocator,
    filter: []const u8,
    value: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, filter, "sanitize")) return sanitize(allocator, value);
    if (std.mem.eql(u8, filter, "sanitize_db")) return sanitizeDb(allocator, value);
    if (std.mem.eql(u8, filter, "hash")) return hashValue(allocator, value);
    if (std.mem.eql(u8, filter, "hash_port")) return hashPort(allocator, value);

    return error.UnknownFilter;
}

fn sanitize(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (value) |ch| {
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '_') {
            try result.append(allocator, ch);
        } else {
            try result.append(allocator, '-');
        }
    }

    return result.toOwnedSlice(allocator);
}

fn sanitizeDb(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var last_was_underscore = false;
    var first = true;
    for (value) |ch| {
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_') {
            const lower = std.ascii.toLower(ch);
            if (first and std.ascii.isDigit(lower)) {
                try result.append(allocator, '_');
                last_was_underscore = true;
            }
            if (lower == '_' and last_was_underscore) continue;
            try result.append(allocator, lower);
            last_was_underscore = lower == '_';
        } else if (!last_was_underscore) {
            try result.append(allocator, '_');
            last_was_underscore = true;
        }

        first = false;
    }

    if (result.items.len == 0) {
        try result.append(allocator, '_');
    }

    return result.toOwnedSlice(allocator);
}

fn hashValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const hashed = std.hash.Wyhash.hash(0, value);
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{hashed});
}

fn hashPort(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const hashed = std.hash.Wyhash.hash(0, value);
    const port: u16 = 10000 + @as(u16, @intCast(hashed % 55536));
    return std.fmt.allocPrint(allocator, "{d}", .{port});
}

test "render applies filters and variables" {
    const allocator = std.testing.allocator;
    const vars = [_]Variable{
        .{ .name = "branch", .value = "feat/login" },
        .{ .name = "worktree_name", .value = "repo feature" },
        .{ .name = "repo", .value = "wt-zig" },
        .{ .name = "default_branch", .value = "main" },
    };

    const rendered = try render(
        allocator,
        "branch={{ branch | sanitize }}, tree={{ worktree_name | sanitize_db }}, repo={{ repo }}, port={{ branch | hash_port }}",
        &vars,
    );
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "branch=feat-login") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tree=repo_feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "repo=wt-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "port=") != null);
}

test "render supports hash filter" {
    const allocator = std.testing.allocator;
    const vars = [_]Variable{
        .{ .name = "commit", .value = "abcdef1234567890" },
    };

    const rendered = try render(allocator, "{{ commit | hash }}", &vars);
    defer allocator.free(rendered);

    const expected = try std.fmt.allocPrint(allocator, "{x:0>16}", .{std.hash.Wyhash.hash(0, "abcdef1234567890")});
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}

test "render rejects unknown variables and filters" {
    const allocator = std.testing.allocator;
    const vars = [_]Variable{
        .{ .name = "branch", .value = "main" },
    };

    try std.testing.expectError(error.UnknownVariable, render(allocator, "{{ repo }}", &vars));
    try std.testing.expectError(error.UnknownFilter, render(allocator, "{{ branch | nope }}", &vars));
}

test "render rejects invalid templates" {
    const allocator = std.testing.allocator;
    const vars = [_]Variable{
        .{ .name = "branch", .value = "main" },
    };

    try std.testing.expectError(error.InvalidTemplate, render(allocator, "{{ }}", &vars));
    try std.testing.expectError(error.InvalidTemplate, render(allocator, "{{ branch ", &vars));
}
