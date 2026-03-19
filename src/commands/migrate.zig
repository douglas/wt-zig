const std = @import("std");
const config = @import("../config.zig");
const path_mod = @import("../path.zig");
const git_repo = @import("../git/repo.zig");
const worktree = @import("../git/worktree.zig");

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

const ParsedArgs = struct {
    force: bool,
};

pub fn run(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseArgs(args) catch {
        try stderr.writeAll("Usage: wt migrate [--force|-f]\n");
        return 1;
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var info = try git_repo.getRepoInfo(allocator);
    defer freeRepoInfo(allocator, &info);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    const plan = try buildMigratePlan(allocator, cfg, info, listed.entries, &env_map, parsed.force);
    defer freePlan(allocator, plan);

    return applyMigratePlan(allocator, parsed.force, plan, stdout, stderr);
}

pub fn buildMigratePlan(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo: path_mod.RepoInfo,
    entries: []const worktree.Entry,
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

fn applyMigratePlan(
    allocator: std.mem.Allocator,
    force: bool,
    plan: []const PlanItem,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var moved: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    for (plan) |item| {
        if (!item.primary) continue;

        switch (item.action) {
            .skip => {
                skipped += 1;
                try stdout.print("Skipped primary checkout: {s}\n", .{item.reason});
            },
            .move, .move_force => {
                movePrimaryCheckout(allocator, item.from, item.to.?, item.action == .move_force, stderr) catch |err| {
                    failed += 1;
                    try stdout.print("Failed primary checkout: {s}\n", .{@errorName(err)});
                    continue;
                };

                moved += 1;
                try stdout.print("Moved primary checkout: {s} -> {s}\n", .{ item.from, item.to.? });
            },
        }
    }

    for (plan) |item| {
        if (item.primary) continue;

        switch (item.action) {
            .skip => {
                skipped += 1;
                try stdout.print("Skipped {s}: {s}\n", .{ item.branch, item.reason });
            },
            .move, .move_force => {
                moveLinkedWorktree(allocator, item.from, item.to.?, item.action == .move_force, stderr) catch |err| {
                    failed += 1;
                    try stdout.print("Failed {s}: {s}\n", .{ item.branch, @errorName(err) });
                    continue;
                };

                moved += 1;
                try stdout.print("Moved {s}: {s} -> {s}\n", .{ item.branch, item.from, item.to.? });
            },
        }
    }

    try stdout.print(
        "\nMigration complete: {d} moved, {d} skipped, {d} failed\n",
        .{ moved, skipped, failed },
    );

    _ = force;
    if (failed > 0) return 1;
    return 0;
}

fn movePrimaryCheckout(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
    force: bool,
    stderr: anytype,
) !void {
    try prepareMigrateTarget(to, force);
    try std.fs.renameAbsolute(from, to);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", to, "worktree", "repair" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return;

    const message = std.mem.trim(u8, result.stderr, " \r\n\t");
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
    stderr: anytype,
) !void {
    try prepareMigrateTarget(to, force);

    const owned = try allocator.dupe([]const u8, &.{ "git", "worktree", "move", from, to });
    defer allocator.free(owned);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = owned,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return;

    const message = std.mem.trim(u8, result.stderr, " \r\n\t");
    if (message.len != 0) {
        try stderr.print("failed to move worktree from {s} to {s}: {s}\n", .{ from, to, message });
    }
    return error.GitCommandFailed;
}

fn prepareMigrateTarget(target: []const u8, force: bool) !void {
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
    try makePathAbsolute(parent);
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

fn isDirEmpty(pathname: []const u8) !bool {
    var dir = try std.fs.openDirAbsolute(pathname, .{ .iterate = true });
    defer dir.close();

    return isOpenDirEmpty(&dir);
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

fn makePathAbsolute(pathname: []const u8) !void {
    if (!std.fs.path.isAbsolute(pathname)) {
        return std.fs.cwd().makePath(pathname);
    }

    if (pathname.len == 0 or std.mem.eql(u8, pathname, "/")) return;

    var current = std.ArrayList(u8).empty;
    defer current.deinit(std.heap.page_allocator);
    try current.append(std.heap.page_allocator, std.fs.path.sep);

    var parts = std.mem.splitScalar(u8, pathname[1..], std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (current.items.len > 1) {
            try current.append(std.heap.page_allocator, std.fs.path.sep);
        }
        try current.appendSlice(std.heap.page_allocator, part);
        std.fs.makeDirAbsolute(current.items) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
            continue;
        }

        return error.InvalidArguments;
    }

    return .{ .force = force };
}

fn freePlan(allocator: std.mem.Allocator, plan: []PlanItem) void {
    for (plan) |item| {
        if (item.to) |to| allocator.free(to);
    }
    allocator.free(plan);
}

fn freeRepoInfo(allocator: std.mem.Allocator, info: *path_mod.RepoInfo) void {
    allocator.free(info.main);
    allocator.free(info.host);
    allocator.free(info.owner);
    allocator.free(info.name);
}

test "parseArgs accepts force flag" {
    const parsed = try parseArgs(&.{"--force"});
    try std.testing.expect(parsed.force);
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"--wat"}));
}

