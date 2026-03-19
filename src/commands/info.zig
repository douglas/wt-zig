const std = @import("std");
const config = @import("../config.zig");
const path = @import("../path.zig");

pub fn run(cfg: *const config.Resolved, stdout: anytype, stderr: anytype) !u8 {
    _ = stderr;

    const config_status = if (cfg.config_file_found) "found" else "not found, using defaults";
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "unknown";

    try stdout.print(
        \\Config:    {s} ({s})
        \\
        \\Strategy:  {s}
        \\Pattern:   {s}
        \\Root:      {s}
        \\Separator: "{s}"
        \\
    ,
        .{
            cfg.config_file_path,
            config_status,
            cfg.strategy,
            pattern,
            cfg.root,
            cfg.separator,
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
        try printHookGroup("pre_create", cfg.hooks.pre_create, stdout);
        try printHookGroup("post_create", cfg.hooks.post_create, stdout);
        try printHookGroup("pre_checkout", cfg.hooks.pre_checkout, stdout);
        try printHookGroup("post_checkout", cfg.hooks.post_checkout, stdout);
        try printHookGroup("pre_remove", cfg.hooks.pre_remove, stdout);
        try printHookGroup("post_remove", cfg.hooks.post_remove, stdout);
        try printHookGroup("pre_pr", cfg.hooks.pre_pr, stdout);
        try printHookGroup("post_pr", cfg.hooks.post_pr, stdout);
        try printHookGroup("pre_mr", cfg.hooks.pre_mr, stdout);
        try printHookGroup("post_mr", cfg.hooks.post_mr, stdout);
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

fn printHookGroup(name: []const u8, commands: []const []const u8, writer: anytype) !void {
    for (commands) |command| {
        try writer.print("  {s}: {s}\n", .{ name, command });
    }
}
