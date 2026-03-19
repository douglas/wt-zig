const builtin = @import("builtin");
const std = @import("std");

pub const Hooks = struct {
    pre_create: []const []const u8 = &.{},
    post_create: []const []const u8 = &.{},
    pre_checkout: []const []const u8 = &.{},
    post_checkout: []const []const u8 = &.{},
    pre_remove: []const []const u8 = &.{},
    post_remove: []const []const u8 = &.{},
    pre_pr: []const []const u8 = &.{},
    post_pr: []const []const u8 = &.{},
    pre_mr: []const []const u8 = &.{},
    post_mr: []const []const u8 = &.{},
};

pub const Sources = struct {
    root: []const u8,
    strategy: []const u8,
    pattern: []const u8,
    separator: []const u8,
};

pub const Resolved = struct {
    root: []const u8,
    strategy: []const u8,
    pattern: []const u8,
    separator: []const u8,
    hooks: Hooks,
    config_file_path: []const u8,
    config_file_found: bool,
    sources: Sources,
};

pub const LoadResult = struct {
    arena: std.heap.ArenaAllocator,
    resolved: Resolved,

    pub fn deinit(self: *LoadResult) void {
        self.arena.deinit();
    }
};

pub const ParsedFile = struct {
    root: ?[]const u8 = null,
    strategy: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    separator: ?[]const u8 = null,
    hooks: Hooks = .{},

    pub fn deinit(self: *ParsedFile, allocator: std.mem.Allocator) void {
        if (self.root) |value| allocator.free(value);
        if (self.strategy) |value| allocator.free(value);
        if (self.pattern) |value| allocator.free(value);
        if (self.separator) |value| allocator.free(value);
        freeHookList(allocator, self.hooks.pre_create);
        freeHookList(allocator, self.hooks.post_create);
        freeHookList(allocator, self.hooks.pre_checkout);
        freeHookList(allocator, self.hooks.post_checkout);
        freeHookList(allocator, self.hooks.pre_remove);
        freeHookList(allocator, self.hooks.post_remove);
        freeHookList(allocator, self.hooks.pre_pr);
        freeHookList(allocator, self.hooks.post_pr);
        freeHookList(allocator, self.hooks.pre_mr);
        freeHookList(allocator, self.hooks.post_mr);
    }
};

pub const Options = struct {
    cli_config_path: ?[]const u8 = null,
    env_map: ?*const std.process.EnvMap = null,
};

pub const default_config_template =
    \\# wt configuration file
    \\# Zig port starter config
    \\
    \\# Root directory for worktrees (default: ~/dev/worktrees)
    \\# root = "~/dev/worktrees"
    \\
    \\# Worktree placement strategy
    \\# Options: global, sibling-repo, parent-branches, parent-worktrees,
    \\#          parent-dotdir, inside-dotdir, custom
    \\# strategy = "global"
    \\
    \\# Custom pattern (used when strategy = "custom", or to override any strategy's default)
    \\# Available variables: {.worktreeRoot}, {.repo.Name}, {.repo.Main},
    \\#                      {.repo.Owner}, {.repo.Host}, {.branch},
    \\#                      {.env.VARNAME}
    \\# pattern = "{.worktreeRoot}/{.repo.Name}/{.branch}"
    \\
    \\# Separator replaces "/" and "\\" in template value variables.
    \\# separator = "/"
    \\
    \\[hooks]
    \\# post_create = ["test -f $WT_MAIN/.env && cp $WT_MAIN/.env $WT_PATH/.env || true"]
    \\# post_checkout = ["cd $WT_PATH && npm install"]
    \\# pre_remove = ["echo Removing $WT_PATH"]
    \\
;

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
    const config_path = try resolveConfigPath(arena_allocator, env_map, options.cli_config_path);

    var resolved = Resolved{
        .root = default_root,
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{},
        .config_file_path = config_path,
        .config_file_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };

    if (fileExists(config_path)) {
        resolved.config_file_found = true;
        const parsed = try parseFile(arena_allocator, config_path);
        try applyParsedFile(arena_allocator, &resolved, parsed, home);
    }

    try applyEnvOverrides(arena_allocator, &resolved, env_map);

    return .{
        .arena = arena,
        .resolved = resolved,
    };
}

