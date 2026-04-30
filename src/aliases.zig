const std = @import("std");
const config = @import("config.zig");
const hooks = @import("hooks.zig");

pub fn find(cfg: *const config.Resolved, name: []const u8) ?[]const []const u8 {
    for (cfg.aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias.commands;
    }

    return null;
}

pub fn run(
    allocator: std.mem.Allocator,
    alias_name: []const u8,
    commands: []const []const u8,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    if (commands.len == 0) {
        try stderr.print("alias \"{s}\" has no commands\n", .{alias_name});
        return 1;
    }

    for (commands, 0..) |command, index| {
        const command_to_run = if (index == commands.len - 1)
            try hooks.appendArgs(allocator, command, args)
        else
            try allocator.dupe(u8, command);
        defer allocator.free(command_to_run);

        const term = try hooks.runShellCommand(allocator, command_to_run, null);
        switch (term) {
            .Exited => |code| {
                if (code == 0) continue;
                return @intCast(code);
            },
            else => return 1,
        }
    }

    return 0;
}

test "find returns configured alias commands" {
    var cfg = config.testing_defaults;
    cfg.aliases = &.{.{
        .name = "recent",
        .commands = &.{"git branch --sort=-committerdate"},
    }};

    const commands = find(&cfg, "recent") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(1, commands.len);
    try std.testing.expectEqualStrings("git branch --sort=-committerdate", commands[0]);
    try std.testing.expect(find(&cfg, "missing") == null);
}
