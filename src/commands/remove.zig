const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

pub const Outcome = struct {
    path: []const u8,
    navigate_to: ?[]const u8,
};

const ParsedArgs = struct {
    branch: ?[]const u8 = null,
    force: bool = false,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt remove", "Usage: wt remove [branch] [--force|-f]");
    };

    var branch = parsed.branch;
    var owned_branches: ?[][]u8 = null;
    defer if (owned_branches) |branches| {
        for (branches) |candidate| allocator.free(candidate);
        allocator.free(branches);
    };

    if (branch == null) {
        if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt remove", "wt remove with --format json requires an explicit branch argument");
            return 1;
        }

        const branches = git_repo.getExistingWorktreeBranches(allocator) catch {
            try stderr.writeAll("failed to get worktrees\n");
            return 1;
        };
        owned_branches = branches;
        if (branches.len == 0) {
            try stderr.writeAll("no worktrees to remove\n");
            return 1;
        }

        const selection = prompt.selectItem(allocator, "Select worktree to remove", branches, stderr) catch |err| switch (err) {
            error.SelectionCancelled => {
                try stderr.writeAll("selection cancelled\n");
                return 1;
            },
            else => {
                try stderr.writeAll("invalid selection\n");
                return 1;
            },
        };
        branch = selection.value;
    }

    const outcome = removeWorktree(allocator, cfg, branch.?, parsed.force, stderr) catch |err| switch (err) {
        error.NoSuchWorktree => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "no worktree found for branch: {s}", .{branch.?});
                defer allocator.free(message);
                try output.emitError(ctx, stdout, "wt remove", message);
            } else {
                try stderr.print("no worktree found for branch: {s}\n", .{branch.?});
            }
            return 1;
        },
        error.CannotRemoveMainWorktree => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt remove", "cannot remove the main worktree");
            } else {
                try stderr.writeAll("cannot remove the main worktree\n");
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt remove", "pre-remove hook failed");
            } else {
                try stderr.writeAll("pre-remove hook failed\n");
            }
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);
    defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt remove", .{
            .status = "removed",
            .branch = branch.?,
            .path = outcome.path,
            .navigate_to = outcome.navigate_to,
        });
    } else {
        try stdout.print("Removed worktree: {s}\n", .{outcome.path});
        if (outcome.navigate_to) |navigate_to| {
            try stdout.print("wt navigating to: {s}\n", .{navigate_to});
        }
    }
    return 0;
}

pub fn removeWorktree(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    branch: []const u8,
    force: bool,
    stderr: *std.Io.Writer,
) !Outcome {
    var info = try git_repo.getRepoInfo(allocator);
    defer git_repo.freeRepoInfo(allocator, &info);

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

    const success = try runGitRemove(allocator, existing_path, force, stderr);
    if (!success) return error.GitCommandFailed;

    path_mod.cleanupWorktreePath(allocator, cfg, existing_path) catch |err| {
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

fn runGitRemove(allocator: std.mem.Allocator, path: []const u8, force: bool, stderr: *std.Io.Writer) !bool {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "worktree", "remove" });
    if (force) try args.append(allocator, "--force");
    try args.append(allocator, path);
    const argv = try args.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);

    if (result.succeeded()) return true;
    try stderr.print("failed to remove worktree: {s}\n", .{result.trimmedStderr()});
    return false;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }
        if (parsed.branch == null) {
            parsed.branch = arg;
            continue;
        }
        return error.InvalidArguments;
    }

    return parsed;
}

test "isSameOrChildPath matches boundaries" {
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo/sub"));
    try std.testing.expect(!isSameOrChildPath("/tmp/repo", "/tmp/repository"));
}

test "parseArgs accepts optional force" {
    const parsed = try parseArgs(&.{ "--force", "feature" });
    try std.testing.expect(parsed.force);
    try std.testing.expectEqualStrings("feature", parsed.branch.?);
}
