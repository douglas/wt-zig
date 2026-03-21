const std = @import("std");
const proc = @import("../process.zig");

pub const Entry = struct {
    path: []const u8 = "",
    head: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    bare: bool = false,
    detached: bool = false,
    locked: ?[]const u8 = null,
    prunable: ?[]const u8 = null,
};

pub const ListResult = struct {
    entries: []Entry,
    buffer: []u8,

    pub fn deinit(self: *ListResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.buffer);
    }
};

pub fn list(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !ListResult {
    const result = try proc.run(allocator, &.{ "git", "worktree", "list", "--porcelain" });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                try printGitFailure(stderr, result.stderr, code);
                return error.GitCommandFailed;
            }
        },
        else => {
            try stderr.writeAll("git worktree list terminated unexpectedly.\n");
            return error.GitCommandFailed;
        },
    }

    allocator.free(result.stderr);

    const entries = try parsePorcelain(allocator, result.stdout);
    return .{
        .entries = entries,
        .buffer = result.stdout,
    };
}

fn printGitFailure(stderr: *std.Io.Writer, git_stderr: []const u8, code: u8) !void {
    const trimmed = std.mem.trim(u8, git_stderr, " \r\n\t");
    if (trimmed.len == 0) {
        try stderr.print("git worktree list --porcelain failed with exit code {d}.\n", .{code});
        return;
    }

    try stderr.print("git worktree list --porcelain failed: {s}\n", .{trimmed});
}

pub fn parsePorcelain(allocator: std.mem.Allocator, buffer: []u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var current = Entry{};
    var has_current = false;
    var lines = std.mem.splitScalar(u8, buffer, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (line.len == 0) {
            if (has_current and current.path.len > 0) {
                try entries.append(allocator, current);
                current = Entry{};
                has_current = false;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (has_current and current.path.len > 0) {
                try entries.append(allocator, current);
            }

            current = Entry{ .path = line["worktree ".len..] };
            has_current = true;
            continue;
        }

        if (!has_current) {
            continue;
        }

        if (std.mem.startsWith(u8, line, "HEAD ")) {
            current.head = line["HEAD ".len..];
            continue;
        }

        if (std.mem.startsWith(u8, line, "branch ")) {
            const branch_ref = line["branch ".len..];
            current.branch = trimBranchRef(branch_ref);
            continue;
        }

        if (std.mem.eql(u8, line, "bare")) {
            current.bare = true;
            continue;
        }

        if (std.mem.eql(u8, line, "detached")) {
            current.detached = true;
            continue;
        }

        if (std.mem.startsWith(u8, line, "locked")) {
            current.locked = parseOptionalValue(line["locked".len..]);
            continue;
        }

        if (std.mem.startsWith(u8, line, "prunable")) {
            current.prunable = parseOptionalValue(line["prunable".len..]);
        }
    }

    if (has_current and current.path.len > 0) {
        try entries.append(allocator, current);
    }

    return entries.toOwnedSlice(allocator);
}

fn trimBranchRef(branch_ref: []const u8) []const u8 {
    const prefix = "refs/heads/";
    if (std.mem.startsWith(u8, branch_ref, prefix)) {
        return branch_ref[prefix.len..];
    }

    return branch_ref;
}

fn parseOptionalValue(raw_value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_value, " \t");
    return trimmed;
}

test "parse porcelain captures branch and head" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(
        u8,
        "worktree /repo\nHEAD 1234567\nbranch refs/heads/main\n\nworktree /repo/feature\nHEAD abcdef0\nbranch refs/heads/feature/login\nlocked reason here\nprunable stale metadata\n",
    );
    defer allocator.free(source);

    const entries = try parsePorcelain(allocator, source);
    defer allocator.free(entries);

    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("/repo", entries[0].path);
    try std.testing.expectEqualStrings("main", entries[0].branch.?);
    try std.testing.expectEqualStrings("feature/login", entries[1].branch.?);
    try std.testing.expectEqualStrings("reason here", entries[1].locked.?);
    try std.testing.expectEqualStrings("stale metadata", entries[1].prunable.?);
}

test "parse porcelain handles detached and bare entries" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(
        u8,
        "worktree /bare.git\nbare\n\nworktree /repo/detached\nHEAD deadbeef\ndetached\n",
    );
    defer allocator.free(source);

    const entries = try parsePorcelain(allocator, source);
    defer allocator.free(entries);

    try std.testing.expect(entries[0].bare);
    try std.testing.expect(entries[1].detached);
    try std.testing.expectEqualStrings("deadbeef", entries[1].head.?);
}
