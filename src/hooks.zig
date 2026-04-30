const builtin = @import("builtin");
const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");
const path = @import("path.zig");

pub fn getHooks(cfg: *const config.Resolved, hook_name: []const u8) []const []const u8 {
    inline for (comptime std.meta.fields(@TypeOf(cfg.hooks))) |field| {
        if (std.mem.eql(u8, hook_name, field.name)) {
            return @field(cfg.hooks, field.name);
        }
    }
    return &.{};
}

pub fn appendArgs(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, command);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, command);
    for (args) |arg| {
        const quoted = try quoteShellArg(allocator, arg);
        defer allocator.free(quoted);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, quoted);
    }

    return out.toOwnedSlice(allocator);
}

pub fn runStartHooks(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    info: path.RepoInfo,
    branch: []const u8,
    worktree_path: []const u8,
    stderr: *std.Io.Writer,
) !void {
    const pre_hooks = getHooks(cfg, "pre_start");
    if (pre_hooks.len != 0) {
        var pre_hook_env = try buildHookEnv(allocator, info, branch, worktree_path);
        defer pre_hook_env.deinit();
        try runHooks(allocator, "pre_start", pre_hooks, &pre_hook_env, stderr);
    }

    const post_hooks = getHooks(cfg, "post_start");
    if (post_hooks.len == 0) return;

    var post_hook_env = try buildHookEnv(allocator, info, branch, worktree_path);
    defer post_hook_env.deinit();
    try runHooksDetached(allocator, "post_start", post_hooks, &post_hook_env, stderr);
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

pub fn runHooksDetached(
    allocator: std.mem.Allocator,
    hook_name: []const u8,
    hook_commands: []const []const u8,
    hook_env: *const std.process.EnvMap,
    stderr: *std.Io.Writer,
) !void {
    if (hook_commands.len == 0) return;

    var current_env = try std.process.getEnvMap(allocator);
    defer current_env.deinit();

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
    try merged_env.put("WT_BACKGROUND_HOOK", "1");
    try merged_env.put("WORKTRUNK_FOREGROUND", "-1");

    const log_path = hookLogPath(allocator, hook_name, hook_env) catch |err| {
        try stderr.print("warning: failed to prepare {s} hook log: {s}\n", .{ hook_name, @errorName(err) });
        return;
    };
    defer allocator.free(log_path);

    fs.ensureParentDir(allocator, log_path) catch |err| {
        try stderr.print("warning: failed to create {s} hook log directory: {s}\n", .{ hook_name, @errorName(err) });
        return;
    };

    for (hook_commands) |command| {
        spawnDetachedHook(allocator, command, log_path, &merged_env) catch |err| {
            try stderr.print("warning: failed to start {s} hook: {s}\n", .{ hook_name, @errorName(err) });
        };
    }
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
    return runShellCommand(allocator, command, env_map);
}

pub fn runShellCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    env_map: ?*const std.process.EnvMap,
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

fn spawnDetachedHook(
    allocator: std.mem.Allocator,
    command: []const u8,
    log_path: []const u8,
    env_map: *const std.process.EnvMap,
) !void {
    const quoted_log = try shellQuote(allocator, log_path);
    defer allocator.free(quoted_log);
    const script = try std.fmt.allocPrint(allocator, "exec >> {s} 2>&1; {s}", .{ quoted_log, command });
    defer allocator.free(script);

    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", script }
    else
        &[_][]const u8{ "sh", "-c", script };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = env_map;
    try child.spawn();
}

fn hookLogPath(
    allocator: std.mem.Allocator,
    hook_name: []const u8,
    hook_env: *const std.process.EnvMap,
) ![]const u8 {
    const worktree_path = hook_env.get("WT_PATH") orelse hook_env.get("WT_MAIN") orelse return error.MissingHookPath;
    const branch = hook_env.get("WT_BRANCH") orelse "unknown";
    const git_dir = gitOutputTrimmed(allocator, &.{ "git", "-C", worktree_path, "rev-parse", "--git-common-dir" }) catch |err| switch (err) {
        error.GitCommandFailed => hook_env.get("WT_MAIN") orelse return err,
        else => return err,
    };
    defer allocator.free(git_dir);

    const common_dir = if (std.fs.path.isAbsolute(git_dir))
        try allocator.dupe(u8, git_dir)
    else
        try std.fs.path.join(allocator, &.{ worktree_path, git_dir });
    defer allocator.free(common_dir);

    const safe_branch = try sanitizePathComponent(allocator, branch);
    defer allocator.free(safe_branch);
    const safe_hook = try sanitizePathComponent(allocator, hook_name);
    defer allocator.free(safe_hook);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.log", .{safe_branch});
    defer allocator.free(file_name);

    return std.fs.path.join(allocator, &.{ common_dir, "wt", "logs", safe_hook, file_name });
}

fn gitOutputTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

fn sanitizePathComponent(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*ch| {
        if (!(std.ascii.isAlphanumeric(ch.*) or ch.* == '-' or ch.* == '_' or ch.* == '.')) {
            ch.* = '-';
        }
    }
    return out;
}

pub fn quoteShellArg(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) return cmdQuote(allocator, value);
    return shellQuote(allocator, value);
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn cmdQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        if (ch == '"' or ch == '^' or ch == '&' or ch == '|' or ch == '<' or ch == '>') {
            try out.append(allocator, '^');
        }
        try out.append(allocator, ch);
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

test "getHooks returns configured slice" {
    var cfg = config.testing_defaults;
    cfg.hooks = .{ .pre_start = &.{"echo pre"} };

    try std.testing.expectEqual(1, getHooks(&cfg, "pre_start").len);
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
        runHooks(allocator, "pre_start", &.{"false"}, &hook_env, &discard),
    );

    try runHooks(allocator, "post_start", &.{"false"}, &hook_env, &discard);
}

test "appendArgs shell-quotes args on final command" {
    const allocator = std.testing.allocator;
    const command = try appendArgs(allocator, "printf %s", &.{ "hello world", "it's fine" });
    defer allocator.free(command);

    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectEqualStrings("printf %s \"hello world\" \"it's fine\"", command);
    } else {
        try std.testing.expectEqualStrings("printf %s 'hello world' 'it'\\''s fine'", command);
    }
}
