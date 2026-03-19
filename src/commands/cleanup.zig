const std = @import("std");
const config = @import("../config.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");
const prune = @import("prune.zig");
const remove = @import("remove.zig");

const ParsedArgs = struct {
    dry_run: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseArgs(args) catch {
        try stderr.writeAll("Usage: wt cleanup [--dry-run]\n");
        return 1;
    };

    const base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(base);

    const merged = try git_repo.getMergedBranches(allocator, base);
    defer freeStringSlice(allocator, merged);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    const candidates = try collectCandidates(allocator, listed.entries, merged, base);
    defer allocator.free(candidates);

    if (parsed.dry_run) {
        if (candidates.len == 0) {
            try stdout.writeAll("No worktrees found for merged branches.\n");
            return 0;
        }

        try stdout.print("Would remove {d} worktree(s) for merged branches:\n", .{candidates.len});
        for (candidates) |entry| {
            try stdout.print("  - {s} ({s})\n", .{ entry.branch.?, entry.path });
        }
        return 0;
    }

    var removed_count: usize = 0;
    for (candidates) |entry| {
        const branch = entry.branch.?;

        const outcome = remove.removeWorktree(allocator, cfg, branch, stderr) catch |err| switch (err) {
            error.NoSuchWorktree, error.CannotRemoveMainWorktree => continue,
            error.HookCommandFailed => {
                try stderr.print("skipped merged branch {s}: pre-remove hook failed\n", .{branch});
                continue;
            },
            error.GitCommandFailed => continue,
            else => return err,
        };
        defer allocator.free(outcome.path);
        defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

        removed_count += 1;
        try stdout.print("Removed merged worktree: {s} ({s})\n", .{ branch, outcome.path });
    }

    if (removed_count == 0) {
        try stdout.writeAll("No worktrees found for merged branches.\n");
        return 0;
    }

    _ = try prune.run(allocator, &.{}, stdout, stderr);
    try stdout.print("Cleanup complete: {d} removed.\n", .{removed_count});
    return 0;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }

        return error.InvalidArguments;
    }

    return parsed;
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    entries: []const worktree.Entry,
    merged: []const []u8,
    base: []const u8,
) ![]worktree.Entry {
    var candidates: std.ArrayList(worktree.Entry) = .empty;
    errdefer candidates.deinit(allocator);

    for (entries) |entry| {
        const branch = entry.branch orelse continue;
        if (std.mem.eql(u8, branch, base)) continue;
        if (!containsBranch(merged, branch)) continue;
        try candidates.append(allocator, entry);
    }

    return candidates.toOwnedSlice(allocator);
}

fn containsBranch(branches: []const []u8, target: []const u8) bool {
    for (branches) |branch| {
        if (std.mem.eql(u8, branch, target)) return true;
    }

    return false;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "containsBranch matches existing branch names" {
    try std.testing.expect(containsBranch(&.{ "feat/a", "feat/b" }, "feat/a"));
    try std.testing.expect(!containsBranch(&.{ "feat/a", "feat/b" }, "feat/c"));
}

test "parseArgs accepts dry run only" {
    const parsed = try parseArgs(&.{"--dry-run"});
    try std.testing.expect(parsed.dry_run);
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"--force"}));
}

test "collectCandidates filters to merged non-base worktrees" {
    const allocator = std.testing.allocator;
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/repo/.worktrees/feat-a", .branch = "feat-a" },
        .{ .path = "/repo/.worktrees/feat-b", .branch = "feat-b" },
        .{ .path = "/repo/.worktrees/detached", .detached = true },
    };
    const merged = [_][]u8{
        @constCast("feat-a"),
        @constCast("feat-c"),
    };

    const candidates = try collectCandidates(allocator, &entries, &merged, "main");
    defer allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("feat-a", candidates[0].branch.?);
    try std.testing.expectEqualStrings("/repo/.worktrees/feat-a", candidates[0].path);
}
