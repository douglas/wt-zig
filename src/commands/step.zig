const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const cow_copy = @import("../cow_copy.zig");
const fs = @import("../fs.zig");
const git_repo = @import("../git/repo.zig");
const hooks = @import("../hooks.zig");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");
const template = @import("../template.zig");
const cleanup_cmd = @import("cleanup.zig");
const migrate_support = @import("migrate_support.zig");
const worktree = @import("../git/worktree.zig");

const ParsedDiffArgs = struct {
    target: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
};

const ParsedCopyIgnoredArgs = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    dry_run: bool = false,
    force: bool = false,
};

const ParsedEvalArgs = struct {
    template: []const u8,
    dry_run: bool = false,
};

const ParsedForEachArgs = struct {
    argv: []const []const u8,
};

const ParsedRelocateArgs = struct {
    dry_run: bool = false,
    force: bool = false,
};

const StageMode = enum {
    all,
    tracked,
    none,
};

const ParsedCommitArgs = struct {
    message: ?[]const u8 = null,
    stage: StageMode = .all,
};

const ParsedTargetArgs = struct {
    target: ?[]const u8 = null,
};

const ParsedSquashArgs = struct {
    target: ?[]const u8 = null,
    message: ?[]const u8 = null,
    stage: StageMode = .all,
};

const IgnoredEntry = struct {
    path: []const u8,
    directory: bool,
};

const IncludePattern = struct {
    pattern: []const u8,
    directory: bool,
    negate: bool,
};

const CopyIgnoredOutcome = enum {
    copied,
    skipped,
    would_copy,
    would_overwrite,
    would_skip,
};

const CopyIgnoredStats = struct {
    copied: usize = 0,
    skipped: usize = 0,
    would_copy: usize = 0,
    would_overwrite: usize = 0,
    would_skip: usize = 0,
    failed: usize = 0,

    fn record(self: *CopyIgnoredStats, outcome: CopyIgnoredOutcome) void {
        switch (outcome) {
            .copied => self.copied += 1,
            .skipped => self.skipped += 1,
            .would_copy => self.would_copy += 1,
            .would_overwrite => self.would_overwrite += 1,
            .would_skip => self.would_skip += 1,
        }
    }
};

const IncludePatternList = struct {
    patterns: []IncludePattern,
    buffer: []u8,

    fn deinit(self: *IncludePatternList, allocator: std.mem.Allocator) void {
        allocator.free(self.patterns);
        allocator.free(self.buffer);
    }
};

const IgnoredList = struct {
    entries: []IgnoredEntry,
    buffer: []u8,

    fn deinit(self: *IgnoredList, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.buffer);
    }
};

const builtin_copy_ignored_excludes = [_][]const u8{
    ".bzr",
    ".conductor",
    ".entire",
    ".hg",
    ".jj",
    ".pi",
    ".pijul",
    ".sl",
    ".svn",
    ".worktrees",
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0 or isHelpFlag(args[0])) {
        try printHelp(ctx, stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "eval")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printEvalHelp(ctx, stdout);
            return 0;
        }

        const parsed = parseEvalArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step eval", "Usage: wt step eval [--dry-run] <template>");
        };

        return evalTemplate(ctx, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "for-each")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printForEachHelp(ctx, stdout);
            return 0;
        }

        const parsed = parseForEachArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step for-each", "Usage: wt step for-each -- <command> [args...]");
        };

        return forEach(ctx, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "diff")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printDiffHelp(ctx, stdout);
            return 0;
        }

        if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt step diff", "wt step diff emits raw git diff output; run without --format json");
            return 1;
        }

        const parsed = parseDiffArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step diff", "Usage: wt step diff [target] [-- <git diff args>...]");
        };

        return diff(ctx.allocator, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "relocate")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printRelocateHelp(ctx, stdout);
            return 0;
        }

        const parsed = parseRelocateArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step relocate", "Usage: wt step relocate [--dry-run] [--force|-f]");
        };

        return relocate(ctx, cfg, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "copy-ignored")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printCopyIgnoredHelp(ctx, stdout);
            return 0;
        }

        if (output.isJson(ctx)) {
            try output.emitError(ctx, stdout, "wt step copy-ignored", "wt step copy-ignored emits raw copy output; run without --format json");
            return 1;
        }

        const parsed = parseCopyIgnoredArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step copy-ignored", "Usage: wt step copy-ignored [--from <branch>] [--to <branch>] [--dry-run] [--force]");
        };

        return copyIgnored(ctx.allocator, cfg, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "commit")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printCommitHelp(ctx, stdout);
            return 0;
        }
        const parsed = parseCommitArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step commit", "Usage: wt step commit --message <message> [--stage all|tracked|none]");
        };
        return commit(ctx, cfg, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "squash")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printSquashHelp(ctx, stdout);
            return 0;
        }
        const parsed = parseSquashArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step squash", "Usage: wt step squash [target] --message <message> [--stage all|tracked|none]");
        };
        return squash(ctx, cfg, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "rebase")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printRebaseHelp(ctx, stdout);
            return 0;
        }
        const parsed = parseSingleTargetArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step rebase", "Usage: wt step rebase [target]");
        };
        return rebase(ctx, cfg, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "push")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printPushHelp(ctx, stdout);
            return 0;
        }
        const parsed = parseSingleTargetArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step push", "Usage: wt step push [target]");
        };
        return push(ctx, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "promote")) {
        if (args.len > 1 and isHelpFlag(args[1])) {
            try printPromoteHelp(ctx, stdout);
            return 0;
        }
        const parsed = parseSingleTargetArgs(args[1..]) catch {
            return output.usageError(ctx, stdout, stderr, "wt step promote", "Usage: wt step promote [branch]");
        };
        return promote(ctx, parsed, stdout, stderr);
    }

    if (std.mem.eql(u8, args[0], "prune")) {
        return cleanup_cmd.run(ctx, cfg, args[1..], stdout, stderr);
    }

    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "unknown step command: {s}", .{args[0]});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt step", message);
        return 1;
    } else {
        try stderr.print("Unknown step command: {s}\n", .{args[0]});
    }
    return 1;
}

fn diff(
    allocator: std.mem.Allocator,
    parsed: ParsedDiffArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const worktree_root = gitOutputTrimmed(allocator, &.{ "git", "rev-parse", "--show-toplevel" }) catch {
        try stderr.writeAll("failed to resolve git worktree root\n");
        return 1;
    };
    defer allocator.free(worktree_root);

    const target = if (parsed.target) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try git_repo.getDefaultBase(allocator);
    defer allocator.free(target);

    if (!try refExists(allocator, worktree_root, target)) {
        const safe_target = prompt.sanitizeForTerminal(allocator, target) catch target;
        defer if (safe_target.ptr != target.ptr) allocator.free(safe_target);
        try stderr.print("target ref not found: {s}\n", .{safe_target});
        return 1;
    }

    const merge_base = mergeBase(allocator, worktree_root, "HEAD", target) catch |err| switch (err) {
        error.NoMergeBase => {
            const safe_target = prompt.sanitizeForTerminal(allocator, target) catch target;
            defer if (safe_target.ptr != target.ptr) allocator.free(safe_target);
            try stderr.print("no common ancestor with target branch: {s}\n", .{safe_target});
            return 1;
        },
        else => {
            try stderr.writeAll("failed to resolve merge base\n");
            return 1;
        },
    };
    defer allocator.free(merge_base);

    const git_dir = gitOutputTrimmedInPath(allocator, worktree_root, &.{ "rev-parse", "--git-dir" }) catch {
        try stderr.writeAll("failed to resolve git directory\n");
        return 1;
    };
    defer allocator.free(git_dir);

    const real_index = try indexPath(allocator, worktree_root, git_dir);
    defer allocator.free(real_index);

    const temp_index = try tempIndexPath(allocator);
    defer allocator.free(temp_index);
    defer std.fs.deleteFileAbsolute(temp_index) catch {};

    std.fs.copyFileAbsolute(real_index, temp_index, .{}) catch {
        try stderr.writeAll("failed to copy git index\n");
        return 1;
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("GIT_INDEX_FILE", temp_index);

    var add_result = try runWithEnv(
        allocator,
        &.{ "git", "-C", worktree_root, "add", "--intent-to-add", "." },
        &env_map,
    );
    defer add_result.deinit(allocator);
    if (!add_result.succeeded()) {
        try writeGitFailure(allocator, stderr, add_result.trimmedStderr(), "failed to register untracked files");
        return 1;
    }

    var diff_args = std.ArrayList([]const u8).empty;
    defer diff_args.deinit(allocator);
    try diff_args.appendSlice(allocator, &.{ "git", "-C", worktree_root, "diff", merge_base });
    try diff_args.appendSlice(allocator, parsed.extra_args);
    const argv = try diff_args.toOwnedSlice(allocator);
    defer allocator.free(argv);

    var diff_result = try runWithEnv(allocator, argv, &env_map);
    defer diff_result.deinit(allocator);

    try stdout.writeAll(diff_result.stdout);
    try stderr.writeAll(diff_result.stderr);

    return switch (diff_result.term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn printHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step",
        \\Run focused workflow steps.
        \\
        \\Usage:
        \\  wt step <command>
        \\
        \\Available Commands:
        \\  commit  Commit staged or selected changes with an explicit message
        \\  copy-ignored  Copy ignored files and directories between worktrees
        \\  diff  Show all changes since branching
        \\  eval  Render a template in the current worktree context
        \\  for-each  Run a command in each non-prunable worktree
        \\  prune  Remove worktrees for merged branches
        \\  promote  Swap a branch into the main worktree
        \\  push  Fast-forward a target branch to the current branch
        \\  rebase  Rebase the current branch onto a target
        \\  relocate  Move the current worktree to its configured path
        \\  squash  Squash current branch changes into one commit
        \\
    );
}

fn printEvalHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step eval",
        \\Render a template in the current worktree context.
        \\
        \\Usage:
        \\  wt step eval [--dry-run] <template>
        \\
        \\Examples:
        \\  wt step eval "{{ branch }}"
        \\  wt step eval "{{ branch | sanitize_db }}"
        \\
    );
}

