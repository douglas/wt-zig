const std = @import("std");
const output = @import("../output.zig");

const UsageExample = struct {
    command: []const u8,
    purpose: []const u8,
    outcome: []const u8,
    exit_code: []const u8,
    text_example: ?[]const u8 = null,
    json_example: ?[]const u8 = null,
    path_example: ?[]const u8 = null,
    path_basis: ?[]const u8 = null,
    preconditions: []const []const u8 = &.{},
    side_effects: []const []const u8 = &.{},
    failure_modes: []const []const u8 = &.{},
    follow_up: []const []const u8 = &.{},
    notes: []const []const u8 = &.{},
};

const Topic = struct {
    name: []const u8,
    description: []const u8,
    examples: []const UsageExample,
};

const checkout_examples = [_]UsageExample{
    .{
        .command = "wt checkout feature-branch",
        .purpose = "Create or reuse a worktree for an existing local branch.",
        .outcome = "Worktree for feature-branch exists and branch is checked out there.",
        .exit_code = "0 on success; non-zero if branch does not exist or git worktree creation fails.",
        .text_example = "Worktree already exists: $WORKTREE_ROOT/<repo>/feature-branch\nwt navigating to: $WORKTREE_ROOT/<repo>/feature-branch",
        .path_example = "$WORKTREE_ROOT/<repo>/feature-branch (existing or created)",
        .path_basis = "Derived from the active pattern in wt info; this example assumes the default global strategy.",
        .preconditions = &.{"Run inside a git repository."},
        .side_effects = &.{
            "In text mode with shellenv, the wrapper may auto-navigate to the target path.",
            "In --format json mode, shell wrappers do not auto-navigate.",
        },
        .failure_modes = &.{
            "Branch does not exist: create it first or use wt create.",
            "Worktree add failure: inspect git worktree list and path conflicts.",
        },
        .follow_up = &.{ "wt list", "wt remove feature-branch" },
    },
    .{
        .command = "wt --format json checkout feature-branch",
        .purpose = "Machine-readable checkout flow for automation.",
        .outcome = "JSON envelope describing whether the worktree was created or already existed, including navigate_to.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt checkout\",\"data\":{\"status\":\"exists\",\"branch\":\"feature-branch\",\"path\":\"$WORKTREE_ROOT/<repo>/feature-branch\",\"navigate_to\":\"$WORKTREE_ROOT/<repo>/feature-branch\"}}",
        .notes = &.{"Parse data.navigate_to if your tool wants to change directories explicitly."},
    },
};

const create_examples = [_]UsageExample{
    .{
        .command = "wt create my-feature",
        .purpose = "Create a new branch from the default base (main/master) and create its worktree.",
        .outcome = "The new branch exists, the worktree directory is created, and the branch is checked out there.",
        .exit_code = "0 on success; non-zero if the base is missing or the branch/path conflicts.",
        .text_example = "Worktree created at: $WORKTREE_ROOT/<repo>/my-feature\nwt navigating to: $WORKTREE_ROOT/<repo>/my-feature",
        .path_example = "global: $WORKTREE_ROOT/<repo>/my-feature\nsibling-repo: <repo-main-parent>/<repo>-my-feature\nparent-branches: <repo-main-parent>/my-feature\nparent-worktrees: <repo-main-parent>/<repo>.worktrees/my-feature\ncustom pattern: $WORKTREE_ROOT/custom/<repo>/my-feature",
        .path_basis = "Static placeholders for one branch name across strategies. <repo-main-parent> contains the main checkout at <repo-main-parent>/<repo>.",
        .preconditions = &.{"Repository has main or master, or pass an explicit base branch."},
        .side_effects = &.{
            "Runs configured pre_create and post_create hooks.",
            "Text mode with shellenv may auto-navigate.",
        },
        .failure_modes = &.{
            "Base branch missing: use wt create my-feature <base>.",
            "Worktree path conflict: inspect existing worktrees with wt list.",
        },
        .follow_up = &.{ "wt list", "wt remove my-feature" },
    },
    .{
        .command = "wt --format json create my-feature",
        .purpose = "Automation-friendly branch/worktree creation output.",
        .outcome = "JSON envelope with status, branch, base, path, and navigate_to.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt create\",\"data\":{\"status\":\"created\",\"branch\":\"my-feature\",\"base\":\"main\",\"path\":\"$WORKTREE_ROOT/<repo>/my-feature\",\"navigate_to\":\"$WORKTREE_ROOT/<repo>/my-feature\"}}",
        .side_effects = &.{"No auto-navigation marker is printed in JSON mode."},
    },
};

