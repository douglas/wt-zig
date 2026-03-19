const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const path_mod = @import("../path.zig");
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
    if (args.len != 1) {
        try stderr.writeAll("Usage: wt checkout <branch>\n");
        return 1;
    }

    const outcome = checkoutBranch(allocator, cfg, args[0], .{}, stderr) catch |err| switch (err) {
        error.BranchDoesNotExist => {
            try stderr.print("branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch\n", .{ args[0], args[0] });
            return 1;
        },
        error.HookCommandFailed => {
            try stderr.writeAll("pre-checkout hook failed\n");
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);

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
    const fetch_branch = try runGitCommand(primary, "failed to fetch branch", stderr);
    if (fetch_branch) return;

    if (options.refspec) |refspec| {
        const fallback = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ refspec, branch });
        defer allocator.free(fallback);
        const fallback_argv = try allocator.dupe([]const u8, &.{ "git", "fetch", "origin", fallback });
        defer allocator.free(fallback_argv);
        _ = try runGitCommand(fallback_argv, "failed to fetch branch", stderr);
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
    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = argv,
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return true;
    const message = std.mem.trim(u8, result.stderr, " \r\n\t");
    if (message.len != 0) {
        try stderr.print("{s}: {s}\n", .{ failure_prefix, message });
    }
    return false;
}

fn freeRepoInfo(allocator: std.mem.Allocator, info: *path_mod.RepoInfo) void {
    allocator.free(info.main);
    allocator.free(info.host);
    allocator.free(info.owner);
    allocator.free(info.name);
}
