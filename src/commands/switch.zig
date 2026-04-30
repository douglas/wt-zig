const std = @import("std");
const checkout = @import("checkout.zig");
const config = @import("../config.zig");
const create = @import("create.zig");
const git_repo = @import("../git/repo.zig");
const jump = @import("jump.zig");
const output = @import("../output.zig");
const pr_cmd = @import("pr.zig");
const pr_git = @import("../git/pr.zig");
const worktree = @import("../git/worktree.zig");

const usage = "Usage: wt switch [--create|-c] [--base <branch>] [--execute|-x <command>] <branch|^|@|-|pr:N|mr:N> [-- <args>...]";

const ParsedArgs = struct {
    target: ?[]const u8 = null,
    create: bool = false,
    base: ?[]const u8 = null,
    execute: ?[]const u8 = null,
    execute_args: []const []const u8 = &.{},
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt switch", usage);
    };
    const target = parsed.target orelse {
        return output.usageError(ctx, stdout, stderr, "wt switch", usage);
    };

    if (!parsed.create) {
        if (std.mem.eql(u8, target, "^")) {
            return switchMain(ctx, parsed, stdout, stderr);
        }
        if (std.mem.eql(u8, target, "@")) {
            return switchCurrent(ctx, parsed, stdout, stderr);
        }
        if (std.mem.eql(u8, target, "-")) {
            return switchPrevious(ctx, parsed, stdout, stderr);
        }
        if (parsed.execute != null and (prefixedValue(target, "pr:") != null or prefixedValue(target, "mr:") != null)) {
            return emitSwitchError(ctx, stdout, stderr, "--execute is not supported with pr: or mr: shortcuts yet");
        }
        if (prefixedValue(target, "pr:")) |id| {
            return pr_cmd.runRemoteCommand(ctx, cfg, &.{id}, stdout, stderr, pr_git.RemoteType.github);
        }
        if (prefixedValue(target, "mr:")) |id| {
            return pr_cmd.runRemoteCommand(ctx, cfg, &.{id}, stdout, stderr, pr_git.RemoteType.gitlab);
        }
    }

    if (parsed.create) {
        const owned_base = if (parsed.base == null) try git_repo.getDefaultBase(allocator) else null;
        defer if (owned_base) |base| allocator.free(base);
        const base = parsed.base orelse owned_base.?;
        return createAndSwitch(ctx, cfg, target, base, parsed, stdout, stderr);
    }

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (jump.findBestMatch(allocator, listed.entries, target)) |matched| {
        return emitSwitch(ctx, stdout, stderr, matched.branch orelse "", matched.path, parsed);
    }

    const outcome = checkout.checkoutBranch(allocator, cfg, target, .{}, stderr) catch |err| switch (err) {
        error.BranchDoesNotExist => {
            const message = try std.fmt.allocPrint(
                allocator,
                "branch '{s}' does not exist\nUse 'wt switch --create {s}' to create a new branch",
                .{ target, target },
            );
            defer allocator.free(message);
            return emitSwitchError(ctx, stdout, stderr, message);
        },
        error.HookCommandFailed => return emitSwitchError(ctx, stdout, stderr, "pre-checkout hook failed"),
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer allocator.free(outcome.path);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt switch", .{
            .status = if (outcome.existed) "exists" else "created",
            .branch = target,
            .path = outcome.path,
            .navigate_to = outcome.path,
            .execute = parsed.execute,
        });
        return 0;
    }

    try stdout.writeAll(if (outcome.existed) "Worktree already exists: " else "Worktree created at: ");
    try stdout.writeAll(outcome.path);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, outcome.path);
    try emitOrRunExecute(ctx, stdout, stderr, outcome.path, parsed);
    return 0;
}

