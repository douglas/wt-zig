const std = @import("std");
const config = @import("../config.zig");
const output = @import("../output.zig");
const path = @import("../path.zig");
const prompt = @import("../prompt.zig");

pub fn run(ctx: output.Context, cfg: *const config.Resolved, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    _ = stderr;

    const config_status = if (cfg.config_file_found) "found" else "not found, using defaults";
    const repo_config_status = if (cfg.config_repo_found) "found" else "not found";
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "unknown";

    const copy_strategy = cfg.copy_files.strategy orelse "auto-detect";

    if (output.isJson(ctx)) {
        const repo_config_path = if (cfg.config_repo_path.len > 0) cfg.config_repo_path else null;
        const repo_status = if (cfg.config_repo_path.len > 0) repo_config_status else null;
        try output.emitSuccess(ctx, stdout, "wt info", .{
            .config = .{
                .path = cfg.config_file_path,
                .status = config_status,
                .strategy = cfg.strategy,
                .pattern = pattern,
                .root = cfg.root,
                .separator = cfg.separator,
                .copy_strategy = copy_strategy,
                .repo_config_path = repo_config_path,
                .repo_config_status = repo_status,
            },
            .strategies = .{
                .{ .name = "global", .pattern = "{.worktreeRoot}/{.repo.Name}/{.branch}" },
                .{ .name = "sibling-repo", .pattern = "{.repo.Main}/../{.repo.Name}-{.branch}" },
                .{ .name = "parent-branches", .pattern = "{.repo.Main}/../{.branch}" },
                .{ .name = "parent-worktrees", .pattern = "{.repo.Main}/../{.repo.Name}.worktrees/{.branch}" },
                .{ .name = "parent-dotdir", .pattern = "{.repo.Main}/../.worktrees/{.branch}" },
                .{ .name = "inside-dotdir", .pattern = "{.repo.Main}/.worktrees/{.branch}" },
                .{ .name = "custom", .pattern = "requires pattern setting" },
            },
            .pattern_variables = .{
                "{.repo.Name}",
                "{.repo.Main}",
                "{.repo.Owner}",
                "{.repo.Host}",
                "{.branch}",
                "{.worktreeRoot}",
                "{.env.VARNAME}",
            },
            .hooks = cfg.hooks,
        });
        return 0;
    }

    try stdout.print(
        \\Config:    {s} ({s})
        \\Repo cfg:  {s} ({s})
        \\
        \\Strategy:  {s}
        \\Pattern:   {s}
        \\Root:      {s}
        \\Separator: "{s}"
        \\Copy strategy: {s}
        \\
    ,
        .{
            cfg.config_file_path,
            config_status,
            if (cfg.config_repo_path.len > 0) cfg.config_repo_path else "(none)",
            if (cfg.config_repo_path.len > 0) repo_config_status else "not in a git repository",
            cfg.strategy,
            pattern,
            cfg.root,
            cfg.separator,
            copy_strategy,
        },
    );
    try stdout.writeAll(
        \\Strategies:
        \\  global           -> {.worktreeRoot}/{.repo.Name}/{.branch}
        \\  sibling-repo     -> {.repo.Main}/../{.repo.Name}-{.branch}
        \\  parent-branches  -> {.repo.Main}/../{.branch}
        \\  parent-worktrees -> {.repo.Main}/../{.repo.Name}.worktrees/{.branch}
        \\  parent-dotdir    -> {.repo.Main}/../.worktrees/{.branch}
        \\  inside-dotdir    -> {.repo.Main}/.worktrees/{.branch}
        \\  custom           -> requires pattern setting
        \\
        \\Pattern variables: {.repo.Name}, {.repo.Main}, {.repo.Owner}, {.repo.Host}, {.branch}, {.worktreeRoot}, {.env.VARNAME}
        \\Note: The separator setting controls how "/" and "\" in value variables are replaced.
        \\      Default "/" preserves slashes (nested dirs). Set to "-" or "_" for flat paths.
        \\      Path variables ({.repo.Main}, {.worktreeRoot}) are never transformed.
        \\
    );

    if (hasHooks(cfg.hooks)) {
        try stdout.writeAll("Hooks:\n");
        try printHookGroup("pre_create", cfg.hooks.pre_create, stdout, ctx.allocator);
        try printHookGroup("post_create", cfg.hooks.post_create, stdout, ctx.allocator);
        try printHookGroup("pre_checkout", cfg.hooks.pre_checkout, stdout, ctx.allocator);
        try printHookGroup("post_checkout", cfg.hooks.post_checkout, stdout, ctx.allocator);
        try printHookGroup("pre_remove", cfg.hooks.pre_remove, stdout, ctx.allocator);
        try printHookGroup("post_remove", cfg.hooks.post_remove, stdout, ctx.allocator);
        try printHookGroup("pre_pr", cfg.hooks.pre_pr, stdout, ctx.allocator);
        try printHookGroup("post_pr", cfg.hooks.post_pr, stdout, ctx.allocator);
        try printHookGroup("pre_mr", cfg.hooks.pre_mr, stdout, ctx.allocator);
        try printHookGroup("post_mr", cfg.hooks.post_mr, stdout, ctx.allocator);
        try stdout.writeByte('\n');
    } else {
        try stdout.writeAll("Hooks:    (none configured)\n\n");
    }

    return 0;
}

fn hasHooks(hooks: config.Hooks) bool {
    return hooks.pre_create.len != 0 or
        hooks.post_create.len != 0 or
        hooks.pre_checkout.len != 0 or
        hooks.post_checkout.len != 0 or
        hooks.pre_remove.len != 0 or
        hooks.post_remove.len != 0 or
        hooks.pre_pr.len != 0 or
        hooks.post_pr.len != 0 or
        hooks.pre_mr.len != 0 or
        hooks.post_mr.len != 0;
}

fn printHookGroup(name: []const u8, commands: []const []const u8, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
    for (commands) |command| {
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try writer.print("  {s}: {s}\n", .{ name, safe });
    }
}
