const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const trash = @import("../trash.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

pub const Outcome = struct {
    path: []const u8,
    navigate_to: ?[]const u8,
    branch_deleted: bool = false,
    branch_delete_reason: ?[]const u8 = null,
    branch_retained_reason: ?[]const u8 = null,
};

pub const BranchCleanupMode = enum {
    delete_if_safe,
    keep,
    force_delete,
};

pub const RemoveOptions = struct {
    force: bool = false,
    branch_cleanup: BranchCleanupMode = .delete_if_safe,
};

const ParsedArgs = struct {
    branches: []const []const u8 = &.{},
    force: bool = false,
    branch_cleanup: BranchCleanupMode = .delete_if_safe,
};

const GumChoice = struct {
    label: []u8,
    value: []u8,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(allocator, args) catch {
        return output.usageError(ctx, stdout, stderr, "wt remove", "Usage: wt remove [branches...] [--force|-f] [--no-delete-branch] [--force-delete|-D]");
    };
    defer allocator.free(parsed.branches);

    var branches = parsed.branches;
    var owned_branches: ?[][]u8 = null;
    defer if (owned_branches) |owned| {
        for (owned) |candidate| allocator.free(candidate);
        allocator.free(owned);
    };
    var owned_selected_branch: ?[]u8 = null;
    defer if (owned_selected_branch) |selected| allocator.free(selected);
    var selected_branches: ?[][]const u8 = null;
    defer if (selected_branches) |selected| allocator.free(selected);

    if (branches.len == 0) {
        if (try currentLinkedWorktreeBranch(allocator, stderr)) |current_branch| {
            owned_selected_branch = current_branch;
            const selected = try allocator.alloc([]const u8, 1);
            selected[0] = current_branch;
            selected_branches = selected;
            branches = selected;
        } else if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt remove", "wt remove with --format json requires a linked worktree or an explicit branch argument");
            return 1;
        } else if (try gumAvailable(allocator)) {
            const selected_branch = chooseRemoveBranchWithGum(allocator, stderr) catch |err| switch (err) {
                error.SelectionCancelled => {
                    try stderr.writeAll("selection cancelled\n");
                    return 1;
                },
                error.GumCommandFailed => {
                    try stderr.writeAll("gum failed while selecting a worktree\n");
                    return 1;
                },
                error.GitCommandFailed => {
                    try stderr.writeAll("failed to get worktrees\n");
                    return 1;
                },
                error.GumNotFound => {
                    try stderr.writeAll("gum is required for this remove UI flow. Install gum and try again.\n");
                    return 1;
                },
                else => return err,
            };
            if (selected_branch == null) {
                try stderr.writeAll("no linked worktrees to remove\n");
                return 1;
            }
            owned_selected_branch = selected_branch.?;

            const safe_branch = prompt.sanitizeForTerminal(allocator, selected_branch.?) catch selected_branch.?;
            defer if (safe_branch.ptr != selected_branch.?.ptr) allocator.free(safe_branch);
            const confirm_message = try std.fmt.allocPrint(allocator, "Remove worktree for branch {s}?", .{safe_branch});
            defer allocator.free(confirm_message);

            const confirmed = gumConfirm(allocator, confirm_message) catch |err| switch (err) {
                error.GumNotFound => {
                    try stderr.writeAll("gum is required for this remove UI flow. Install gum and try again.\n");
                    return 1;
                },
                else => return err,
            };
            if (!confirmed) {
                try stderr.writeAll("selection cancelled\n");
                return 1;
            }

            const selected = try allocator.alloc([]const u8, 1);
            selected[0] = selected_branch.?;
            selected_branches = selected;
            branches = selected;
        } else {
            const worktree_branches = git_repo.getExistingWorktreeBranches(allocator) catch {
                try stderr.writeAll("failed to get worktrees\n");
                return 1;
            };
            owned_branches = worktree_branches;
            if (worktree_branches.len == 0) {
                try stderr.writeAll("no worktrees to remove\n");
                return 1;
            }

            const selection = prompt.selectItem(allocator, "Select worktree to remove", worktree_branches, stderr) catch |err| switch (err) {
                error.SelectionCancelled => {
                    try stderr.writeAll("selection cancelled\n");
                    return 1;
                },
                else => {
                    try stderr.writeAll("invalid selection\n");
                    return 1;
                },
            };
            const selected = try allocator.alloc([]const u8, 1);
            selected[0] = selection.value;
            selected_branches = selected;
            branches = selected;
        }
    }

    const options = RemoveOptions{
        .force = parsed.force,
        .branch_cleanup = parsed.branch_cleanup,
    };

    if (output.isJson(ctx)) {
        const JsonRemoval = struct {
            branch: []const u8,
            path: []const u8,
            navigate_to: ?[]const u8,
            branch_deleted: bool,
            branch_delete_reason: ?[]const u8,
            branch_retained_reason: ?[]const u8,
        };

        var removals = std.ArrayList(JsonRemoval).empty;
        defer removals.deinit(allocator);
        var owned_outcomes = std.ArrayList(Outcome).empty;
        defer {
            for (owned_outcomes.items) |outcome| {
                allocator.free(outcome.path);
                if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);
            }
            owned_outcomes.deinit(allocator);
        }

        for (branches) |branch| {
            const outcome = removeWorktree(allocator, cfg, branch, options, stderr) catch |err| {
                return handleRemoveError(ctx, stdout, stderr, branch, err);
            };
            try owned_outcomes.append(allocator, outcome);
            try removals.append(allocator, .{
                .branch = branch,
                .path = outcome.path,
                .navigate_to = outcome.navigate_to,
                .branch_deleted = outcome.branch_deleted,
                .branch_delete_reason = outcome.branch_delete_reason,
                .branch_retained_reason = outcome.branch_retained_reason,
            });
        }

        if (branches.len == 1) {
            try output.emitSuccess(ctx, stdout, "wt remove", .{
                .status = "removed",
                .branch = removals.items[0].branch,
                .path = removals.items[0].path,
                .navigate_to = removals.items[0].navigate_to,
                .branch_deleted = removals.items[0].branch_deleted,
                .branch_delete_reason = removals.items[0].branch_delete_reason,
                .branch_retained_reason = removals.items[0].branch_retained_reason,
            });
        } else {
            try output.emitSuccess(ctx, stdout, "wt remove", .{
                .status = "removed",
                .removed = removals.items.len,
                .worktrees = removals.items,
            });
        }
    } else {
        for (branches) |branch| {
            const outcome = removeWorktree(allocator, cfg, branch, options, stderr) catch |err| {
                return handleRemoveError(ctx, stdout, stderr, branch, err);
            };
            defer allocator.free(outcome.path);
            defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

            try stdout.writeAll("Removed worktree: ");
            try stdout.writeAll(outcome.path);
            try stdout.writeByte('\n');
            if (outcome.branch_deleted) {
                try stdout.print(
                    "Deleted branch: {s} ({s})\n",
                    .{ branch, outcome.branch_delete_reason orelse "deleted" },
                );
            } else if (outcome.branch_retained_reason) |reason| {
                try stdout.print("Kept branch: {s} ({s})\n", .{ branch, reason });
            }
            if (outcome.navigate_to) |navigate_to| {
                try output.emitNavigateTo(stdout, navigate_to);
            }
        }
    }

    return 0;
}

