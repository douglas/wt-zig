const std = @import("std");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
const proc = @import("../process.zig");

pub const Action = enum {
    move,
    move_force,
    skip,
};

pub const PlanItem = struct {
    branch: []const u8,
    from: []const u8,
    to: ?[]const u8,
    primary: bool,
    action: Action,
    reason: []const u8 = "",
};

const TargetState = enum {
    missing,
    file,
    dir_empty,
    dir_non_empty,
};

const ResultItem = struct {
    branch: []const u8,
    from: []const u8,
    to: ?[]const u8 = null,
    status: []const u8,
    primary: bool,
    reason: ?[]const u8 = null,
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo: path_mod.RepoInfo,
    entries: []const @import("../git/worktree.zig").Entry,
    env_map: *const std.process.EnvMap,
    force: bool,
) ![]PlanItem {
    const abs_worktree_root = try canonicalPath(allocator, cfg.root);
    defer allocator.free(abs_worktree_root);

    const primary_target = try resolvePrimaryCheckoutTarget(allocator, repo, env_map);
    defer allocator.free(primary_target);

    var plan: std.ArrayList(PlanItem) = .empty;
    errdefer plan.deinit(allocator);

    for (entries, 0..) |entry, index| {
        const from = entry.path;
        const branch_label = entry.branch orelse "<detached>";

        if (index == 0) {
            if (!isPathWithinRoot(allocator, from, abs_worktree_root)) {
                try appendPlanItem(allocator, &plan, .{
                    .branch = branch_label,
                    .from = from,
                    .to = null,
                    .primary = true,
                    .action = .skip,
                    .reason = "primary checkout already outside WORKTREE_ROOT",
                });
                continue;
            }

            if (std.mem.eql(u8, from, primary_target)) {
                try appendPlanItem(allocator, &plan, .{
                    .branch = branch_label,
                    .from = from,
                    .to = from,
                    .primary = true,
                    .action = .skip,
                    .reason = "primary checkout already at target path",
                });
                continue;
            }

            const state = try detectTargetState(primary_target);
            try appendPlanItem(allocator, &plan, planItemForTarget(
                branch_label,
                from,
                primary_target,
                true,
                state,
                force,
            ));
            continue;
        }

        if (entry.detached or entry.branch == null or std.mem.trim(u8, entry.branch.?, " \t").len == 0) {
            try appendPlanItem(allocator, &plan, .{
                .branch = branch_label,
                .from = from,
                .to = null,
                .primary = false,
                .action = .skip,
                .reason = "detached or branchless worktree",
            });
            continue;
        }

        const target_path = try path_mod.renderWorktreePath(allocator, cfg, repo, entry.branch.?, env_map);
        defer allocator.free(target_path);

        if (std.mem.eql(u8, from, target_path)) {
            try appendPlanItem(allocator, &plan, .{
                .branch = branch_label,
                .from = from,
                .to = from,
                .primary = false,
                .action = .skip,
                .reason = "already in configured path",
            });
            continue;
        }

        const state = try detectTargetState(target_path);
        try appendPlanItem(allocator, &plan, planItemForTarget(
            branch_label,
            from,
            target_path,
            false,
            state,
            force,
        ));
    }

    return plan.toOwnedSlice(allocator);
}

