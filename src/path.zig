const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");

pub const RepoInfo = struct {
    main: []const u8,
    host: []const u8 = "",
    owner: []const u8 = "",
    name: []const u8,
};

pub const PatternInfo = struct {
    pattern: []const u8,
    source: []const u8,
};

pub fn resolvePattern(cfg: *const config.Resolved) !PatternInfo {
    if (cfg.pattern.len != 0) {
        return .{
            .pattern = cfg.pattern,
            .source = cfg.sources.pattern,
        };
    }

    if (std.mem.eql(u8, cfg.strategy, "custom")) {
        return error.MissingCustomPattern;
    }

    if (std.mem.eql(u8, cfg.strategy, "global")) {
        return .{
            .pattern = "{.worktreeRoot}/{.repo.Name}/{.branch}",
            .source = "strategy default",
        };
    }
    if (std.mem.eql(u8, cfg.strategy, "sibling-repo") or std.mem.eql(u8, cfg.strategy, "sibling")) {
        return .{
            .pattern = "{.repo.Main}/../{.repo.Name}-{.branch}",
            .source = "strategy default",
        };
    }
    if (std.mem.eql(u8, cfg.strategy, "parent-worktrees") or std.mem.eql(u8, cfg.strategy, "parent-centered")) {
        return .{
            .pattern = "{.repo.Main}/../{.repo.Name}.worktrees/{.branch}",
            .source = "strategy default",
        };
    }
    if (std.mem.eql(u8, cfg.strategy, "parent-branches") or std.mem.eql(u8, cfg.strategy, "repo-root")) {
        return .{
            .pattern = "{.repo.Main}/../{.branch}",
            .source = "strategy default",
        };
    }
    if (std.mem.eql(u8, cfg.strategy, "parent-dotdir") or std.mem.eql(u8, cfg.strategy, "local-root")) {
        return .{
            .pattern = "{.repo.Main}/../.worktrees/{.branch}",
            .source = "strategy default",
        };
    }
    if (std.mem.eql(u8, cfg.strategy, "inside-dotdir") or std.mem.eql(u8, cfg.strategy, "nested-local")) {
        return .{
            .pattern = "{.repo.Main}/.worktrees/{.branch}",
            .source = "strategy default",
        };
    }

    return error.UnsupportedStrategy;
}

pub fn renderWorktreePath(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo: RepoInfo,
    branch: []const u8,
    env_map: *const std.process.EnvMap,
) ![]const u8 {
    const pattern_info = try resolvePattern(cfg);
    var rendered = std.ArrayList(u8).empty;
    errdefer rendered.deinit(allocator);

    var index: usize = 0;
    while (index < pattern_info.pattern.len) {
        const start = std.mem.indexOfPos(u8, pattern_info.pattern, index, "{.") orelse {
            try rendered.appendSlice(allocator, pattern_info.pattern[index..]);
            break;
        };

        try rendered.appendSlice(allocator, pattern_info.pattern[index..start]);
        const end = std.mem.indexOfPos(u8, pattern_info.pattern, start, "}") orelse return error.InvalidPattern;
        const token = pattern_info.pattern[start + 2 .. end];
        const value = try resolveToken(allocator, token, cfg, repo, branch, env_map);
        defer allocator.free(value);
        try rendered.appendSlice(allocator, value);
        index = end + 1;
    }

    const raw = try rendered.toOwnedSlice(allocator);
    errdefer allocator.free(raw);

    if (std.fs.path.isAbsolute(raw)) {
        const resolved = try std.fs.path.resolve(allocator, &.{raw});
        allocator.free(raw);
        return resolved;
    }

    const resolved = try std.fs.path.resolve(allocator, &.{ cfg.root, raw });
    allocator.free(raw);
    return resolved;
}

pub fn buildWorktreePath(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo: RepoInfo,
    branch: []const u8,
    env_map: *const std.process.EnvMap,
) ![]const u8 {
    const rendered = try renderWorktreePath(allocator, cfg, repo, branch, env_map);
    errdefer allocator.free(rendered);

    const parent = std.fs.path.dirname(rendered) orelse return error.InvalidRenderedPath;
    try fs.ensureDir(allocator, parent);
    return rendered;
}

