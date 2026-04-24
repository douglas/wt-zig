const std = @import("std");
const fs = @import("fs.zig");
const support = @import("config_support.zig");
const types = @import("config_types.zig");

pub const Hooks = types.Hooks;
pub const CopyFiles = types.CopyFiles;
pub const CopyFilesRepoOverride = types.CopyFilesRepoOverride;
pub const Sources = types.Sources;
pub const Resolved = types.Resolved;
pub const LoadResult = types.LoadResult;
pub const Options = types.Options;
pub const testing_defaults = types.testing_defaults;
pub const ParsedFile = support.ParsedFile;
pub const default_config_template = support.default_config_template;
pub const resolveConfigPath = support.resolveConfigPath;
pub const writeDefaultConfig = support.writeDefaultConfig;
pub const configDir = support.configDir;
pub const parseFile = support.parseFile;

pub fn load(allocator: std.mem.Allocator, options: Options) !LoadResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    var owned_env: ?std.process.EnvMap = null;
    defer if (owned_env) |*env| env.deinit();

    const env_map = options.env_map orelse blk: {
        owned_env = try std.process.getEnvMap(arena_allocator);
        break :blk &owned_env.?;
    };

    const home = env_map.get("HOME") orelse return error.MissingHomeDirectory;
    const default_root = try std.fs.path.join(arena_allocator, &.{ home, "dev", "worktrees" });
    const config_path = try support.resolveConfigPath(arena_allocator, env_map, options.cli_config_path);

    var resolved = Resolved{
        .root = default_root,
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{},
        .config_file_path = config_path,
        .config_file_found = false,
        .config_repo_path = "",
        .config_repo_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };

    if (fs.fileExists(config_path) and isRegularFile(config_path)) {
        resolved.config_file_found = true;
        const parsed = try support.parseFile(arena_allocator, config_path);
        try applyParsedFile(arena_allocator, &resolved, parsed, home);
    }

    try applyRepoConfig(arena_allocator, &resolved);

    try applyEnvOverrides(arena_allocator, &resolved, env_map);

    return .{
        .arena = arena,
        .resolved = resolved,
    };
}

fn applyParsedFile(
    allocator: std.mem.Allocator,
    resolved: *Resolved,
    parsed: ParsedFile,
    home: []const u8,
) !void {
    if (parsed.root) |value| {
        resolved.root = try expandHome(allocator, value, home);
        resolved.sources.root = "config file";
    }
    if (parsed.strategy) |value| {
        resolved.strategy = try asciiLowerAlloc(allocator, value);
        resolved.sources.strategy = "config file";
    }
    if (parsed.pattern) |value| {
        resolved.pattern = try allocator.dupe(u8, value);
        resolved.sources.pattern = "config file";
    }
    if (parsed.separator) |value| {
        resolved.separator = try allocator.dupe(u8, value);
        resolved.sources.separator = "config file";
    }

    resolved.hooks = parsed.hooks;
    resolved.copy_files = parsed.copy_files;
}

fn applyEnvOverrides(
    allocator: std.mem.Allocator,
    resolved: *Resolved,
    env_map: *const std.process.EnvMap,
) !void {
    if (env_map.get("WORKTREE_ROOT")) |value| {
        resolved.root = try allocator.dupe(u8, value);
        resolved.sources.root = "env: WORKTREE_ROOT";
    }
    if (env_map.get("WORKTREE_STRATEGY")) |value| {
        resolved.strategy = try asciiLowerAlloc(allocator, value);
        resolved.sources.strategy = "env: WORKTREE_STRATEGY";
    }
    if (env_map.get("WORKTREE_PATTERN")) |value| {
        resolved.pattern = try allocator.dupe(u8, value);
        resolved.sources.pattern = "env: WORKTREE_PATTERN";
    }
    if (env_map.get("WORKTREE_SEPARATOR")) |value| {
        resolved.separator = try allocator.dupe(u8, value);
        resolved.sources.separator = "env: WORKTREE_SEPARATOR";
    }
}