fn printForEachHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step for-each",
        \\Run a command in each non-prunable worktree.
        \\
        \\Usage:
        \\  wt step for-each -- <command> [args...]
        \\
        \\Command arguments are rendered as templates for each worktree.
        \\
    );
}

fn printCommitHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step commit",
        \\Commit staged or selected changes with an explicit message.
        \\
        \\Usage:
        \\  wt step commit --message <message> [--stage all|tracked|none]
        \\
    );
}

fn printSquashHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step squash",
        \\Squash all changes since the target branch into one commit.
        \\
        \\Usage:
        \\  wt step squash [target] --message <message> [--stage all|tracked|none]
        \\
    );
}

fn printRebaseHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step rebase",
        \\Rebase the current branch onto a target branch.
        \\
        \\Usage:
        \\  wt step rebase [target]
        \\
    );
}

fn printPushHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step push",
        \\Fast-forward a target branch to the current branch.
        \\
        \\Usage:
        \\  wt step push [target]
        \\
    );
}

fn printPromoteHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step promote",
        \\Swap a branch into the main worktree.
        \\
        \\Usage:
        \\  wt step promote [branch]
        \\
        \\Without a branch, linked worktrees promote their current branch and
        \\the main worktree restores the default branch. Both involved
        \\worktrees must be clean and attached to local branches.
        \\
    );
}

fn printCopyIgnoredHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step copy-ignored",
        \\Copy ignored files and directories from one worktree to another.
        \\
        \\The source defaults to the main/primary worktree. The destination
        \\defaults to the current worktree.
        \\
        \\Usage:
        \\  wt step copy-ignored [--from <branch>] [--to <branch>] [--dry-run] [--force]
        \\
        \\Ignored entries are discovered with:
        \\  git -C <source> ls-files --ignored --exclude-standard -o --directory -z
        \\
    );
}

fn printDiffHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step diff",
        \\Show all changes since branching.
        \\
        \\Includes committed, staged, unstaged, and untracked files.
        \\
        \\Usage:
        \\  wt step diff [target] [-- <git diff args>...]
        \\
        \\Arguments after -- are forwarded to git diff, for example:
        \\  wt step diff -- --stat
        \\  wt step diff main -- --name-only
        \\
    );
}

fn printRelocateHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    try output.commandHelp(ctx, stdout, "wt step relocate",
        \\Move the current worktree to its configured path.
        \\
        \\Usage:
        \\  wt step relocate [--dry-run] [--force|-f]
        \\
        \\Uses the same target planner as `wt migrate`, but applies only to the
        \\current worktree. `--force` removes an existing target file or
        \\non-empty directory before moving.
        \\
    );
}

fn parseEvalArgs(args: []const []const u8) !ParsedEvalArgs {
    var parsed = ParsedEvalArgs{ .template = "" };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.template.len != 0) return error.InvalidArguments;
        parsed.template = arg;
    }
    if (parsed.template.len == 0) return error.InvalidArguments;
    return parsed;
}

fn parseForEachArgs(args: []const []const u8) !ParsedForEachArgs {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "--")) return error.InvalidArguments;
    return .{ .argv = args[1..] };
}

fn parseDiffArgs(args: []const []const u8) !ParsedDiffArgs {
    var parsed = ParsedDiffArgs{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            parsed.extra_args = args[index + 1 ..];
            return parsed;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.target != null) return error.InvalidArguments;
        parsed.target = arg;
    }

    return parsed;
}

fn parseCopyIgnoredArgs(args: []const []const u8) !ParsedCopyIgnoredArgs {
    var parsed = ParsedCopyIgnoredArgs{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            parsed.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--from")) {
            index += 1;
            if (index >= args.len or parsed.from != null) return error.InvalidArguments;
            parsed.from = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--to")) {
            index += 1;
            if (index >= args.len or parsed.to != null) return error.InvalidArguments;
            parsed.to = args[index];
            continue;
        }
        return error.InvalidArguments;
    }

    return parsed;
}

fn parseCommitArgs(args: []const []const u8) !ParsedCommitArgs {
    var parsed = ParsedCommitArgs{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len or parsed.message != null) return error.InvalidArguments;
            parsed.message = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--stage")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.stage = parseStageMode(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        return error.InvalidArguments;
    }

    if (parsed.message == null) return error.InvalidArguments;
    return parsed;
}

fn parseSquashArgs(args: []const []const u8) !ParsedSquashArgs {
    var parsed = ParsedSquashArgs{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--message") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len or parsed.message != null) return error.InvalidArguments;
            parsed.message = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--stage")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            parsed.stage = parseStageMode(args[index]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.target != null) return error.InvalidArguments;
        parsed.target = arg;
    }

    if (parsed.message == null) return error.InvalidArguments;
    return parsed;
}

fn parseSingleTargetArgs(args: []const []const u8) !ParsedTargetArgs {
    var parsed = ParsedTargetArgs{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
        if (parsed.target != null) return error.InvalidArguments;
        parsed.target = arg;
    }
    return parsed;
}

fn parseRelocateArgs(args: []const []const u8) !ParsedRelocateArgs {
    var parsed = ParsedRelocateArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }
        return error.InvalidArguments;
    }
    return parsed;
}

fn parseStageMode(raw: []const u8) ?StageMode {
    if (std.mem.eql(u8, raw, "all")) return .all;
    if (std.mem.eql(u8, raw, "tracked")) return .tracked;
    if (std.mem.eql(u8, raw, "none")) return .none;
    return null;
}

fn evalTemplate(
    ctx: output.Context,
    parsed: ParsedEvalArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var info = git_repo.getRepoInfoWithWorktrees(allocator, listed.entries) catch {
        try stderr.writeAll("failed to resolve repository info\n");
        return 1;
    };
    defer git_repo.freeRepoInfo(allocator, &info);

    const current_path = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve current worktree\n");
        return 1;
    };
    defer allocator.free(current_path);

    const current_entry = findWorktreeByPath(listed.entries, current_path) orelse {
        try stderr.writeAll("current directory is not inside a git worktree\n");
        return 1;
    };

    var variables = buildTemplateVariables(allocator, info, current_entry) catch {
        try stderr.writeAll("failed to build template variables\n");
        return 1;
    };
    defer variables.deinit(allocator);

    const rendered = template.render(allocator, parsed.template, variables.items) catch |err| {
        try writeTemplateError(stderr, err);
        return 1;
    };
    defer allocator.free(rendered);

    if (parsed.dry_run) {
        for (variables.items) |variable| {
            try stderr.print("{s}={s}\n", .{ variable.name, variable.value });
        }
        try stderr.writeAll("---\n");
        try stderr.print("Result: {s}\n", .{rendered});
        return 0;
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step eval", .{ .result = rendered });
    } else {
        try stdout.print("{s}\n", .{rendered});
    }
    return 0;
}

