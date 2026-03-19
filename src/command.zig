const std = @import("std");

pub const Kind = enum {
    help,
    version,
    list,
    config,
    checkout,
    create,
    info,
    remove,
    prune,
    cleanup,
    pr,
    mr,
    shellenv,
    init,
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
    .{
        .kind = .info,
        .name = "info",
        .aliases = &.{},
        .display = "info",
        .summary = "Show resolved worktree configuration and strategy details",
        .usage = "wt info",
        .details = "Display the active config path, effective pattern, strategy catalog, and configured hooks.",
    },
    .{
        .kind = .remove,
        .name = "remove",
        .aliases = &.{"rm"},
        .display = "remove, rm",
        .summary = "Remove a linked worktree for a branch",
        .usage = "wt remove <branch>",
        .details = "Remove an existing linked worktree, run remove hooks, and clean up the worktree directory.",
    },
    .{
        .kind = .prune,
        .name = "prune",
        .aliases = &.{},
        .display = "prune",
        .summary = "Prune stale Git worktree administrative files",
        .usage = "wt prune",
        .details = "Run `git worktree prune` to clean stale administrative metadata.",
    },
    .{
        .kind = .cleanup,
        .name = "cleanup",
        .aliases = &.{},
        .display = "cleanup",
        .summary = "Remove worktrees for merged branches",
        .usage = "wt cleanup",
        .details = "Find linked worktrees whose branches are merged into the default base branch and remove them.",
    },
    .{
        .kind = .pr,
        .name = "pr",
        .aliases = &.{},
        .display = "pr",
        .summary = "Checkout a GitHub pull request in a worktree",
        .usage = "wt pr <number|url>",
        .details = "Resolve a GitHub PR to its source branch with `gh` and reuse the checkout flow.",
    },
    .{
        .kind = .mr,
        .name = "mr",
        .aliases = &.{},
        .display = "mr",
        .summary = "Checkout a GitLab merge request in a worktree",
        .usage = "wt mr <number|url>",
        .details = "Resolve a GitLab MR to its source branch with `glab` and reuse the checkout flow.",
    },
    .{
        .kind = .shellenv,
        .name = "shellenv",
        .aliases = &.{},
        .display = "shellenv",
        .summary = "Print shell integration for automatic directory navigation",
        .usage = "wt shellenv",
        .details = "Emit a bash/zsh wrapper function that follows `wt navigating to:` markers after successful commands.",
    },
    .{
        .kind = .init,
        .name = "init",
        .aliases = &.{},
        .display = "init",
        .summary = "Install wt shell integration into your shell rc file",
        .usage = "wt init [bash|zsh]",
        .details = "Append an idempotent `wt shellenv` block to the detected bash or zsh config file.",
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
