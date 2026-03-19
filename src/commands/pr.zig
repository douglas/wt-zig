const std = @import("std");
const config = @import("../config.zig");
const checkout = @import("checkout.zig");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");
const pr_git = @import("../git/pr.zig");

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    return runRemoteCommand(ctx, cfg, args, stdout, stderr, .github);
}

pub fn runRemoteCommand(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    remote_type: pr_git.RemoteType,
) !u8 {
    const allocator = ctx.allocator;
    const command_name = commandName(remote_type);
    var input: []const u8 = undefined;
    var owned_input: ?[]u8 = null;
    defer if (owned_input) |value| allocator.free(value);

    switch (args.len) {
        0 => {
            if (output.isJson(ctx)) {
                const message = switch (remote_type) {
                    .github => "wt pr with --format json requires an explicit PR number or URL",
                    .gitlab => "wt mr with --format json requires an explicit MR number or URL",
                };
                try output.emitError(ctx, stdout, command_name, message);
                return 1;
            }

            const items = pr_git.getOpenItems(allocator, remote_type) catch |err| switch (err) {
                error.MissingPlatformCli => {
                    try stderr.print("failed to get {s}: '{s}' CLI not found\n", .{ listLabel(remote_type), cliName(remote_type) });
                    return 1;
                },
                else => {
                    try stderr.print("failed to get {s}\n", .{listLabel(remote_type)});
                    return 1;
                },
            };
            defer pr_git.freeOpenItems(allocator, items);
            if (items.len == 0) {
                try stderr.print("no open {s} found\n", .{listLabel(remote_type)});
                return 1;
            }

            var labels = try allocator.alloc([]const u8, items.len);
            defer allocator.free(labels);
            for (items, 0..) |item, index| labels[index] = item.label;

            const selection = prompt.selectItem(
                allocator,
                if (remote_type == .github) "Select Pull Request" else "Select Merge Request",
                labels,
                stderr,
            ) catch |err| switch (err) {
                error.SelectionCancelled => {
                    try stderr.writeAll("selection cancelled\n");
                    return 1;
                },
                else => {
                    try stderr.writeAll("invalid selection\n");
                    return 1;
                },
            };
            owned_input = try allocator.dupe(u8, items[selection.index].id);
            input = owned_input.?;
        },
        1 => input = args[0],
        else => return output.usageError(ctx, stdout, stderr, command_name, usageText(remote_type)),
    }

    const resolved = pr_git.resolveBranchName(allocator, remote_type, input) catch |err| switch (err) {
        error.InvalidPullRequestInput => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "invalid {s} number or URL: {s}", .{ pr_git.commandName(remote_type), input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("invalid {s} number or URL: {s}\n", .{ pr_git.commandName(remote_type), input });
            }
            return 1;
        },
        error.MissingPlatformCli => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "'{s}' CLI not found", .{cliName(remote_type)});
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("'{s}' CLI not found\n", .{cliName(remote_type)});
            }
            return 1;
        },
        error.PlatformLookupFailed => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "failed to look up branch for {s}: {s}", .{ pr_git.label(remote_type), input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("failed to look up branch for {s}: {s}\n", .{ pr_git.label(remote_type), input });
            }
            return 1;
        },
        error.EmptyBranchName => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "empty branch name returned for {s}: {s}", .{ pr_git.label(remote_type), input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("empty branch name returned for {s}: {s}\n", .{ pr_git.label(remote_type), input });
            }
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
            const message = try std.fmt.allocPrint(allocator, "branch '{s}' does not exist after fetching {s} #{s}", .{
                resolved.branch, pr_git.label(remote_type), resolved.id,
            });
            defer allocator.free(message);
            if (output.isJson(ctx)) try output.emitError(ctx, stdout, command_name, message) else try stderr.print("{s}\n", .{message});
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) try output.emitError(ctx, stdout, command_name, "pre hook failed") else try stderr.print("pre-{s} hook failed\n", .{pr_git.commandName(remote_type)});
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, command_name, .{
            .status = if (outcome.existed) "exists" else "created",
            .id = resolved.id,
            .kind = pr_git.commandName(remote_type),
            .branch = resolved.branch,
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

fn commandName(remote_type: pr_git.RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "wt pr",
        .gitlab => "wt mr",
    };
}

fn usageText(remote_type: pr_git.RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "Usage: wt pr <number|url>",
        .gitlab => "Usage: wt mr <number|url>",
    };
}

fn listLabel(remote_type: pr_git.RemoteType) []const u8 {
    return switch (remote_type) {
        .github => "pull requests",
        .gitlab => "merge requests",
    };
}
