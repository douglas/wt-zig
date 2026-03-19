const builtin = @import("builtin");
const fs = @import("fs.zig");
const std = @import("std");
const types = @import("config_types.zig");

pub const Hooks = types.Hooks;

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

pub fn writeDefaultConfig(allocator: std.mem.Allocator, path: []const u8, force: bool) !void {
    if (fs.fileExists(path) and !force) return error.ConfigFileAlreadyExists;
    try fs.writeFile(allocator, path, default_config_template);
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

        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

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
