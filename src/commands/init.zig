const builtin = @import("builtin");
const fs = @import("../fs.zig");
const std = @import("std");
const output = @import("../output.zig");

const marker_start = "# >>> wt initialize >>>";
const marker_end = "# <<< wt initialize <<<";

pub const Shell = enum {
    bash,
    zsh,
    powershell,
};

const ParsedArgs = struct {
    shell: ?Shell = null,
    dry_run: bool = false,
    uninstall: bool = false,
    no_prompt: bool = false,
};

const InstallResult = enum {
    installed,
    updated,
    already_present,
    planned_append,
    planned_update,
};

const RemoveResult = enum {
    removed,
    planned_remove,
    not_found,
};

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt init", "Usage: wt init [bash|zsh|powershell] [--dry-run] [--uninstall] [--no-prompt]");
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const shell = detectShell(parsed.shell, &env_map) catch |err| switch (err) {
        error.UnsupportedShell => {
            try writeCommandError(ctx, stdout, stderr, "could not detect shell. Please specify: wt init bash|zsh|powershell");
            return 1;
        },
        else => return err,
    };

    if (shell == .powershell and builtin.os.tag != .windows) {
        try writeCommandError(ctx, stdout, stderr, "PowerShell shell integration is only supported on Windows. On macOS/Linux, use: wt init bash or wt init zsh");
        return 1;
    }

    const config_path = shellConfigPath(allocator, shell, &env_map) catch |err| switch (err) {
        error.MissingHomeDirectory => {
            try writeCommandError(ctx, stdout, stderr, "could not determine shell config path: missing HOME");
            return 1;
        },
        else => return err,
    };
    defer allocator.free(config_path);

    if (parsed.uninstall) {
        const result = try removeShellConfig(allocator, config_path, parsed.dry_run);
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt init", .{
                .status = if (parsed.dry_run) "planned" else "removed",
                .operation = "uninstall",
                .shell = shellName(shell),
                .config_path = config_path,
                .dry_run = parsed.dry_run,
            });
        } else switch (result) {
            .removed => try stdout.print("Removed wt configuration from {s}\n", .{config_path}),
            .planned_remove => try stdout.print("Would remove wt configuration from {s}\n", .{config_path}),
            .not_found => try stdout.print("No wt configuration found in {s}\n", .{config_path}),
        }
        return 0;
    }

    const result = try installShellConfig(allocator, config_path, shell, parsed.dry_run);
    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt init", .{
            .status = if (parsed.dry_run) "planned" else "installed",
            .operation = "install",
            .shell = shellName(shell),
            .config_path = config_path,
            .dry_run = parsed.dry_run,
        });
    } else switch (result) {
        .already_present => try stdout.print("wt shell integration already installed in {s}\n", .{config_path}),
        .installed => {
            try stdout.print("Installed wt shell integration in {s}\n", .{config_path});
            if (!parsed.no_prompt) try printActivationGuidance(shell, config_path, stdout);
        },
        .updated => {
            try stdout.print("Updated wt shell integration in {s}\n", .{config_path});
            if (!parsed.no_prompt) try printActivationGuidance(shell, config_path, stdout);
        },
        .planned_append => {
            try stdout.print("Would append to {s}:\n\n{s}\n", .{ config_path, shellConfigContent(shell) });
            try stdout.writeAll("\nTo apply, run: wt init\n");
        },
        .planned_update => {
            try stdout.print(
                "Would update {s} (already configured, updating)\n\nNew configuration block:\n{s}\n",
                .{ config_path, shellConfigContent(shell) },
            );
        },
    }

    return 0;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--uninstall")) {
            parsed.uninstall = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-prompt")) {
            parsed.no_prompt = true;
            continue;
        }

        const shell = parseShell(arg) orelse return error.InvalidArguments;
        if (parsed.shell != null) return error.InvalidArguments;
        parsed.shell = shell;
    }

    return parsed;
}

fn detectShell(explicit_shell: ?Shell, env_map: *const std.process.EnvMap) !Shell {
    if (explicit_shell) |shell| return shell;
    if (builtin.os.tag == .windows) return error.UnsupportedShell;

    const shell_env = env_map.get("SHELL") orelse return .bash;
    if (std.mem.indexOf(u8, shell_env, "zsh") != null) return .zsh;
    if (std.mem.indexOf(u8, shell_env, "bash") != null) return .bash;
    return .bash;
}