const pr_examples = [_]UsageExample{
    .{
        .command = "wt pr 123",
        .purpose = "Fetch a GitHub PR branch and create a worktree from it.",
        .outcome = "A local branch for the PR exists and a worktree is checked out there.",
        .exit_code = "0 on success; non-zero if gh/git operations fail.",
        .text_example = "PR #123 (pr-123) checked out at: $WORKTREE_ROOT/<repo>/pr-123\nwt navigating to: $WORKTREE_ROOT/<repo>/pr-123",
        .preconditions = &.{"gh CLI installed and authenticated for repo access."},
        .failure_modes = &.{ "PR not found or inaccessible.", "Network or auth issues with GitHub." },
        .follow_up = &.{ "wt list", "wt remove pr-123" },
    },
    .{
        .command = "wt --format json pr 123",
        .purpose = "Reference machine-readable PR checkout for tooling.",
        .outcome = "JSON envelope with status, PR id, branch, path, and navigate_to.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt pr\",\"data\":{\"status\":\"created\",\"id\":\"123\",\"kind\":\"pr\",\"branch\":\"pr-123\",\"path\":\"$WORKTREE_ROOT/<repo>/pr-123\",\"navigate_to\":\"$WORKTREE_ROOT/<repo>/pr-123\"}}",
        .failure_modes = &.{"Interactive PR selection is not supported in JSON mode; pass a number or URL."},
    },
};

const mr_examples = [_]UsageExample{
    .{
        .command = "wt mr 123",
        .purpose = "Fetch a GitLab MR branch and create a worktree from it.",
        .outcome = "A local branch for the MR exists and a worktree is checked out there.",
        .exit_code = "0 on success; non-zero if glab/git operations fail.",
        .text_example = "MR #123 (mr-123) checked out at: $WORKTREE_ROOT/<repo>/mr-123\nwt navigating to: $WORKTREE_ROOT/<repo>/mr-123",
        .preconditions = &.{"glab CLI installed and authenticated for repo access."},
        .failure_modes = &.{ "MR not found or inaccessible.", "Network or auth issues with GitLab." },
        .follow_up = &.{ "wt list", "wt remove mr-123" },
    },
    .{
        .command = "wt --format json mr 123",
        .purpose = "Reference machine-readable MR checkout output.",
        .outcome = "JSON envelope with status, MR id, branch, path, and navigate_to.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt mr\",\"data\":{\"status\":\"created\",\"id\":\"123\",\"kind\":\"mr\",\"branch\":\"mr-123\",\"path\":\"$WORKTREE_ROOT/<repo>/mr-123\",\"navigate_to\":\"$WORKTREE_ROOT/<repo>/mr-123\"}}",
        .failure_modes = &.{"Interactive MR selection is not supported in JSON mode; pass a number or URL."},
    },
};

const list_examples = [_]UsageExample{
    .{
        .command = "wt list",
        .purpose = "Inspect currently registered git worktrees.",
        .outcome = "Text summary built from git worktree list --porcelain.",
        .exit_code = "0 on success.",
        .text_example = "$WORKTREE_ROOT/<repo>                             a1b2c3d [main]\n$WORKTREE_ROOT/<repo>/feature-login               d4e5f6a [feature-login]",
        .follow_up = &.{ "wt remove <branch>", "wt cleanup" },
        .failure_modes = &.{"Outside a git repository the command fails."},
    },
    .{
        .command = "wt --format json list",
        .purpose = "Reference structured worktree inventory for scripts and assistants.",
        .outcome = "JSON envelope containing worktree entries parsed from git porcelain output.",
        .exit_code = "0 on success.",
        .json_example = "{\"ok\":true,\"command\":\"wt list\",\"data\":{\"worktrees\":[{\"path\":\"$WORKTREE_ROOT/<repo>\",\"branch\":\"main\",\"head\":\"a1b2c3d\"}]}}",
    },
};

