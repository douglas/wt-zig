const builtin = @import("builtin");
const fs = @import("fs.zig");
const std = @import("std");
const types = @import("config_types.zig");

pub const Hooks = types.Hooks;
pub const Alias = types.Alias;

pub const ParsedFile = struct {
    root: ?[]const u8 = null,
    strategy: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    separator: ?[]const u8 = null,
    hooks: Hooks = .{},
    aliases: []const Alias = &.{},
    copy_files: types.CopyFiles = .{},
    step: types.Step = .{},

    pub fn deinit(self: *ParsedFile, allocator: std.mem.Allocator) void {
        if (self.root) |value| allocator.free(value);
        if (self.strategy) |value| allocator.free(value);
        if (self.pattern) |value| allocator.free(value);
        if (self.separator) |value| allocator.free(value);
        freeHookList(allocator, self.hooks.pre_create);
        freeHookList(allocator, self.hooks.post_create);
        freeHookList(allocator, self.hooks.pre_start);
        freeHookList(allocator, self.hooks.post_start);
        freeHookList(allocator, self.hooks.pre_commit);
        freeHookList(allocator, self.hooks.post_commit);
        freeHookList(allocator, self.hooks.pre_checkout);
        freeHookList(allocator, self.hooks.post_checkout);
        freeHookList(allocator, self.hooks.pre_merge);
        freeHookList(allocator, self.hooks.post_merge);
        freeHookList(allocator, self.hooks.pre_remove);
        freeHookList(allocator, self.hooks.post_remove);
        freeHookList(allocator, self.hooks.pre_pr);
        freeHookList(allocator, self.hooks.post_pr);
        freeHookList(allocator, self.hooks.pre_mr);
        freeHookList(allocator, self.hooks.post_mr);
        freeAliasList(allocator, self.aliases);
        freeStringList(allocator, self.copy_files.paths);
        freeStringList(allocator, self.copy_files.dirs);
        if (self.copy_files.strategy) |s| allocator.free(s);
        for (self.copy_files.repo_overrides) |override| {
            allocator.free(override.repo_name);
            freeStringList(allocator, override.paths);
        }
        if (self.copy_files.repo_overrides.len > 0)
            allocator.free(self.copy_files.repo_overrides);
        freeStringList(allocator, self.step.copy_ignored.exclude);
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
    \\# Commands run via "sh -c" with WT_* environment variables.
    \\# Always quote variables in hooks: "$WT_PATH" not $WT_PATH
    \\# post_create = ["test -f \"$WT_MAIN\"/.env && cp \"$WT_MAIN\"/.env \"$WT_PATH\"/.env || true"]
    \\# pre_start = ["echo Starting \"$WT_BRANCH\""]
    \\# post_start = ["wt step copy-ignored"]
    \\# pre_commit = ["zig fmt --check ."]
    \\# post_commit = ["echo Committed \"$WT_BRANCH\""]
    \\# post_checkout = ["cd \"$WT_PATH\" && npm install"]
    \\# pre_merge = ["zig build test"]
    \\# post_merge = ["echo Merged \"$WT_BRANCH\""]
    \\# pre_remove = ["echo Removing \"$WT_PATH\""]
    \\
    \\[aliases]
    \\# Aliases run shell commands serially. Extra CLI args are appended to the last command.
    \\# recent = "git branch --sort=-committerdate"
    \\# ship = ["git status --short", "git push"]
    \\
    \\[copy_files]
    \\# Files to copy from the main worktree into each new worktree.
    \\# paths = [".env", "config/local.yml"]
    \\#
    \\# Directories to copy using copy-on-write when supported (clonefile on APFS,
    \\# FICLONE on Btrfs/XFS). Ideal for git-ignored build caches like node_modules.
    \\# dirs = ["node_modules", ".build", "target"]
    \\#
    \\# Copy strategy for files and directories. Auto-detected if omitted.
    \\# Options: native_clone (clonefile/FICLONE), clone (cp --reflink), rsync, standard
    \\# strategy = "native_clone"
    \\#
    \\# Per-repo overrides add extra files when the repo name matches:
    \\# [copy_files.my-project]
    \\# paths = [".env.local", ".env.test.local"]
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
    try fs.ensureParentDir(allocator, path);
    // Security: write config with restrictive permissions (0o600) to protect sensitive data
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(default_config_template);
    } else {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(default_config_template);
    }
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
    var alias_entries = std.ArrayList(types.Alias).empty;
    var repo_overrides = std.ArrayList(types.CopyFilesRepoOverride).empty;
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
            if (current_section == null) {
                if (std.mem.eql(u8, key, "step.copy-ignored.exclude") or
                    std.mem.eql(u8, key, "step.copy_ignored.exclude"))
                {
                    parsed.step.copy_ignored.exclude = items;
                }
            } else if (current_section) |section| {
                if (std.mem.eql(u8, section, "hooks")) {
                    setHookField(&parsed.hooks, key, items);
                } else if (std.mem.eql(u8, section, "aliases")) {
                    try setAliasField(allocator, &alias_entries, key, items);
                } else if (std.mem.eql(u8, section, "copy_files")) {
                    if (std.mem.eql(u8, key, "paths")) {
                        parsed.copy_files.paths = items;
                    } else if (std.mem.eql(u8, key, "dirs")) {
                        parsed.copy_files.dirs = items;
                    }
                } else if (std.mem.eql(u8, section, "step.copy-ignored") or
                    std.mem.eql(u8, section, "step.copy_ignored"))
                {
                    if (std.mem.eql(u8, key, "exclude")) {
                        parsed.step.copy_ignored.exclude = items;
                    }
                } else if (std.mem.startsWith(u8, section, "copy_files.")) {
                    if (std.mem.eql(u8, key, "paths")) {
                        const repo_name = section["copy_files.".len..];
                        try repo_overrides.append(allocator, .{
                            .repo_name = try allocator.dupe(u8, repo_name),
                            .paths = items,
                        });
                    }
                }
            }
            continue;
        }

        const string_value = try parseStringValue(allocator, value);
        if (current_section == null) {
            if (std.mem.eql(u8, key, "root")) {
                parsed.root = string_value;
            } else if (std.mem.eql(u8, key, "strategy")) {
                parsed.strategy = string_value;
            } else if (std.mem.eql(u8, key, "pattern")) {
                parsed.pattern = string_value;
            } else if (std.mem.eql(u8, key, "separator")) {
                parsed.separator = string_value;
            } else {
                allocator.free(string_value);
            }
        } else if (current_section) |section| {
            if (std.mem.eql(u8, section, "copy_files") and std.mem.eql(u8, key, "strategy")) {
                parsed.copy_files.strategy = string_value;
            } else if (std.mem.eql(u8, section, "aliases")) {
                const commands = try allocator.alloc([]const u8, 1);
                commands[0] = string_value;
                try setAliasField(allocator, &alias_entries, key, commands);
            } else {
                allocator.free(string_value);
            }
        }
    }

    parsed.aliases = try alias_entries.toOwnedSlice(allocator);
    parsed.copy_files.repo_overrides = try repo_overrides.toOwnedSlice(allocator);
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

