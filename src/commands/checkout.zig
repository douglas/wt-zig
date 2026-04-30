const builtin = @import("builtin");
const std = @import("std");
const config = @import("../config.zig");
const copy_files = @import("../copy_files.zig");
const cow_copy = @import("../cow_copy.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

pub const CheckoutOptions = struct {
    hook_prefix: []const u8 = "checkout",
    prefetch: ?PrefetchOptions = null,
};

pub const PrefetchOptions = struct {
    refspec: ?[]const u8 = null,
};

pub const Outcome = struct {
    path: []const u8,
    existed: bool,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    var branch: []const u8 = undefined;
    var owned_branches: ?[][]u8 = null;
    defer if (owned_branches) |branches| {
        for (branches) |candidate| allocator.free(candidate);
        allocator.free(branches);
    };

    switch (args.len) {
        0 => {
            if (output.isJson(ctx)) {
                const message = "wt checkout with --format json requires an explicit branch argument";
                try output.emitError(ctx, stdout, "wt checkout", message);
                return 1;
            }

            const branches = git_repo.getAvailableBranches(allocator) catch {
                try stderr.writeAll("failed to get branches\n");
                return 1;
            };
            owned_branches = branches;
            if (branches.len == 0) {
                try stderr.writeAll("no available branches to checkout\n");
                return 1;
            }

            const selection = prompt.selectItem(allocator, "Select branch to checkout", branches, stderr) catch |err| switch (err) {
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
        },
        1 => branch = args[0],
        else => return output.usageError(ctx, stdout, stderr, "wt checkout", "Usage: wt checkout [branch]"),
    }

    const outcome = checkoutBranch(allocator, cfg, branch, .{}, stderr) catch |err| switch (err) {
        error.BranchDoesNotExist => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch", .{ branch, branch });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, "wt checkout", message);
            } else {
                try stderr.print("branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch\n", .{ branch, branch });
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt checkout", "pre-checkout hook failed");
            } else {
                try stderr.writeAll("pre-checkout hook failed\n");
            }
            return 1;
        },
        error.StartHookFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt checkout", "pre-start hook failed");
            } else {
                try stderr.writeAll("pre-start hook failed\n");
            }
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt checkout", .{
            .status = if (outcome.existed) "exists" else "created",
            .branch = branch,
            .path = outcome.path,
            .navigate_to = outcome.path,
        });
        return 0;
    }

    if (outcome.existed) {
        try stdout.writeAll("Worktree already exists: ");
        try stdout.writeAll(outcome.path);
        try stdout.writeByte('\n');
        try output.emitNavigateTo(stdout, outcome.path);
        return 0;
    }

    try stdout.writeAll("Worktree created at: ");
    try stdout.writeAll(outcome.path);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, outcome.path);
    return 0;
}

