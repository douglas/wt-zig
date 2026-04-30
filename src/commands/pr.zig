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
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    return runRemoteCommand(ctx, cfg, args, stdout, stderr, .github);
}

pub fn runRemoteCommand(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
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

    const safe_input = prompt.sanitizeForTerminal(allocator, input) catch input;
    defer if (safe_input.ptr != input.ptr) allocator.free(safe_input);

    const resolved = pr_git.resolveBranchName(allocator, remote_type, input, stderr) catch |err| {
        return emitResolveError(ctx, stdout, stderr, remote_type, safe_input, err);
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
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.writeAll(message);
                try stderr.writeByte('\n');
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, command_name, "pre hook failed");
            } else {
                try stderr.writeAll("pre-");
                try stderr.writeAll(pr_git.commandName(remote_type));
                try stderr.writeAll(" hook failed\n");
            }
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
        try stdout.writeAll("Worktree already exists: ");
        try stdout.writeAll(outcome.path);
        try stdout.writeByte('\n');
        try output.emitNavigateTo(stdout, outcome.path);
        return 0;
    }

    const safe_branch = prompt.sanitizeForTerminal(allocator, resolved.branch) catch resolved.branch;
    defer if (safe_branch.ptr != resolved.branch.ptr) allocator.free(safe_branch);
    try stdout.writeAll(pr_git.label(remote_type));
    try stdout.writeAll(" #");
    try stdout.writeAll(resolved.id);
    try stdout.writeAll(" (");
    try stdout.writeAll(safe_branch);
    try stdout.writeAll(") checked out at: ");
    try stdout.writeAll(outcome.path);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, outcome.path);
    return 0;
}

fn emitResolveError(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    remote_type: pr_git.RemoteType,
    safe_input: []const u8,
    err: anyerror,
) !u8 {
    const allocator = ctx.allocator;
    const command_name = commandName(remote_type);

    switch (err) {
        error.InvalidPullRequestInput => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "invalid {s} number or URL: {s}", .{ pr_git.commandName(remote_type), safe_input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("invalid {s} number or URL: {s}\n", .{ pr_git.commandName(remote_type), safe_input });
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
                const message = try std.fmt.allocPrint(allocator, "failed to look up branch for {s}: {s}", .{ pr_git.label(remote_type), safe_input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("failed to look up branch for {s}: {s}\n", .{ pr_git.label(remote_type), safe_input });
            }
            return 1;
        },
        error.EmptyBranchName => {
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "empty branch name returned for {s}: {s}", .{ pr_git.label(remote_type), safe_input });
                defer allocator.free(message);
                try output.emitError(ctx, stdout, command_name, message);
            } else {
                try stderr.print("empty branch name returned for {s}: {s}\n", .{ pr_git.label(remote_type), safe_input });
            }
            return 1;
        },
        else => return err,
    }
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

test "missing platform cli maps to text errors" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [4096]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const pr_exit = try emitResolveError(
        .{ .allocator = allocator, .format = .text },
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
        .github,
        "123",
        error.MissingPlatformCli,
    );
    const mr_exit = try emitResolveError(
        .{ .allocator = allocator, .format = .text },
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
        .gitlab,
        "456",
        error.MissingPlatformCli,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(1, pr_exit);
    try std.testing.expectEqual(1, mr_exit);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "'gh' CLI not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "'glab' CLI not found") != null);
}

test "missing platform cli maps to json errors" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [4096]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const pr_exit = try emitResolveError(
        .{ .allocator = allocator, .format = .json },
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
        .github,
        "123",
        error.MissingPlatformCli,
    );
    const mr_exit = try emitResolveError(
        .{ .allocator = allocator, .format = .json },
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
        .gitlab,
        "456",
        error.MissingPlatformCli,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(1, pr_exit);
    try std.testing.expectEqual(1, mr_exit);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"command\":\"wt pr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"error\":\"'gh' CLI not found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"command\":\"wt mr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"error\":\"'glab' CLI not found\"") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}