fn forEach(
    ctx: output.Context,
    parsed: ParsedForEachArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt step for-each", "wt step for-each emits command output; run without --format json");
        return 1;
    }

    const allocator = ctx.allocator;
    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var info = git_repo.getRepoInfoWithWorktrees(allocator, listed.entries) catch {
        try stderr.writeAll("failed to resolve repository info\n");
        return 1;
    };
    defer git_repo.freeRepoInfo(allocator, &info);

    var completed: usize = 0;
    var failed: usize = 0;
    for (listed.entries) |entry| {
        if (entry.prunable != null) continue;
        if (entry.bare) continue;

        const label = worktreeLabel(entry);
        try stderr.print("Running in {s}...\n", .{label});

        var variables = buildTemplateVariables(allocator, info, entry) catch {
            try stderr.writeAll("failed to build template variables\n");
            failed += 1;
            continue;
        };
        defer variables.deinit(allocator);

        const rendered_argv = renderArgv(allocator, parsed.argv, variables.items) catch |err| {
            try writeTemplateError(stderr, err);
            failed += 1;
            continue;
        };
        defer freeArgv(allocator, rendered_argv);

        var result = try runInPath(allocator, rendered_argv, entry.path);
        defer result.deinit(allocator);

        try stdout.writeAll(result.stdout);
        try stderr.writeAll(result.stderr);
        if (result.succeeded()) {
            completed += 1;
        } else {
            failed += 1;
        }
    }

    if (failed != 0) {
        try stderr.print("Completed in {d} worktrees; {d} failed.\n", .{ completed, failed });
        return 1;
    }
    try stderr.print("Completed in {d} worktrees.\n", .{completed});
    return 0;
}

fn relocate(
    ctx: output.Context,
    cfg: *const config.Resolved,
    parsed: ParsedRelocateArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    var info = git_repo.getRepoInfoWithWorktrees(allocator, listed.entries) catch {
        try stderr.writeAll("failed to resolve repository info\n");
        return 1;
    };
    defer git_repo.freeRepoInfo(allocator, &info);

    const current_path = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve current worktree\n");
        return 1;
    };
    defer allocator.free(current_path);

    const current_entry = findWorktreeByPath(listed.entries, current_path) orelse {
        try stderr.writeAll("current directory is not inside a git worktree\n");
        return 1;
    };

    const plan = try migrate_support.buildPlan(allocator, cfg, info, listed.entries, &env_map, parsed.force);
    defer migrate_support.freePlan(allocator, plan);

    const planned_item = findPlanItemByPath(plan, current_entry.path) orelse {
        try stderr.writeAll("current worktree was not included in relocation plan\n");
        return 1;
    };

    const item = if (current_entry.locked != null)
        lockedRelocateItem(planned_item)
    else if (try isWorktreeDirty(allocator, current_entry.path))
        dirtyRelocateItem(planned_item)
    else
        planned_item;

    var selected = [_]migrate_support.PlanItem{item};
    if (parsed.dry_run) {
        return printRelocateDryRun(ctx, parsed.force, selected[0], stdout);
    }
    return migrate_support.applyPlanWithCommand(ctx, parsed.force, &selected, "wt step relocate", stdout, stderr);
}

fn commit(
    ctx: output.Context,
    cfg: *const config.Resolved,
    parsed: ParsedCommitArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const worktree_root = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve git worktree root\n");
        return 1;
    };
    defer allocator.free(worktree_root);

    if (!try stageChanges(allocator, worktree_root, parsed.stage, stderr)) return 1;
    if (!try runHooksForCurrentWorktree(allocator, cfg, "pre_commit", stderr)) return 1;
    if (!try gitCommit(allocator, worktree_root, parsed.message.?, stderr)) return 1;
    try runPostHookForCurrentWorktree(allocator, cfg, "post_commit", stderr);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step commit", .{ .status = "committed" });
    } else {
        try stdout.writeAll("Committed changes.\n");
    }
    return 0;
}

fn squash(
    ctx: output.Context,
    cfg: *const config.Resolved,
    parsed: ParsedSquashArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const worktree_root = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve git worktree root\n");
        return 1;
    };
    defer allocator.free(worktree_root);

    const target = if (parsed.target) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try git_repo.getDefaultBase(allocator);
    defer allocator.free(target);

    const base = mergeBase(allocator, worktree_root, "HEAD", target) catch {
        try stderr.writeAll("failed to resolve merge base for squash\n");
        return 1;
    };
    defer allocator.free(base);

    if (!try stageChanges(allocator, worktree_root, parsed.stage, stderr)) return 1;
    if (!try runHooksForCurrentWorktree(allocator, cfg, "pre_commit", stderr)) return 1;
    if (!try gitQuiet(allocator, &.{ "git", "-C", worktree_root, "reset", "--soft", base }, stderr, "git reset --soft failed")) return 1;
    if (!try gitCommit(allocator, worktree_root, parsed.message.?, stderr)) return 1;
    try runPostHookForCurrentWorktree(allocator, cfg, "post_commit", stderr);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step squash", .{ .status = "squashed", .target = target });
    } else {
        try stdout.print("Squashed changes since {s}.\n", .{target});
    }
    return 0;
}

fn rebase(
    ctx: output.Context,
    cfg: *const config.Resolved,
    parsed: ParsedTargetArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = cfg;
    const allocator = ctx.allocator;
    const worktree_root = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve git worktree root\n");
        return 1;
    };
    defer allocator.free(worktree_root);
    const target = if (parsed.target) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try git_repo.getDefaultBase(allocator);
    defer allocator.free(target);

    if (!try gitQuiet(allocator, &.{ "git", "-C", worktree_root, "rebase", target }, stderr, "git rebase failed")) return 1;
    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step rebase", .{ .status = "rebased", .target = target });
    } else {
        try stdout.print("Rebased onto {s}.\n", .{target});
    }
    return 0;
}

fn push(
    ctx: output.Context,
    parsed: ParsedTargetArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    const source_branch = currentBranch(allocator) catch {
        try stderr.writeAll("wt step push requires a local branch\n");
        return 1;
    };
    defer allocator.free(source_branch);
    const target = if (parsed.target) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try git_repo.getDefaultBase(allocator);
    defer allocator.free(target);

    if (std.mem.eql(u8, source_branch, target)) {
        try stderr.writeAll("source and target branch are the same\n");
        return 1;
    }

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (findWorktreePathByBranch(listed.entries, target)) |target_path| {
        if (!try gitQuiet(allocator, &.{ "git", "-C", target_path, "merge", "--ff-only", source_branch }, stderr, "git merge --ff-only failed")) return 1;
    } else {
        if (!try fastForwardBranchRef(allocator, target, source_branch, stderr)) return 1;
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step push", .{ .status = "pushed", .source = source_branch, .target = target });
    } else {
        try stdout.print("Fast-forwarded {s} to {s}.\n", .{ target, source_branch });
    }
    return 0;
}

