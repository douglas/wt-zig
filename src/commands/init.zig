const builtin = @import("builtin");
const std = @import("std");

const marker_start = "# >>> wt initialize >>>";
const marker_end = "# <<< wt initialize <<<";

pub const Shell = enum {
    bash,
    zsh,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len > 1) {
        try stderr.writeAll("Usage: wt init [bash|zsh]\n");
        return 1;
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const shell = detectShell(args, &env_map) catch |err| switch (err) {
        error.UnsupportedShell => {
            try stderr.writeAll("could not detect shell. Please specify: wt init bash|zsh\n");
            return 1;
        },
        else => return err,
    };

    const config_path = shellConfigPath(allocator, shell, &env_map) catch |err| switch (err) {
        error.MissingHomeDirectory => {
            try stderr.writeAll("could not determine shell config path: missing HOME\n");
            return 1;
        },
        else => return err,
    };
    defer allocator.free(config_path);

    const installed = try installShellConfig(allocator, config_path, shell);
    if (installed == .already_present) {
        try stdout.print("wt shell integration already installed in {s}\n", .{config_path});
        return 0;
    }

    try stdout.print("Installed wt shell integration in {s}\n", .{config_path});
    return 0;
}

const InstallResult = enum {
    installed,
    already_present,
};

fn detectShell(args: []const []const u8, env_map: *const std.process.EnvMap) !Shell {
    if (args.len == 1) {
        return parseShell(args[0]) orelse error.UnsupportedShell;
    }

    if (builtin.os.tag == .windows) return error.UnsupportedShell;

    const shell_env = env_map.get("SHELL") orelse return .bash;
    if (std.mem.indexOf(u8, shell_env, "zsh") != null) return .zsh;
    if (std.mem.indexOf(u8, shell_env, "bash") != null) return .bash;
    return .bash;
}

fn parseShell(value: []const u8) ?Shell {
    if (std.ascii.eqlIgnoreCase(value, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(value, "zsh")) return .zsh;
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
    };
}

fn bashConfigPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const bashrc = try std.fs.path.join(allocator, &.{ home, ".bashrc" });
    errdefer allocator.free(bashrc);

    if (fileExists(bashrc)) return bashrc;
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

fn installShellConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    shell: Shell,
) !InstallResult {
    const existing = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    if (std.mem.indexOf(u8, existing, marker_start) != null) {
        return .already_present;
    }

    const block = shellConfigContent(shell);
    const new_contents = try mergeContents(allocator, existing, block);
    defer allocator.free(new_contents);

    const parent = std.fs.path.dirname(config_path) orelse return error.InvalidConfigPath;
    try makePathAbsolute(parent);
    try writeFileAbsolute(config_path, new_contents);
    return .installed;
}

fn shellConfigContent(shell: Shell) []const u8 {
    _ = shell;
    return 
    \\# >>> wt initialize >>>
    \\eval "$(wt shellenv)"
    \\# <<< wt initialize <<<
    \\
    ;
}

fn mergeContents(allocator: std.mem.Allocator, existing: []const u8, block: []const u8) ![]u8 {
    if (existing.len == 0) return allocator.dupe(u8, block);
    if (existing[existing.len - 1] == '\n') {
        return std.mem.concat(allocator, u8, &.{ existing, block });
    }

    return std.mem.concat(allocator, u8, &.{ existing, "\n", block });
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

test "detectShell prefers explicit argument" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/bash");

    try std.testing.expectEqual(Shell.zsh, try detectShell(&.{"zsh"}, &env));
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

test "installShellConfig appends block once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, ".bashrc" });
    defer allocator.free(config_path);

    try writeFileAbsolute(config_path, "# existing\n");
    try std.testing.expectEqual(InstallResult.installed, try installShellConfig(allocator, config_path, .bash));
    try std.testing.expectEqual(InstallResult.already_present, try installShellConfig(allocator, config_path, .bash));

    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, marker_start) != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "eval \"$(wt shellenv)\"") != null);
}
