const builtin = @import("builtin");
const fs = @import("../fs.zig");
const std = @import("std");

const marker_start = "# >>> wt initialize >>>";
const marker_end = "# <<< wt initialize <<<";

pub const Shell = enum {
    bash,
    zsh,
    powershell,
};

pub const ParsedArgs = struct {
    shell: ?Shell = null,
    dry_run: bool = false,
    uninstall: bool = false,
    no_prompt: bool = false,
};

pub const InstallResult = enum {
    installed,
    updated,
    already_present,
    planned_append,
    planned_update,
};

pub const RemoveResult = enum {
    removed,
    planned_remove,
    not_found,
};

pub fn parseArgs(args: []const []const u8) !ParsedArgs {
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

pub fn detectShell(explicit_shell: ?Shell, env_map: *const std.process.EnvMap) !Shell {
    if (explicit_shell) |shell| return shell;
    if (builtin.os.tag == .windows) return error.UnsupportedShell;

    const shell_env = env_map.get("SHELL") orelse return .bash;
    if (std.mem.indexOf(u8, shell_env, "zsh") != null) return .zsh;
    if (std.mem.indexOf(u8, shell_env, "bash") != null) return .bash;
    return .bash;
}

pub fn parseShell(value: []const u8) ?Shell {
    if (std.ascii.eqlIgnoreCase(value, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(value, "zsh")) return .zsh;
    if (std.ascii.eqlIgnoreCase(value, "powershell")) return .powershell;
    if (std.ascii.eqlIgnoreCase(value, "pwsh")) return .powershell;
    return null;
}

pub fn shellConfigPath(
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

pub fn installShellConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    shell: Shell,
    dry_run: bool,
) !InstallResult {
    // Security: reject symlinked shell config files to prevent writing to unintended targets
    if (isSymlink(config_path)) return error.RefusingSymlink;

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

pub fn removeShellConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    dry_run: bool,
) !RemoveResult {
    // Security: reject symlinked shell config files to prevent writing to unintended targets
    if (isSymlink(config_path)) return error.RefusingSymlink;

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

    if (std.mem.endsWith(u8, before, "\n\n")) before = before[0 .. before.len - 1];
    if (std.mem.startsWith(u8, after, "\n")) after = after[1..];

    const updated = try std.mem.concat(allocator, u8, &.{ before, after });
    defer allocator.free(updated);

    if (dry_run) return .planned_remove;

    try writeShellConfig(allocator, config_path, updated);
    return .removed;
}

pub fn shellConfigContent(shell: Shell) []const u8 {
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

pub fn printActivationGuidance(shell: Shell, config_path: []const u8, stdout: *std.Io.Writer) !void {
    try stdout.writeAll("\nTo activate, run:\n");
    switch (shell) {
        .bash, .zsh => try stdout.print("  source {s}\n", .{config_path}),
        .powershell => try stdout.writeAll("  . $PROFILE\n"),
    }
    try stdout.writeAll("\nOr start a new shell session.\n");
}

pub fn shellName(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => "bash",
        .zsh => "zsh",
        .powershell => "powershell",
    };
}

/// Detect symlinks using lstat to avoid following them. This prevents symlink attacks
/// where writing to a symlinked rc file would modify the symlink target.
fn isSymlink(path: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    const stat = std.posix.fstatat(
        std.fs.cwd().fd,
        path,
        std.posix.AT.SYMLINK_NOFOLLOW,
    ) catch return false;
    return (stat.mode & std.posix.S.IFMT) == std.posix.S.IFLNK;
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

fn mergeContents(allocator: std.mem.Allocator, existing: []const u8, block: []const u8) ![]u8 {
    if (existing.len == 0) {
        return std.mem.concat(allocator, u8, &.{ block, "\n" });
    }
    if (existing[existing.len - 1] == '\n') {
        return std.mem.concat(allocator, u8, &.{ existing, "\n", block, "\n" });
    }

    return std.mem.concat(allocator, u8, &.{ existing, "\n\n", block, "\n" });
}

fn writeShellConfig(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    try fs.writeFile(allocator, path, contents);
}