fn promote(
    ctx: output.Context,
    parsed: ParsedTargetArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;
    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (listed.entries.len == 0) {
        try stderr.writeAll("no worktrees found\n");
        return 1;
    }

    var info = git_repo.getRepoInfoWithWorktrees(allocator, listed.entries) catch {
        try stderr.writeAll("failed to resolve repository info\n");
        return 1;
    };
    defer git_repo.freeRepoInfo(allocator, &info);

    const current_path = repoRoot(allocator) catch {
        try stderr.writeAll("failed to resolve current worktree\n");
        return 1;
    };
    defer allocator.free(current_path);

    const current_entry = findWorktreeByPath(listed.entries, current_path) orelse {
        try stderr.writeAll("current directory is not inside a git worktree\n");
        return 1;
    };
    const main_entry = findWorktreeByPath(listed.entries, info.main) orelse listed.entries[0];

    if (main_entry.bare or current_entry.bare) {
        try stderr.writeAll("wt step promote does not support bare repositories\n");
        return 1;
    }
    if (main_entry.detached or main_entry.branch == null) {
        try stderr.writeAll("main worktree must be attached to a local branch\n");
        return 1;
    }
    if (current_entry.detached or current_entry.branch == null) {
        try stderr.writeAll("current worktree must be attached to a local branch\n");
        return 1;
    }

    const default_base = try git_repo.getDefaultBase(allocator);
    defer allocator.free(default_base);
    const promote_branch = if (parsed.target) |branch|
        branch
    else if (std.mem.eql(u8, current_entry.path, main_entry.path))
        default_base
    else
        current_entry.branch.?;

    const target_entry = findWorktreeByBranch(listed.entries, promote_branch) orelse {
        const safe = prompt.sanitizeForTerminal(allocator, promote_branch) catch promote_branch;
        defer if (safe.ptr != promote_branch.ptr) allocator.free(safe);
        try stderr.print("worktree not found for branch: {s}\n", .{safe});
        return 1;
    };

    if (target_entry.detached or target_entry.branch == null) {
        try stderr.writeAll("target worktree must be attached to a local branch\n");
        return 1;
    }
    if (std.mem.eql(u8, main_entry.path, target_entry.path)) {
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt step promote", .{
                .status = "unchanged",
                .main = main_entry.path,
                .main_branch = main_entry.branch.?,
            });
        } else {
            try stdout.print("Main worktree already has {s}.\n", .{main_entry.branch.?});
        }
        return 0;
    }

    if (try isWorktreeDirty(allocator, main_entry.path)) {
        try stderr.writeAll("main worktree is dirty; commit or stash changes before promote\n");
        return 1;
    }
    if (try isWorktreeDirty(allocator, target_entry.path)) {
        try stderr.writeAll("target worktree is dirty; commit or stash changes before promote\n");
        return 1;
    }

    const previous_main_branch = main_entry.branch.?;
    if (!output.isJson(ctx)) {
        try stdout.print("Promoting {s} into main worktree...\n", .{promote_branch});
    }
    if (!try swapWorktreeBranches(allocator, main_entry.path, previous_main_branch, target_entry.path, promote_branch, stderr)) {
        return 1;
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt step promote", .{
            .status = "promoted",
            .main = main_entry.path,
            .main_branch = promote_branch,
            .target = target_entry.path,
            .target_branch = previous_main_branch,
        });
    } else {
        try stdout.print("Main worktree now has {s}; {s} now has {s}.\n", .{
            promote_branch,
            target_entry.path,
            previous_main_branch,
        });
    }
    return 0;
}

pub fn fastForwardBranchRef(
    allocator: std.mem.Allocator,
    target_branch: []const u8,
    source_branch: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    var ancestor = try proc.run(allocator, &.{ "git", "merge-base", "--is-ancestor", target_branch, source_branch });
    defer ancestor.deinit(allocator);
    if (!ancestor.succeeded()) {
        try stderr.writeAll("target branch is not an ancestor of source; rebase or merge manually first\n");
        return false;
    }
    return gitQuiet(
        allocator,
        &.{ "git", "branch", "-f", target_branch, source_branch },
        stderr,
        "failed to update target branch",
    );
}

fn stageChanges(
    allocator: std.mem.Allocator,
    worktree_root: []const u8,
    stage: StageMode,
    stderr: *std.Io.Writer,
) !bool {
    return switch (stage) {
        .all => gitQuiet(allocator, &.{ "git", "-C", worktree_root, "add", "-A" }, stderr, "git add failed"),
        .tracked => gitQuiet(allocator, &.{ "git", "-C", worktree_root, "add", "-u" }, stderr, "git add failed"),
        .none => true,
    };
}

fn gitCommit(
    allocator: std.mem.Allocator,
    worktree_root: []const u8,
    message: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    return gitQuiet(
        allocator,
        &.{ "git", "-C", worktree_root, "commit", "-m", message },
        stderr,
        "git commit failed",
    );
}

fn gitQuiet(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stderr: *std.Io.Writer,
    fallback: []const u8,
) !bool {
    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);
    if (result.succeeded()) return true;
    try writeGitFailure(allocator, stderr, result.trimmedStderr(), fallback);
    return false;
}

fn runHooksForCurrentWorktree(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    hook_name: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    const hook_commands = hooks.getHooks(cfg, hook_name);
    if (hook_commands.len == 0) return true;

    var hook_env = try currentHookEnv(allocator);
    defer hook_env.deinit();
    hooks.runApprovedHooks(allocator, cfg, hook_name, hook_commands, &hook_env, stderr) catch |err| switch (err) {
        error.HookCommandFailed => return false,
        else => return err,
    };
    return true;
}

fn runPostHookForCurrentWorktree(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    hook_name: []const u8,
    stderr: *std.Io.Writer,
) !void {
    const hook_commands = hooks.getHooks(cfg, hook_name);
    if (hook_commands.len == 0) return;

    var hook_env = try currentHookEnv(allocator);
    defer hook_env.deinit();
    hooks.runApprovedHooks(allocator, cfg, hook_name, hook_commands, &hook_env, stderr) catch {};
}

fn currentHookEnv(allocator: std.mem.Allocator) !std.process.EnvMap {
    var listed_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&listed_buf);
    var listed = try worktree.list(allocator, &discard);
    defer listed.deinit(allocator);

    var info = try git_repo.getRepoInfoWithWorktrees(allocator, listed.entries);
    defer git_repo.freeRepoInfo(allocator, &info);

    const branch = try currentBranch(allocator);
    defer allocator.free(branch);
    const root = try repoRoot(allocator);
    defer allocator.free(root);

    return hooks.buildHookEnv(allocator, info, branch, root);
}

fn copyIgnored(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    parsed: ParsedCopyIgnoredArgs,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    lowerPriorityForBackgroundHook(allocator);

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (listed.entries.len == 0) {
        try stderr.writeAll("failed to resolve worktrees\n");
        return 1;
    }

    const source_path = if (parsed.from) |branch|
        findWorktreePathByBranch(listed.entries, branch) orelse {
            const safe = prompt.sanitizeForTerminal(allocator, branch) catch branch;
            defer if (safe.ptr != branch.ptr) allocator.free(safe);
            try stderr.print("source worktree not found for branch: {s}\n", .{safe});
            return 1;
        }
    else
        listed.entries[0].path;

    const destination_path = if (parsed.to) |branch|
        findWorktreePathByBranch(listed.entries, branch) orelse {
            const safe = prompt.sanitizeForTerminal(allocator, branch) catch branch;
            defer if (safe.ptr != branch.ptr) allocator.free(safe);
            try stderr.print("destination worktree not found for branch: {s}\n", .{safe});
            return 1;
        }
    else blk: {
        const current = gitOutputTrimmed(allocator, &.{ "git", "rev-parse", "--show-toplevel" }) catch {
            try stderr.writeAll("failed to resolve current worktree\n");
            return 1;
        };
        break :blk current;
    };
    const destination_owned = parsed.to == null;
    defer if (destination_owned) allocator.free(destination_path);

    const resolved_source = std.fs.cwd().realpathAlloc(allocator, source_path) catch {
        try stderr.writeAll("failed to resolve source worktree path\n");
        return 1;
    };
    defer allocator.free(resolved_source);

    const resolved_destination = std.fs.cwd().realpathAlloc(allocator, destination_path) catch {
        if (parsed.to != null) {
            try stderr.writeAll("failed to resolve destination worktree path\n");
        } else {
            try stderr.writeAll("failed to resolve current worktree path\n");
        }
        return 1;
    };
    defer allocator.free(resolved_destination);

    if (samePath(resolved_source, resolved_destination)) {
        try stdout.writeAll("Source and destination worktrees are the same; nothing to copy.\n");
        return 0;
    }

    const strategy = cow_copy.detect(allocator, resolved_source);
    var ignored = collectIgnoredEntries(allocator, resolved_source, stderr) catch return 1;
    defer ignored.deinit(allocator);
    filterIgnoredEntries(allocator, resolved_source, listed.entries, cfg.step.copy_ignored.exclude, &ignored) catch {
        try stderr.writeAll("failed to filter ignored entries\n");
        return 1;
    };

    if (ignored.entries.len == 0) {
        try stdout.writeAll("No matching ignored entries found.\n");
        return 0;
    }

    try stdout.print(
        "Copying {d} matching ignored {s} using {s} strategy...\n",
        .{ ignored.entries.len, pluralize(ignored.entries.len, "entry", "entries"), @tagName(strategy) },
    );

    var stats = CopyIgnoredStats{};
    for (ignored.entries) |entry| {
        const outcome = copyIgnoredEntry(
            allocator,
            resolved_source,
            resolved_destination,
            entry,
            strategy,
            parsed.dry_run,
            parsed.force,
            stdout,
        ) catch |err| {
            const safe = prompt.sanitizeForTerminal(allocator, entry.path) catch entry.path;
            defer if (safe.ptr != entry.path.ptr) allocator.free(safe);
            try stderr.print("warning: failed to copy ignored entry {s}: {s}\n", .{ safe, @errorName(err) });
            stats.failed += 1;
            continue;
        };
        stats.record(outcome);
    }

    if (parsed.dry_run) {
        try stdout.writeAll("Dry run complete.\n");
        try stdout.print(
            "Copy summary: {d} would copy, {d} would overwrite, {d} would skip, {d} failed.\n",
            .{ stats.would_copy, stats.would_overwrite, stats.would_skip, stats.failed },
        );
    } else {
        try stdout.print(
            "Copy summary: {d} copied, {d} skipped, {d} failed.\n",
            .{ stats.copied, stats.skipped, stats.failed },
        );
    }

    return 0;
}

