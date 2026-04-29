const std = @import("std");
const config = @import("../config.zig");
const git_repo = @import("../git/repo.zig");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const worktree = @import("../git/worktree.zig");
const remove = @import("remove.zig");

const ParsedArgs = struct {
    dry_run: bool = false,
    force: bool = false,
    stale: bool = false,
    stale_days: i64 = 30,
};

const Reason = union(enum) {
    merged,
    remote_deleted,
    inactive_days: i64,
};

const Candidate = struct {
    branch: []const u8,
    path: []const u8,
    reason: Reason,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return output.usageError(
            ctx,
            stdout,
            stderr,
            "wt cleanup",
            "Usage: wt cleanup [--dry-run] [--force|-f] [--stale] [--stale-days <days>]",
        );
    };

    const base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(base);

    const merged = try git_repo.getMergedBranches(allocator, base);
    defer freeStringSlice(allocator, merged);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var candidates = std.ArrayList(Candidate).empty;
    defer candidates.deinit(allocator);

    try collectMergedCandidates(allocator, &candidates, listed.entries, merged, base);
    if (parsed.stale) {
        try appendStaleCandidates(allocator, &candidates, listed.entries, base, parsed.stale_days);
    }

    if (candidates.items.len == 0) {
        if (output.isJson(ctx)) {
            const empty: []const []const u8 = &.{};
            try output.emitSuccess(ctx, stdout, "wt cleanup", .{
                .removed = 0,
                .skipped = 0,
                .base = base,
                .worktrees = empty,
            });
        } else if (parsed.stale) {
            try stdout.writeAll("No worktrees found for merged or stale branches\n");
        } else {
            try stdout.writeAll("No worktrees found for merged branches\n");
        }
        return 0;
    }

    if (output.isJson(ctx) and !parsed.dry_run and !parsed.force) {
        try output.emitError(ctx, stdout, "wt cleanup", "wt cleanup with --format json requires --force or --dry-run");
        return 1;
    }

    if (parsed.dry_run) {
        return emitDryRun(ctx, base, candidates.items, stdout);
    }

    var removed_count: usize = 0;
    var skipped_count: usize = 0;
    for (candidates.items) |candidate| {
        const safe_branch = prompt.sanitizeForTerminal(allocator, candidate.branch) catch candidate.branch;
        defer if (safe_branch.ptr != candidate.branch.ptr) allocator.free(safe_branch);

        var reason_buffer: [64]u8 = undefined;
        const reason = try reasonText(&reason_buffer, candidate.reason);

        if (!parsed.force) {
            const label = try std.fmt.allocPrint(allocator, "Remove worktree for {s} branch '{s}'?", .{ reason, safe_branch });
            defer allocator.free(label);

            const confirmed = prompt.confirmPrompt(allocator, label, stderr) catch false;
            if (!confirmed) {
                skipped_count += 1;
                if (!output.isJson(ctx)) {
                    try stdout.print("  Skipped: {s}\n", .{safe_branch});
                }
                continue;
            }
        }

        const outcome = remove.removeWorktree(allocator, cfg, candidate.branch, .{
            .force = parsed.force,
            .branch_cleanup = .keep,
        }, stderr) catch |err| switch (err) {
            error.NoSuchWorktree, error.CannotRemoveMainWorktree => continue,
            error.HookCommandFailed => {
                skipped_count += 1;
                if (!output.isJson(ctx)) try stderr.print("skipped {s} branch {s}: pre-remove hook failed\n", .{ reason, safe_branch });
                continue;
            },
            error.GitCommandFailed => {
                skipped_count += 1;
                if (!output.isJson(ctx)) try stdout.print("  Failed to remove {s}\n", .{safe_branch});
                continue;
            },
            else => return err,
        };
        defer allocator.free(outcome.path);
        defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

        removed_count += 1;
        if (!output.isJson(ctx)) {
            try stdout.print("Removed worktree: {s} [{s}]\n", .{ safe_branch, reason });
        }
    }

    _ = runGitPrune(allocator) catch {};

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt cleanup", .{
            .dry_run = false,
            .base = base,
            .removed = removed_count,
            .skipped = skipped_count,
        });
        return 0;
    }

    try stdout.print("\nCleanup complete: {d} removed, {d} skipped\n", .{ removed_count, skipped_count });
    return 0;
}

