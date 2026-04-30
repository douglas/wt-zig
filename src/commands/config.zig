const std = @import("std");
const approvals = @import("../approvals.zig");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");
const path = @import("../path.zig");

pub fn run(ctx: output.Context, args: []const []const u8, cfg: *const config.Resolved, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (args.len == 0) {
        try printHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "alias")) {
        return runAlias(ctx, args[1..], cfg, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "approvals")) {
        return runApprovals(ctx, args[1..], cfg, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 1) {
            return output.usageError(ctx, stdout, stderr, "wt config show", "Usage: wt config show");
        }
        if (output.isJson(ctx)) {
            try printShowJson(ctx, cfg, stdout);
        } else {
            try printShow(cfg, stdout);
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "path")) {
        if (args.len != 1) {
            return output.usageError(ctx, stdout, stderr, "wt config path", "Usage: wt config path");
        }
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config path", .{ .path = cfg.config_file_path });
        } else {
            try stdout.writeAll(cfg.config_file_path);
            try stdout.writeByte('\n');
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "init")) {
        const force = parseInitForce(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt config init", "Usage: wt config init [--force]");
        };

        config.writeDefaultConfig(ctx.allocator, cfg.config_file_path, force) catch |err| switch (err) {
            error.ConfigFileAlreadyExists => {
                if (output.isJson(ctx)) {
                    const message = try std.fmt.allocPrint(ctx.allocator, "config file already exists: {s}", .{cfg.config_file_path});
                    defer ctx.allocator.free(message);
                    try output.emitError(ctx, stdout, "wt config init", message);
                } else {
                    try stderr.print("config file already exists: {s}\n", .{cfg.config_file_path});
                }
                return 1;
            },
            else => return err,
        };

        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config init", .{
                .path = cfg.config_file_path,
                .status = "created",
            });
        } else {
            try stdout.print("Created config file: {s}\n", .{cfg.config_file_path});
        }
        return 0;
    }

    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "Unknown config command: {s}", .{args[0]});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt config", message);
    } else {
        try stderr.print("Unknown config command: {s}\n\n", .{args[0]});
        try printHelp(stderr);
    }
    return 1;
}

fn runAlias(
    ctx: output.Context,
    args: []const []const u8,
    cfg: *const config.Resolved,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try printAliasHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        return runAliasShow(ctx, args[1..], cfg, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "dry-run")) {
        return runAliasDryRun(ctx, args[1..], cfg, stdout, stderr);
    }

    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "Unknown config alias command: {s}", .{args[0]});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt config alias", message);
    } else {
        try stderr.print("Unknown config alias command: {s}\n\n", .{args[0]});
        try printAliasHelp(stderr);
    }
    return 1;
}

fn runApprovals(
    ctx: output.Context,
    args: []const []const u8,
    cfg: *const config.Resolved,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try printApprovalsHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len != 1 and !(args.len == 2 and std.mem.eql(u8, args[1], "--all"))) {
            return output.usageError(ctx, stdout, stderr, "wt config approvals add", "Usage: wt config approvals add [--all]");
        }

        var result = try approvals.approveProjectCommands(ctx.allocator, cfg);
        defer result.deinit(ctx.allocator);
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config approvals add", .{
                .path = result.path,
                .added = result.added,
                .total = result.total,
            });
        } else if (cfg.config_repo_found) {
            try stdout.print("Approved {d} new project command(s); {d} total in {s}\n", .{
                result.added,
                result.total,
                result.path,
            });
        } else {
            try stdout.print("No project config found; approvals file: {s}\n", .{result.path});
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 1) {
            return output.usageError(ctx, stdout, stderr, "wt config approvals show", "Usage: wt config approvals show");
        }

        var state = try approvals.load(ctx.allocator, cfg);
        defer state.deinit(ctx.allocator);
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config approvals show", .{
                .path = state.path,
                .commands = state.commands,
            });
        } else {
            try printApprovedCommands(state.path, state.commands, stdout, ctx.allocator);
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "clear")) {
        if (args.len != 1) {
            return output.usageError(ctx, stdout, stderr, "wt config approvals clear", "Usage: wt config approvals clear");
        }

        const path_value = try approvals.clear(ctx.allocator, cfg);
        defer ctx.allocator.free(path_value);
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config approvals clear", .{ .path = path_value });
        } else {
            try stdout.print("Cleared approvals: {s}\n", .{path_value});
        }
        return 0;
    }

    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "Unknown config approvals command: {s}", .{args[0]});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt config approvals", message);
    } else {
        try stderr.print("Unknown config approvals command: {s}\n\n", .{args[0]});
        try printApprovalsHelp(stderr);
    }
    return 1;
}

fn runAliasShow(
    ctx: output.Context,
    args: []const []const u8,
    cfg: *const config.Resolved,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len > 1) {
        return output.usageError(ctx, stdout, stderr, "wt config alias show", "Usage: wt config alias show [name]");
    }

    if (args.len == 1) {
        const alias = findAlias(cfg, args[0]) orelse {
            return unknownAlias(ctx, stdout, stderr, "wt config alias show", args[0]);
        };

        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt config alias show", .{
                .alias = .{
                    .name = alias.name,
                    .commands = alias.commands,
                },
            });
        } else {
            try printAlias(alias, stdout, ctx.allocator);
        }
        return 0;
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt config alias show", .{
            .aliases = cfg.aliases,
        });
    } else {
        try printAliases(cfg.aliases, stdout, ctx.allocator);
    }
    return 0;
}