fn lowerPriorityForBackgroundHook(allocator: std.mem.Allocator) void {
    if (!isBackgroundHookProcess()) return;
    if (builtin.os.tag != .linux) return;

    const pid = std.os.linux.getpid();
    var pid_buf: [32]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    _ = proc.quietSuccess(allocator, &.{ "renice", "-n", "10", "-p", pid_text }) catch false;
}

fn isBackgroundHookProcess() bool {
    if (std.posix.getenv("WT_BACKGROUND_HOOK")) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
    }
    if (std.posix.getenv("WORKTRUNK_FOREGROUND")) |value| {
        if (std.mem.eql(u8, value, "-1")) return true;
    }
    return false;
}

fn findWorktreePathByBranch(entries: []const worktree.Entry, branch: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (entry.branch) |entry_branch| {
            if (std.mem.eql(u8, entry_branch, branch)) return entry.path;
        }
    }
    return null;
}

fn findWorktreeByBranch(entries: []const worktree.Entry, branch: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |entry_branch| {
            if (std.mem.eql(u8, entry_branch, branch)) return entry;
        }
    }
    return null;
}

fn findWorktreeByPath(entries: []const worktree.Entry, path_value: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path_value)) return entry;
    }
    return null;
}

fn findPlanItemByPath(plan: []const migrate_support.PlanItem, path_value: []const u8) ?migrate_support.PlanItem {
    for (plan) |item| {
        if (std.mem.eql(u8, item.from, path_value)) return item;
    }
    return null;
}

fn lockedRelocateItem(item: migrate_support.PlanItem) migrate_support.PlanItem {
    var skipped = item;
    skipped.action = .skip;
    skipped.reason = "locked worktree";
    return skipped;
}

fn dirtyRelocateItem(item: migrate_support.PlanItem) migrate_support.PlanItem {
    var skipped = item;
    skipped.action = .skip;
    skipped.reason = "dirty worktree";
    return skipped;
}

fn printRelocateDryRun(
    ctx: output.Context,
    force: bool,
    item: migrate_support.PlanItem,
    stdout: *std.Io.Writer,
) !u8 {
    if (output.isJson(ctx)) {
        const result = [_]struct {
            branch: []const u8,
            from: []const u8,
            to: ?[]const u8,
            action: []const u8,
            primary: bool,
            reason: ?[]const u8,
        }{.{
            .branch = item.branch,
            .from = item.from,
            .to = item.to,
            .action = @tagName(item.action),
            .primary = item.primary,
            .reason = if (item.reason.len == 0) null else item.reason,
        }};
        try output.emitSuccess(ctx, stdout, "wt step relocate", .{
            .dry_run = true,
            .force = force,
            .total = @as(usize, 1),
            .results = result[0..],
        });
        return 0;
    }

    const target = item.to orelse "(none)";
    switch (item.action) {
        .move, .move_force => try stdout.print("Would move {s}: {s} -> {s}\n", .{ item.branch, item.from, target }),
        .skip => try stdout.print("Would skip {s}: {s}\n", .{ item.branch, item.reason }),
    }
    try stdout.writeAll("\nRelocation dry run complete: 0 moved, 1 previewed\n");
    return 0;
}

fn worktreeLabel(entry: worktree.Entry) []const u8 {
    if (entry.branch) |branch| return branch;
    if (entry.detached) return "detached";
    return entry.path;
}

const TemplateVariables = struct {
    items: []template.Variable,
    names: [][]u8,
    values: [][]u8,

    fn deinit(self: *TemplateVariables, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        for (self.values) |value| allocator.free(value);
        allocator.free(self.items);
        allocator.free(self.names);
        allocator.free(self.values);
    }
};

fn buildTemplateVariables(
    allocator: std.mem.Allocator,
    info: @import("../path.zig").RepoInfo,
    entry: worktree.Entry,
) !TemplateVariables {
    var names = std.ArrayList([]u8).empty;
    var values = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        for (values.items) |value| allocator.free(value);
        names.deinit(allocator);
        values.deinit(allocator);
    }

    const branch = entry.branch orelse "";
    const commit_hash = entry.head orelse "";
    const short_commit = if (commit_hash.len > 7) commit_hash[0..7] else commit_hash;
    const worktree_name = std.fs.path.basename(entry.path);
    const default_branch = git_repo.getDefaultBase(allocator) catch try allocator.dupe(u8, "main");
    defer allocator.free(default_branch);
    const cwd = std.process.getCwdAlloc(allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(cwd);

    try appendTemplateVariable(allocator, &names, &values, "branch", branch);
    try appendTemplateVariable(allocator, &names, &values, "commit", commit_hash);
    try appendTemplateVariable(allocator, &names, &values, "short_commit", short_commit);
    try appendTemplateVariable(allocator, &names, &values, "cwd", cwd);
    try appendTemplateVariable(allocator, &names, &values, "default_branch", default_branch);
    try appendTemplateVariable(allocator, &names, &values, "main_worktree", info.name);
    try appendTemplateVariable(allocator, &names, &values, "main_worktree_path", info.main);
    try appendTemplateVariable(allocator, &names, &values, "primary_worktree_path", info.main);
    try appendTemplateVariable(allocator, &names, &values, "repo", info.name);
    try appendTemplateVariable(allocator, &names, &values, "repo_path", info.main);
    try appendTemplateVariable(allocator, &names, &values, "repo_root", info.main);
    try appendTemplateVariable(allocator, &names, &values, "worktree", entry.path);
    try appendTemplateVariable(allocator, &names, &values, "worktree_name", worktree_name);
    try appendTemplateVariable(allocator, &names, &values, "worktree_path", entry.path);

    const name_slice = try names.toOwnedSlice(allocator);
    errdefer allocator.free(name_slice);
    const value_slice = try values.toOwnedSlice(allocator);
    errdefer allocator.free(value_slice);
    const items = try allocator.alloc(template.Variable, name_slice.len);
    errdefer allocator.free(items);

    for (items, 0..) |*item, index| {
        item.* = .{ .name = name_slice[index], .value = value_slice[index] };
    }

    return .{
        .items = items,
        .names = name_slice,
        .values = value_slice,
    };
}

fn appendTemplateVariable(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]u8),
    values: *std.ArrayList([]u8),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try names.append(allocator, owned_name);
    try values.append(allocator, owned_value);
}