fn emitDryRun(ctx: output.Context, base: []const u8, candidates: []const Candidate, stdout: *std.Io.Writer) !u8 {
    if (output.isJson(ctx)) {
        const JsonCandidate = struct {
            branch: []const u8,
            path: []const u8,
            reason: []const u8,
        };

        var planned = std.ArrayList(JsonCandidate).empty;
        defer planned.deinit(ctx.allocator);
        var owned_reasons = std.ArrayList([]const u8).empty;
        defer {
            for (owned_reasons.items) |value| ctx.allocator.free(value);
            owned_reasons.deinit(ctx.allocator);
        }

        for (candidates) |candidate| {
            const reason = try reasonTextAlloc(ctx.allocator, candidate.reason);
            try owned_reasons.append(ctx.allocator, reason);
            try planned.append(ctx.allocator, .{
                .branch = candidate.branch,
                .path = candidate.path,
                .reason = reason,
            });
        }

        try output.emitSuccess(ctx, stdout, "wt cleanup", .{
            .dry_run = true,
            .base = base,
            .worktrees = planned.items,
        });
        return 0;
    }

    try stdout.print("Would remove {d} worktree(s):\n", .{candidates.len});
    for (candidates) |candidate| {
        const safe = prompt.sanitizeForTerminal(ctx.allocator, candidate.branch) catch candidate.branch;
        defer if (safe.ptr != candidate.branch.ptr) ctx.allocator.free(safe);
        var reason_buffer: [64]u8 = undefined;
        const reason = try reasonText(&reason_buffer, candidate.reason);
        try stdout.print("  - {s} ({s}) [{s}]\n", .{ safe, candidate.path, reason });
    }
    return 0;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stale")) {
            parsed.stale = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stale-days")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.stale_days = try std.fmt.parseInt(i64, args[index], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--stale-days=")) {
            parsed.stale_days = try std.fmt.parseInt(i64, arg["--stale-days=".len..], 10);
            continue;
        }

        return error.InvalidArguments;
    }

    if (parsed.stale_days < 0) return error.InvalidArguments;
    return parsed;
}

fn collectMergedCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    entries: []const worktree.Entry,
    merged: []const []u8,
    base: []const u8,
) !void {
    for (entries) |entry| {
        const branch = entry.branch orelse continue;
        if (std.mem.eql(u8, branch, base)) continue;
        if (!containsBranch(merged, branch)) continue;
        try candidates.append(allocator, .{
            .branch = branch,
            .path = entry.path,
            .reason = .merged,
        });
    }
}

fn appendStaleCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    entries: []const worktree.Entry,
    base: []const u8,
    stale_days: i64,
) !void {
    const remote_output = try getLsRemoteHeadsOutput(allocator);
    defer if (remote_output) |value| allocator.free(value);

    const now_unix = std.time.timestamp();
    for (entries) |entry| {
        const branch = entry.branch orelse continue;
        if (isProtectedBranch(branch, base)) continue;
        if (candidateExists(candidates.items, branch)) continue;

        const remote_deleted = if (remote_output) |text|
            isRemoteBranchDeletedFromOutput(branch, text)
        else
            false;

        const last_commit = try getLastCommitUnixTimestamp(allocator, entry.path);
        const reason = classifyStaleWorktree(branch, remote_deleted, last_commit, stale_days, base, now_unix) orelse continue;
        try candidates.append(allocator, .{
            .branch = branch,
            .path = entry.path,
            .reason = reason,
        });
    }
}

fn isProtectedBranch(branch: []const u8, base: []const u8) bool {
    return std.mem.eql(u8, branch, "main") or
        std.mem.eql(u8, branch, "master") or
        std.mem.eql(u8, branch, base);
}

fn candidateExists(candidates: []const Candidate, branch: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.branch, branch)) return true;
    }
    return false;
}

fn classifyStaleWorktree(
    branch: []const u8,
    remote_deleted: bool,
    last_commit_unix: ?i64,
    stale_days: i64,
    default_base: []const u8,
    now_unix: i64,
) ?Reason {
    if (isProtectedBranch(branch, default_base)) return null;

    if (remote_deleted) return .remote_deleted;

    const last_commit = last_commit_unix orelse return null;
    const age_seconds = now_unix - last_commit;
    if (age_seconds <= 0) return null;
    const age_days = @divFloor(age_seconds, 24 * 60 * 60);
    if (age_days > stale_days) {
        return .{ .inactive_days = age_days };
    }

    return null;
}

