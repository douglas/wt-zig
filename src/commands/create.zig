const std = @import("std");
const config = @import("../config.zig");
const copy_files = @import("../copy_files.zig");
const cow_copy = @import("../cow_copy.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const git_repo = @import("../git/repo.zig");
const path_mod = @import("../path.zig");
const worktree = @import("../git/worktree.zig");

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    if (args.len == 0 or args.len > 2) {
        return output.usageError(ctx, stdout, stderr, "wt create", "Usage: wt create <branch> [base-branch]");
    }

    const branch = args[0];
    const base = if (args.len == 2) args[1] else try git_repo.getDefaultBase(allocator);
    defer if (args.len != 2) allocator.free(base);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var info = try git_repo.getRepoInfoWithWorktrees(allocator, listed.entries);
    defer git_repo.freeRepoInfo(allocator, &info);
    for (listed.entries) |entry| {
        if (entry.branch) |existing_branch| {
            if (std.mem.eql(u8, existing_branch, branch)) {
                if (output.isJson(ctx)) {
                    try output.emitSuccess(ctx, stdout, "wt create", .{
                        .status = "exists",
                        .branch = branch,
                        .base = base,
                        .path = entry.path,
                        .navigate_to = entry.path,
                    });
                } else {
                    try stdout.writeAll("Worktree already exists: ");
                    try stdout.writeAll(entry.path);
                    try stdout.writeByte('\n');
                    try output.emitNavigateTo(stdout, entry.path);
                }
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
        if (output.isJson(ctx)) {
            output.emitError(ctx, stdout, "wt create", "pre-create hook failed") catch {};
        } else {
            stderr.writeAll("pre-create hook failed: ") catch {};
            stderr.writeAll(@errorName(err)) catch {};
            stderr.writeByte('\n') catch {};
        }
        return 1;
    };

    const success = try runGitCreate(allocator, target_path, branch, base, stderr);
    if (!success) return 1;

    copy_files.copyFiles(allocator, cfg, info.name, info.main, target_path, stderr);

    // Warm the OS page/metadata cache in the background so subsequent tool
    // calls (grep, find, git status) are served from memory immediately.
    if (std.Thread.spawn(.{}, cow_copy.warmDiskCache, .{target_path})) |t| t.detach() else |_| {}

    hooks.runHooks(allocator, "post_create", hooks.getHooks(cfg, "post_create"), &hook_env, stderr) catch {};

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt create", .{
            .status = "created",
            .branch = branch,
            .base = base,
            .path = target_path,
            .navigate_to = target_path,
        });
    } else {
        try stdout.writeAll("Worktree created at: ");
        try stdout.writeAll(target_path);
        try stdout.writeByte('\n');
        try output.emitNavigateTo(stdout, target_path);
    }
    return 0;
}

fn runGitCreate(
    allocator: std.mem.Allocator,
    path: []const u8,
    branch: []const u8,
    base: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    const owned = try allocator.dupe([]const u8, &.{ "git", "worktree", "add", path, "-b", branch, "--", base });
    defer allocator.free(owned);

    var result = try proc.run(allocator, owned);
    defer result.deinit(allocator);

    if (result.succeeded()) return true;
    const msg = result.trimmedStderr();
    const safe = prompt.sanitizeForTerminal(allocator, msg) catch msg;
    defer if (safe.ptr != msg.ptr) allocator.free(safe);
    try stderr.print("failed to create worktree: {s}\n", .{safe});
    return false;
}