fn renderArgv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    variables: []const template.Variable,
) ![]const []const u8 {
    var rendered = std.ArrayList([]const u8).empty;
    errdefer {
        for (rendered.items) |arg| allocator.free(arg);
        rendered.deinit(allocator);
    }

    for (argv) |arg| {
        try rendered.append(allocator, try template.render(allocator, arg, variables));
    }
    return rendered.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn runInPath(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !proc.Captured {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 100 * 1024 * 1024,
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn writeTemplateError(stderr: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.UnknownVariable => try stderr.writeAll("template error: unknown variable\n"),
        error.UnknownFilter => try stderr.writeAll("template error: unknown filter\n"),
        error.InvalidTemplate => try stderr.writeAll("template error: invalid template\n"),
        else => try stderr.print("template error: {s}\n", .{@errorName(err)}),
    }
}

fn currentBranch(allocator: std.mem.Allocator) ![]u8 {
    const branch = try gitOutputTrimmed(allocator, &.{ "git", "branch", "--show-current" });
    if (branch.len == 0) {
        allocator.free(branch);
        return error.DetachedHead;
    }
    return branch;
}

fn repoRoot(allocator: std.mem.Allocator) ![]u8 {
    return gitOutputTrimmed(allocator, &.{ "git", "rev-parse", "--show-toplevel" });
}

fn collectIgnoredEntries(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    stderr: *std.Io.Writer,
) !IgnoredList {
    var result = try runGit(
        allocator,
        source_root,
        &.{ "ls-files", "--ignored", "--exclude-standard", "-o", "--directory", "-z" },
    );
    errdefer result.deinit(allocator);

    if (!result.succeeded()) {
        try writeGitFailure(allocator, stderr, result.trimmedStderr(), "failed to list ignored entries");
        return error.GitCommandFailed;
    }

    const entries = try parseIgnoredEntries(allocator, result.stdout);
    allocator.free(result.stderr);
    return .{
        .entries = entries,
        .buffer = result.stdout,
    };
}

fn parseIgnoredEntries(allocator: std.mem.Allocator, buffer: []u8) ![]IgnoredEntry {
    var entries: std.ArrayList(IgnoredEntry) = .empty;
    errdefer entries.deinit(allocator);

    var parts = std.mem.splitScalar(u8, buffer, 0);
    while (parts.next()) |raw| {
        if (raw.len == 0) continue;
        var path = raw;
        var directory = false;
        if (std.mem.endsWith(u8, raw, "/")) {
            directory = true;
            path = raw[0 .. raw.len - 1];
        }
        if (path.len == 0) continue;
        try entries.append(allocator, .{ .path = path, .directory = directory });
    }

    return entries.toOwnedSlice(allocator);
}

fn filterIgnoredEntries(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    worktrees: []const worktree.Entry,
    config_excludes: []const []const u8,
    ignored: *IgnoredList,
) !void {
    var include_patterns = try loadWorktreeInclude(allocator, source_root);
    defer {
        if (include_patterns) |*patterns| patterns.deinit(allocator);
    }

    var filtered: std.ArrayList(IgnoredEntry) = .empty;
    errdefer filtered.deinit(allocator);
    const exclude_patterns = try parseConfigPatterns(allocator, config_excludes);
    defer allocator.free(exclude_patterns);

    for (ignored.entries) |entry| {
        if (isBuiltInCopyIgnoredExclude(entry.path)) continue;
        if (matchesAnyPattern(exclude_patterns, entry)) continue;
        if (try containsNestedWorktree(allocator, source_root, entry.path, worktrees)) continue;
        if (include_patterns) |patterns| {
            if (!matchesWorktreeInclude(patterns.patterns, entry)) continue;
        }
        try filtered.append(allocator, entry);
    }

    allocator.free(ignored.entries);
    ignored.entries = try filtered.toOwnedSlice(allocator);
}

fn loadWorktreeInclude(allocator: std.mem.Allocator, source_root: []const u8) !?IncludePatternList {
    const include_path = try std.fs.path.join(allocator, &.{ source_root, ".worktreeinclude" });
    defer allocator.free(include_path);

    const buffer = std.fs.cwd().readFileAlloc(allocator, include_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(buffer);

    var patterns: std.ArrayList(IncludePattern) = .empty;
    errdefer patterns.deinit(allocator);

    var lines = std.mem.splitScalar(u8, buffer, '\n');
    while (lines.next()) |raw_line| {
        if (parsePattern(raw_line)) |pattern| {
            try patterns.append(allocator, pattern);
        }
    }

    return .{
        .patterns = try patterns.toOwnedSlice(allocator),
        .buffer = buffer,
    };
}

fn parseConfigPatterns(allocator: std.mem.Allocator, raw_patterns: []const []const u8) ![]IncludePattern {
    var patterns: std.ArrayList(IncludePattern) = .empty;
    errdefer patterns.deinit(allocator);

    for (raw_patterns) |raw| {
        if (parsePattern(raw)) |pattern| {
            try patterns.append(allocator, pattern);
        }
    }

    return patterns.toOwnedSlice(allocator);
}

fn parsePattern(raw: []const u8) ?IncludePattern {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;

    var negate = false;
    if (line[0] == '!') {
        negate = true;
        line = std.mem.trimLeft(u8, line[1..], " \t");
    }
    while (std.mem.startsWith(u8, line, "/")) {
        line = line[1..];
    }
    if (line.len == 0) return null;

    var directory = false;
    while (std.mem.endsWith(u8, line, "/")) {
        directory = true;
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0) return null;

    return .{
        .pattern = line,
        .directory = directory,
        .negate = negate,
    };
}

fn matchesWorktreeInclude(patterns: []const IncludePattern, entry: IgnoredEntry) bool {
    var included = false;
    for (patterns) |pattern| {
        if (includePatternMatches(pattern, entry)) {
            included = !pattern.negate;
        }
    }
    return included;
}

fn matchesAnyPattern(patterns: []const IncludePattern, entry: IgnoredEntry) bool {
    var matched = false;
    for (patterns) |pattern| {
        if (includePatternMatches(pattern, entry)) {
            matched = !pattern.negate;
        }
    }
    return matched;
}

fn includePatternMatches(pattern: IncludePattern, entry: IgnoredEntry) bool {
    const path = entry.path;
    if (pattern.directory and !entry.directory and !pathCanBeInsidePattern(pattern.pattern, path)) {
        return false;
    }

    if (std.mem.indexOfScalar(u8, pattern.pattern, '/') != null) {
        if (globMatch(pattern.pattern, path)) return true;
        return pattern.directory and pathCanBeInsidePattern(pattern.pattern, path);
    }

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (globMatch(pattern.pattern, part)) return true;
    }
    return false;
}

fn pathCanBeInsidePattern(pattern: []const u8, path: []const u8) bool {
    if (globMatch(pattern, path)) return true;
    if (!hasGlob(pattern)) {
        return std.mem.startsWith(u8, path, pattern) and
            path.len > pattern.len and
            path[pattern.len] == '/';
    }

    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] != '/') continue;
        if (globMatch(pattern, path[0..index])) return true;
    }
    return false;
}

fn hasGlob(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var match_index: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '?' and text[t] != '/') {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            const slash_ok = p + 1 < pattern.len and pattern[p + 1] == '*';
            while (p + 1 < pattern.len and pattern[p + 1] == '*') {
                p += 1;
            }
            star = p;
            match_index = t;
            p += 1;
            if (!slash_ok and text[t] == '/') {
                return false;
            }
        } else if (star) |star_index| {
            if (pattern[star_index] != '*' or
                (star_index == 0 or pattern[star_index - 1] != '*') and text[match_index] == '/')
            {
                return false;
            }
            p = star_index + 1;
            match_index += 1;
            t = match_index;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }
    return p == pattern.len;
}

fn pluralize(count: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (count == 1) singular else plural;
}

fn isBuiltInCopyIgnoredExclude(path: []const u8) bool {
    const first = firstPathComponent(path);
    for (builtin_copy_ignored_excludes) |excluded| {
        if (std.mem.eql(u8, first, excluded)) return true;
    }
    return false;
}

fn firstPathComponent(path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |index| {
        return path[0..index];
    }
    return path;
}

fn containsNestedWorktree(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    relative_path: []const u8,
    worktrees: []const worktree.Entry,
) !bool {
    const entry_path = try boundedPath(allocator, source_root, relative_path);
    defer allocator.free(entry_path);

    for (worktrees) |entry| {
        const worktree_path = std.fs.cwd().realpathAlloc(allocator, entry.path) catch continue;
        defer allocator.free(worktree_path);
        if (samePath(worktree_path, source_root)) continue;
        if (isSameOrChildPath(entry_path, worktree_path)) return true;
    }
    return false;
}

