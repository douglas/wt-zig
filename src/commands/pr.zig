const std = @import("std");
const config = @import("../config.zig");
const checkout = @import("checkout.zig");
const pr_git = @import("../git/pr.zig");

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    return runRemoteCommand(allocator, cfg, args, stdout, stderr, .github);
}

pub fn runRemoteCommand(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    remote_type: pr_git.RemoteType,
) !u8 {
    if (args.len != 1) {
        try stderr.print("Usage: wt {s} <number|url>\n", .{pr_git.commandName(remote_type)});
        return 1;
    }

    const resolved = pr_git.resolveBranchName(allocator, remote_type, args[0]) catch |err| switch (err) {
        error.InvalidPullRequestInput => {
            try stderr.print("invalid {s} number or URL: {s}\n", .{ pr_git.commandName(remote_type), args[0] });
            return 1;
        },
        error.MissingPlatformCli => {
            try stderr.print("'{s}' CLI not found\n", .{cliName(remote_type)});
            return 1;
        },
        error.PlatformLookupFailed => {
            try stderr.print("failed to look up branch for {s}: {s}\n", .{ pr_git.label(remote_type), args[0] });
            return 1;
        },
        error.EmptyBranchName => {
            try stderr.print("empty branch name returned for {s}: {s}\n", .{ pr_git.label(remote_type), args[0] });
            return 1;
        },
        else => return err,
    };
    defer allocator.free(resolved.id);
    defer allocator.free(resolved.branch);

    const refspec = try pr_git.fallbackRefspec(allocator, remote_type, resolved.id);
    defer allocator.free(refspec);

    const outcome = checkout.checkoutBranch(
        allocator,
        cfg,
        resolved.branch,
        .{
            .hook_prefix = pr_git.commandName(remote_type),
            .prefetch = .{ .refspec = refspec },
        },
        stderr,
    ) catch |err| switch (err) {
        error.BranchDoesNotExist => {
            try stderr.print("branch '{s}' does not exist after fetching {s} #{s}\n", .{
                resolved.branch,
                pr_git.label(remote_type),
                resolved.id,
            });
            return 1;
        },
        error.HookCommandFailed => {
            try stderr.print("pre-{s} hook failed\n", .{pr_git.commandName(remote_type)});
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

    try stdout.print("{s} #{s} ({s}) checked out at: {s}\n", .{
        pr_git.label(remote_type),
        resolved.id,
        resolved.branch,
        outcome.path,
    });
    try stdout.print("wt navigating to: {s}\n", .{outcome.path});
    return 0;
}

fn cliName(remote_type: pr_git.RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "gh",
        .gitlab => "glab",
    };
}
