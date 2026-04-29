const std = @import("std");
const config = @import("../config.zig");
const git_repo = @import("../git/repo.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const remove = @import("remove.zig");
const worktree = @import("../git/worktree.zig");

const usage = "Usage: wt merge [target] [--no-remove] [--no-ff] [--squash] [--rebase] [--push] [--no-hooks] [--message <message>]";

const ParsedArgs = struct {
    target: ?[]const u8 = null,
    remove_worktree: bool = true,
    ff_only: bool = true,
    squash: bool = false,
    rebase: bool = false,
    push: bool = false,
    hooks: bool = true,
    message: ?[]const u8 = null,
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
        return output.usageError(ctx, stdout, stderr, "wt merge", usage);
    };

    const source_branch = currentBranch(allocator) catch {
        return emitMergeError(ctx, stdout, stderr, "wt merge requires a local branch");
    };
    defer allocator.free(source_branch);
    const source_path = repoRoot(allocator) catch {
        return emitMergeError(ctx, stdout, stderr, "failed to resolve source worktree");
    };
    defer allocator.free(source_path);

    const target_branch = if (parsed.target) |target|
        try allocator.dupe(u8, target)
    else
        try git_repo.getDefaultBase(allocator);
    defer allocator.free(target_branch);

    if (std.mem.eql(u8, source_branch, target_branch)) {
        return emitMergeError(ctx, stdout, stderr, "already on target branch");
    }

    if (!try localBranchExists(allocator, target_branch)) {
        const message = try std.fmt.allocPrint(allocator, "target branch not found: {s}", .{target_branch});
        defer allocator.free(message);
        return emitMergeError(ctx, stdout, stderr, message);
    }

    if (parsed.squash and parsed.message == null) {
        return emitMergeError(ctx, stdout, stderr, "wt merge --squash requires --message");
    }

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var info = try git_repo.getRepoInfoWithWorktrees(allocator, listed.entries);
    defer git_repo.freeRepoInfo(allocator, &info);

    var hook_env = try hooks.buildHookEnv(allocator, info, source_branch, source_path);
    defer hook_env.deinit();

    if (parsed.rebase) {
        try stdout.print("Rebasing {s} onto {s}...\n", .{ source_branch, target_branch });
        if (!try gitQuiet(allocator, &.{ "git", "-C", source_path, "rebase", target_branch }, stderr, "git rebase failed")) return 1;
    }

    if (parsed.squash) {
        try stdout.print("Squashing {s} changes since {s}...\n", .{ source_branch, target_branch });
        if (parsed.hooks and !try runMergeHook(allocator, cfg, "pre_commit", &hook_env, stderr)) {
            return emitMergeError(ctx, stdout, stderr, "pre-commit hook failed before squash");
        }
        const base = mergeBase(allocator, source_path, "HEAD", target_branch) catch {
            return emitMergeError(ctx, stdout, stderr, "failed to resolve merge base for squash");
        };
        defer allocator.free(base);
        if (!try gitQuiet(allocator, &.{ "git", "-C", source_path, "add", "-A" }, stderr, "git add failed")) return 1;
        if (!try gitQuiet(allocator, &.{ "git", "-C", source_path, "reset", "--soft", base }, stderr, "git reset --soft failed")) return 1;
        if (!try gitQuiet(allocator, &.{ "git", "-C", source_path, "commit", "-m", parsed.message.? }, stderr, "git commit failed")) return 1;
        if (parsed.hooks) try runMergePostHook(allocator, cfg, "post_commit", &hook_env, stderr);
    }

    const source_entry = findBranchWorktree(listed.entries, source_branch);
    const target_entry = findBranchWorktree(listed.entries, target_branch);
    const merge_dir = if (target_entry) |entry| entry.path else try repoRoot(allocator);
    defer if (target_entry == null) allocator.free(merge_dir);

    const source_head = gitOutputTrimmed(allocator, &.{ "git", "rev-parse", source_branch }) catch {
        return emitMergeError(ctx, stdout, stderr, "failed to resolve source branch");
    };
    defer allocator.free(source_head);

    if (!parsed.ff_only) {
        try stdout.print("Merging {s} into {s} with a merge commit...\n", .{ source_branch, target_branch });
    } else {
        try stdout.print("Merging {s} into {s}...\n", .{ source_branch, target_branch });
    }

    if (parsed.hooks and !try runMergeHook(allocator, cfg, "pre_merge", &hook_env, stderr)) {
        return emitMergeError(ctx, stdout, stderr, "pre-merge hook failed");
    }

    const merged = if (target_entry) |_|
        try mergeInWorktree(allocator, merge_dir, source_branch, parsed.ff_only, stderr)
    else
        try updateBranchRef(allocator, target_branch, source_branch, parsed.ff_only, stderr);

    if (!merged) return 1;

    if (parsed.push) {
        if (!try gitQuiet(allocator, &.{ "git", "-C", merge_dir, "push" }, stderr, "git push failed")) return 1;
    }

    var removed_path: ?[]const u8 = null;
    defer if (removed_path) |path| allocator.free(path);
    var branch_deleted = false;
    var branch_delete_reason: ?[]const u8 = null;
    var branch_retained_reason: ?[]const u8 = null;

    if (parsed.remove_worktree and source_entry != null) {
        const default_base = try git_repo.getDefaultBase(allocator);
        defer allocator.free(default_base);
        const cleanup_mode: remove.BranchCleanupMode = if (std.mem.eql(u8, target_branch, default_base))
            .delete_if_safe
        else
            .force_delete;
        const removal = remove.removeWorktree(allocator, cfg, source_branch, .{
            .force = false,
            .branch_cleanup = cleanup_mode,
        }, stderr) catch |err| switch (err) {
            error.HookCommandFailed => return emitMergeError(ctx, stdout, stderr, "pre-remove hook failed after merge"),
            error.GitCommandFailed => return 1,
            else => return err,
        };
        removed_path = removal.path;
        if (removal.navigate_to) |navigate_to| allocator.free(navigate_to);
        branch_deleted = removal.branch_deleted;
        branch_delete_reason = removal.branch_delete_reason;
        branch_retained_reason = removal.branch_retained_reason;
    }

    if (parsed.hooks) try runMergePostHook(allocator, cfg, "post_merge", &hook_env, stderr);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt merge", .{
            .status = "merged",
            .source = source_branch,
            .target = target_branch,
            .commit = source_head,
            .target_path = merge_dir,
            .removed_path = removed_path,
            .branch_deleted = branch_deleted,
            .branch_delete_reason = branch_delete_reason,
            .branch_retained_reason = branch_retained_reason,
            .navigate_to = merge_dir,
        });
        return 0;
    }

    try stdout.print("Merged {s} into {s} @ {s}\n", .{ source_branch, target_branch, source_head[0..@min(source_head.len, 12)] });
    if (removed_path) |path| {
        try stdout.print("Removed worktree: {s}\n", .{path});
        if (branch_deleted) {
            try stdout.print("Deleted branch: {s} ({s})\n", .{ source_branch, branch_delete_reason orelse "deleted" });
        } else if (branch_retained_reason) |reason| {
            try stdout.print("Kept branch: {s} ({s})\n", .{ source_branch, reason });
        }
    }
    try output.emitNavigateTo(stdout, merge_dir);
    return 0;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--no-remove")) {
            parsed.remove_worktree = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-ff")) {
            parsed.ff_only = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--squash")) {
            parsed.squash = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rebase")) {
            parsed.rebase = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--push")) {
            parsed.push = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-hooks")) {
            parsed.hooks = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len or parsed.message != null) return error.InvalidArguments;
            parsed.message = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.target != null) return error.InvalidArguments;
        parsed.target = arg;
    }
    return parsed;
}