pub fn removeWorktree(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    branch: []const u8,
    options: RemoveOptions,
    stderr: *std.Io.Writer,
) !Outcome {
    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);

    var info = try git_repo.getRepoInfoWithWorktrees(allocator, listed.entries);
    defer git_repo.freeRepoInfo(allocator, &info);

    const existing = findBranchWorktree(listed.entries, branch) orelse return error.NoSuchWorktree;
    if (std.mem.eql(u8, existing.path, info.main)) return error.CannotRemoveMainWorktree;

    const existing_path = try allocator.dupe(u8, existing.path);
    errdefer allocator.free(existing_path);

    const branch_cleanup = try resolveBranchCleanup(allocator, info.main, branch, options.branch_cleanup);

    var hook_env = try hooks.buildHookEnv(allocator, info, branch, existing_path);
    defer hook_env.deinit();

    try hooks.runHooks(allocator, "pre_remove", hooks.getHooks(cfg, "pre_remove"), &hook_env, stderr);

    const navigate_to = try navigationTarget(allocator, existing_path, info.main);
    errdefer if (navigate_to) |path| allocator.free(path);

    // Fast path: rename to trash (O(1)) then prune git's internal refs.
    // Falls back to synchronous git worktree remove on cross-device rename.
    const used_trash = trashRemove(allocator, existing_path, stderr);
    if (!used_trash) {
        const success = try runGitRemove(allocator, existing_path, options.force, stderr);
        if (!success) return error.GitCommandFailed;
    }

    path_mod.cleanupWorktreePath(allocator, cfg, existing_path) catch |err| {
        try stderr.print(
            "warning: failed to clean removed worktree path {s}: {s}\n",
            .{ existing_path, @errorName(err) },
        );
    };

    hooks.runHooks(allocator, "post_remove", hooks.getHooks(cfg, "post_remove"), &hook_env, stderr) catch {};

    if (branch_cleanup.delete_branch) {
        const deleted = try git_repo.deleteBranch(
            allocator,
            info.main,
            branch,
            options.branch_cleanup == .force_delete,
        );
        if (!deleted) {
            const safe_branch = prompt.sanitizeForTerminal(allocator, branch) catch branch;
            defer if (safe_branch.ptr != branch.ptr) allocator.free(safe_branch);
            try stderr.print("failed to delete branch: {s}\n", .{safe_branch});
            return error.GitCommandFailed;
        }
    }

    return .{
        .path = existing_path,
        .navigate_to = navigate_to,
        .branch_deleted = branch_cleanup.delete_branch,
        .branch_delete_reason = branch_cleanup.delete_reason,
        .branch_retained_reason = branch_cleanup.retained_reason,
    };
}