pub fn applyPlan(
    ctx: output.Context,
    force: bool,
    plan: []PlanItem,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    var results = std.ArrayList(ResultItem).empty;
    defer results.deinit(allocator);

    var moved: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    for (plan) |item| {
        if (!item.primary) continue;

        switch (item.action) {
            .skip => {
                skipped += 1;
                if (!output.isJson(ctx)) try stdout.print("Skipped primary checkout: {s}\n", .{item.reason});
                try results.append(allocator, .{
                    .branch = item.branch,
                    .from = item.from,
                    .to = item.to,
                    .status = "skipped",
                    .primary = true,
                    .reason = if (item.reason.len == 0) null else item.reason,
                });
            },
            .move, .move_force => {
                movePrimaryCheckout(allocator, item.from, item.to.?, item.action == .move_force, stderr) catch |err| {
                    failed += 1;
                    if (!output.isJson(ctx)) try stdout.print("Failed primary checkout: {s}\n", .{@errorName(err)});
                    try results.append(allocator, .{
                        .branch = item.branch,
                        .from = item.from,
                        .to = item.to,
                        .status = "failed",
                        .primary = true,
                        .reason = @errorName(err),
                    });
                    continue;
                };

                moved += 1;
                if (!output.isJson(ctx)) try stdout.print("Moved primary checkout: {s} -> {s}\n", .{ item.from, item.to.? });
                try results.append(allocator, .{
                    .branch = item.branch,
                    .from = item.from,
                    .to = item.to,
                    .status = "moved",
                    .primary = true,
                    .reason = if (item.reason.len == 0) null else item.reason,
                });
            },
        }
    }

    for (plan) |item| {
        if (item.primary) continue;

        switch (item.action) {
            .skip => {
                skipped += 1;
                if (!output.isJson(ctx)) try stdout.print("Skipped {s}: {s}\n", .{ item.branch, item.reason });
                try results.append(allocator, .{
                    .branch = item.branch,
                    .from = item.from,
                    .to = item.to,
                    .status = "skipped",
                    .primary = false,
                    .reason = if (item.reason.len == 0) null else item.reason,
                });
            },
            .move, .move_force => {
                moveLinkedWorktree(allocator, item.from, item.to.?, item.action == .move_force, stderr) catch |err| {
                    failed += 1;
                    if (!output.isJson(ctx)) try stdout.print("Failed {s}: {s}\n", .{ item.branch, @errorName(err) });
                    try results.append(allocator, .{
                        .branch = item.branch,
                        .from = item.from,
                        .to = item.to,
                        .status = "failed",
                        .primary = false,
                        .reason = @errorName(err),
                    });
                    continue;
                };

                moved += 1;
                if (!output.isJson(ctx)) try stdout.print("Moved {s}: {s} -> {s}\n", .{ item.branch, item.from, item.to.? });
                try results.append(allocator, .{
                    .branch = item.branch,
                    .from = item.from,
                    .to = item.to,
                    .status = "moved",
                    .primary = false,
                    .reason = if (item.reason.len == 0) null else item.reason,
                });
            },
        }
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt migrate", .{
            .force = force,
            .total = plan.len,
            .migrated = moved,
            .skipped = skipped,
            .failed = failed,
            .results = results.items,
        });
    } else {
        try stdout.print("\nMigration complete: {d} moved, {d} skipped, {d} failed\n", .{ moved, skipped, failed });
    }

    if (failed > 0) return 1;
    return 0;
}

pub fn freePlan(allocator: std.mem.Allocator, plan: []PlanItem) void {
    for (plan) |item| {
        if (item.to) |to| allocator.free(to);
    }
    allocator.free(plan);
}

fn appendPlanItem(
    allocator: std.mem.Allocator,
    plan: *std.ArrayList(PlanItem),
    item: PlanItem,
) !void {
    var owned = item;
    if (item.to) |to| {
        owned.to = try allocator.dupe(u8, to);
    }
    try plan.append(allocator, owned);
}

fn planItemForTarget(
    branch: []const u8,
    from: []const u8,
    to: []const u8,
    primary: bool,
    state: TargetState,
    force: bool,
) PlanItem {
    var item = PlanItem{
        .branch = branch,
        .from = from,
        .to = to,
        .primary = primary,
        .action = .move,
    };

    switch (state) {
        .missing => {},
        .dir_empty => item.reason = "target path exists but is empty",
        .dir_non_empty => {
            if (force) {
                item.action = .move_force;
                item.reason = "target path exists and is non-empty (force)";
            } else {
                item.action = .skip;
                item.reason = "target path exists and is non-empty";
            }
        },
        .file => {
            if (force) {
                item.action = .move_force;
                item.reason = "target path exists as file (force)";
            } else {
                item.action = .skip;
                item.reason = "target path exists as file";
            }
        },
    }

    return item;
}

