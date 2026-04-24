const std = @import("std");
const output = @import("../output.zig");
const support = @import("init_support.zig");

pub const Shell = support.Shell;
const ParsedArgs = support.ParsedArgs;
const InstallResult = support.InstallResult;
const RemoveResult = support.RemoveResult;

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const parsed = support.parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt init", "Usage: wt init [bash|zsh|powershell] [--dry-run] [--uninstall] [--no-prompt]");
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const shell = support.detectShell(parsed.shell, &env_map) catch |err| switch (err) {
        error.UnsupportedShell => {
            try writeCommandError(ctx, stdout, stderr, "could not detect shell. Please specify: wt init bash|zsh|powershell");
            return 1;
        },
        else => return err,
    };

    if (shell == .powershell and @import("builtin").os.tag != .windows) {
        try writeCommandError(ctx, stdout, stderr, "PowerShell shell integration is only supported on Windows. On macOS/Linux, use: wt init bash or wt init zsh");
        return 1;
    }

    var selected_shell = shell;
    var config_path = support.shellConfigPath(allocator, selected_shell, &env_map) catch |err| switch (err) {
        error.MissingHomeDirectory => {
            try writeCommandError(ctx, stdout, stderr, "could not determine shell config path: missing HOME");
            return 1;
        },
        else => return err,
    };
    defer allocator.free(config_path);

    if (parsed.uninstall) {
        var result = try support.removeShellConfig(allocator, config_path, parsed.dry_run);

        // If shell was auto-detected and no block exists there, try the other
        // Unix shell config path. This handles environments where $SHELL does
        // not match the file that was previously initialized.
        if (parsed.shell == null and result == .not_found and selected_shell != .powershell) {
            const fallback_shell: Shell = switch (selected_shell) {
                .bash => .zsh,
                .zsh => .bash,
                .powershell => .powershell,
            };
            const fallback_path = support.shellConfigPath(allocator, fallback_shell, &env_map) catch null;
            if (fallback_path) |path| {
                const fallback_result = try support.removeShellConfig(allocator, path, parsed.dry_run);
                if (fallback_result != .not_found) {
                    allocator.free(config_path);
                    config_path = path;
                    selected_shell = fallback_shell;
                    result = fallback_result;
                } else {
                    allocator.free(path);
                }
            }
        }

        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt init", .{
                .status = if (parsed.dry_run) "planned" else "removed",
                .operation = "uninstall",
                .shell = support.shellName(selected_shell),
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

    const result = try support.installShellConfig(allocator, config_path, shell, parsed.dry_run);
    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt init", .{
            .status = if (parsed.dry_run) "planned" else "installed",
            .operation = "install",
            .shell = support.shellName(selected_shell),
            .config_path = config_path,
            .dry_run = parsed.dry_run,
        });
    } else switch (result) {
        .already_present => try stdout.print("wt shell integration already installed in {s}\n", .{config_path}),
        .installed => {
            try stdout.print("Installed wt shell integration in {s}\n", .{config_path});
            if (!parsed.no_prompt) try support.printActivationGuidance(shell, config_path, stdout);
        },
        .updated => {
            try stdout.print("Updated wt shell integration in {s}\n", .{config_path});
            if (!parsed.no_prompt) try support.printActivationGuidance(shell, config_path, stdout);
        },
        .planned_append => {
            try stdout.print("Would append to {s}:\n\n{s}\n", .{ config_path, support.shellConfigContent(shell) });
            try stdout.writeAll("\nTo apply, run: wt init\n");
        },
        .planned_update => {
            try stdout.print(
                "Would update {s} (already configured, updating)\n\nNew configuration block:\n{s}\n",
                .{ config_path, support.shellConfigContent(shell) },
            );
        },
    }

    return 0;
}

fn writeCommandError(ctx: output.Context, stdout: *std.Io.Writer, stderr: *std.Io.Writer, message: []const u8) !void {
    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt init", message);
    } else {
        try stderr.writeAll(message);
        try stderr.writeByte('\n');
    }
}

test "parseArgs accepts shell and flags in any order" {
    const parsed = try support.parseArgs(&.{ "--dry-run", "zsh", "--no-prompt" });
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.no_prompt);
    try std.testing.expectEqual(Shell.zsh, parsed.shell.?);
    try std.testing.expectError(error.InvalidArguments, support.parseArgs(&.{ "bash", "zsh" }));
}

test "parseShell accepts powershell aliases" {
    try std.testing.expectEqual(Shell.powershell, support.parseShell("powershell").?);
    try std.testing.expectEqual(Shell.powershell, support.parseShell("pwsh").?);
}

test "detectShell prefers explicit argument" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/bash");

    try std.testing.expectEqual(Shell.zsh, try support.detectShell(.zsh, &env));
}

test "shellConfigPath respects ZDOTDIR" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("ZDOTDIR", "custom-zsh");

    const path = try support.shellConfigPath(std.testing.allocator, .zsh, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/home/tester/custom-zsh/.zshrc", path);
}

test "shellConfigPath prefers PROFILE for powershell" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("PROFILE", "/tmp/profile.ps1");

    const path = try support.shellConfigPath(std.testing.allocator, .powershell, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/profile.ps1", path);
}

test "shellConfigContent uses powershell invocation" {
    const content = support.shellConfigContent(.powershell);
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

    try @import("../fs.zig").writeFile(allocator, config_path, "# existing\n");
    try std.testing.expectEqual(InstallResult.installed, try support.installShellConfig(allocator, config_path, .bash, false));
    try std.testing.expectEqual(InstallResult.already_present, try support.installShellConfig(allocator, config_path, .bash, false));

    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "# >>> wt initialize >>>") != null);
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
    try @import("../fs.zig").writeFile(allocator, config_path, stale);

    try std.testing.expectEqual(InstallResult.planned_update, try support.installShellConfig(allocator, config_path, .bash, true));

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
    try @import("../fs.zig").writeFile(allocator, config_path, initial);

    try std.testing.expectEqual(RemoveResult.removed, try support.removeShellConfig(allocator, config_path, false));

    const after = try std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "# >>> wt initialize >>>") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# preamble") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# postamble") != null);
}

test "run with no prompt suppresses activation guidance" {
    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout_al = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_al.adaptToNewApi(&stdout_io_buf);
    var stderr_al = stderr_buffer.writer(allocator);
    var stderr_io_buf: [4096]u8 = undefined;
    var stderr_adapted = stderr_al.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(.{ .allocator = allocator, .format = .text }, &.{ "--no-prompt", "--dry-run", "bash" }, &stdout_adapted.new_interface, &stderr_adapted.new_interface);
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();
    try std.testing.expectEqual(0, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Would append to ") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "To activate, run:") == null);
}

test "run rejects powershell on non-windows after parsing flags" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout_al = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_al.adaptToNewApi(&stdout_io_buf);
    var stderr_al = stderr_buffer.writer(allocator);
    var stderr_io_buf: [4096]u8 = undefined;
    var stderr_adapted = stderr_al.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(.{ .allocator = allocator, .format = .text }, &.{ "powershell", "--dry-run" }, &stdout_adapted.new_interface, &stderr_adapted.new_interface);
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();
    try std.testing.expectEqual(1, exit_code);
    try std.testing.expectEqual(0, stdout_buffer.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "PowerShell shell integration is only supported on Windows") != null);
}
