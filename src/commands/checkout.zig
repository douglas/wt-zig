const std = @import("std");
const config = @import("../config.zig");
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
    if (args.len != 1) {
        try stderr.writeAll("Usage: wt checkout <branch>\n");
        return 1;
    }

    const branch = args[0];
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

    if (!(try git_repo.branchExists(allocator, branch))) {
        try stderr.print("branch '{s}' does not exist\nUse 'wt create {s}' to create a new branch\n", .{ branch, branch });
        return 1;
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const target_path = try path_mod.buildWorktreePath(allocator, cfg, info, branch, &env_map);
    defer allocator.free(target_path);

    const success = try runGitWorktreeAdd(allocator, target_path, &.{branch}, stderr);
    if (!success) return 1;

    try stdout.print("Worktree created at: {s}\n", .{target_path});
    try stdout.print("wt navigating to: {s}\n", .{target_path});
    return 0;
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
