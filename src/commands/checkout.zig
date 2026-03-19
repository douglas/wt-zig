const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
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
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var branch: []const u8 = undefined;
    var owned_branches: ?[][]u8 = null;
    defer if (owned_branches) |branches| {
        for (branches) |candidate| allocator.free(candidate);
        allocator.free(branches);
    };

    switch (args.len) {
        0 => {
            if (output.isJson()) {
                const message = "wt checkout with --format json requires an explicit branch argument";
                try output.emitError(stdout, "wt checkout", message);
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
        else => return output.usageError(stdout, stderr, "wt checkout", "Usage: wt checkout [branch]"),
    }

    const outcome = checkoutBranch(allocator, cfg, branch, .{}, stderr) catch |err| switch (err) {
        error.BranchDoesNotExist => {
            if (output.isJson()) {
                const message = try std.fmt.allocPrint(allocator, "branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch", .{ branch, branch });
                defer allocator.free(message);
                try output.emitError(stdout, "wt checkout", message);
            } else {
                try stderr.print("branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch\n", .{ branch, branch });
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson()) {
                try output.emitError(stdout, "wt checkout", "pre-checkout hook failed");
            } else {
                try stderr.writeAll("pre-checkout hook failed\n");
            }
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);

    if (output.isJson()) {
        try output.emitSuccess(allocator, stdout, "wt checkout", .{
            .status = if (outcome.existed) "exists" else "created",
            .branch = branch,
            .path = outcome.path,
            .navigate_to = outcome.path,
        });
        return 0;
    }

    if (outcome.existed) {
        try stdout.print("Worktree already exists: {s}\n", .{outcome.path});
        try stdout.print("wt navigating to: {s}\n", .{outcome.path});
        return 0;
    }

    try stdout.print("Worktree created at: {s}\n", .{outcome.path});
    try stdout.print("wt navigating to: {s}\n", .{outcome.path});
    return 0;
}

pub fn checkoutBranch(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    branch: []const u8,
    options: CheckoutOptions,
    stderr: anytype,
) !Outcome {
    var info = try git_repo.getRepoInfo(allocator);
    defer freeRepoInfo(allocator, &info);

    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);
    for (listed.entries) |entry| {
        if (entry.branch) |existing_branch| {
            if (std.mem.eql(u8, existing_branch, branch)) {
                return .{
                    .path = try allocator.dupe(u8, entry.path),
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

    const pre_hook = try std.fmt.allocPrint(allocator, "pre_{s}", .{options.hook_prefix});
    defer allocator.free(pre_hook);
    const post_hook = try std.fmt.allocPrint(allocator, "post_{s}", .{options.hook_prefix});
    defer allocator.free(post_hook);

    var hook_env = try hooks.buildHookEnv(allocator, info, branch, target_path);
    defer hook_env.deinit();

    try hooks.runHooks(allocator, pre_hook, hooks.getHooks(cfg, pre_hook), &hook_env, stderr);

    const success = try runGitWorktreeAdd(allocator, target_path, &.{branch}, stderr);
    if (!success) return error.GitCommandFailed;

    hooks.runHooks(allocator, post_hook, hooks.getHooks(cfg, post_hook), &hook_env, stderr) catch {};

    return .{
        .path = target_path,
        .existed = false,
    };
}

fn fetchBranch(
    allocator: std.mem.Allocator,
    branch: []const u8,
    options: PrefetchOptions,
    stderr: anytype,
) !void {
    const primary = try allocator.dupe([]const u8, &.{ "git", "fetch", "origin", branch });
    defer allocator.free(primary);
    const primary_result = try runGitCommandResult(allocator, primary);
    defer allocator.free(primary_result.stderr);
    defer allocator.free(primary_result.stdout);
    if (primary_result.success) return;

    if (options.refspec) |refspec| {
        const fallback = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ refspec, branch });
        defer allocator.free(fallback);
        const fallback_argv = try allocator.dupe([]const u8, &.{ "git", "fetch", "origin", fallback });
        defer allocator.free(fallback_argv);
        const fallback_result = try runGitCommandResult(allocator, fallback_argv);
        defer allocator.free(fallback_result.stderr);
        defer allocator.free(fallback_result.stdout);
        if (fallback_result.success) return;

        const fallback_message = std.mem.trim(u8, fallback_result.stderr, " \r\n\t");
        if (fallback_message.len != 0) {
            try stderr.print("failed to fetch branch: {s}\n", .{fallback_message});
        }
        return;
    }

    const primary_message = std.mem.trim(u8, primary_result.stderr, " \r\n\t");
    if (primary_message.len != 0) {
        try stderr.print("failed to fetch branch: {s}\n", .{primary_message});
    }
}

fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    path: []const u8,
    trailing_args: []const []const u8,
    stderr: anytype,
) !bool {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "worktree", "add", path });
    try args.appendSlice(allocator, trailing_args);
    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);
    return runGitCommand(owned, "failed to create worktree", stderr);
}

fn runGitCommand(
    argv: []const []const u8,
    failure_prefix: []const u8,
    stderr: anytype,
) !bool {
    const result = try runGitCommandResult(std.heap.page_allocator, argv);
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.success) return true;
    const message = std.mem.trim(u8, result.stderr, " \r\n\t");
    if (message.len != 0) {
        try stderr.print("{s}: {s}\n", .{ failure_prefix, message });
    }
    return false;
}

const GitCommandResult = struct {
    success: bool,
    stdout: []u8,
    stderr: []u8,
};

fn runGitCommandResult(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !GitCommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    return .{
        .success = result.term == .Exited and result.term.Exited == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn freeRepoInfo(allocator: std.mem.Allocator, info: *path_mod.RepoInfo) void {
    allocator.free(info.main);
    allocator.free(info.host);
    allocator.free(info.owner);
    allocator.free(info.name);
}
