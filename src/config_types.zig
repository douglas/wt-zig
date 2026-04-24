const std = @import("std");

pub const CopyFilesRepoOverride = struct {
    repo_name: []const u8,
    paths: []const []const u8,
};

pub const CopyFiles = struct {
    paths: []const []const u8 = &.{},
    /// Directories to copy (CoW when supported: clonefile on APFS, FICLONE on Btrfs/XFS).
    /// Use for build caches and other git-ignored directories (e.g. node_modules, target/).
    dirs: []const []const u8 = &.{},
    /// Copy strategy override. null = auto-detect at runtime.
    /// Valid values: "native_clone", "clone", "rsync", "standard".
    strategy: ?[]const u8 = null,
    repo_overrides: []const CopyFilesRepoOverride = &.{},
};

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
    copy_files: CopyFiles = .{},
    config_file_path: []const u8,
    config_file_found: bool,
    config_repo_path: []const u8 = "",
    config_repo_found: bool = false,
    sources: Sources,
};

pub const LoadResult = struct {
    arena: std.heap.ArenaAllocator,
    resolved: Resolved,

    pub fn deinit(self: *LoadResult) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    cli_config_path: ?[]const u8 = null,
    env_map: ?*const std.process.EnvMap = null,
};

pub const testing_defaults = Resolved{
    .root = "/tmp/worktrees",
    .strategy = "global",
    .pattern = "",
    .separator = "/",
    .hooks = .{},
    .config_file_path = "/tmp/config.toml",
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