const remove_examples = [_]UsageExample{
    .{
        .command = "wt remove old-branch",
        .purpose = "Delete a worktree for a branch and clean up directory bookkeeping.",
        .outcome = "The branch worktree path is removed; text mode may navigate back to the main worktree.",
        .exit_code = "0 on success; non-zero if the branch has no worktree or removal fails.",
        .text_example = "Removed worktree: $WORKTREE_ROOT/<repo>/old-branch\nwt navigating to: <main-worktree-path>",
        .path_example = "global: $WORKTREE_ROOT/<repo>/old-branch -> (removed)\nsibling-repo: <repo-main-parent>/<repo>-old-branch -> (removed)\nparent-branches: <repo-main-parent>/old-branch -> (removed)\nparent-worktrees: <repo-main-parent>/<repo>.worktrees/old-branch -> (removed)\ncustom pattern: $WORKTREE_ROOT/custom/<repo>/old-branch -> (removed)",
        .path_basis = "Static placeholders for one branch across strategies. <repo-main-parent> contains the main checkout at <repo-main-parent>/<repo>.",
        .preconditions = &.{"The target branch currently has a linked worktree."},
        .failure_modes = &.{ "Dirty worktree may require --force in the Go CLI.", "No matching worktree for the branch." },
        .follow_up = &.{"wt list"},
    },
    .{
        .command = "wt --format json remove old-branch",
        .purpose = "Reference machine-readable removal flow.",
        .outcome = "JSON envelope with removed path and navigate_to target.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt remove\",\"data\":{\"status\":\"removed\",\"branch\":\"old-branch\",\"path\":\"$WORKTREE_ROOT/<repo>/old-branch\",\"navigate_to\":\"<main-worktree-path>\"}}",
        .failure_modes = &.{"JSON mode requires an explicit branch argument; there is no interactive selector."},
    },
};

const cleanup_examples = [_]UsageExample{
    .{
        .command = "wt cleanup --dry-run",
        .purpose = "Preview merged-branch worktrees that would be removed.",
        .outcome = "Lists candidate worktrees without deleting them.",
        .exit_code = "0 on success.",
        .text_example = "Would remove 1 worktree(s) for merged branches:\n  - old-feature ($WORKTREE_ROOT/<repo>/old-feature)",
        .path_example = "$WORKTREE_ROOT/<repo>/<merged-branch> -> (candidate for removal)",
        .path_basis = "Candidates are discovered from merged branches and mapped through the active pattern.",
        .side_effects = &.{"No deletions happen in dry-run mode."},
        .follow_up = &.{"wt cleanup"},
        .failure_modes = &.{"Merge-base detection may fail in unusual repository states."},
    },
    .{
        .command = "wt --format json cleanup --force",
        .purpose = "Reference batch cleanup with a machine-readable summary.",
        .outcome = "JSON envelope with removed and skipped counters.",
        .exit_code = "0 on success; non-zero on errors.",
        .json_example = "{\"ok\":true,\"command\":\"wt cleanup\",\"data\":{\"dry_run\":false,\"base\":\"main\",\"removed\":1,\"skipped\":0}}",
        .failure_modes = &.{"In JSON mode, cleanup requires --force or --dry-run."},
    },
};

const examples_examples = [_]UsageExample{
    .{
        .command = "wt examples",
        .purpose = "Inspect the full examples catalog for all commands.",
        .outcome = "Prints all example topics with outcomes, text/json samples, and operational notes.",
        .exit_code = "0 on success.",
        .text_example = "wt examples\n\ncheckout: Checkout an existing branch in a worktree\n  wt checkout feature-branch\n...",
        .failure_modes = &.{"This command takes no arguments; `wt examples <topic>` fails."},
        .follow_up = &.{"wt help <command>"},
    },
};