fn currentBranch(allocator: std.mem.Allocator) ![]u8 {
    const branch = try gitOutputTrimmed(allocator, &.{ "git", "branch", "--show-current" });
    if (branch.len == 0) {
        allocator.free(branch);
        return error.DetachedHead;
    }
    return branch;
}

fn repoRoot(allocator: std.mem.Allocator) ![]u8 {
    return gitOutputTrimmed(allocator, &.{ "git", "rev-parse", "--show-toplevel" });
}

fn localBranchExists(allocator: std.mem.Allocator, branch: []const u8) !bool {
    const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(ref);
    var result = try proc.run(allocator, &.{ "git", "show-ref", "--verify", "--quiet", ref });
    defer result.deinit(allocator);
    return result.succeeded();
}

fn mergeInWorktree(
    allocator: std.mem.Allocator,
    path: []const u8,
    source_branch: []const u8,
    ff_only: bool,
    stderr: *std.Io.Writer,
) !bool {
    const merge_flag = if (ff_only) "--ff-only" else "--no-ff";
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "-C", path, "merge", merge_flag });
    if (!ff_only) {
        const message = try std.fmt.allocPrint(allocator, "Merge branch '{s}'", .{source_branch});
        defer allocator.free(message);
        try args.appendSlice(allocator, &.{ "-m", message });
    }
    try args.append(allocator, source_branch);
    const argv = try args.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);
    if (result.succeeded()) return true;
    try writeGitFailure(allocator, stderr, result.trimmedStderr(), "git merge failed");
    return false;
}