test "buildMigratePlan moves linked worktree into configured root" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const worktree_root = try std.fs.path.join(allocator, &.{ root, "worktrees" });
    defer allocator.free(worktree_root);
    const main_repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(main_repo);
    const legacy = try std.fs.path.join(allocator, &.{ root, "legacy", "feature-a" });
    defer allocator.free(legacy);

    try std.fs.makeDirAbsolute(worktree_root);

    const cfg = config.Resolved{
        .root = worktree_root,
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{},
        .config_file_path = "/tmp/config.toml",
        .config_file_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };
    const repo = path_mod.RepoInfo{
        .main = main_repo,
        .host = "",
        .owner = "",
        .name = "repo",
    };
    const entries = [_]worktree.Entry{
        .{ .path = main_repo, .branch = "main" },
        .{ .path = legacy, .branch = "feature-a" },
    };

    const plan = try buildMigratePlan(allocator, &cfg, repo, &entries, &env, false);
    defer freePlan(allocator, plan);

    try std.testing.expectEqual(@as(usize, 2), plan.len);
    try std.testing.expect(plan[0].primary);
    try std.testing.expectEqual(Action.skip, plan[0].action);
    try std.testing.expectEqual(Action.move, plan[1].action);
    try std.testing.expectEqualStrings("feature-a", plan[1].branch);
    try std.testing.expectEqualStrings(legacy, plan[1].from);
    const expected = try std.fs.path.join(allocator, &.{ worktree_root, "repo", "feature-a" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, plan[1].to.?);
}

test "buildMigratePlan skips detached worktree and conflicting target without force" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const worktree_root = try std.fs.path.join(allocator, &.{ root, "worktrees" });
    defer allocator.free(worktree_root);
    const main_repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(main_repo);
    const legacy = try std.fs.path.join(allocator, &.{ root, "legacy", "feature-b" });
    defer allocator.free(legacy);
    const target = try std.fs.path.join(allocator, &.{ worktree_root, "repo", "feature-b" });
    defer allocator.free(target);

    try makePathAbsolute(target);
    const conflict = try std.fs.path.join(allocator, &.{ target, "conflict.txt" });
    defer allocator.free(conflict);
    const file = try std.fs.createFileAbsolute(conflict, .{});
    file.close();

    const cfg = config.Resolved{
        .root = worktree_root,
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{},
        .config_file_path = "/tmp/config.toml",
        .config_file_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };
    const repo = path_mod.RepoInfo{
        .main = main_repo,
        .host = "",
        .owner = "",
        .name = "repo",
    };
    const entries = [_]worktree.Entry{
        .{ .path = main_repo, .branch = "main" },
        .{ .path = legacy, .detached = true },
        .{ .path = legacy, .branch = "feature-b" },
    };

    const plan = try buildMigratePlan(allocator, &cfg, repo, &entries, &env, false);
    defer freePlan(allocator, plan);

    try std.testing.expectEqual(Action.skip, plan[1].action);
    try std.testing.expectEqualStrings("detached or branchless worktree", plan[1].reason);
    try std.testing.expectEqual(Action.skip, plan[2].action);
    try std.testing.expectEqualStrings("target path exists and is non-empty", plan[2].reason);
}

test "buildMigratePlan forces primary move when target exists as file" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    try env.put("HOME", home);

    const worktree_root = try std.fs.path.join(allocator, &.{ home, "worktrees" });
    defer allocator.free(worktree_root);
    const primary = try std.fs.path.join(allocator, &.{ worktree_root, "repo" });
    defer allocator.free(primary);
    const target = try std.fs.path.join(allocator, &.{ home, "src", "repo" });
    defer allocator.free(target);

    try makePathAbsolute(primary);
    const target_parent = std.fs.path.dirname(target).?;
    try makePathAbsolute(target_parent);
    const file = try std.fs.createFileAbsolute(target, .{});
    file.close();

    const cfg = config.Resolved{
        .root = worktree_root,
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{},
        .config_file_path = "/tmp/config.toml",
        .config_file_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };
    const repo = path_mod.RepoInfo{
        .main = primary,
        .host = "",
        .owner = "",
        .name = "repo",
    };
    const entries = [_]worktree.Entry{
        .{ .path = primary, .branch = "main" },
    };

    const plan = try buildMigratePlan(allocator, &cfg, repo, &entries, &env, true);
    defer freePlan(allocator, plan);

    try std.testing.expectEqual(Action.move_force, plan[0].action);
    try std.testing.expectEqualStrings("target path exists as file (force)", plan[0].reason);
    try std.testing.expect(plan[0].primary);
}
