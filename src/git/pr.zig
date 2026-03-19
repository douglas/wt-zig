const std = @import("std");
const proc = @import("../process.zig");

pub const RemoteType = enum {
    github,
    gitlab,
};

pub const OpenItem = struct {
    id: []u8,
    label: []u8,
};

pub fn resolveBranchName(
    allocator: std.mem.Allocator,
    remote_type: RemoteType,
    input: []const u8,
) !struct { id: []u8, branch: []u8 } {
    const id = try parseIdentifier(allocator, remote_type, input);
    errdefer allocator.free(id);

    const branch = try switch (remote_type) {
        .github => loadGitHubBranchName(allocator, id),
        .gitlab => loadGitLabBranchName(allocator, id),
    };

    return .{
        .id = id,
        .branch = branch,
    };
}

pub fn fallbackRefspec(allocator: std.mem.Allocator, remote_type: RemoteType, id: []const u8) ![]u8 {
    return switch (remote_type) {
        .github => std.fmt.allocPrint(allocator, "pull/{s}/head", .{id}),
        .gitlab => std.fmt.allocPrint(allocator, "merge-requests/{s}/head", .{id}),
    };
}

pub fn commandName(remote_type: RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "pr",
        .gitlab => "mr",
    };
}

pub fn label(remote_type: RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "PR",
        .gitlab => "MR",
    };
}

pub fn getOpenItems(allocator: std.mem.Allocator, remote_type: RemoteType) ![]OpenItem {
    return switch (remote_type) {
        .github => getOpenGitHubItems(allocator),
        .gitlab => getOpenGitLabItems(allocator),
    };
}

pub fn freeOpenItems(allocator: std.mem.Allocator, items: []OpenItem) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.label);
    }
    allocator.free(items);
}

fn parseIdentifier(
    allocator: std.mem.Allocator,
    remote_type: RemoteType,
    input: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPullRequestInput;

    if (isDigits(trimmed)) return allocator.dupe(u8, trimmed);

    const marker = switch (remote_type) {
        .github => "/pull/",
        .gitlab => "/-/merge_requests/",
    };
    const marker_index = std.mem.indexOf(u8, trimmed, marker) orelse return error.InvalidPullRequestInput;
    const tail = trimmed[marker_index + marker.len ..];
    const digits = leadingDigits(tail);
    if (digits.len == 0) return error.InvalidPullRequestInput;
    return allocator.dupe(u8, digits);
}

fn isDigits(value: []const u8) bool {
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return value.len != 0;
}

fn leadingDigits(value: []const u8) []const u8 {
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    return value[0..end];
}

fn loadGitHubBranchName(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var result = proc.run(allocator, &.{ "gh", "pr", "view", id, "--json", "headRefName" }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPlatformCli,
        else => return err,
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return error.PlatformLookupFailed;
    }

    const parsed = try std.json.parseFromSlice(
        struct { headRefName: []const u8 },
        allocator,
        result.stdout,
        .{},
    );
    defer parsed.deinit();

    if (parsed.value.headRefName.len == 0) {
        return error.EmptyBranchName;
    }

    return allocator.dupe(u8, parsed.value.headRefName);
}

fn loadGitLabBranchName(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var result = proc.run(allocator, &.{ "glab", "mr", "view", id, "--output", "json" }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPlatformCli,
        else => return err,
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return error.PlatformLookupFailed;
    }

    const parsed = try std.json.parseFromSlice(
        struct { source_branch: []const u8 },
        allocator,
        result.stdout,
        .{},
    );
    defer parsed.deinit();

    if (parsed.value.source_branch.len == 0) {
        return error.EmptyBranchName;
    }

    return allocator.dupe(u8, parsed.value.source_branch);
}

fn getOpenGitHubItems(allocator: std.mem.Allocator) ![]OpenItem {
    var result = proc.run(allocator, &.{ "gh", "pr", "list", "--json", "number,title", "--jq", ".[] | \"\\(.number)\\t\\(.title)\"" }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPlatformCli,
        else => return err,
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.PlatformLookupFailed;
    return parseTabSeparatedItems(allocator, result.stdout, "#");
}

fn getOpenGitLabItems(allocator: std.mem.Allocator) ![]OpenItem {
    var result = proc.run(allocator, &.{ "glab", "mr", "list" }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingPlatformCli,
        else => return err,
    };
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.PlatformLookupFailed;
    return parseGitLabListItems(allocator, result.stdout);
}

fn parseTabSeparatedItems(allocator: std.mem.Allocator, output: []const u8, prefix: []const u8) ![]OpenItem {
    var items = std.ArrayList(OpenItem).empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
        const id = std.mem.trim(u8, trimmed[0..tab], " \t");
        const title = std.mem.trim(u8, trimmed[tab + 1 ..], " \t");
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .label = try std.fmt.allocPrint(allocator, "{s}{s}: {s}", .{ prefix, id, title }),
        });
    }
    return items.toOwnedSlice(allocator);
}

fn parseGitLabListItems(allocator: std.mem.Allocator, output: []const u8) ![]OpenItem {
    var items = std.ArrayList(OpenItem).empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0 or trimmed[0] != '!') continue;
        var index: usize = 1;
        while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) : (index += 1) {}
        if (index == 1) continue;
        const id = trimmed[1..index];
        const title_start = std.mem.indexOfNonePos(u8, trimmed, index, " \t") orelse continue;
        const title = std.mem.trim(u8, trimmed[title_start..], " \t");
        try items.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .label = try std.fmt.allocPrint(allocator, "!{s}: {s}", .{ id, title }),
        });
    }
    return items.toOwnedSlice(allocator);
}

test "parseIdentifier handles number and URLs" {
    const allocator = std.testing.allocator;

    const github_number = try parseIdentifier(allocator, .github, "42");
    defer allocator.free(github_number);
    try std.testing.expectEqualStrings("42", github_number);

    const github_url = try parseIdentifier(allocator, .github, "https://github.com/acme/repo/pull/123");
    defer allocator.free(github_url);
    try std.testing.expectEqualStrings("123", github_url);

    const gitlab_url = try parseIdentifier(allocator, .gitlab, "https://gitlab.com/acme/repo/-/merge_requests/77");
    defer allocator.free(gitlab_url);
    try std.testing.expectEqualStrings("77", gitlab_url);
}

test "parseIdentifier rejects malformed input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPullRequestInput, parseIdentifier(allocator, .github, "feature/test"));
}

test "parseTabSeparatedItems formats github labels" {
    const allocator = std.testing.allocator;
    const items = try parseTabSeparatedItems(allocator, "123\tFix it\n", "#");
    defer freeOpenItems(allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("123", items[0].id);
    try std.testing.expectEqualStrings("#123: Fix it", items[0].label);
}