const init_examples = [_]UsageExample{
    .{
        .command = "wt init --dry-run",
        .purpose = "Preview shell profile changes before writing anything.",
        .outcome = "Shows what would be added or updated in the detected shell profile.",
        .exit_code = "0 on success; non-zero if shell or config-path detection fails.",
        .text_example = "Would append to ~/.bashrc:\n\n# >>> wt initialize >>>\neval \"$(wt shellenv)\"\n# <<< wt initialize <<<",
        .preconditions = &.{"Run in an environment where shell/profile detection works, or pass an explicit shell."},
        .failure_modes = &.{ "Unsupported shell argument.", "PowerShell integration requested on a non-Windows host." },
        .follow_up = &.{ "wt init", "wt init --uninstall" },
    },
    .{
        .command = "wt --format json init --dry-run",
        .purpose = "Machine-readable dry-run output for shell integration setup.",
        .outcome = "JSON envelope describing the detected shell, config path, and action.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt init\",\"data\":{\"status\":\"planned\",\"shell\":\"bash\",\"config_path\":\"~/.bashrc\",\"dry_run\":true,\"operation\":\"install\"}}",
        .notes = &.{"Use an explicit shell argument in automation for deterministic behavior."},
    },
};

const migrate_examples = [_]UsageExample{
    .{
        .command = "wt migrate",
        .purpose = "Move managed worktrees to paths derived from the current configuration.",
        .outcome = "Worktrees are moved where possible; non-empty target paths are skipped unless force is used.",
        .exit_code = "0 when the migration plan completes; non-zero on fatal errors.",
        .text_example = "Moved feature-a: $WORKTREE_ROOT_OLD/<repo>/feature-a -> $WORKTREE_ROOT_NEW/<repo>/feature-a\nMigration complete: 1 moved, 0 skipped, 0 failed.",
        .path_example = "global -> sibling-repo: $WORKTREE_ROOT_OLD/<repo>/<branch> -> <repo-main-parent>/<repo>-<branch>\nglobal -> parent-branches: $WORKTREE_ROOT_OLD/<repo>/<branch> -> <repo-main-parent>/<branch>\nsibling-repo -> global: <repo-main-parent>/<repo>-<branch> -> $WORKTREE_ROOT_NEW/<repo>/<branch>",
        .path_basis = "Static placeholders compare strategy switches for the same branch. <repo-main-parent> contains the main checkout at <repo-main-parent>/<repo>.",
        .preconditions = &.{"Set the desired strategy or pattern first with wt config or environment variables."},
        .failure_modes = &.{ "Target path already exists and is non-empty.", "Filesystem move or rename failures." },
        .follow_up = &.{ "wt list", "wt info" },
    },
    .{
        .command = "wt --format json migrate --force",
        .purpose = "Reference migration results in automation without shell parsing.",
        .outcome = "JSON envelope reporting totals, migrated entries, skipped entries, and failures.",
        .exit_code = "0 when migration completes; non-zero on fatal errors.",
        .json_example = "{\"ok\":true,\"command\":\"wt migrate\",\"data\":{\"force\":true,\"total\":4,\"migrated\":4,\"skipped\":0,\"failed\":0}}",
    },
};

const prune_examples = [_]UsageExample{
    .{
        .command = "wt prune",
        .purpose = "Clean stale git worktree metadata entries.",
        .outcome = "Prunes stale administrative records from git worktree metadata.",
        .exit_code = "0 on success; non-zero on git errors.",
        .text_example = "Pruned stale worktree administrative files",
        .follow_up = &.{"wt list"},
    },
    .{
        .command = "wt --format json prune",
        .purpose = "Reference prune in automation without text parsing.",
        .outcome = "JSON envelope confirming prune status.",
        .exit_code = "0 on success; non-zero on failure.",
        .json_example = "{\"ok\":true,\"command\":\"wt prune\",\"data\":{\"status\":\"pruned\"}}",
    },
};