fn copyIgnoredEntry(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    destination_root: []const u8,
    entry: IgnoredEntry,
    strategy: cow_copy.CopyStrategy,
    dry_run: bool,
    force: bool,
    stdout: *std.Io.Writer,
) !CopyIgnoredOutcome {
    const source_path = try boundedPath(allocator, source_root, entry.path);
    defer allocator.free(source_path);
    const destination_path = try boundedPath(allocator, destination_root, entry.path);
    defer allocator.free(destination_path);

    if (dry_run) {
        const existing = try existingPathKind(destination_path);
        if (existing != null and !force) {
            try stdout.print("would skip existing ignored entry: {s}\n", .{entry.path});
            return .would_skip;
        } else if (existing != null) {
            try stdout.print("would overwrite ignored entry: {s}\n", .{entry.path});
            return .would_overwrite;
        } else {
            try stdout.print("would copy ignored entry: {s}\n", .{entry.path});
            return .would_copy;
        }
    }

    if (try existingPathKind(destination_path)) |kind| {
        if (!force) {
            try stdout.print("skipping existing ignored entry: {s}\n", .{entry.path});
            return .skipped;
        }
        try deleteExistingPath(destination_path, kind);
    }

    try fs.ensureParentDir(allocator, destination_path);
    try cow_copy.copyPathWithStrategy(allocator, source_path, destination_path, strategy);

    if (entry.directory) {
        try stdout.print("copied ignored directory: {s}\n", .{entry.path});
    } else {
        try stdout.print("copied ignored file: {s}\n", .{entry.path});
    }
    return .copied;
}

fn boundedPath(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{ root, relative_path });
    errdefer allocator.free(resolved);
    if (!isSameOrChildPath(root, resolved)) return error.PathEscapesWorktree;
    return resolved;
}

fn existingPathKind(path: []const u8) !?PathKind {
    const stat = std.posix.fstatat(std.fs.cwd().fd, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return switch (stat.mode & std.posix.S.IFMT) {
        std.posix.S.IFDIR => .directory,
        std.posix.S.IFREG => .file,
        std.posix.S.IFLNK => .symlink,
        else => .other,
    };
}

fn deleteExistingPath(path: []const u8, kind: PathKind) !void {
    switch (kind) {
        .directory => try std.fs.deleteTreeAbsolute(path),
        .file, .symlink, .other => try std.fs.deleteFileAbsolute(path),
    }
}

const PathKind = enum {
    file,
    directory,
    symlink,
    other,
};

fn samePath(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

fn isSameOrChildPath(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    if (parent.len == 0) return false;
    return parent[parent.len - 1] == std.fs.path.sep or child[parent.len] == std.fs.path.sep;
}

fn runGit(
    allocator: std.mem.Allocator,
    worktree_root: []const u8,
    argv: []const []const u8,
) !proc.Captured {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "-C", worktree_root });
    try args.appendSlice(allocator, argv);
    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = owned,
        .max_output_bytes = 100 * 1024 * 1024,
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn refExists(allocator: std.mem.Allocator, worktree_root: []const u8, ref: []const u8) !bool {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);

    var result = try proc.run(allocator, &.{ "git", "-C", worktree_root, "rev-parse", "--verify", "--quiet", commit_ref });
    defer result.deinit(allocator);
    return result.succeeded();
}

fn isWorktreeDirty(allocator: std.mem.Allocator, worktree_root: []const u8) !bool {
    var result = try proc.run(allocator, &.{ "git", "-C", worktree_root, "status", "--porcelain" });
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.GitCommandFailed;
    return std.mem.trim(u8, result.stdout, " \r\n\t").len != 0;
}

fn swapWorktreeBranches(
    allocator: std.mem.Allocator,
    main_path: []const u8,
    main_branch: []const u8,
    target_path: []const u8,
    target_branch: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    if (!try gitQuiet(allocator, &.{ "git", "-C", main_path, "checkout", "--detach", target_branch }, stderr, "failed to detach main worktree")) {
        return false;
    }
    if (!try gitQuiet(allocator, &.{ "git", "-C", target_path, "checkout", "--detach", main_branch }, stderr, "failed to detach target worktree")) {
        _ = gitQuiet(allocator, &.{ "git", "-C", main_path, "switch", main_branch }, stderr, "failed to restore main worktree") catch false;
        return false;
    }
    if (!try gitQuiet(allocator, &.{ "git", "-C", main_path, "switch", target_branch }, stderr, "failed to switch main worktree")) {
        return false;
    }
    if (!try gitQuiet(allocator, &.{ "git", "-C", target_path, "switch", main_branch }, stderr, "failed to switch target worktree")) {
        return false;
    }
    return true;
}

fn mergeBase(
    allocator: std.mem.Allocator,
    worktree_root: []const u8,
    lhs: []const u8,
    rhs: []const u8,
) ![]u8 {
    var result = try proc.run(allocator, &.{ "git", "-C", worktree_root, "merge-base", lhs, rhs });
    defer result.deinit(allocator);

    if (result.succeeded()) {
        return allocator.dupe(u8, result.trimmedStdout());
    }

    return switch (result.term) {
        .Exited => |code| if (code == 1) error.NoMergeBase else error.GitCommandFailed,
        else => error.GitCommandFailed,
    };
}

fn gitOutputTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var result = try proc.run(allocator, argv);
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.GitCommandFailed;
    return allocator.dupe(u8, result.trimmedStdout());
}

fn gitOutputTrimmedInPath(allocator: std.mem.Allocator, worktree_root: []const u8, argv: []const []const u8) ![]u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "git", "-C", worktree_root });
    try args.appendSlice(allocator, argv);
    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);
    return gitOutputTrimmed(allocator, owned);
}

fn indexPath(allocator: std.mem.Allocator, worktree_root: []const u8, git_dir: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(git_dir)) {
        return std.fs.path.join(allocator, &.{ git_dir, "index" });
    }
    return std.fs.path.join(allocator, &.{ worktree_root, git_dir, "index" });
}

fn tempIndexPath(allocator: std.mem.Allocator) ![]u8 {
    const tmp_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "/tmp"),
        else => return err,
    };
    defer allocator.free(tmp_dir);

    return std.fmt.allocPrint(allocator, "{s}/wt-zig-index-{d}", .{ tmp_dir, std.time.nanoTimestamp() });
}

fn runWithEnv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: *const std.process.EnvMap,
) !proc.Captured {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = env_map,
        .max_output_bytes = 100 * 1024 * 1024,
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn writeGitFailure(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    git_stderr: []const u8,
    fallback: []const u8,
) !void {
    const safe = prompt.sanitizeForTerminal(allocator, git_stderr) catch git_stderr;
    defer if (safe.ptr != git_stderr.ptr) allocator.free(safe);
    if (safe.len == 0) {
        try stderr.print("{s}\n", .{fallback});
    } else {
        try stderr.print("{s}: {s}\n", .{ fallback, safe });
    }
}

test "parseDiffArgs accepts empty args" {
    const parsed = try parseDiffArgs(&.{});
    try std.testing.expect(parsed.target == null);
    try std.testing.expectEqual(0, parsed.extra_args.len);
}

test "parseDiffArgs accepts target and forwarded args" {
    const parsed = try parseDiffArgs(&.{ "main", "--", "--stat", "*.zig" });
    try std.testing.expectEqualStrings("main", parsed.target.?);
    try std.testing.expectEqual(2, parsed.extra_args.len);
    try std.testing.expectEqualStrings("--stat", parsed.extra_args[0]);
}

test "parseDiffArgs accepts forwarded args without target" {
    const parsed = try parseDiffArgs(&.{ "--", "--name-only" });
    try std.testing.expect(parsed.target == null);
    try std.testing.expectEqualStrings("--name-only", parsed.extra_args[0]);
}

test "parseDiffArgs rejects flags before separator" {
    try std.testing.expectError(error.InvalidArguments, parseDiffArgs(&.{"--stat"}));
}

test "indexPath resolves relative git dir" {
    const path = try indexPath(std.testing.allocator, "/repo", ".git");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/repo/.git/index", path);
}

test "parseCopyIgnoredArgs accepts source, destination, and flags" {
    const parsed = try parseCopyIgnoredArgs(&.{ "--from", "main", "--to", "feature", "--dry-run", "--force" });
    try std.testing.expectEqualStrings("main", parsed.from.?);
    try std.testing.expectEqualStrings("feature", parsed.to.?);
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.force);
}

