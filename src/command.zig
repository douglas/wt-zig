const std = @import("std");

pub const Kind = enum {
    help,
    version,
    list,
    status,
    default,
    config,
    completion,
    checkout,
    create,
    info,
    remove,
    prune,
    cleanup,
    migrate,
    pr,
    mr,
    examples,
    shellenv,
    init,
    done,
    jump,
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
        .kind = .status,
        .name = "status",
        .aliases = &.{},
        .display = "status",
        .summary = "Show status dashboard of all worktrees",
        .usage = "wt status",
        .details = "For each worktree, show branch, path, dirty state, and ahead/behind tracking relative to upstream.",
    },
    .{
        .kind = .default,
        .name = "default",
        .aliases = &.{},
        .display = "default",
        .summary = "Navigate to the main worktree",
        .usage = "wt default",
        .details = "Resolve the main worktree path for the current repository and emit the navigation marker.",
    },
    .{
        .kind = .config,
        .name = "config",
        .aliases = &.{},
        .display = "config",
        .summary = "Inspect resolved configuration values",
        .usage = "wt config <show|path|init>",
        .details = "Inspect the active config file path, print effective configuration sources, or create a starter config file with `wt config init [--force]`.",
    },
    .{
        .kind = .completion,
        .name = "completion",
        .aliases = &.{},
        .display = "completion",
        .summary = "Generate completion script for the specified shell",
        .usage = "wt completion [bash|zsh|fish|powershell]",
        .details = "Generate shell completion script text for bash, zsh, fish, or PowerShell.",
    },
    .{
        .kind = .checkout,
        .name = "checkout",
        .aliases = &.{"co"},
        .display = "checkout, co",
        .summary = "Create a worktree for an existing branch",
        .usage = "wt checkout [branch]",
        .details = "Create a new worktree for an existing branch using the configured path strategy, or interactively choose a branch in text mode.",
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
        .usage = "wt remove [branch] [--force|-f]",
        .details = "Remove an existing linked worktree, optionally force the underlying git removal, and prompt for branch selection in text mode when no branch is given.",
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
        .usage = "wt cleanup [--dry-run] [--force|-f] [--stale] [--stale-days <days>]",
        .details = "Find linked worktrees whose branches are merged into the default base branch; with --stale also include branches with deleted remotes or old commits.",
    },
    .{
        .kind = .migrate,
        .name = "migrate",
        .aliases = &.{},
        .display = "migrate",
        .summary = "Migrate existing worktrees to the configured path strategy",
        .usage = "wt migrate [--force|-f]",
        .details = "Move linked worktrees into their configured locations and move the primary checkout back under ~/src when it currently lives inside WORKTREE_ROOT.",
    },
    .{
        .kind = .pr,
        .name = "pr",
        .aliases = &.{},
        .display = "pr",
        .summary = "Checkout a GitHub pull request in a worktree",
        .usage = "wt pr [number|url]",
        .details = "Resolve a GitHub PR to its source branch with `gh`, reuse the checkout flow, or interactively choose from open PRs in text mode.",
    },
    .{
        .kind = .mr,
        .name = "mr",
        .aliases = &.{},
        .display = "mr",
        .summary = "Checkout a GitLab merge request in a worktree",
        .usage = "wt mr [number|url]",
        .details = "Resolve a GitLab MR to its source branch with `glab`, reuse the checkout flow, or interactively choose from open merge requests in text mode.",
    },
    .{
        .kind = .examples,
        .name = "examples",
        .aliases = &.{},
        .display = "examples",
        .summary = "Show detailed command examples and outcomes",
        .usage = "wt examples",
        .details = "Print the full examples catalog for the current wt-zig feature set in either text or JSON form.",
    },
    .{
        .kind = .shellenv,
        .name = "shellenv",
        .aliases = &.{},
        .display = "shellenv",
        .summary = "Print shell integration for automatic directory navigation",
        .usage = "wt shellenv",
        .details = "Emit OS-appropriate shell integration that follows `wt navigating to:` markers, skips auto-cd in JSON mode, and registers shell completions.",
    },
    .{
        .kind = .init,
        .name = "init",
        .aliases = &.{},
        .display = "init",
        .summary = "Install wt shell integration into your shell rc file",
        .usage = "wt init [bash|zsh|powershell] [--dry-run] [--uninstall] [--no-prompt]",
        .details = "Append, update, preview, or remove an idempotent `wt shellenv` block in the detected bash, zsh, or PowerShell config file.",
    },
    .{
        .kind = .done,
        .name = "done",
        .aliases = &.{},
        .display = "done",
        .summary = "Remove the current linked worktree and navigate back",
        .usage = "wt done [--force|-f]",
        .details = "Detect the linked worktree for the current directory, remove it using the standard removal flow (hooks and cleanup), and navigate back to the main project directory.",
    },
    .{
        .kind = .jump,
        .name = "jump",
        .aliases = &.{"j"},
        .display = "jump, j",
        .summary = "Navigate to an existing worktree by branch name",
        .usage = "wt jump [query]",
        .details = "Find a worktree matching the query using exact, word-boundary, substring, or fuzzy matching, then navigate to it. Without a query, shows an interactive picker.",
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
