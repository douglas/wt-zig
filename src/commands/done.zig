const std = @import("std");
const config = @import("../config.zig");
const output = @import("../output.zig");
const remove = @import("remove.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

const ParsedArgs = struct {
    force: bool = false,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt done", "Usage: wt done [--force|-f]");
    };

    const cwd = std.process.getCwdAlloc(allocator) catch {
        try stderr.writeAll("failed to get current directory\n");
        return 1;
    };
    defer allocator.free(cwd);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    const current = findCurrentWorktree(listed.entries, cwd) orelse {
        if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt done", "not inside a linked worktree");
        } else {
            try stderr.writeAll("not inside a linked worktree\n");
        }
        return 1;
    };

    const branch = current.branch orelse {
        if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt done", "current worktree has no branch (detached HEAD)");
        } else {
            try stderr.writeAll("current worktree has no branch (detached HEAD)\n");
        }
        return 1;
    };

    const outcome = remove.removeWorktree(allocator, cfg, branch, parsed.force, stderr) catch |err| switch (err) {
        error.CannotRemoveMainWorktree => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt done", "cannot remove the main worktree");
            } else {
                try stderr.writeAll("cannot remove the main worktree\n");
            }
            return 1;
        },
        error.NoSuchWorktree => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt done", "no worktree found for current branch");
            } else {
                try stderr.writeAll("no worktree found for current branch\n");
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt done", "pre-remove hook failed");
            } else {
                try stderr.writeAll("pre-remove hook failed\n");
            }
            return 1;
        },
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);
    defer if (outcome.navigate_to) |nav| allocator.free(nav);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt done", .{
            .status = "removed",
            .branch = branch,
            .path = outcome.path,
            .navigate_to = outcome.navigate_to,
        });
    } else {
        try stdout.print("Removed worktree: {s}\n", .{outcome.path});
        if (outcome.navigate_to) |navigate_to| {
            try stdout.print("wt navigating to: {s}\n", .{navigate_to});
        }
    }
    return 0;
}

fn findCurrentWorktree(entries: []const worktree.Entry, cwd: []const u8) ?worktree.Entry {
    // Skip entry[0] which is the main worktree.
    if (entries.len <= 1) return null;
    for (entries[1..]) |entry| {
        if (isSameOrChildPath(entry.path, cwd)) return entry;
    }
    return null;
}

fn isSameOrChildPath(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }
        return error.InvalidArguments;
    }
    return parsed;
}

test "parseArgs accepts no arguments" {
    const parsed = try parseArgs(&.{});
    try std.testing.expect(!parsed.force);
}

test "parseArgs accepts force flag" {
    const parsed = try parseArgs(&.{"--force"});
    try std.testing.expect(parsed.force);
}

test "parseArgs accepts short force flag" {
    const parsed = try parseArgs(&.{"-f"});
    try std.testing.expect(parsed.force);
}

test "parseArgs rejects positional arguments" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"main"}));
}

test "findCurrentWorktree skips main worktree" {
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/worktrees/feature", .branch = "feature" },
    };
    const result = findCurrentWorktree(&entries, "/repo/subdir");
    try std.testing.expect(result == null);
}

test "findCurrentWorktree matches linked worktree" {
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/worktrees/feature", .branch = "feature" },
    };
    const result = findCurrentWorktree(&entries, "/worktrees/feature/src") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("feature", result.branch.?);
}

test "findCurrentWorktree matches exact path" {
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/worktrees/feature", .branch = "feature" },
    };
    const result = findCurrentWorktree(&entries, "/worktrees/feature") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("feature", result.branch.?);
}

test "findCurrentWorktree returns null when not in any worktree" {
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/worktrees/feature", .branch = "feature" },
    };
    const result = findCurrentWorktree(&entries, "/somewhere/else");
    try std.testing.expect(result == null);
}

test "isSameOrChildPath matches boundaries" {
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo/sub"));
    try std.testing.expect(!isSameOrChildPath("/tmp/repo", "/tmp/repository"));
}
