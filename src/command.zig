const std = @import("std");

pub const Kind = enum {
    help,
    version,
    list,
    config,
    checkout,
    create,
};

pub const Spec = struct {
    kind: Kind,
    name: []const u8,
    aliases: []const []const u8,
    display: []const u8,
    summary: []const u8,
    usage: []const u8,
    details: []const u8,
};

pub const all = [_]Spec{
    .{
        .kind = .help,
        .name = "help",
        .aliases = &.{},
        .display = "help",
        .summary = "Show help for wt or a specific command",
        .usage = "wt help [command]",
        .details = "Print root help or detailed usage for a specific command.",
    },
    .{
        .kind = .version,
        .name = "version",
        .aliases = &.{},
        .display = "version",
        .summary = "Show the wt build version",
        .usage = "wt version",
        .details = "Print the current wt version string for troubleshooting and automation.",
    },
    .{
        .kind = .list,
        .name = "list",
        .aliases = &.{"ls"},
        .display = "list, ls",
        .summary = "List worktrees using `git worktree list --porcelain`",
        .usage = "wt list",
        .details = "Read Git's porcelain worktree output, parse it, and render a small text summary.",
    },
    .{
        .kind = .config,
        .name = "config",
        .aliases = &.{},
        .display = "config",
        .summary = "Inspect resolved configuration values",
        .usage = "wt config <show|path>",
        .details = "Inspect the active config file path and effective configuration sources.",
    },
    .{
        .kind = .checkout,
        .name = "checkout",
        .aliases = &.{"co"},
        .display = "checkout, co",
        .summary = "Create a worktree for an existing branch",
        .usage = "wt checkout <branch>",
        .details = "Create a new worktree for an existing branch using the configured path strategy.",
    },
    .{
        .kind = .create,
        .name = "create",
        .aliases = &.{},
        .display = "create",
        .summary = "Create a new branch in a worktree",
        .usage = "wt create <branch> [base-branch]",
        .details = "Create a new branch and worktree using the configured path strategy.",
    },
};

pub fn find(name: []const u8) ?*const Spec {
    for (&all) |*spec| {
        if (std.mem.eql(u8, name, spec.name)) {
            return spec;
        }

        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) {
                return spec;
            }
        }
    }

    return null;
}

test "find resolves aliases" {
    const spec = find("ls") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Kind.list, spec.kind);
}