test "parseCommitArgs requires message and accepts stage" {
    const parsed = try parseCommitArgs(&.{ "--message", "ship it", "--stage", "tracked" });
    try std.testing.expectEqualStrings("ship it", parsed.message.?);
    try std.testing.expectEqual(StageMode.tracked, parsed.stage);

    try std.testing.expectError(error.InvalidArguments, parseCommitArgs(&.{}));
}

test "parseSquashArgs accepts target message and stage" {
    const parsed = try parseSquashArgs(&.{ "main", "-m", "one commit", "--stage", "none" });
    try std.testing.expectEqualStrings("main", parsed.target.?);
    try std.testing.expectEqualStrings("one commit", parsed.message.?);
    try std.testing.expectEqual(StageMode.none, parsed.stage);
}

test "parseSingleTargetArgs accepts optional target" {
    const empty = try parseSingleTargetArgs(&.{});
    try std.testing.expect(empty.target == null);

    const parsed = try parseSingleTargetArgs(&.{"main"});
    try std.testing.expectEqualStrings("main", parsed.target.?);
    try std.testing.expectError(error.InvalidArguments, parseSingleTargetArgs(&.{ "main", "next" }));
}

test "parseRelocateArgs accepts dry-run and force" {
    const parsed = try parseRelocateArgs(&.{ "--dry-run", "-f" });
    try std.testing.expect(parsed.dry_run);
    try std.testing.expect(parsed.force);
    try std.testing.expectError(error.InvalidArguments, parseRelocateArgs(&.{"branch"}));
}

test "relocate skip item helpers preserve target" {
    const item = migrate_support.PlanItem{
        .branch = "feature",
        .from = "/repo/old",
        .to = "/repo/new",
        .primary = false,
        .action = .move,
    };

    const locked = lockedRelocateItem(item);
    try std.testing.expectEqual(migrate_support.Action.skip, locked.action);
    try std.testing.expectEqualStrings("locked worktree", locked.reason);
    try std.testing.expectEqualStrings("/repo/new", locked.to.?);

    const dirty = dirtyRelocateItem(item);
    try std.testing.expectEqual(migrate_support.Action.skip, dirty.action);
    try std.testing.expectEqualStrings("dirty worktree", dirty.reason);
}

test "parseIgnoredEntries trims ignored directory suffixes" {
    const allocator = std.testing.allocator;
    const raw = try allocator.dupe(u8, "cache/\x00build.log\x00");
    defer allocator.free(raw);

    const entries = try parseIgnoredEntries(allocator, raw);
    defer allocator.free(entries);

    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("cache", entries[0].path);
    try std.testing.expect(entries[0].directory);
    try std.testing.expectEqualStrings("build.log", entries[1].path);
    try std.testing.expect(!entries[1].directory);
}

test "matchesWorktreeInclude supports directory globs and negation" {
    const patterns = [_]IncludePattern{
        .{ .pattern = "cache", .directory = true, .negate = false },
        .{ .pattern = "*.local", .directory = false, .negate = false },
        .{ .pattern = ".env.local", .directory = false, .negate = true },
    };

    try std.testing.expect(matchesWorktreeInclude(&patterns, .{ .path = "cache", .directory = true }));
    try std.testing.expect(matchesWorktreeInclude(&patterns, .{ .path = "cache/build.bin", .directory = false }));
    try std.testing.expect(matchesWorktreeInclude(&patterns, .{ .path = "nested/file.local", .directory = false }));
    try std.testing.expect(!matchesWorktreeInclude(&patterns, .{ .path = ".env.local", .directory = false }));
    try std.testing.expect(!matchesWorktreeInclude(&patterns, .{ .path = "tmp.log", .directory = false }));
}

test "globMatch keeps single star within path component and supports globstar" {
    try std.testing.expect(globMatch("build/*", "build/cache.bin"));
    try std.testing.expect(!globMatch("build/*", "build/tmp/cache.bin"));
    try std.testing.expect(globMatch("build/**", "build/tmp/cache.bin"));
    try std.testing.expect(!globMatch("?.log", "a/log"));
}

test "filterIgnoredEntries applies worktreeinclude and built-in excludes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const include_path = try std.fs.path.join(allocator, &.{ root, ".worktreeinclude" });
    defer allocator.free(include_path);
    try fs.writeFile(allocator, include_path, ".env\ncache/\n*.local\n!.env.local\n.jj/\n");

    const raw = try allocator.dupe(u8, "cache/\x00.env\x00.env.local\x00tmp.log\x00.jj/\x00nested/file.local\x00");
    var ignored = IgnoredList{
        .entries = try parseIgnoredEntries(allocator, raw),
        .buffer = raw,
    };
    defer ignored.deinit(allocator);

    const worktrees = [_]worktree.Entry{.{ .path = root }};
    try filterIgnoredEntries(allocator, root, &worktrees, &.{}, &ignored);

    try std.testing.expectEqual(3, ignored.entries.len);
    try std.testing.expectEqualStrings("cache", ignored.entries[0].path);
    try std.testing.expectEqualStrings(".env", ignored.entries[1].path);
    try std.testing.expectEqualStrings("nested/file.local", ignored.entries[2].path);
}

test "filterIgnoredEntries applies config excludes with gitignore-like patterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const raw = try allocator.dupe(
        u8,
        "cache/\x00logs/app.log\x00nested/tmp/cache.bin\x00nested/keep.local\x00.env\x00",
    );
    var ignored = IgnoredList{
        .entries = try parseIgnoredEntries(allocator, raw),
        .buffer = raw,
    };
    defer ignored.deinit(allocator);

    const worktrees = [_]worktree.Entry{.{ .path = root }};
    const excludes = [_][]const u8{ "cache/", "*.log", "nested/**", "!nested/keep.local" };
    try filterIgnoredEntries(allocator, root, &worktrees, &excludes, &ignored);

    try std.testing.expectEqual(2, ignored.entries.len);
    try std.testing.expectEqualStrings("nested/keep.local", ignored.entries[0].path);
    try std.testing.expectEqualStrings(".env", ignored.entries[1].path);
}

test "copyIgnoredEntry skips existing directories unless forced" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_root = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source_root);
    const destination_root = try std.fs.path.join(allocator, &.{ root, "destination" });
    defer allocator.free(destination_root);

    try std.fs.makeDirAbsolute(source_root);
    try std.fs.makeDirAbsolute(destination_root);

    const source_cache = try std.fs.path.join(allocator, &.{ source_root, "cache" });
    defer allocator.free(source_cache);
    try std.fs.makeDirAbsolute(source_cache);
    const source_file = try std.fs.path.join(allocator, &.{ source_cache, "nested.txt" });
    defer allocator.free(source_file);
    const source_handle = try std.fs.createFileAbsolute(source_file, .{});
    try source_handle.writeAll("fresh");
    source_handle.close();

    const destination_cache = try std.fs.path.join(allocator, &.{ destination_root, "cache" });
    defer allocator.free(destination_cache);
    try std.fs.makeDirAbsolute(destination_cache);
    const stale_file = try std.fs.path.join(allocator, &.{ destination_cache, "stale.txt" });
    defer allocator.free(stale_file);
    const stale_handle = try std.fs.createFileAbsolute(stale_file, .{});
    try stale_handle.writeAll("stale");
    stale_handle.close();

    const entry = IgnoredEntry{ .path = "cache", .directory = true };

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    const stderr = std.Io.Writer.fixed(&err_buf);

    const skipped = try copyIgnoredEntry(
        allocator,
        source_root,
        destination_root,
        entry,
        .standard,
        false,
        false,
        &stdout,
    );
    try std.testing.expectEqual(CopyIgnoredOutcome.skipped, skipped);
    const stale_contents = try std.fs.cwd().readFileAlloc(allocator, stale_file, 64);
    defer allocator.free(stale_contents);
    try std.testing.expectEqualStrings("stale", stale_contents);

    const copied = try copyIgnoredEntry(
        allocator,
        source_root,
        destination_root,
        entry,
        .standard,
        false,
        true,
        &stdout,
    );
    try std.testing.expectEqual(CopyIgnoredOutcome.copied, copied);

    const copied_file = try std.fs.path.join(allocator, &.{ destination_cache, "nested.txt" });
    defer allocator.free(copied_file);
    const copied_contents = try std.fs.cwd().readFileAlloc(allocator, copied_file, 64);
    defer allocator.free(copied_contents);
    try std.testing.expectEqualStrings("fresh", copied_contents);

    _ = stderr;
}