fn applyRepoConfig(
    allocator: std.mem.Allocator,
    resolved: *Resolved,
) !void {
    const repo_root = gitRepoRoot(allocator) catch {
        resolved.config_repo_path = "";
        resolved.config_repo_found = false;
        return;
    };

    const repo_config_path = try std.fs.path.join(allocator, &.{ repo_root, ".wt.toml" });
    resolved.config_repo_path = repo_config_path;
    resolved.config_repo_found = false;

    if (!fs.fileExists(repo_config_path) or !isRegularFile(repo_config_path)) {
        return;
    }

    resolved.config_repo_found = true;
    const parsed = try support.parseFile(allocator, repo_config_path);

    if (parsed.strategy) |value| {
        resolved.strategy = try asciiLowerAlloc(allocator, value);
        resolved.sources.strategy = "repo config";
    }
    if (parsed.pattern) |value| {
        resolved.pattern = try allocator.dupe(u8, value);
        resolved.sources.pattern = "repo config";
    }
    if (parsed.separator) |value| {
        resolved.separator = try allocator.dupe(u8, value);
        resolved.sources.separator = "repo config";
    }

    mergeHooks(&resolved.hooks, parsed.hooks);
}

fn mergeHooks(base: *Hooks, overrides: Hooks) void {
    if (overrides.pre_create.len > 0) base.pre_create = overrides.pre_create;
    if (overrides.post_create.len > 0) base.post_create = overrides.post_create;
    if (overrides.pre_checkout.len > 0) base.pre_checkout = overrides.pre_checkout;
    if (overrides.post_checkout.len > 0) base.post_checkout = overrides.post_checkout;
    if (overrides.pre_remove.len > 0) base.pre_remove = overrides.pre_remove;
    if (overrides.post_remove.len > 0) base.post_remove = overrides.post_remove;
    if (overrides.pre_pr.len > 0) base.pre_pr = overrides.pre_pr;
    if (overrides.post_pr.len > 0) base.post_pr = overrides.post_pr;
    if (overrides.pre_mr.len > 0) base.pre_mr = overrides.pre_mr;
    if (overrides.post_mr.len > 0) base.post_mr = overrides.post_mr;
}

fn gitRepoRoot(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.NotInGitRepository;
        },
        else => return error.NotInGitRepository,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return error.NotInGitRepository;
    return allocator.dupe(u8, trimmed);
}

/// Security: verify the config file is a regular file to prevent hangs on FIFOs,
/// device nodes, or other special files (e.g., --config /dev/stdin).
fn isRegularFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

fn expandHome(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) return std.mem.concat(allocator, u8, &.{ home, path[1..] });
    return allocator.dupe(u8, path);
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const buffer = try allocator.dupe(u8, input);
    for (buffer) |*ch| ch.* = std.ascii.toLower(ch.*);
    return buffer;
}

test "resolveConfigPath prefers flag then env then default" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("WT_CONFIG", "/env/config.toml");
    try env.put("XDG_CONFIG_HOME", "/xdg");

    const flag_path = try resolveConfigPath(std.testing.allocator, &env, "/flag/config.toml");
    defer std.testing.allocator.free(flag_path);
    try std.testing.expectEqualStrings("/flag/config.toml", flag_path);

    const env_path = try resolveConfigPath(std.testing.allocator, &env, null);
    defer std.testing.allocator.free(env_path);
    try std.testing.expectEqualStrings("/env/config.toml", env_path);

    env.remove("WT_CONFIG");
    const default_path = try resolveConfigPath(std.testing.allocator, &env, null);
    defer std.testing.allocator.free(default_path);
    try std.testing.expectEqualStrings("/xdg/wt/config.toml", default_path);
}

test "parseFile reads scalar settings and hooks" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\root = "~/worktrees"
        \\strategy = "SIBLING-REPO"
        \\pattern = "{.repo.Main}/../{.branch}"
        \\separator = "-"
        \\
        \\[hooks]
        \\post_create = ["echo one", "echo two"]
        \\pre_remove = ["cleanup"]
        \\
        ,
    });

    const config_path = try dir.dir.realpathAlloc(allocator, "config.toml");
    defer allocator.free(config_path);

    var parsed = try parseFile(allocator, config_path);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("~/worktrees", parsed.root.?);
    try std.testing.expectEqualStrings("SIBLING-REPO", parsed.strategy.?);
    try std.testing.expectEqualStrings("-", parsed.separator.?);
    try std.testing.expectEqual(2, parsed.hooks.post_create.len);
    try std.testing.expectEqualStrings("cleanup", parsed.hooks.pre_remove[0]);
}

