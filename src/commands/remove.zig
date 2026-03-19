const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const path_mod = @import("../path.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

pub const Outcome = struct {
    path: []const u8,
    navigate_to: ?[]const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len != 1) {
        try stderr.writeAll("Usage: wt remove <branch>\n");
        return 1;
    }

    const outcome = removeWorktree(allocator, cfg, args[0], stderr) catch |err| switch (err) {
        error.NoSuchWorktree => {
            try stderr.print("no worktree found for branch: {s}\n", .{args[0]});
            return 1;
        },
        error.CannotRemoveMainWorktree => {
            try stderr.writeAll("cannot remove the main worktree\n");
            return 1;
        },
        error.HookCommandFailed => {
            try stderr.writeAll("pre-remove hook failed\n");
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);
    defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

    try stdout.print("Removed worktree: {s}\n", .{outcome.path});
    if (outcome.navigate_to) |navigate_to| {
        try stdout.print("wt navigating to: {s}\n", .{navigate_to});
    }
    return 0;
}

pub fn removeWorktree(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    branch: []const u8,
    stderr: anytype,
) !Outcome {
    var info = try git_repo.getRepoInfo(allocator);
    defer freeRepoInfo(allocator, &info);

    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);

    const existing = findBranchWorktree(listed.entries, branch) orelse return error.NoSuchWorktree;
    if (std.mem.eql(u8, existing.path, info.main)) return error.CannotRemoveMainWorktree;

    const existing_path = try allocator.dupe(u8, existing.path);
    errdefer allocator.free(existing_path);

    var hook_env = try hooks.buildHookEnv(allocator, info, branch, existing_path);
    defer hook_env.deinit();

    try hooks.runHooks(allocator, "pre_remove", hooks.getHooks(cfg, "pre_remove"), &hook_env, stderr);

    const navigate_to = try navigationTarget(allocator, existing_path, info.main);
    errdefer if (navigate_to) |path| allocator.free(path);

    const success = try runGitRemove(allocator, existing_path, stderr);
    if (!success) return error.GitCommandFailed;

    path_mod.cleanupWorktreePath(cfg, existing_path) catch |err| {
        try stderr.print(
            "warning: failed to clean removed worktree path {s}: {s}\n",
            .{ existing_path, @errorName(err) },
        );
    };

    hooks.runHooks(allocator, "post_remove", hooks.getHooks(cfg, "post_remove"), &hook_env, stderr) catch {};

    return .{
        .path = existing_path,
        .navigate_to = navigate_to,
    };
}

fn findBranchWorktree(entries: []const worktree.Entry, branch: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |entry_branch| {
            if (std.mem.eql(u8, entry_branch, branch)) return entry;
        }
    }

    return null;
}

fn navigationTarget(
    allocator: std.mem.Allocator,
    removed_path: []const u8,
    main_path: []const u8,
) !?[]u8 {
    const cwd = std.process.getCwdAlloc(allocator) catch return null;
    defer allocator.free(cwd);

    if (!isSameOrChildPath(removed_path, cwd)) return null;
    const navigate_to = try allocator.dupe(u8, main_path);
    return navigate_to;
}

fn isSameOrChildPath(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn runGitRemove(allocator: std.mem.Allocator, path: []const u8, stderr: anytype) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "worktree", "remove", path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return true;
    try stderr.print("failed to remove worktree: {s}\n", .{std.mem.trim(u8, result.stderr, " \r\n\t")});
    return false;
}

fn freeRepoInfo(allocator: std.mem.Allocator, info: *path_mod.RepoInfo) void {
    allocator.free(info.main);
    allocator.free(info.host);
    allocator.free(info.owner);
    allocator.free(info.name);
}

test "isSameOrChildPath matches boundaries" {
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo/sub"));
    try std.testing.expect(!isSameOrChildPath("/tmp/repo", "/tmp/repository"));
}