fn movePrimaryCheckout(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
    force: bool,
    stderr: *std.Io.Writer,
) !void {
    try prepareMigrateTarget(allocator, to, force);
    try std.fs.renameAbsolute(from, to);

    var result = try proc.run(allocator, &.{ "git", "-C", to, "worktree", "repair" });
    defer result.deinit(allocator);

    if (result.succeeded()) return;

    const message = result.trimmedStderr();
    if (message.len != 0) {
        try stderr.print("failed to repair worktrees after moving primary checkout: {s}\n", .{message});
    }
    return error.GitCommandFailed;
}

fn moveLinkedWorktree(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
    force: bool,
    stderr: *std.Io.Writer,
) !void {
    try prepareMigrateTarget(allocator, to, force);

    const owned = try allocator.dupe([]const u8, &.{ "git", "worktree", "move", from, to });
    defer allocator.free(owned);

    var result = try proc.run(allocator, owned);
    defer result.deinit(allocator);

    if (result.succeeded()) return;

    const message = result.trimmedStderr();
    if (message.len != 0) {
        try stderr.print("failed to move worktree from {s} to {s}: {s}\n", .{ from, to, message });
    }
    return error.GitCommandFailed;
}

fn prepareMigrateTarget(allocator: std.mem.Allocator, target: []const u8, force: bool) !void {
    switch (try detectTargetState(target)) {
        .missing => {},
        .dir_empty => std.fs.deleteDirAbsolute(target) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        },
        .dir_non_empty => {
            if (!force) return error.TargetPathNonEmpty;
            std.fs.deleteTreeAbsolute(target) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
        .file => {
            if (!force) return error.TargetPathFile;
            std.fs.deleteFileAbsolute(target) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
    }

    const parent = std.fs.path.dirname(target) orelse return error.InvalidRenderedPath;
    try fs.ensureDir(allocator, parent);
}

fn detectTargetState(target: []const u8) !TargetState {
    var dir = std.fs.openDirAbsolute(target, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotDir => return .file,
        else => return err,
    };
    defer dir.close();

    if (try isOpenDirEmpty(&dir)) return .dir_empty;
    return .dir_non_empty;
}

fn isOpenDirEmpty(dir: *std.fs.Dir) !bool {
    var iter = dir.iterate();
    return (try iter.next()) == null;
}

fn resolvePrimaryCheckoutTarget(
    allocator: std.mem.Allocator,
    repo: path_mod.RepoInfo,
    env_map: *const std.process.EnvMap,
) ![]const u8 {
    const home = env_map.get("HOME") orelse return error.MissingHomeDirectory;

    if (repo.owner.len == 0) {
        return std.fs.path.join(allocator, &.{ home, "src", repo.name });
    }

    return std.fs.path.join(allocator, &.{ home, "src", repo.owner, repo.name });
}

fn canonicalPath(allocator: std.mem.Allocator, pathname: []const u8) ![]const u8 {
    const absolute = try std.fs.path.resolve(allocator, &.{pathname});
    errdefer allocator.free(absolute);

    const resolved = std.fs.cwd().realpathAlloc(allocator, absolute) catch return absolute;
    allocator.free(absolute);
    return resolved;
}

fn isPathWithinRoot(allocator: std.mem.Allocator, pathname: []const u8, root: []const u8) bool {
    const canonical_path = canonicalPath(allocator, pathname) catch return false;
    defer allocator.free(canonical_path);

    const rel = std.fs.path.relative(allocator, root, canonical_path) catch return false;
    defer allocator.free(rel);

    if (std.mem.eql(u8, rel, ".")) return true;
    return !std.mem.eql(u8, rel, "..") and
        !std.mem.startsWith(u8, rel, "../") and
        !std.mem.startsWith(u8, rel, "..\\");
}
