const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const path_mod = @import("../path.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len == 0 or args.len > 2) {
        try stderr.writeAll("Usage: wt create <branch> [base-branch]\n");
        return 1;
    }

    const branch = args[0];
    const base = if (args.len == 2) args[1] else try git_repo.getDefaultBase(allocator);
    defer if (args.len != 2) allocator.free(base);

    var info = try git_repo.getRepoInfo(allocator);
    defer freeRepoInfo(allocator, &info);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);
    for (listed.entries) |entry| {
        if (entry.branch) |existing_branch| {
            if (std.mem.eql(u8, existing_branch, branch)) {
                try stdout.print("Worktree already exists: {s}\n", .{entry.path});
                try stdout.print("wt navigating to: {s}\n", .{entry.path});
                return 0;
            }
        }
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const target_path = try path_mod.buildWorktreePath(allocator, cfg, info, branch, &env_map);
    defer allocator.free(target_path);

    var hook_env = try hooks.buildHookEnv(allocator, info, branch, target_path);
    defer hook_env.deinit();

    hooks.runHooks(allocator, "pre_create", hooks.getHooks(cfg, "pre_create"), &hook_env, stderr) catch |err| {
        try stderr.print("pre-create hook failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    const success = try runGitCreate(allocator, target_path, branch, base, stderr);
    if (!success) return 1;

    hooks.runHooks(allocator, "post_create", hooks.getHooks(cfg, "post_create"), &hook_env, stderr) catch {};

    try stdout.print("Worktree created at: {s}\n", .{target_path});
    try stdout.print("wt navigating to: {s}\n", .{target_path});
    return 0;
}

fn runGitCreate(
    allocator: std.mem.Allocator,
    path: []const u8,
    branch: []const u8,
    base: []const u8,
    stderr: anytype,
) !bool {
    const owned = try allocator.dupe([]const u8, &.{ "git", "worktree", "add", path, "-b", branch, base });
    defer allocator.free(owned);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = owned,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return true;
    try stderr.print("failed to create worktree: {s}\n", .{std.mem.trim(u8, result.stderr, " \r\n\t")});
    return false;
}

fn freeRepoInfo(allocator: std.mem.Allocator, info: *path_mod.RepoInfo) void {
    allocator.free(info.main);
    allocator.free(info.host);
    allocator.free(info.owner);
    allocator.free(info.name);
}
