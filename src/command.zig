const std = @import("std");

pub const Kind = enum {
    help,
    version,
    list,
    status,
    default,
    config,
    hook,
    completion,
    checkout,
    create,
    info,
    remove,
    prune,
    cleanup,
    merge,
    migrate,
    pr,
    mr,
    examples,
    shellenv,
    init,
    done,
    switch_cmd,
    step,
    ui,
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
        .usage = "wt list [--full]",
        .details = "Read Git's porcelain worktree output, parse it, and render a small text summary. Use --full to include current, dirty, and upstream ahead/behind status for each worktree.",
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
        .usage = "wt config <show|path|init|alias|approvals>",
        .details = "Inspect the active config file path, print effective configuration sources, manage configured aliases with `wt config alias show [name]` and `wt config alias dry-run <name> [-- <args>...]`, manage project command approvals with `wt config approvals <show|add|clear>`, or create a starter config file with `wt config init [--force]`.",
    },
    .{
        .kind = .hook,
        .name = "hook",
        .aliases = &.{},
        .display = "hook",
        .summary = "Show configured hooks",
        .usage = "wt hook show [name]",
        .details = "Display the configured hook commands, or a single hook when a name is provided.",
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
        .usage = "wt remove [branches...] [--force|-f] [--no-delete-branch] [--force-delete|-D]",
        .details = "Remove one or more linked worktrees, optionally force worktree removal, and delete the branch when it is safe. Use --no-delete-branch to keep branches or --force-delete to delete them even when unsafe.",
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
        .kind = .merge,
        .name = "merge",
        .aliases = &.{},
        .display = "merge",
        .summary = "Merge current branch into a target branch",
        .usage = "wt merge [target] [--no-remove] [--no-ff] [--squash] [--rebase] [--push] [--no-hooks] [--message <message>]",
        .details = "Merge the current branch into the target branch, which defaults to the default base. Fast-forward merges are used by default; --no-ff creates a merge commit when the target branch has a worktree. Opt into pipeline steps with --squash, --rebase, and --push. Removes the source worktree after merge unless --no-remove is passed.",
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
        .usage = "wt done [--force|-f] [--no-delete-branch] [--force-delete|-D]",
        .details = "Detect the linked worktree for the current directory, remove it using the standard removal flow (hooks and cleanup), safely delete the branch by default, and navigate back to the main project directory.",
    },
    .{
        .kind = .switch_cmd,
        .name = "switch",
        .aliases = &.{ "sw", "cd", "jump", "j" },
        .display = "switch, sw, cd, jump, j",
        .summary = "Switch to, create, or checkout a worktree",
        .usage = "wt switch [--create|-c] [--base <branch>] [--execute|-x <command>] <branch|^|@|-|pr:N|mr:N> [-- <args>...]",
        .details = "Navigate to an existing worktree by branch name, create a new branch with --create, checkout an existing branch into a worktree, or use shortcuts like ^ for the main worktree, @ for the current worktree, - for OLDPWD, pr:N, and mr:N. Use --execute to run a shell command after switching.",
    },
    .{
        .kind = .step,
        .name = "step",
        .aliases = &.{},
        .display = "step",
        .summary = "Run focused workflow steps",
        .usage = "wt step <commit|squash|rebase|push|promote|diff|copy-ignored|relocate|prune> ...",
        .details = "Run workflow subcommands. `wt step commit`, `squash`, `rebase`, and `push` provide deterministic git-backed workflow primitives. `wt step promote` swaps a branch into the main worktree. `wt step diff` shows all changes since branching, including committed, staged, unstaged, and untracked files. `wt step copy-ignored` copies gitignored files and directories between worktrees, optionally constrained by `.worktreeinclude`. `wt step relocate` moves the current worktree to its configured path using the migrate planner.",
    },
    .{
        .kind = .ui,
        .name = "ui",
        .aliases = &.{},
        .display = "ui",
        .summary = "Open an interactive worktree UI (requires gum)",
        .usage = "wt ui [jump|remove] [--force|-f]",
        .details = "Launch a gum-powered picker to navigate to a worktree or remove linked worktrees with confirmation. Use `wt ui remove --force` to forward force removal.",
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

test "find resolves switch cd alias" {
    const spec = find("cd") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Kind.switch_cmd, spec.kind);
}

test "find resolves legacy jump alias to switch" {
    const spec = find("jump") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Kind.switch_cmd, spec.kind);
}