fn getLsRemoteHeadsOutput(allocator: std.mem.Allocator) !?[]u8 {
    var result = try proc.run(allocator, &.{ "git", "ls-remote", "--heads", "origin" });
    defer allocator.free(result.stderr);
    if (!result.succeeded()) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn isRemoteBranchDeletedFromOutput(branch: []const u8, ls_remote_output: []const u8) bool {
    if (branch.len == 0) return true;

    var target_buffer: [512]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buffer, "refs/heads/{s}", .{branch}) catch return true;

    var lines = std.mem.splitScalar(u8, ls_remote_output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        const tab_index = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
        if (std.mem.eql(u8, trimmed[tab_index + 1 ..], target)) return false;
    }

    return true;
}

fn getLastCommitUnixTimestamp(allocator: std.mem.Allocator, path: []const u8) !?i64 {
    var result = try proc.run(allocator, &.{ "git", "-C", path, "log", "-1", "--format=%ct" });
    defer result.deinit(allocator);
    if (!result.succeeded()) return null;

    const trimmed = result.trimmedStdout();
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn reasonText(buffer: *[64]u8, reason: Reason) ![]const u8 {
    return switch (reason) {
        .merged => "merged",
        .remote_deleted => "remote deleted",
        .inactive_days => |days| std.fmt.bufPrint(buffer, "inactive ({d} days)", .{days}),
    };
}

fn reasonTextAlloc(allocator: std.mem.Allocator, reason: Reason) ![]const u8 {
    return switch (reason) {
        .merged => allocator.dupe(u8, "merged"),
        .remote_deleted => allocator.dupe(u8, "remote deleted"),
        .inactive_days => |days| std.fmt.allocPrint(allocator, "inactive ({d} days)", .{days}),
    };
}

fn containsBranch(branches: []const []u8, target: []const u8) bool {
    for (branches) |branch| {
        if (std.mem.eql(u8, branch, target)) return true;
    }

    return false;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn runGitPrune(allocator: std.mem.Allocator) !void {
    var result = try proc.run(allocator, &.{ "git", "worktree", "prune" });
    defer result.deinit(allocator);
}

test "containsBranch matches existing branch names" {
    var feat_a = "feat/a".*;
    var feat_b = "feat/b".*;
    const branches = [_][]u8{ &feat_a, &feat_b };
    try std.testing.expect(containsBranch(&branches, "feat/a"));
    try std.testing.expect(!containsBranch(&branches, "feat/c"));
}

test "parseArgs accepts stale and stale-days" {
    const parsed = try parseArgs(&.{ "--stale", "--stale-days", "14", "--dry-run" });
    try std.testing.expect(parsed.stale);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expectEqual(14, parsed.stale_days);
}

test "parseArgs accepts stale-days=value form" {
    const parsed = try parseArgs(&.{"--stale-days=7"});
    try std.testing.expectEqual(7, parsed.stale_days);
}

test "classifyStaleWorktree skips protected branches" {
    try std.testing.expectEqual(@as(?Reason, null), classifyStaleWorktree("main", true, null, 30, "main", std.time.timestamp()));
    try std.testing.expectEqual(@as(?Reason, null), classifyStaleWorktree("master", true, null, 30, "main", std.time.timestamp()));
}

test "classifyStaleWorktree remote deletion takes priority" {
    const reason = classifyStaleWorktree("feat/a", true, null, 30, "main", std.time.timestamp()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(reason) == .remote_deleted);
}

test "collectMergedCandidates filters to merged non-base worktrees" {
    const allocator = std.testing.allocator;
    const entries = [_]worktree.Entry{
        .{ .path = "/repo", .branch = "main" },
        .{ .path = "/repo/.worktrees/feat-a", .branch = "feat-a" },
        .{ .path = "/repo/.worktrees/feat-b", .branch = "feat-b" },
        .{ .path = "/repo/.worktrees/detached", .detached = true },
    };
    var feat_a_str = "feat-a".*;
    var feat_c_str = "feat-c".*;
    const merged = [_][]u8{ &feat_a_str, &feat_c_str };

    var candidates = std.ArrayList(Candidate).empty;
    defer candidates.deinit(allocator);
    try collectMergedCandidates(allocator, &candidates, &entries, &merged, "main");

    try std.testing.expectEqual(1, candidates.items.len);
    try std.testing.expectEqualStrings("feat-a", candidates.items[0].branch);
    try std.testing.expectEqualStrings("/repo/.worktrees/feat-a", candidates.items[0].path);
    try std.testing.expect(std.meta.activeTag(candidates.items[0].reason) == .merged);
}
