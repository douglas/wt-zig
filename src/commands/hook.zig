const std = @import("std");
const config = @import("../config.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try printHelp(stdout);
        return 0;
    }

    if (!std.mem.eql(u8, args[0], "show")) {
        if (output.isJson(ctx)) {
            const message = try std.fmt.allocPrint(ctx.allocator, "Unknown hook command: {s}", .{args[0]});
            defer ctx.allocator.free(message);
            try output.emitError(ctx, stdout, "wt hook", message);
        } else {
            try stderr.print("Unknown hook command: {s}\n\n", .{args[0]});
            try printHelp(stderr);
        }
        return 1;
    }

    if (args.len > 2) {
        return output.usageError(ctx, stdout, stderr, "wt hook show", "Usage: wt hook show [name]");
    }

    if (args.len == 2) {
        const command_list = findHook(cfg, args[1]) orelse {
            return unknownHook(ctx, stdout, stderr, args[1]);
        };

        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt hook show", .{
                .hook = .{
                    .name = args[1],
                    .commands = command_list,
                },
            });
        } else {
            try printHookGroup(args[1], command_list, stdout, ctx.allocator);
        }
        return 0;
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt hook show", .{
            .hooks = cfg.hooks,
        });
    } else {
        try printHooks(cfg, stdout, ctx.allocator);
    }
    return 0;
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Show configured hook commands.
        \\
        \\Usage:
        \\  wt hook show [name]
        \\
        \\Commands:
        \\  show [name]
        \\      Print all configured hooks or a single hook
        \\
    );
}

fn printHooks(cfg: *const config.Resolved, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (!hasHooks(cfg.hooks)) {
        try writer.writeAll("Hooks:  (none configured)\n\n");
        return;
    }

    try writer.writeAll("Hooks:\n");
    inline for (comptime std.meta.fields(@TypeOf(cfg.hooks))) |field| {
        try printHookField(field.name, @field(cfg.hooks, field.name), writer, allocator);
    }
    try writer.writeByte('\n');
}

fn printHookGroup(name: []const u8, commands: []const []const u8, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (commands.len == 0) {
        try writer.print("  {s}: (no commands)\n", .{name});
        return;
    }

    for (commands) |command| {
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try writer.print("  {s}: {s}\n", .{ name, safe });
    }
}

fn printHookField(name: []const u8, commands: []const []const u8, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    if (commands.len == 0) return;
    try printHookGroup(name, commands, writer, allocator);
}

fn findHook(cfg: *const config.Resolved, name: []const u8) ?[]const []const u8 {
    inline for (comptime std.meta.fields(@TypeOf(cfg.hooks))) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(cfg.hooks, field.name);
        }
    }
    return null;
}

fn hasHooks(hooks_value: config.Hooks) bool {
    inline for (comptime std.meta.fields(@TypeOf(hooks_value))) |field| {
        if (@field(hooks_value, field.name).len != 0) return true;
    }
    return false;
}

fn unknownHook(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    hook_name: []const u8,
) !u8 {
    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "Unknown hook: {s}", .{hook_name});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt hook show", message);
    } else {
        try stderr.print("Unknown hook: {s}\n", .{hook_name});
    }
    return 1;
}

test "findHook resolves configured hook commands" {
    var cfg = config.testing_defaults;
    cfg.hooks.pre_start = &.{"echo start"};

    const found = findHook(&cfg, "pre_start") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(1, found.len);
    try std.testing.expect(findHook(&cfg, "missing") == null);
}