pub fn resolveConfigPath(
    allocator: std.mem.Allocator,
    env_map: *const std.process.EnvMap,
    cli_config_path: ?[]const u8,
) ![]const u8 {
    if (cli_config_path) |path| {
        return allocator.dupe(u8, path);
    }

    if (env_map.get("WT_CONFIG")) |path| {
        return allocator.dupe(u8, path);
    }

    const dir = try configDir(allocator, env_map);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "config.toml" });
}

pub fn writeDefaultConfig(path: []const u8) !void {
    if (fileExists(path)) return error.ConfigFileAlreadyExists;

    const dir = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
    try makePathAbsolute(dir);
    try writeFileAbsolute(path, default_config_template);
}

pub fn configDir(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap) ![]const u8 {
    if (env_map.get("XDG_CONFIG_HOME")) |dir| {
        return std.fs.path.join(allocator, &.{ dir, "wt" });
    }

    if (builtin.os.tag == .windows) {
        if (env_map.get("APPDATA")) |dir| {
            return std.fs.path.join(allocator, &.{ dir, "wt" });
        }
    }

    const home = env_map.get("HOME") orelse return error.MissingHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".config", "wt" });
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !ParsedFile {
    const buffer = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(buffer);

    var parsed: ParsedFile = .{};
    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, buffer, '\n');

    while (lines.next()) |raw_line| {
        const trimmed_right = std.mem.trimRight(u8, raw_line, "\r");
        const line = std.mem.trim(u8, trimmed_right, " \t");

        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
            continue;
        }

        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        if (value.len == 0) continue;

        if (value[0] == '[') {
            const items = try parseStringArray(allocator, value);
            if (current_section != null and std.mem.eql(u8, current_section.?, "hooks")) {
                setHookField(&parsed.hooks, key, items);
            }
            continue;
        }

        const string_value = try parseStringValue(allocator, value);
        if (current_section == null) {
            if (std.mem.eql(u8, key, "root")) parsed.root = string_value;
            if (std.mem.eql(u8, key, "strategy")) parsed.strategy = string_value;
            if (std.mem.eql(u8, key, "pattern")) parsed.pattern = string_value;
            if (std.mem.eql(u8, key, "separator")) parsed.separator = string_value;
        }
    }

    return parsed;
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

fn parseStringValue(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return allocator.dupe(u8, raw[1 .. raw.len - 1]);
    }

    return allocator.dupe(u8, raw);
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') {
        return &.{};
    }

    const inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t");
    if (inner.len == 0) {
        return &.{};
    }

    var items = std.ArrayList([]const u8).empty;
    errdefer items.deinit(allocator);

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try items.append(allocator, try parseStringValue(allocator, trimmed));
    }

    return items.toOwnedSlice(allocator);
}

fn setHookField(hooks: *Hooks, key: []const u8, value: []const []const u8) void {
    if (std.mem.eql(u8, key, "pre_create")) hooks.pre_create = value;
    if (std.mem.eql(u8, key, "post_create")) hooks.post_create = value;
    if (std.mem.eql(u8, key, "pre_checkout")) hooks.pre_checkout = value;
    if (std.mem.eql(u8, key, "post_checkout")) hooks.post_checkout = value;
    if (std.mem.eql(u8, key, "pre_remove")) hooks.pre_remove = value;
    if (std.mem.eql(u8, key, "post_remove")) hooks.post_remove = value;
    if (std.mem.eql(u8, key, "pre_pr")) hooks.pre_pr = value;
    if (std.mem.eql(u8, key, "post_pr")) hooks.post_pr = value;
    if (std.mem.eql(u8, key, "pre_mr")) hooks.pre_mr = value;
    if (std.mem.eql(u8, key, "post_mr")) hooks.post_mr = value;
}

fn freeHookList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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

fn writeFileAbsolute(path: []const u8, contents: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
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
    try std.testing.expectEqual(@as(usize, 2), parsed.hooks.post_create.len);
    try std.testing.expectEqualStrings("cleanup", parsed.hooks.pre_remove[0]);
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

    try writeDefaultConfig(config_path);

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

    try writeFileAbsolute(config_path, "existing\n");
    try std.testing.expectError(error.ConfigFileAlreadyExists, writeDefaultConfig(config_path));
}