fn runAliasDryRun(
    ctx: output.Context,
    args: []const []const u8,
    cfg: *const config.Resolved,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseAliasDryRunArgs(args) catch {
        return output.usageError(
            ctx,
            stdout,
            stderr,
            "wt config alias dry-run",
            "Usage: wt config alias dry-run <name> [-- <args>...]",
        );
    };

    const alias = findAlias(cfg, parsed.name) orelse {
        return unknownAlias(ctx, stdout, stderr, "wt config alias dry-run", parsed.name);
    };

    if (alias.commands.len == 0) {
        if (output.isJson(ctx)) {
            const message = try std.fmt.allocPrint(ctx.allocator, "alias \"{s}\" has no commands", .{alias.name});
            defer ctx.allocator.free(message);
            try output.emitError(ctx, stdout, "wt config alias dry-run", message);
        } else {
            try stderr.print("alias \"{s}\" has no commands\n", .{alias.name});
        }
        return 1;
    }

    const preview_commands = try buildDryRunCommands(ctx.allocator, alias.commands, parsed.extra_args);
    defer freeCommandList(ctx.allocator, preview_commands);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt config alias dry-run", .{
            .alias = .{
                .name = alias.name,
                .commands = preview_commands,
            },
        });
    } else {
        try printCommands(preview_commands, stdout, ctx.allocator);
    }
    return 0;
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Manage wt configuration.
        \\
        \\Usage:
        \\  wt config <command>
        \\
        \\Commands:
        \\  approvals add
        \\      Approve all project-config hook and alias commands for this repository
        \\  approvals clear
        \\      Clear saved project-command approvals
        \\  approvals show
        \\      Print saved project-command approvals
        \\  alias dry-run <name> [-- <args>...]
        \\      Show the exact shell commands that would run for an alias without executing them
        \\  alias show [name]
        \\      Print configured aliases or a single alias
        \\  init
        \\      Create a starter config file at the resolved config path
        \\  show
        \\      Print the effective configuration and its sources
        \\  path
        \\      Print the resolved config file path
        \\
        \\Config also supports:
        \\  [aliases]
        \\      Custom shell commands. Extra CLI args are appended to the final alias command.
        \\  [step.copy-ignored]
        \\      exclude = ["cache/", "*.sqlite", "!cache/keep.sqlite"]
        \\
    );
}

fn printAliasHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Manage configured aliases.
        \\
        \\Usage:
        \\  wt config alias <command>
        \\
        \\Commands:
        \\  dry-run <name> [-- <args>...]
        \\      Show the shell commands that would run without executing them
        \\  show [name]
        \\      Print all configured aliases or a single alias
        \\
    );
}

fn printApprovalsHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Manage project command approvals.
        \\
        \\Usage:
        \\  wt config approvals <command>
        \\
        \\Commands:
        \\  add [--all]
        \\      Approve all project-config hook and alias commands for this repository
        \\  clear
        \\      Clear saved approvals
        \\  show
        \\      Print saved approvals
        \\
        \\Project-config hooks and aliases are blocked until approved. User config commands
        \\are trusted. Use global --yes to bypass approval once without saving it.
        \\
    );
}

pub fn printShow(cfg: *const config.Resolved, writer: *std.Io.Writer) !void {
    const config_status = if (cfg.config_file_found) "found" else "not found";
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "(none)";
    const pattern_source = if (pattern_info) |info| info.source else cfg.sources.pattern;
    const copy_strategy = cfg.copy_files.strategy orelse "auto-detect";
    const copy_strategy_source = if (cfg.copy_files.strategy != null) "config" else "default";

    try writer.print(
        \\Config file: {s} ({s})
        \\
        \\Effective configuration:
        \\  root = {s} ({s})
        \\  strategy = {s} ({s})
        \\  pattern = {s} ({s})
        \\  separator = "{s}" ({s})
        \\  copy_strategy = {s} ({s})
        \\  copy_ignored.exclude = {d} pattern(s)
        \\  aliases = {d} configured
        \\
    ,
        .{
            cfg.config_file_path,
            config_status,
            cfg.root,
            cfg.sources.root,
            cfg.strategy,
            cfg.sources.strategy,
            pattern,
            pattern_source,
            cfg.separator,
            cfg.sources.separator,
            copy_strategy,
            copy_strategy_source,
            cfg.step.copy_ignored.exclude.len,
            cfg.aliases.len,
        },
    );

    if (cfg.config_repo_found) {
        try writer.print("Repo config: {s} (found)\n", .{cfg.config_repo_path});
    }
}