fn createAndSwitch(
    ctx: output.Context,
    cfg: *const config.Resolved,
    branch: []const u8,
    base: []const u8,
    parsed: ParsedArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const outcome = create.createBranch(ctx.allocator, cfg, branch, base, stderr) catch |err| switch (err) {
        error.HookCommandFailed => return emitSwitchError(ctx, stdout, stderr, "pre-create hook failed"),
        error.GitCommandFailed => return 1,
        else => return err,
    };
    defer ctx.allocator.free(outcome.path);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt switch", .{
            .status = if (outcome.existed) "exists" else "created",
            .branch = branch,
            .base = base,
            .path = outcome.path,
            .navigate_to = outcome.path,
            .execute = parsed.execute,
        });
        return 0;
    }

    try stdout.writeAll(if (outcome.existed) "Worktree already exists: " else "Worktree created at: ");
    try stdout.writeAll(outcome.path);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, outcome.path);
    try emitOrRunExecute(ctx, stdout, stderr, outcome.path, parsed);
    return 0;
}

fn switchMain(ctx: output.Context, parsed: ParsedArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var info = try git_repo.getRepoInfo(ctx.allocator);
    defer git_repo.freeRepoInfo(ctx.allocator, &info);
    return emitSwitch(ctx, stdout, stderr, "", info.main, parsed);
}

fn switchCurrent(ctx: output.Context, parsed: ParsedArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const cwd = std.process.getCwdAlloc(ctx.allocator) catch {
        return emitSwitchError(ctx, stdout, stderr, "failed to get current directory");
    };
    defer ctx.allocator.free(cwd);

    var listed = worktree.list(ctx.allocator, stderr) catch return 1;
    defer listed.deinit(ctx.allocator);

    const entry = findContainingPath(listed.entries, cwd) orelse {
        return emitSwitchError(ctx, stdout, stderr, "current directory is not inside a git worktree");
    };
    return emitSwitch(ctx, stdout, stderr, entry.branch orelse "", entry.path, parsed);
}

fn switchPrevious(ctx: output.Context, parsed: ParsedArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const oldpwd = std.posix.getenv("OLDPWD") orelse {
        return emitSwitchError(ctx, stdout, stderr, "OLDPWD is not set; cannot resolve previous worktree");
    };

    var listed = worktree.list(ctx.allocator, stderr) catch return 1;
    defer listed.deinit(ctx.allocator);

    const entry = findContainingPath(listed.entries, oldpwd) orelse {
        return emitSwitchError(ctx, stdout, stderr, "OLDPWD is not inside a known worktree");
    };
    return emitSwitch(ctx, stdout, stderr, entry.branch orelse "", entry.path, parsed);
}

fn emitSwitch(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    branch: []const u8,
    path: []const u8,
    parsed: ParsedArgs,
) !u8 {
    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt switch", .{
            .status = "switched",
            .branch = branch,
            .path = path,
            .navigate_to = path,
            .execute = parsed.execute,
        });
        return 0;
    }

    try stdout.writeAll("Switching to worktree: ");
    try stdout.writeAll(path);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, path);
    try emitOrRunExecute(ctx, stdout, stderr, path, parsed);
    return 0;
}

fn emitSwitchError(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    message: []const u8,
) !u8 {
    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt switch", message);
    } else {
        try stderr.writeAll(message);
        try stderr.writeByte('\n');
    }
    return 1;
}

fn emitOrRunExecute(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    path: []const u8,
    parsed: ParsedArgs,
) !void {
    const command = parsed.execute orelse return;
    const full_command = try buildExecuteCommand(ctx.allocator, command, parsed.execute_args);
    defer ctx.allocator.free(full_command);

    if (try output.emitExecute(full_command)) {
        return;
    }

    try stdout.flush();
    try stderr.flush();
    var child = std.process.Child.init(&.{ "sh", "-c", full_command }, ctx.allocator);
    child.cwd = path;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn buildExecuteCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) ![]u8 {
    if (args.len == 0) return allocator.dupe(u8, command);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, command);
    for (args) |arg| {
        try buffer.append(allocator, ' ');
        try appendShellQuoted(allocator, &buffer, arg);
    }
    return buffer.toOwnedSlice(allocator);
}