pub fn checkoutBranch(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    branch: []const u8,
    options: CheckoutOptions,
    stderr: *std.Io.Writer,
) !Outcome {
    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);

    var info = try git_repo.getRepoInfoWithWorktrees(allocator, listed.entries);
    defer git_repo.freeRepoInfo(allocator, &info);

    const pre_hook = try std.fmt.allocPrint(allocator, "pre_{s}", .{options.hook_prefix});
    defer allocator.free(pre_hook);
    const post_hook = try std.fmt.allocPrint(allocator, "post_{s}", .{options.hook_prefix});
    defer allocator.free(post_hook);

    for (listed.entries) |entry| {
        if (entry.branch) |existing_branch| {
            if (std.mem.eql(u8, existing_branch, branch)) {
                const existing_path = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(existing_path);

                var existing_hook_env = try hooks.buildHookEnv(allocator, info, branch, existing_path);
                defer existing_hook_env.deinit();

                try hooks.runApprovedHooks(allocator, cfg, pre_hook, hooks.getHooks(cfg, pre_hook), &existing_hook_env, stderr);
                hooks.runApprovedHooks(allocator, cfg, post_hook, hooks.getHooks(cfg, post_hook), &existing_hook_env, stderr) catch {};

                return .{
                    .path = existing_path,
                    .existed = true,
                };
            }
        }
    }

    if (options.prefetch) |prefetch| {
        try fetchBranch(allocator, branch, prefetch, stderr);
    }

    if (!(try git_repo.branchExists(allocator, branch))) {
        return error.BranchDoesNotExist;
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const target_path = try path_mod.buildWorktreePath(allocator, cfg, info, branch, &env_map);
    errdefer allocator.free(target_path);

    var hook_env = try hooks.buildHookEnv(allocator, info, branch, target_path);
    defer hook_env.deinit();

    try hooks.runApprovedHooks(allocator, cfg, pre_hook, hooks.getHooks(cfg, pre_hook), &hook_env, stderr);

    const success = try runGitWorktreeAdd(allocator, target_path, &.{branch}, stderr);
    if (!success) return error.GitCommandFailed;

    copy_files.copyFiles(allocator, cfg, info.name, info.main, target_path, stderr);

    // Warm the OS page/metadata cache in the background so subsequent tool
    // calls (grep, find, git status) are served from memory immediately.
    if (!builtin.single_threaded) {
        if (std.Thread.spawn(.{}, cow_copy.warmDiskCache, .{target_path})) |t| t.detach() else |_| {}
    }

    hooks.runApprovedHooks(allocator, cfg, post_hook, hooks.getHooks(cfg, post_hook), &hook_env, stderr) catch {};

    hooks.runStartHooks(allocator, cfg, info, branch, target_path, stderr) catch |err| switch (err) {
        error.HookCommandFailed => return error.StartHookFailed,
        else => return err,
    };

    return .{
        .path = target_path,
        .existed = false,
    };
}

fn fetchBranch(
    allocator: std.mem.Allocator,
    branch: []const u8,
    options: PrefetchOptions,
    stderr: *std.Io.Writer,
) !void {
    const primary = try allocator.dupe([]const u8, &.{ "git", "fetch", "origin", branch });
    defer allocator.free(primary);
    var primary_result = try runGitCommandResult(allocator, primary);
    defer primary_result.deinit(allocator);
    if (primary_result.succeeded()) return;

    if (options.refspec) |refspec| {
        const fallback = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ refspec, branch });
        defer allocator.free(fallback);
        const fallback_argv = try allocator.dupe([]const u8, &.{ "git", "fetch", "origin", fallback });
        defer allocator.free(fallback_argv);
        var fallback_result = try runGitCommandResult(allocator, fallback_argv);
        defer fallback_result.deinit(allocator);
        if (fallback_result.succeeded()) return;

        const fallback_message = fallback_result.trimmedStderr();
        if (fallback_message.len != 0) {
            const safe = prompt.sanitizeForTerminal(allocator, fallback_message) catch fallback_message;
            defer if (safe.ptr != fallback_message.ptr) allocator.free(safe);
            try stderr.print("failed to fetch branch: {s}\n", .{safe});
        }
        return;
    }

    const primary_message = primary_result.trimmedStderr();
    if (primary_message.len != 0) {
        const safe = prompt.sanitizeForTerminal(allocator, primary_message) catch primary_message;
        defer if (safe.ptr != primary_message.ptr) allocator.free(safe);
        try stderr.print("failed to fetch branch: {s}\n", .{safe});
    }
}

fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    path: []const u8,
    trailing_args: []const []const u8,
    stderr: *std.Io.Writer,
) !bool {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "worktree", "add", path, "--" });
    try args.appendSlice(allocator, trailing_args);
    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);
    return runGitCommand(allocator, owned, "failed to create worktree", stderr);
}

fn runGitCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    failure_prefix: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    const result = try runGitCommandResult(allocator, argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.succeeded()) return true;
    const message = result.trimmedStderr();
    if (message.len != 0) {
        const safe = prompt.sanitizeForTerminal(allocator, message) catch message;
        defer if (safe.ptr != message.ptr) allocator.free(safe);
        try stderr.writeAll(failure_prefix);
        try stderr.writeAll(": ");
        try stderr.writeAll(safe);
        try stderr.writeByte('\n');
    }
    return false;
}

const GitCommandResult = proc.Captured;

fn runGitCommandResult(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !GitCommandResult {
    return proc.run(allocator, argv);
}