fn parseShell(value: []const u8) ?Shell {
    if (std.ascii.eqlIgnoreCase(value, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(value, "zsh")) return .zsh;
    if (std.ascii.eqlIgnoreCase(value, "powershell")) return .powershell;
    if (std.ascii.eqlIgnoreCase(value, "pwsh")) return .powershell;
    return null;
}

fn shellConfigPath(
    allocator: std.mem.Allocator,
    shell: Shell,
    env_map: *const std.process.EnvMap,
) ![]u8 {
    const home = env_map.get("HOME") orelse return error.MissingHomeDirectory;

    return switch (shell) {
        .bash => bashConfigPath(allocator, home),
        .zsh => zshConfigPath(allocator, home, env_map),
        .powershell => powerShellConfigPath(allocator, home, env_map),
    };
}

fn bashConfigPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const bashrc = try std.fs.path.join(allocator, &.{ home, ".bashrc" });
    errdefer allocator.free(bashrc);

    if (fs.fileExists(bashrc)) return bashrc;
    if (builtin.os.tag == .macos) {
        allocator.free(bashrc);
        return std.fs.path.join(allocator, &.{ home, ".bash_profile" });
    }

    return bashrc;
}

fn zshConfigPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    env_map: *const std.process.EnvMap,
) ![]u8 {
    if (env_map.get("ZDOTDIR")) |zdotdir| {
        const trimmed = std.mem.trim(u8, zdotdir, " \t\r\n");
        if (trimmed.len != 0) {
            if (std.fs.path.isAbsolute(trimmed)) {
                return std.fs.path.join(allocator, &.{ trimmed, ".zshrc" });
            }

            return std.fs.path.join(allocator, &.{ home, trimmed, ".zshrc" });
        }
    }

    return std.fs.path.join(allocator, &.{ home, ".zshrc" });
}

fn powerShellConfigPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    env_map: *const std.process.EnvMap,
) ![]u8 {
    if (env_map.get("PROFILE")) |profile| {
        const trimmed = std.mem.trim(u8, profile, " \t\r\n");
        if (trimmed.len != 0) return allocator.dupe(u8, trimmed);
    }

    if (builtin.os.tag == .windows) {
        return std.fs.path.join(allocator, &.{ home, "Documents", "WindowsPowerShell", "Microsoft.PowerShell_profile.ps1" });
    }

    return std.fs.path.join(allocator, &.{ home, ".config", "powershell", "Microsoft.PowerShell_profile.ps1" });
}

fn installShellConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    shell: Shell,
    dry_run: bool,
) !InstallResult {
    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    const block = shellConfigContent(shell);
    if (std.mem.indexOf(u8, existing, marker_start)) |start_index| {
        const end_marker_index = std.mem.indexOfPos(u8, existing, start_index, marker_end) orelse return error.MalformedConfigMarkers;
        const end_index = end_marker_index + marker_end.len;
        const updated = try std.mem.concat(allocator, u8, &.{ existing[0..start_index], block, existing[end_index..] });
        defer allocator.free(updated);

        if (std.mem.eql(u8, existing, updated)) return .already_present;
        if (dry_run) return .planned_update;

        try writeShellConfig(allocator, config_path, updated);
        return .updated;
    }

    if (dry_run) return .planned_append;

    const merged = try mergeContents(allocator, existing, block);
    defer allocator.free(merged);
    try writeShellConfig(allocator, config_path, merged);
    return .installed;
}

fn removeShellConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    dry_run: bool,
) !RemoveResult {
    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return err,
    };
    defer allocator.free(existing);

    const start_index = std.mem.indexOf(u8, existing, marker_start) orelse return .not_found;
    const end_marker_index = std.mem.indexOfPos(u8, existing, start_index, marker_end) orelse return error.MalformedConfigMarkers;
    const end_index = end_marker_index + marker_end.len;

    var before = existing[0..start_index];
    var after = existing[end_index..];

    if (std.mem.endsWith(u8, before, "\n\n")) {
        before = before[0 .. before.len - 1];
    }
    if (std.mem.startsWith(u8, after, "\n")) {
        after = after[1..];
    }

    const updated = try std.mem.concat(allocator, u8, &.{ before, after });
    defer allocator.free(updated);

    if (dry_run) return .planned_remove;

    try writeShellConfig(allocator, config_path, updated);
    return .removed;
}

fn shellConfigContent(shell: Shell) []const u8 {
    return switch (shell) {
        .bash, .zsh =>
        \\# >>> wt initialize >>>
        \\eval "$(wt shellenv)"
        \\# <<< wt initialize <<<
        ,
        .powershell =>
        \\# >>> wt initialize >>>
        \\Invoke-Expression (& wt shellenv)
        \\# <<< wt initialize <<<
        ,
    };
}