const BranchCleanupDecision = struct {
    delete_branch: bool = false,
    delete_reason: ?[]const u8 = null,
    retained_reason: ?[]const u8 = null,
};

fn resolveBranchCleanup(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    branch: []const u8,
    mode: BranchCleanupMode,
) !BranchCleanupDecision {
    switch (mode) {
        .keep => return .{
            .retained_reason = git_repo.branchRetainedReasonText(.disabled),
        },
        .force_delete => return .{
            .delete_branch = true,
            .delete_reason = git_repo.branchDeleteReasonText(.force_delete),
        },
        .delete_if_safe => {},
    }

    const default_base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(default_base);

    if (git_repo.isProtectedBranchName(branch, default_base)) {
        return .{
            .retained_reason = git_repo.branchRetainedReasonText(.protected),
        };
    }

    if (try git_repo.safeBranchDeleteReason(allocator, repo_path, branch, default_base)) |reason| {
        return .{
            .delete_branch = true,
            .delete_reason = git_repo.branchDeleteReasonText(reason),
        };
    }

    return .{
        .retained_reason = git_repo.branchRetainedReasonText(.unsafe),
    };
}

/// Try to move the worktree to trash and prune git's metadata. Returns true on
/// success, false if the caller should fall back to `git worktree remove`.
fn trashRemove(allocator: std.mem.Allocator, path: []const u8, stderr: *std.Io.Writer) bool {
    trash.moveToTrash(allocator, path) catch |err| switch (err) {
        error.CrossDevice => return false,
        else => return false,
    };
    // Directory is gone; git worktree prune cleans up the administrative refs.
    var prune_result = proc.run(allocator, &.{ "git", "worktree", "prune" }) catch return true;
    prune_result.deinit(allocator);
    _ = stderr;
    return true;
}

