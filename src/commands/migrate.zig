const std = @import("std");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const output = @import("../output.zig");
const path_mod = @import("../path.zig");
const git_repo = @import("../git/repo.zig");
const support = @import("migrate_support.zig");
const worktree = @import("../git/worktree.zig");

pub const Action = support.Action;
pub const PlanItem = support.PlanItem;

const ParsedArgs = struct {
    force: bool,
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
        return output.usageError(ctx, stdout, stderr, "wt migrate", "Usage: wt migrate [--force|-f]");
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var info = try git_repo.getRepoInfo(allocator);
    defer git_repo.freeRepoInfo(allocator, &info);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    const plan = try support.buildPlan(allocator, cfg, info, listed.entries, &env_map, parsed.force);
    defer support.freePlan(allocator, plan);

    return support.applyPlan(ctx, parsed.force, plan, stdout, stderr);
}

pub fn buildMigratePlan(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo: path_mod.RepoInfo,
    entries: []const worktree.Entry,
    env_map: *const std.process.EnvMap,
    force: bool,
) ![]PlanItem {
    return support.buildPlan(allocator, cfg, repo, entries, env_map, force);
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
    defer support.freePlan(allocator, plan);

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

    try fs.ensureDir(allocator, target);
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
    defer support.freePlan(allocator, plan);

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

    try fs.ensureDir(allocator, primary);
    const target_parent = std.fs.path.dirname(target).?;
    try fs.ensureDir(allocator, target_parent);
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
    defer support.freePlan(allocator, plan);

    try std.testing.expectEqual(Action.move_force, plan[0].action);
    try std.testing.expectEqualStrings("target path exists as file (force)", plan[0].reason);
    try std.testing.expect(plan[0].primary);
}