fn setHookField(h: *Hooks, key: []const u8, value: []const []const u8) void {
    inline for (comptime std.meta.fields(Hooks)) |field| {
        if (hookKeyMatches(key, field.name)) {
            @field(h, field.name) = value;
            return;
        }
    }
}

fn setAliasField(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(types.Alias),
    key: []const u8,
    commands: []const []const u8,
) !void {
    for (aliases.items) |*alias| {
        if (std.mem.eql(u8, alias.name, key)) {
            freeStringList(allocator, alias.commands);
            alias.commands = commands;
            return;
        }
    }

    try aliases.append(allocator, .{
        .name = try allocator.dupe(u8, key),
        .commands = commands,
    });
}

fn hookKeyMatches(key: []const u8, field_name: []const u8) bool {
    if (std.mem.eql(u8, key, field_name)) return true;
    if (key.len != field_name.len) return false;

    for (key, field_name) |key_ch, field_ch| {
        if (key_ch == '-' and field_ch == '_') continue;
        if (key_ch != field_ch) return false;
    }

    return true;
}

fn freeAliasList(allocator: std.mem.Allocator, aliases: []const types.Alias) void {
    for (aliases) |alias| {
        allocator.free(alias.name);
        freeStringList(allocator, alias.commands);
    }
    if (aliases.len > 0) allocator.free(aliases);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

const freeHookList = freeStringList;