fn mergeContents(allocator: std.mem.Allocator, existing: []const u8, block: []const u8) ![]u8 {
    if (existing.len == 0) {
        return std.mem.concat(allocator, u8, &.{ block, "\n" });
    }
    if (existing[existing.len - 1] == '\n') {
        return std.mem.concat(allocator, u8, &.{ existing, "\n", block, "\n" });
    }

    return std.mem.concat(allocator, u8, &.{ existing, "\n\n", block, "\n" });
}

fn printActivationGuidance(shell: Shell, config_path: []const u8, stdout: anytype) !void {
    try stdout.writeAll("\nTo activate, run:\n");
    switch (shell) {
        .bash, .zsh => try stdout.print("  source {s}\n", .{config_path}),
        .powershell => try stdout.writeAll("  . $PROFILE\n"),
    }
    try stdout.writeAll("\nOr start a new shell session.\n");
}

fn shellName(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => "bash",
        .zsh => "zsh",
        .powershell => "powershell",
    };
}

fn writeCommandError(ctx: output.Context, stdout: anytype, stderr: anytype, message: []const u8) !void {
    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt init", message);
    } else {
        try stderr.print("{s}\n", .{message});
    }
}

fn writeShellConfig(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    try fs.writeFile(allocator, path, contents);
}

test "parseArgs accepts shell and flags in any order" {
    const parsed = try parseArgs(&.{ "--dry-run", "zsh", "--no-prompt" });
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.no_prompt);
    try std.testing.expectEqual(Shell.zsh, parsed.shell.?);
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "bash", "zsh" }));
}

test "parseShell accepts powershell aliases" {
    try std.testing.expectEqual(Shell.powershell, parseShell("powershell").?);
    try std.testing.expectEqual(Shell.powershell, parseShell("pwsh").?);
}

test "detectShell prefers explicit argument" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/bash");

    try std.testing.expectEqual(Shell.zsh, try detectShell(.zsh, &env));
}

test "shellConfigPath respects ZDOTDIR" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("ZDOTDIR", "custom-zsh");

    const path = try shellConfigPath(std.testing.allocator, .zsh, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/home/tester/custom-zsh/.zshrc", path);
}

test "shellConfigPath prefers PROFILE for powershell" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("PROFILE", "/tmp/profile.ps1");

    const path = try shellConfigPath(std.testing.allocator, .powershell, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/profile.ps1", path);
}

test "shellConfigContent uses powershell invocation" {
    const content = shellConfigContent(.powershell);
    try std.testing.expect(std.mem.indexOf(u8, content, "Invoke-Expression (& wt shellenv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "eval \"$(wt shellenv)\"") == null);
}

test "installShellConfig appends block once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, ".bashrc" });
    defer allocator.free(config_path);

    try writeShellConfig(allocator, config_path, "# existing\n");
    try std.testing.expectEqual(InstallResult.installed, try installShellConfig(allocator, config_path, .bash, false));
    try std.testing.expectEqual(InstallResult.already_present, try installShellConfig(allocator, config_path, .bash, false));

    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, marker_start) != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "eval \"$(wt shellenv)\"") != null);
}

test "installShellConfig updates existing block in dry run without writing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, ".bashrc" });
    defer allocator.free(config_path);

    const stale =
        \\# >>> wt initialize >>>
        \\echo stale
        \\# <<< wt initialize <<<
        \\
    ;
    try writeShellConfig(allocator, config_path, stale);

    try std.testing.expectEqual(InstallResult.planned_update, try installShellConfig(allocator, config_path, .bash, true));

    const after = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(stale, after);
}

test "removeShellConfig removes marker block" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, ".bashrc" });
    defer allocator.free(config_path);

    const initial =
        \\# preamble
        \\
        \\# >>> wt initialize >>>
        \\eval "$(wt shellenv)"
        \\# <<< wt initialize <<<
        \\# postamble
        \\
    ;
    try writeShellConfig(allocator, config_path, initial);

    try std.testing.expectEqual(RemoveResult.removed, try removeShellConfig(allocator, config_path, false));

    const after = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, marker_start) == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# preamble") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# postamble") != null);
}

test "run with no prompt suppresses activation guidance" {
    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout = stdout_buffer.writer(allocator);
    var stderr = stderr_buffer.writer(allocator);

    const exit_code = try run(allocator, &.{ "--no-prompt", "--dry-run", "bash" }, &stdout, &stderr);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Would append to ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "To activate, run:") == null);
}

test "run rejects powershell on non-windows after parsing flags" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout = stdout_buffer.writer(allocator);
    var stderr = stderr_buffer.writer(allocator);

    const exit_code = try run(allocator, &.{ "powershell", "--dry-run" }, &stdout, &stderr);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "PowerShell shell integration is only supported on Windows") != null);
}