fn findBranchWorktree(entries: []const worktree.Entry, branch: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |entry_branch| {
            if (std.mem.eql(u8, entry_branch, branch)) return entry;
        }
    }

    return null;
}

fn navigationTarget(
    allocator: std.mem.Allocator,
    removed_path: []const u8,
    main_path: []const u8,
) !?[]u8 {
    const cwd = std.process.getCwdAlloc(allocator) catch return null;
    defer allocator.free(cwd);

    if (!isSameOrChildPath(removed_path, cwd)) return null;
    const navigate_to = try allocator.dupe(u8, main_path);
    return navigate_to;
}

fn isSameOrChildPath(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn runGitRemove(allocator: std.mem.Allocator, path: []const u8, force: bool, stderr: *std.Io.Writer) !bool {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "worktree", "remove" });
    if (force) try args.append(allocator, "--force");
    try args.append(allocator, path);
    const argv = try args.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);

    if (result.succeeded()) return true;
    const msg = result.trimmedStderr();
    const safe = prompt.sanitizeForTerminal(allocator, msg) catch msg;
    defer if (safe.ptr != msg.ptr) allocator.free(safe);
    try stderr.print("failed to remove worktree: {s}\n", .{safe});
    return false;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var branches = std.ArrayList([]const u8).empty;
    errdefer branches.deinit(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-delete-branch")) {
            parsed.branch_cleanup = .keep;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force-delete") or std.mem.eql(u8, arg, "-D")) {
            parsed.branch_cleanup = .force_delete;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArguments;
        }
        try branches.append(allocator, arg);
    }

    parsed.branches = try branches.toOwnedSlice(allocator);
    return parsed;
}

fn currentLinkedWorktreeBranch(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !?[]u8 {
    const cwd = std.process.getCwdAlloc(allocator) catch return null;
    defer allocator.free(cwd);

    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);

    if (listed.entries.len <= 1) return null;
    for (listed.entries[1..]) |entry| {
        if (!isSameOrChildPath(entry.path, cwd)) continue;
        const branch = entry.branch orelse return null;
        return try allocator.dupe(u8, branch);
    }
    return null;
}

fn handleRemoveError(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    branch: []const u8,
    err: anyerror,
) !u8 {
    const allocator = ctx.allocator;
    switch (err) {
        error.NoSuchWorktree => {
            const safe_branch = prompt.sanitizeForTerminal(allocator, branch) catch branch;
            defer if (safe_branch.ptr != branch.ptr) allocator.free(safe_branch);
            if (output.isJson(ctx)) {
                const message = try std.fmt.allocPrint(allocator, "no worktree found for branch: {s}", .{safe_branch});
                defer allocator.free(message);
                try output.emitError(ctx, stdout, "wt remove", message);
            } else {
                try stderr.print("no worktree found for branch: {s}\n", .{safe_branch});
            }
            return 1;
        },
        error.CannotRemoveMainWorktree => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt remove", "cannot remove the main worktree");
            } else {
                try stderr.writeAll("cannot remove the main worktree\n");
            }
            return 1;
        },
        error.HookCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt remove", "pre-remove hook failed");
            } else {
                try stderr.writeAll("pre-remove hook failed\n");
            }
            return 1;
        },
        error.GitCommandFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt remove", "git command failed");
            }
            return 1;
        },
        else => return err,
    }
}