const shellenv_examples = [_]UsageExample{
    .{
        .command = "wt shellenv",
        .purpose = "Print shell integration to source in your shell profile.",
        .outcome = "Outputs the shell wrapper and completion definitions for the current OS family.",
        .exit_code = "0 on success.",
        .text_example = "wt() {\n    # wrapper omitted\n}\n# completion definitions...",
        .notes = &.{"Source the output in your shell profile; do not parse it as structured JSON."},
    },
    .{
        .command = "wt --format json shellenv",
        .purpose = "Reference machine-readable shellenv behavior in automation.",
        .outcome = "JSON envelope with a note telling callers to run shellenv without JSON for script output.",
        .exit_code = "0 on success.",
        .json_example = "{\"ok\":true,\"command\":\"wt shellenv\",\"data\":{\"note\":\"shellenv outputs shell script text; run without --format json to source it\"}}",
    },
};

const info_examples = [_]UsageExample{
    .{
        .command = "wt info",
        .purpose = "Inspect the current strategy, pattern variables, and configured hooks.",
        .outcome = "Human-readable report of the active worktree placement configuration.",
        .exit_code = "0 on success.",
        .text_example = "Config: ~/.config/wt/config.toml (found)\nStrategy: global\nPattern: {.worktreeRoot}/{.repo.Name}/{.branch}\nRoot: $WORKTREE_ROOT",
    },
    .{
        .command = "wt --format json info",
        .purpose = "Structured config metadata for automation.",
        .outcome = "JSON envelope with config, strategies, pattern variables, and hooks.",
        .exit_code = "0 on success.",
        .json_example = "{\"ok\":true,\"command\":\"wt info\",\"data\":{\"config\":{\"strategy\":\"global\",\"pattern\":\"{.worktreeRoot}/{.repo.Name}/{.branch}\",\"root\":\"$WORKTREE_ROOT\"}}}",
    },
};

const config_examples = [_]UsageExample{
    .{
        .command = "wt config show",
        .purpose = "Inspect effective config values and their sources.",
        .outcome = "Shows the config file path/status and resolved settings.",
        .exit_code = "0 on success.",
        .text_example = "Config file: ~/.config/wt/config.toml (found)\nEffective configuration:\n  root = \"$WORKTREE_ROOT\" (env WORKTREE_ROOT)",
        .failure_modes = &.{"Malformed config files may produce parse errors."},
        .follow_up = &.{ "wt config path", "wt info" },
    },
    .{
        .command = "wt config init",
        .purpose = "Create the default config file.",
        .outcome = "The config file is created unless it already exists.",
        .exit_code = "0 on success; non-zero if the config already exists.",
        .text_example = "Created config file: ~/.config/wt/config.toml",
        .failure_modes = &.{"Permission issues when writing the config path."},
        .follow_up = &.{ "wt config show", "wt info" },
    },
    .{
        .command = "wt --format json config show",
        .purpose = "Structured config introspection for tools.",
        .outcome = "JSON envelope with effective values and source information.",
        .exit_code = "0 on success.",
        .json_example = "{\"ok\":true,\"command\":\"wt config show\",\"data\":{\"effective\":{\"root\":{\"value\":\"$WORKTREE_ROOT\",\"source\":\"env WORKTREE_ROOT\"}}}}",
    },
};

const version_examples = [_]UsageExample{
    .{
        .command = "wt version",
        .purpose = "Print the current wt version for troubleshooting and automation checks.",
        .outcome = "Outputs the wt version string.",
        .exit_code = "0 on success.",
        .text_example = "wt version 0.1.0",
    },
    .{
        .command = "wt --format json version",
        .purpose = "Reference machine-readable version output.",
        .outcome = "JSON envelope with data.version.",
        .exit_code = "0 on success.",
        .json_example = "{\"ok\":true,\"command\":\"wt version\",\"data\":{\"version\":\"0.1.0\"}}",
    },
};

