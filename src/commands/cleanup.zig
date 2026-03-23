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
};

const PlannedWorktree = struct {
    branch: []const u8,
    path: []const u8,
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
        return output.usageError(ctx, stdout, stderr, "wt cleanup", "Usage: wt cleanup [--dry-run] [--force|-f]");
    };

    const base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(base);

    const merged = try git_repo.getMergedBranches(allocator, base);
    defer freeStringSlice(allocator, merged);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    const candidates = try collectCandidates(allocator, listed.entries, merged, base);
    defer allocator.free(candidates);

    if (candidates.len == 0) {
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt cleanup", .{
                .removed = 0,
                .skipped = 0,
                .base = base,
                .worktrees = [_]PlannedWorktree{},
            });
        } else {
            try stdout.writeAll("No worktrees found for merged branches.\n");
        }
        return 0;
    }

    if (output.isJson(ctx) and !parsed.dry_run and !parsed.force) {
        try output.emitError(ctx, stdout, "wt cleanup", "wt cleanup with --format json requires --force or --dry-run");
        return 1;
    }

    if (parsed.dry_run) {
        if (output.isJson(ctx)) {
            var planned = std.ArrayList(PlannedWorktree).empty;
            defer planned.deinit(allocator);
            for (candidates) |entry| {
                try planned.append(allocator, .{
                    .branch = entry.branch.?,
                    .path = entry.path,
                });
            }
            try output.emitSuccess(ctx, stdout, "wt cleanup", .{
                .dry_run = true,
                .base = base,
                .worktrees = planned.items,
            });
            return 0;
        }

        try stdout.print("Would remove {d} worktree(s) for merged branches:\n", .{candidates.len});
        for (candidates) |entry| {
            const safe = prompt.sanitizeForTerminal(allocator, entry.branch.?) catch entry.branch.?;
            defer if (safe.ptr != entry.branch.?.ptr) allocator.free(safe);
            try stdout.print("  - {s} ({s})\n", .{ safe, entry.path });
        }
        return 0;
    }

    var removed_count: usize = 0;
    var skipped_count: usize = 0;
    for (candidates) |entry| {
        const branch = entry.branch.?;
        const safe = prompt.sanitizeForTerminal(allocator, branch) catch branch;
        defer if (safe.ptr != branch.ptr) allocator.free(safe);

        if (!parsed.force) {
            const label = try std.fmt.allocPrint(allocator, "Remove worktree for merged branch '{s}'?", .{safe});
            defer allocator.free(label);

            const confirmed = prompt.confirmPrompt(allocator, label, stderr) catch false;
            if (!confirmed) {
                skipped_count += 1;
                if (!output.isJson(ctx)) {
                    try stdout.print("  Skipped: {s}\n", .{safe});
                }
                continue;
            }
        }

        const outcome = remove.removeWorktree(allocator, cfg, branch, parsed.force, stderr) catch |err| switch (err) {
            error.NoSuchWorktree, error.CannotRemoveMainWorktree => continue,
            error.HookCommandFailed => {
                skipped_count += 1;
                if (!output.isJson(ctx)) try stderr.print("skipped merged branch {s}: pre-remove hook failed\n", .{safe});
                continue;
            },
            error.GitCommandFailed => {
                skipped_count += 1;
                if (!output.isJson(ctx)) try stdout.print("  Failed to remove {s}\n", .{safe});
                continue;
            },
            else => return err,
        };
        defer allocator.free(outcome.path);
        defer if (outcome.navigate_to) |navigate_to| allocator.free(navigate_to);

        removed_count += 1;
        if (!output.isJson(ctx)) {
            try stdout.print("Removed worktree: {s}\n", .{safe});
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

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }

        return error.InvalidArguments;
    }

    return parsed;
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    entries: []const worktree.Entry,
    merged: []const []u8,
    base: []const u8,
) ![]worktree.Entry {
    var candidates: std.ArrayList(worktree.Entry) = .empty;
    errdefer candidates.deinit(allocator);

    for (entries) |entry| {
        const branch = entry.branch orelse continue;
        if (std.mem.eql(u8, branch, base)) continue;
        if (!containsBranch(merged, branch)) continue;
        try candidates.append(allocator, entry);
    }

    return candidates.toOwnedSlice(allocator);
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

test "parseArgs accepts dry run and force" {
    const parsed = try parseArgs(&.{"--dry-run"});
    try std.testing.expect(parsed.dry_run);
    const forced = try parseArgs(&.{"--force"});
    try std.testing.expect(forced.force);
}

test "collectCandidates filters to merged non-base worktrees" {
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

    const candidates = try collectCandidates(allocator, &entries, &merged, "main");
    defer allocator.free(candidates);

    try std.testing.expectEqual(1, candidates.len);
    try std.testing.expectEqualStrings("feat-a", candidates[0].branch.?);
    try std.testing.expectEqualStrings("/repo/.worktrees/feat-a", candidates[0].path);
}
