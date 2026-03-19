const std = @import("std");
const config = @import("../config.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");
const prune = @import("prune.zig");
const remove = @import("remove.zig");

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("Usage: wt cleanup\n");
        return 1;
    }

    const base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(base);

    const merged = try git_repo.getMergedBranches(allocator, base);
    defer freeStringSlice(allocator, merged);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var removed_count: usize = 0;
    for (listed.entries) |entry| {
        const branch = entry.branch orelse continue;
        if (std.mem.eql(u8, branch, base)) continue;
        if (!containsBranch(merged, branch)) continue;

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