test "parseFile reads copy_files with global and per-repo paths" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\root = "~/worktrees"
        \\
        \\[copy_files]
        \\paths = [".env", "config/local.yml"]
        \\dirs = ["node_modules", "target"]
        \\strategy = "rsync"
        \\
        \\[copy_files.campaigns]
        \\paths = [".env.local", ".env.test.local"]
        \\
        \\[copy_files.other-repo]
        \\paths = ["secrets.yml"]
        \\
        ,
    });

    const config_path = try dir.dir.realpathAlloc(allocator, "config.toml");
    defer allocator.free(config_path);

    var parsed = try parseFile(allocator, config_path);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(2, parsed.copy_files.paths.len);
    try std.testing.expectEqualStrings(".env", parsed.copy_files.paths[0]);
    try std.testing.expectEqualStrings("config/local.yml", parsed.copy_files.paths[1]);

    try std.testing.expectEqual(2, parsed.copy_files.dirs.len);
    try std.testing.expectEqualStrings("node_modules", parsed.copy_files.dirs[0]);
    try std.testing.expectEqualStrings("target", parsed.copy_files.dirs[1]);

    try std.testing.expectEqualStrings("rsync", parsed.copy_files.strategy.?);

    try std.testing.expectEqual(2, parsed.copy_files.repo_overrides.len);

    try std.testing.expectEqualStrings("campaigns", parsed.copy_files.repo_overrides[0].repo_name);
    try std.testing.expectEqual(2, parsed.copy_files.repo_overrides[0].paths.len);
    try std.testing.expectEqualStrings(".env.local", parsed.copy_files.repo_overrides[0].paths[0]);
    try std.testing.expectEqualStrings(".env.test.local", parsed.copy_files.repo_overrides[0].paths[1]);

    try std.testing.expectEqualStrings("other-repo", parsed.copy_files.repo_overrides[1].repo_name);
    try std.testing.expectEqual(1, parsed.copy_files.repo_overrides[1].paths.len);
    try std.testing.expectEqualStrings("secrets.yml", parsed.copy_files.repo_overrides[1].paths[0]);
}

test "load applies defaults then file then env overrides" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\root = "~/cfg-worktrees"
        \\strategy = "parent-worktrees"
        \\pattern = "{.repo.Main}/../cfg/{.branch}"
        \\separator = "_"
        \\
        ,
    });

    const config_path = try tmp.dir.realpathAlloc(allocator, "config.toml");
    defer allocator.free(config_path);

    try env.put("WT_CONFIG", config_path);
    try env.put("WORKTREE_ROOT", "/env/worktrees");
    try env.put("WORKTREE_STRATEGY", "parent-branches");

    var loaded = try load(allocator, .{ .env_map = &env });
    defer loaded.deinit();

    try std.testing.expectEqualStrings("/env/worktrees", loaded.resolved.root);
    try std.testing.expectEqualStrings("parent-branches", loaded.resolved.strategy);
    try std.testing.expectEqualStrings("{.repo.Main}/../cfg/{.branch}", loaded.resolved.pattern);
    try std.testing.expectEqualStrings("_", loaded.resolved.separator);
    try std.testing.expectEqualStrings("env: WORKTREE_ROOT", loaded.resolved.sources.root);
    try std.testing.expectEqualStrings("config file", loaded.resolved.sources.pattern);
    try std.testing.expect(loaded.resolved.config_file_found);
}

test "writeDefaultConfig creates parent directories and file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, "nested", "wt", "config.toml" });
    defer allocator.free(config_path);

    try writeDefaultConfig(allocator, config_path, false);

    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(data);

    try std.testing.expectEqualStrings(default_config_template, data);
}

test "writeDefaultConfig refuses to overwrite existing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(config_path);

    try fs.writeFile(allocator, config_path, "existing\n");
    try std.testing.expectError(error.ConfigFileAlreadyExists, writeDefaultConfig(allocator, config_path, false));
}
