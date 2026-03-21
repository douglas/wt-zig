const builtin = @import("builtin");
const std = @import("std");
const config = @import("config.zig");
const path = @import("path.zig");

pub fn getHooks(cfg: *const config.Resolved, hook_name: []const u8) []const []const u8 {
    inline for (comptime std.meta.fields(@TypeOf(cfg.hooks))) |field| {
        if (std.mem.eql(u8, hook_name, field.name)) {
            return @field(cfg.hooks, field.name);
        }
    }
    return &.{};
}

pub fn buildHookEnv(
    allocator: std.mem.Allocator,
    info: path.RepoInfo,
    branch: []const u8,
    worktree_path: []const u8,
) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    errdefer env.deinit();

    try env.put("WT_PATH", worktree_path);
    try env.put("WT_BRANCH", branch);
    try env.put("WT_MAIN", info.main);
    try env.put("WT_REPO_NAME", info.name);
    try env.put("WT_REPO_HOST", info.host);
    try env.put("WT_REPO_OWNER", info.owner);
    return env;
}

pub fn runHooks(
    allocator: std.mem.Allocator,
    hook_name: []const u8,
    hook_commands: []const []const u8,
    hook_env: *const std.process.EnvMap,
    stderr: *std.Io.Writer,
) !void {
    var current_env = try std.process.getEnvMap(allocator);
    defer current_env.deinit();

    try runHooksWithEnvMap(allocator, &current_env, hook_name, hook_commands, hook_env, stderr);
}

fn runHooksWithEnvMap(
    allocator: std.mem.Allocator,
    current_env: *const std.process.EnvMap,
    hook_name: []const u8,
    hook_commands: []const []const u8,
    hook_env: *const std.process.EnvMap,
    stderr: *std.Io.Writer,
) !void {
    if (hook_commands.len == 0) return;

    if (current_env.get("WT_HOOKS_DISABLED")) |value| {
        if (std.mem.eql(u8, value, "1")) return;
    }

    var merged_env = std.process.EnvMap.init(allocator);
    defer merged_env.deinit();

    var current_it = current_env.iterator();
    while (current_it.next()) |entry| {
        try merged_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var hook_it = hook_env.iterator();
    while (hook_it.next()) |entry| {
        try merged_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    const is_pre = std.mem.startsWith(u8, hook_name, "pre_");

    for (hook_commands) |command| {
        const term = try runHookCommand(allocator, command, &merged_env);
        switch (term) {
            .Exited => |code| {
                if (code == 0) continue;
                if (is_pre) return error.HookCommandFailed;
                try stderr.print(
                    "warning: {s} hook failed: command \"{s}\" exited with {d}\n",
                    .{ hook_name, command, code },
                );
            },
            else => {
                if (is_pre) return error.HookCommandFailed;
                try stderr.print(
                    "warning: {s} hook failed: command \"{s}\" terminated unexpectedly\n",
                    .{ hook_name, command },
                );
            },
        }
    }
}

fn runHookCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    env_map: *const std.process.EnvMap,
) !std.process.Child.Term {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", command }
    else
        &[_][]const u8{ "sh", "-c", command };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = env_map;
    return child.spawnAndWait();
}

test "getHooks returns configured slice" {
    const cfg = config.Resolved{
        .root = "/tmp/worktrees",
        .strategy = "global",
        .pattern = "",
        .separator = "/",
        .hooks = .{ .pre_create = &.{"echo pre"} },
        .config_file_path = "/tmp/config.toml",
        .config_file_found = false,
        .sources = .{
            .root = "default",
            .strategy = "default",
            .pattern = "default",
            .separator = "default",
        },
    };

    try std.testing.expectEqual(1, getHooks(&cfg, "pre_create").len);
    try std.testing.expectEqual(0, getHooks(&cfg, "missing").len);
}

test "buildHookEnv populates expected values" {
    const allocator = std.testing.allocator;
    var env = try buildHookEnv(allocator, .{
        .main = "/tmp/repo",
        .host = "github.com",
        .owner = "douglas",
        .name = "wt-zig",
    }, "feat/test", "/tmp/worktrees/wt-zig/feat/test");
    defer env.deinit();

    try std.testing.expectEqualStrings("/tmp/repo", env.get("WT_MAIN").?);
    try std.testing.expectEqualStrings("feat/test", env.get("WT_BRANCH").?);
    try std.testing.expectEqualStrings("wt-zig", env.get("WT_REPO_NAME").?);
}

test "runHooks respects WT_HOOKS_DISABLED" {
    const allocator = std.testing.allocator;
    var current_env = std.process.EnvMap.init(allocator);
    defer current_env.deinit();
    try current_env.put("WT_HOOKS_DISABLED", "1");

    var hook_env = std.process.EnvMap.init(allocator);
    defer hook_env.deinit();
    try hook_env.put("WT_PATH", "/tmp/path");

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    try runHooksWithEnvMap(allocator, &current_env, "pre_create", &.{"false"}, &hook_env, &discard);
}

test "runHooks aborts pre hooks and tolerates post hooks" {
    const allocator = std.testing.allocator;
    var hook_env = std.process.EnvMap.init(allocator);
    defer hook_env.deinit();
    try hook_env.put("WT_PATH", "/tmp/path");

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);

    try std.testing.expectError(
        error.HookCommandFailed,
        runHooks(allocator, "pre_create", &.{"false"}, &hook_env, &discard),
    );

    try runHooks(allocator, "post_create", &.{"false"}, &hook_env, &discard);
}