pub fn cleanupWorktreePath(allocator: std.mem.Allocator, cfg: *const config.Resolved, worktree_path: []const u8) !void {
    if (worktree_path.len == 0) return;

    std.fs.deleteTreeAbsolute(worktree_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const abs_root = try std.fs.path.resolve(allocator, &.{cfg.root});
    defer allocator.free(abs_root);

    const abs_worktree = try std.fs.path.resolve(allocator, &.{worktree_path});
    defer allocator.free(abs_worktree);

    const parent = std.fs.path.dirname(abs_worktree) orelse return;
    if (!isWithinRoot(abs_root, parent)) return;

    var dir = std.fs.openDirAbsolute(parent, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    if ((try iter.next()) == null) {
        std.fs.deleteDirAbsolute(parent) catch |err| switch (err) {
            error.FileNotFound => {},
            error.DirNotEmpty => {},
            else => return err,
        };
    }
}

fn isWithinRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    if (root.len == 0) return false;
    return root[root.len - 1] == std.fs.path.sep or candidate[root.len] == std.fs.path.sep;
}

fn resolveToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    cfg: *const config.Resolved,
    repo: RepoInfo,
    branch: []const u8,
    env_map: *const std.process.EnvMap,
) ![]const u8 {
    if (std.mem.eql(u8, token, "repo.Main")) return allocator.dupe(u8, repo.main);
    if (std.mem.eql(u8, token, "repo.Name")) return transformValue(allocator, repo.name, cfg.separator);
    if (std.mem.eql(u8, token, "repo.Owner")) return transformValue(allocator, repo.owner, cfg.separator);
    if (std.mem.eql(u8, token, "repo.Host")) return transformValue(allocator, repo.host, cfg.separator);
    if (std.mem.eql(u8, token, "branch")) return transformValue(allocator, std.mem.trim(u8, branch, " \t"), cfg.separator);
    if (std.mem.eql(u8, token, "worktreeRoot")) return allocator.dupe(u8, cfg.root);

    if (std.mem.startsWith(u8, token, "env.")) {
        const key = token["env.".len..];
        const value = env_map.get(key) orelse return error.MissingPatternValue;
        return transformValue(allocator, value, cfg.separator);
    }

    return error.MissingPatternValue;
}

fn transformValue(allocator: std.mem.Allocator, value: []const u8, separator: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (value) |ch| {
        if (ch == '/' or ch == '\\') {
            try result.appendSlice(allocator, separator);
        } else {
            try result.append(allocator, ch);
        }
    }

    return result.toOwnedSlice(allocator);
}

test "resolvePattern covers default strategies" {
    var cfg = config.testing_defaults;
    cfg.strategy = "parent-dotdir";

    const info = try resolvePattern(&cfg);
    try std.testing.expectEqualStrings("{.repo.Main}/../.worktrees/{.branch}", info.pattern);
    try std.testing.expectEqualStrings("strategy default", info.source);
}

test "resolvePattern rejects custom without explicit pattern" {
    var cfg = config.testing_defaults;
    cfg.strategy = "custom";

    try std.testing.expectError(error.MissingCustomPattern, resolvePattern(&cfg));
}

test "renderWorktreePath applies separator and env substitution" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("FEATURE", "team/alpha");

    var cfg = config.testing_defaults;
    cfg.strategy = "custom";
    cfg.pattern = "{.worktreeRoot}/{.env.FEATURE}/{.repo.Name}/{.branch}";
    cfg.separator = "-";
    cfg.sources = .{
        .root = "default",
        .strategy = "default",
        .pattern = "config file",
        .separator = "config file",
    };
    const repo = RepoInfo{
        .main = "/tmp/repo",
        .name = "repo",
    };

    const path = try renderWorktreePath(allocator, &cfg, repo, "feat/test", &env);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/worktrees/team-alpha/repo/feat-test", path);
}

test "renderWorktreePath preserves path-valued fields" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    var cfg = config.testing_defaults;
    cfg.strategy = "custom";
    cfg.pattern = "{.repo.Main}/../{.repo.Name}-{.branch}";
    cfg.separator = "-";
    cfg.sources = .{
        .root = "default",
        .strategy = "default",
        .pattern = "config file",
        .separator = "config file",
    };
    const repo = RepoInfo{
        .main = "/tmp/src/repo",
        .name = "repo",
    };

    const path = try renderWorktreePath(allocator, &cfg, repo, "feat/test", &env);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/src/repo-feat-test", path);
}

test "buildWorktreePath creates parent directories" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const worktree_root = try std.fs.path.join(allocator, &.{ root, "worktrees" });
    defer allocator.free(worktree_root);

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
    const repo = RepoInfo{
        .main = try std.fs.path.join(allocator, &.{ root, "repo" }),
        .name = "repo",
    };
    defer allocator.free(repo.main);

    const path = try buildWorktreePath(allocator, &cfg, repo, "feat/test", &env);
    defer allocator.free(path);

    const repo_dir = try std.fs.path.join(allocator, &.{ worktree_root, "repo" });
    defer allocator.free(repo_dir);
    try std.fs.cwd().access(repo_dir, .{});
}

test "cleanupWorktreePath removes empty parent directory inside root" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const worktree_root = try std.fs.path.join(allocator, &.{ root, "worktrees" });
    defer allocator.free(worktree_root);
    const repo_dir = try std.fs.path.join(allocator, &.{ worktree_root, "repo" });
    defer allocator.free(repo_dir);
    const worktree_path = try std.fs.path.join(allocator, &.{ repo_dir, "feature-a" });
    defer allocator.free(worktree_path);

    try std.fs.makeDirAbsolute(worktree_root);
    try std.fs.makeDirAbsolute(repo_dir);
    try std.fs.makeDirAbsolute(worktree_path);

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

    try cleanupWorktreePath(allocator, &cfg, worktree_path);

    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(repo_dir, .{}));
}