fn chooseRemoveBranchWithGum(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !?[]u8 {
    var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
    defer listed.deinit(allocator);

    if (listed.entries.len <= 1) return null;

    var choices = std.ArrayList(GumChoice).empty;
    defer {
        for (choices.items) |choice| {
            allocator.free(choice.label);
            allocator.free(choice.value);
        }
        choices.deinit(allocator);
    }

    for (listed.entries[1..]) |entry| {
        const branch = entry.branch orelse continue;
        const safe_branch = prompt.sanitizeForTerminal(allocator, branch) catch branch;
        defer if (safe_branch.ptr != branch.ptr) allocator.free(safe_branch);
        const safe_path = prompt.sanitizeForTerminal(allocator, entry.path) catch entry.path;
        defer if (safe_path.ptr != entry.path.ptr) allocator.free(safe_path);

        const label = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ safe_branch, safe_path });
        const value = try allocator.dupe(u8, branch);
        try choices.append(allocator, .{ .label = label, .value = value });
    }

    if (choices.items.len == 0) return null;

    const selected = gumChoose(allocator, "Select worktree to remove", choices.items) catch |err| switch (err) {
        error.GumNotFound => return error.GumNotFound,
        else => return err,
    };
    defer if (selected) |value| allocator.free(value);
    if (selected == null) return null;

    for (choices.items) |choice| {
        if (std.mem.eql(u8, choice.label, selected.?)) {
            const branch = try allocator.dupe(u8, choice.value);
            return branch;
        }
    }
    return error.GumCommandFailed;
}

fn gumAvailable(allocator: std.mem.Allocator) !bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gum", "--version" },
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn gumChoose(allocator: std.mem.Allocator, header: []const u8, choices: []const GumChoice) !?[]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "gum", "choose", "--height", "20", "--header", header });
    for (choices) |choice| try argv.append(allocator, choice.label);

    const owned_argv = try argv.toOwnedSlice(allocator);
    defer allocator.free(owned_argv);

    const result = runGumCaptureStdout(allocator, owned_argv) catch |err| switch (err) {
        error.FileNotFound => return error.GumNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);

    return switch (result.term) {
        .Exited => |code| if (code == 0) blk: {
            const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
            if (trimmed.len == 0) break :blk null;
            break :blk try allocator.dupe(u8, trimmed);
        } else if (code == 130)
            error.SelectionCancelled
        else
            error.GumCommandFailed,
        else => error.GumCommandFailed,
    };
}

fn gumConfirm(allocator: std.mem.Allocator, message: []const u8) !bool {
    const result = runGumCaptureStdout(allocator, &.{ "gum", "confirm", message }) catch |err| switch (err) {
        error.FileNotFound => return error.GumNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const GumCaptureResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

fn runGumCaptureStdout(allocator: std.mem.Allocator, argv: []const []const u8) !GumCaptureResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const captured = try child.stdout.?.readToEndAlloc(allocator, 64 * 1024);
    errdefer allocator.free(captured);
    const term = try child.wait();

    return .{
        .term = term,
        .stdout = captured,
    };
}

test "isSameOrChildPath matches boundaries" {
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo/sub"));
    try std.testing.expect(!isSameOrChildPath("/tmp/repo", "/tmp/repository"));
}

test "parseArgs accepts optional force" {
    const allocator = std.testing.allocator;
    const parsed = try parseArgs(allocator, &.{ "--force", "feature" });
    defer allocator.free(parsed.branches);
    try std.testing.expect(parsed.force);
    try std.testing.expectEqual(1, parsed.branches.len);
    try std.testing.expectEqualStrings("feature", parsed.branches[0]);
}

test "parseArgs accepts multiple branches and branch cleanup flags" {
    const allocator = std.testing.allocator;
    const parsed = try parseArgs(allocator, &.{ "feature/a", "feature/b", "--force-delete" });
    defer allocator.free(parsed.branches);

    try std.testing.expectEqual(2, parsed.branches.len);
    try std.testing.expectEqualStrings("feature/a", parsed.branches[0]);
    try std.testing.expectEqualStrings("feature/b", parsed.branches[1]);
    try std.testing.expectEqual(BranchCleanupMode.force_delete, parsed.branch_cleanup);
}

test "parseArgs accepts no-delete-branch" {
    const allocator = std.testing.allocator;
    const parsed = try parseArgs(allocator, &.{"--no-delete-branch"});
    defer allocator.free(parsed.branches);

    try std.testing.expectEqual(BranchCleanupMode.keep, parsed.branch_cleanup);
    try std.testing.expectEqual(0, parsed.branches.len);
}