const topics = [_]Topic{
    .{ .name = "checkout", .description = "Checkout an existing branch in a worktree", .examples = &checkout_examples },
    .{ .name = "cleanup", .description = "Remove worktrees for merged branches", .examples = &cleanup_examples },
    .{ .name = "config", .description = "Manage configuration file", .examples = &config_examples },
    .{ .name = "create", .description = "Create a new branch in a worktree", .examples = &create_examples },
    .{ .name = "examples", .description = "Show detailed command examples and outcomes", .examples = &examples_examples },
    .{ .name = "info", .description = "Show active worktree placement configuration", .examples = &info_examples },
    .{ .name = "init", .description = "Initialize shell integration", .examples = &init_examples },
    .{ .name = "list", .description = "List all worktrees", .examples = &list_examples },
    .{ .name = "migrate", .description = "Migrate existing worktrees to configured paths", .examples = &migrate_examples },
    .{ .name = "mr", .description = "Checkout GitLab MR branch in a worktree", .examples = &mr_examples },
    .{ .name = "pr", .description = "Checkout GitHub PR branch in a worktree", .examples = &pr_examples },
    .{ .name = "prune", .description = "Remove stale worktree administrative files", .examples = &prune_examples },
    .{ .name = "remove", .description = "Remove a worktree", .examples = &remove_examples },
    .{ .name = "shellenv", .description = "Output shell wrapper for auto-navigation and completion", .examples = &shellenv_examples },
    .{ .name = "version", .description = "Show wt version", .examples = &version_examples },
};

pub fn run(ctx: output.Context, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len != 0) {
        var message_buffer: [256]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "unknown command: {s}", .{args[0]});
        return output.usageError(ctx, stdout, stderr, "wt", message);
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt examples", .{
            .catalog_scope = "full",
            .notes = .{
                "The examples catalog is intentionally full and unfiltered.",
                "In --format json mode, shell wrappers must not auto-navigate.",
            },
            .topics = topics,
        });
        return 0;
    }

    try renderText(stdout);
    return 0;
}

pub fn renderText(writer: anytype) !void {
    try writer.writeAll(
        \\wt examples
        \\
        \\Runnable usage examples with expected outcomes.
        \\This command intentionally prints the full catalog; filter with rg if desired.
        \\Note: --format json output is machine-readable and does not auto-navigate your shell.
        \\
    );

    for (topics) |topic| {
        try writer.print("{s}: {s}\n", .{ topic.name, topic.description });
        for (topic.examples) |example| {
            try writer.print("  {s}\n", .{example.command});
            try writer.print("    purpose: {s}\n", .{example.purpose});
            try writer.print("    => {s}\n", .{example.outcome});
            try writer.print("    exit: {s}\n", .{example.exit_code});
            try printListSection(writer, "preconditions", example.preconditions);
            try printOptionalField(writer, "path example", example.path_example);
            try printOptionalField(writer, "path basis", example.path_basis);
            try printOptionalBlock(writer, "text example", example.text_example);
            try printOptionalField(writer, "json example", example.json_example);
            try printListSection(writer, "side effects", example.side_effects);
            try printListSection(writer, "common failures", example.failure_modes);
            try printListSection(writer, "follow-up", example.follow_up);
            try printListSection(writer, "notes", example.notes);
            try writer.writeByte('\n');
        }
    }
}

fn printListSection(writer: anytype, title: []const u8, values: []const []const u8) !void {
    if (values.len == 0) return;
    try writer.print("      {s}:\n", .{title});
    for (values) |value| {
        try writer.print("        - {s}\n", .{value});
    }
}

fn printOptionalField(writer: anytype, label: []const u8, value: ?[]const u8) !void {
    if (value) |present| {
        try writer.print("    {s}: {s}\n", .{ label, present });
    }
}

fn printOptionalBlock(writer: anytype, label: []const u8, value: ?[]const u8) !void {
    if (value) |present| {
        try writer.print("    {s}:\n", .{label});
        var lines = std.mem.splitScalar(u8, present, '\n');
        while (lines.next()) |line| {
            try writer.print("      {s}\n", .{line});
        }
    }
}

test "examples rejects positional arguments" {
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(std.testing.allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(std.testing.allocator);

    var stdout = stdout_buffer.writer(std.testing.allocator);
    var stderr = stderr_buffer.writer(std.testing.allocator);

    const exit_code = try run(&.{"create"}, &stdout, &stderr);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unknown command: create") != null);
}

test "examples text includes catalog topics and json note" {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = buffer.writer(std.testing.allocator);

    try renderText(&writer);

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "checkout: Checkout an existing branch in a worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "examples: Show detailed command examples and outcomes") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--format json output is machine-readable and does not auto-navigate your shell.") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "wt --format json create my-feature") != null);
}