fn updateBranchRef(
    allocator: std.mem.Allocator,
    target_branch: []const u8,
    source_branch: []const u8,
    ff_only: bool,
    stderr: *std.Io.Writer,
) !bool {
    if (!ff_only) {
        try stderr.writeAll("--no-ff requires a worktree for the target branch\n");
        return false;
    }
    var ancestor = try proc.run(allocator, &.{ "git", "merge-base", "--is-ancestor", target_branch, source_branch });
    defer ancestor.deinit(allocator);
    if (!ancestor.succeeded()) {
        try stderr.writeAll("target branch is not an ancestor of source; rebase or merge manually first\n");
        return false;
    }
    var result = try proc.run(allocator, &.{ "git", "branch", "-f", target_branch, source_branch });
    defer result.deinit(allocator);
    if (result.succeeded()) return true;
    try writeGitFailure(allocator, stderr, result.trimmedStderr(), "failed to update target branch");
    return false;
}

fn mergeBase(
    allocator: std.mem.Allocator,
    worktree_root: []const u8,
    lhs: []const u8,
    rhs: []const u8,
) ![]u8 {
    var result = try proc.run(allocator, &.{ "git", "-C", worktree_root, "merge-base", lhs, rhs });
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.GitCommandFailed;
    return allocator.dupe(u8, result.trimmedStdout());
}

fn gitQuiet(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stderr: *std.Io.Writer,
    fallback: []const u8,
) !bool {
    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);
    if (result.succeeded()) return true;
    try writeGitFailure(allocator, stderr, result.trimmedStderr(), fallback);
    return false;
}

fn runMergeHook(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    hook_name: []const u8,
    hook_env: *const std.process.EnvMap,
    stderr: *std.Io.Writer,
) !bool {
    hooks.runHooks(allocator, hook_name, hooks.getHooks(cfg, hook_name), hook_env, stderr) catch |err| switch (err) {
        error.HookCommandFailed => return false,
        else => return err,
    };
    return true;
}

fn runMergePostHook(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    hook_name: []const u8,
    hook_env: *const std.process.EnvMap,
    stderr: *std.Io.Writer,
) !void {
    hooks.runHooks(allocator, hook_name, hooks.getHooks(cfg, hook_name), hook_env, stderr) catch {};
}

fn findBranchWorktree(entries: []const worktree.Entry, branch: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |entry_branch| {
            if (std.mem.eql(u8, entry_branch, branch)) return entry;
        }
    }
    return null;
}

fn gitOutputTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.GitCommandFailed;
    return allocator.dupe(u8, result.trimmedStdout());
}

fn emitMergeError(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    message: []const u8,
) !u8 {
    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt merge", message);
    } else {
        try stderr.print("{s}\n", .{message});
    }
    return 1;
}

fn writeGitFailure(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    git_stderr: []const u8,
    fallback: []const u8,
) !void {
    const safe = prompt.sanitizeForTerminal(allocator, git_stderr) catch git_stderr;
    defer if (safe.ptr != git_stderr.ptr) allocator.free(safe);
    if (safe.len == 0) {
        try stderr.print("{s}\n", .{fallback});
    } else {
        try stderr.print("{s}: {s}\n", .{ fallback, safe });
    }
}

test "parseArgs accepts target and flags" {
    const parsed = try parseArgs(&.{ "--no-remove", "--no-ff", "--squash", "--rebase", "--push", "--no-hooks", "--message", "land it", "develop" });
    try std.testing.expect(!parsed.remove_worktree);
    try std.testing.expect(!parsed.ff_only);
    try std.testing.expect(parsed.squash);
    try std.testing.expect(parsed.rebase);
    try std.testing.expect(parsed.push);
    try std.testing.expect(!parsed.hooks);
    try std.testing.expectEqualStrings("land it", parsed.message.?);
    try std.testing.expectEqualStrings("develop", parsed.target.?);
}

test "parseArgs rejects multiple targets" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "main", "develop" }));
}