fn printShowJson(ctx: output.Context, cfg: *const config.Resolved, stdout: *std.Io.Writer) !void {
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "(none)";
    const pattern_source = if (pattern_info) |info| info.source else cfg.sources.pattern;
    const copy_strategy = cfg.copy_files.strategy orelse "auto-detect";
    const copy_strategy_source = if (cfg.copy_files.strategy != null) "config" else "default";

    const repo_config = if (cfg.config_repo_found) .{
        .path = cfg.config_repo_path,
        .status = "found",
    } else null;

    try output.emitSuccess(ctx, stdout, "wt config show", .{
        .config_file = .{
            .path = cfg.config_file_path,
            .status = if (cfg.config_file_found) "found" else "not found",
        },
        .repo_config = repo_config,
        .effective = .{
            .root = .{ .value = cfg.root, .source = cfg.sources.root },
            .strategy = .{ .value = cfg.strategy, .source = cfg.sources.strategy },
            .pattern = .{ .value = pattern, .source = pattern_source },
            .separator = .{ .value = cfg.separator, .source = cfg.sources.separator },
            .copy_strategy = .{ .value = copy_strategy, .source = copy_strategy_source },
            .copy_ignored_exclude = cfg.step.copy_ignored.exclude,
            .aliases = cfg.aliases,
        },
    });
}

fn printAliases(aliases: []const config.Alias, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (aliases.len == 0) {
        try writer.writeAll("Aliases:  (none configured)\n\n");
        return;
    }

    try writer.writeAll("Aliases:\n");
    for (aliases) |alias| {
        try printAlias(alias, writer, allocator);
    }
    try writer.writeByte('\n');
}

fn printAlias(alias: config.Alias, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    try writer.print("  {s}: ", .{alias.name});
    if (alias.commands.len == 0) {
        try writer.writeAll("(no commands)\n");
        return;
    }

    for (alias.commands, 0..) |command, index| {
        if (index != 0) try writer.writeAll(" && ");
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try writer.print("{s}", .{safe});
    }
    try writer.writeByte('\n');
}

fn printCommands(commands: []const []const u8, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    for (commands) |command| {
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try writer.print("{s}\n", .{safe});
    }
}

fn printApprovedCommands(
    approvals_path: []const u8,
    commands: []const []const u8,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) !void {
    try writer.print("Approvals file: {s}\n", .{approvals_path});
    if (commands.len == 0) {
        try writer.writeAll("Approved commands: (none)\n");
        return;
    }

    try writer.writeAll("Approved commands:\n");
    for (commands) |command| {
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try writer.print("  {s}\n", .{safe});
    }
}

fn findAlias(cfg: *const config.Resolved, name: []const u8) ?config.Alias {
    for (cfg.aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias;
    }
    return null;
}

fn unknownAlias(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    command_name: []const u8,
    alias_name: []const u8,
) !u8 {
    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "Unknown alias: {s}", .{alias_name});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, command_name, message);
    } else {
        try stderr.print("Unknown alias: {s}\n", .{alias_name});
    }
    return 1;
}

const AliasDryRunArgs = struct {
    name: []const u8,
    extra_args: []const []const u8,
};

fn parseAliasDryRunArgs(args: []const []const u8) !AliasDryRunArgs {
    if (args.len == 0) return error.InvalidArguments;
    if (args.len == 1) {
        return .{ .name = args[0], .extra_args = &.{} };
    }
    if (!std.mem.eql(u8, args[1], "--")) return error.InvalidArguments;
    return .{ .name = args[0], .extra_args = args[2..] };
}

fn buildDryRunCommands(
    allocator: std.mem.Allocator,
    commands: []const []const u8,
    extra_args: []const []const u8,
) ![]const []const u8 {
    var preview_commands = std.ArrayList([]const u8).empty;
    errdefer {
        for (preview_commands.items) |command| allocator.free(command);
        preview_commands.deinit(allocator);
    }

    for (commands, 0..) |command, index| {
        const preview = if (index == commands.len - 1)
            try hooks.appendArgs(allocator, command, extra_args)
        else
            try allocator.dupe(u8, command);
        preview_commands.append(allocator, preview) catch |err| {
            allocator.free(preview);
            return err;
        };
    }

    return preview_commands.toOwnedSlice(allocator);
}

fn freeCommandList(allocator: std.mem.Allocator, commands: []const []const u8) void {
    for (commands) |command| allocator.free(command);
    allocator.free(commands);
}

test "parseAliasDryRunArgs requires name and separator" {
    const parsed = try parseAliasDryRunArgs(&.{ "ship", "--", "arg one", "arg two" });
    try std.testing.expectEqualStrings("ship", parsed.name);
    try std.testing.expectEqual(2, parsed.extra_args.len);

    const no_args = try parseAliasDryRunArgs(&.{"ship"});
    try std.testing.expectEqual(0, no_args.extra_args.len);
    try std.testing.expectError(error.InvalidArguments, parseAliasDryRunArgs(&.{ "--", "oops" }));
    try std.testing.expectError(error.InvalidArguments, parseAliasDryRunArgs(&.{ "ship", "arg" }));
}

fn parseInitForce(args: []const []const u8) !bool {
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }

        return error.InvalidArguments;
    }

    return force;
}