fn appendShellQuoted(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try buffer.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try buffer.appendSlice(allocator, "'\\''");
        } else {
            try buffer.append(allocator, ch);
        }
    }
    try buffer.append(allocator, '\'');
}

fn findContainingPath(entries: []const worktree.Entry, path: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (isSameOrChildPath(entry.path, path)) return entry;
    }
    return null;
}

fn isSameOrChildPath(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn prefixedValue(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const suffix = value[prefix.len..];
    return if (suffix.len == 0) null else suffix;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--create") or std.mem.eql(u8, arg, "-c")) {
            parsed.create = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base")) {
            index += 1;
            if (index >= args.len) return error.MissingBase;
            parsed.base = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--base=")) {
            parsed.base = arg["--base=".len..];
            if (parsed.base.?.len == 0) return error.MissingBase;
            continue;
        }
        if (std.mem.eql(u8, arg, "--execute") or std.mem.eql(u8, arg, "-x")) {
            index += 1;
            if (index >= args.len) return error.MissingExecute;
            parsed.execute = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--execute=")) {
            parsed.execute = arg["--execute=".len..];
            if (parsed.execute.?.len == 0) return error.MissingExecute;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            if (parsed.execute == null) return error.ExecuteArgsWithoutExecute;
            parsed.execute_args = args[index + 1 ..];
            return parsed;
        }
        if (std.mem.eql(u8, arg, "-")) {
            if (parsed.target != null) return error.TooManyTargets;
            parsed.target = arg;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.target != null) return error.TooManyTargets;
        parsed.target = arg;
    }
    return parsed;
}

test "parseArgs accepts create and base" {
    const parsed = try parseArgs(&.{ "--create", "--base", "develop", "feature" });
    try std.testing.expect(parsed.create);
    try std.testing.expectEqualStrings("develop", parsed.base.?);
    try std.testing.expectEqualStrings("feature", parsed.target.?);
}

test "parseArgs accepts target before options" {
    const parsed = try parseArgs(&.{ "feature", "-c", "--base=main" });
    try std.testing.expect(parsed.create);
    try std.testing.expectEqualStrings("main", parsed.base.?);
    try std.testing.expectEqualStrings("feature", parsed.target.?);
}

test "parseArgs accepts execute and trailing args" {
    const parsed = try parseArgs(&.{ "--create", "feature", "--execute=claude", "--", "Fix issue", "it's broken" });
    try std.testing.expect(parsed.create);
    try std.testing.expectEqualStrings("feature", parsed.target.?);
    try std.testing.expectEqualStrings("claude", parsed.execute.?);
    try std.testing.expectEqual(2, parsed.execute_args.len);
}

test "parseArgs accepts previous worktree shortcut" {
    const parsed = try parseArgs(&.{"-"});
    try std.testing.expectEqualStrings("-", parsed.target.?);
}

test "buildExecuteCommand quotes trailing args" {
    const command = try buildExecuteCommand(std.testing.allocator, "claude", &.{ "Fix issue", "it's broken" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("claude 'Fix issue' 'it'\\''s broken'", command);
}

test "parseArgs rejects multiple targets" {
    try std.testing.expectError(error.TooManyTargets, parseArgs(&.{ "feature", "other" }));
}

test "parseArgs rejects trailing args without execute" {
    try std.testing.expectError(error.ExecuteArgsWithoutExecute, parseArgs(&.{ "feature", "--", "prompt" }));
}

test "prefixedValue extracts non-empty shortcut payload" {
    try std.testing.expectEqualStrings("123", prefixedValue("pr:123", "pr:").?);
    try std.testing.expect(prefixedValue("pr:", "pr:") == null);
    try std.testing.expect(prefixedValue("feature", "pr:") == null);
}

test "isSameOrChildPath matches boundaries" {
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo"));
    try std.testing.expect(isSameOrChildPath("/tmp/repo", "/tmp/repo/sub"));
    try std.testing.expect(!isSameOrChildPath("/tmp/repo", "/tmp/repository"));
}
