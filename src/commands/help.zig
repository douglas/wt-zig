const std = @import("std");
const command = @import("../command.zig");
const config = @import("../config.zig");
const output = @import("../output.zig");
const path = @import("../path.zig");

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try printRoot(ctx, cfg, stdout);
        return 0;
    }

    if (args.len > 1) {
        return output.usageError(ctx, stdout, stderr, "wt help", "Usage: wt help [command]");
    }

    const spec = command.find(args[0]) orelse {
        if (output.isJson(ctx)) {
            const message = try std.fmt.allocPrint(ctx.allocator, "Unknown command: {s}", .{args[0]});
            defer ctx.allocator.free(message);
            try output.emitError(ctx, stdout, "wt help", message);
        } else {
            try stderr.print("Unknown command: {s}\n", .{args[0]});
        }
        return 1;
    };

    try printCommand(ctx, spec, stdout);
    return 0;
}

pub fn printRoot(ctx: output.Context, cfg: *const config.Resolved, writer: *std.Io.Writer) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.allocator);
    var buffered = buffer.writer(ctx.allocator);
    const pattern = blk: {
        const resolved = path.resolvePattern(cfg) catch break :blk cfg.pattern;
        break :blk resolved.pattern;
    };

    try buffered.print(
        \\Git-like worktree management with organized directory structure.
        \\
        \\Strategy: {s}
        \\Pattern:  {s}
        \\Root:     {s}
        \\
        \\Run 'wt info' to see available strategies and pattern variables.
        \\Set WORKTREE_ROOT, WORKTREE_STRATEGY, and WORKTREE_PATTERN to customize.
        \\
        \\Usage:
        \\  wt [flags]
        \\  wt [command]
        \\
        \\Configured [aliases] can also dispatch custom commands.
        \\
        \\Available Commands:
        \\  checkout    Checkout existing branch in new worktree
        \\  cleanup     Remove worktrees for merged branches
        \\  completion  Generate the autocompletion script for the specified shell
        \\  config      Manage wt configuration
        \\  create      Create new branch in worktree (default: main/master)
        \\  default     Navigate to the main worktree
        \\  done        Remove current linked worktree
        \\  examples    Show detailed command examples and outcomes
        \\  help        Help about any command
        \\  info        Show worktree location configuration
        \\  init        Initialize shell integration
        \\  list        List all worktrees
        \\  merge       Merge current branch into a target branch
        \\  migrate     Migrate existing worktrees to configured paths
        \\  mr          Checkout GitLab MR in worktree (uses glab CLI)
        \\  pr          Checkout GitHub PR in worktree (uses gh CLI)
        \\  prune       Remove worktree administrative files
        \\  remove      Remove a worktree
        \\  shellenv    Output shell function for auto-cd (source this)
        \\  status      Show status dashboard of all worktrees
        \\  step        Run focused workflow steps
        \\  switch      Switch to, create, or checkout a worktree
        \\  ui          Open an interactive worktree UI (requires gum)
        \\  version     Show version information
        \\
        \\Flags:
        \\      --config string   Path to config file (default: ~/.config/wt/config.toml)
        \\      --format string   Output format: text or json (default "text")
        \\  -h, --help            help for wt
        \\
        \\Use "wt [command] --help" for more information about a command.
        \\
    , .{ cfg.strategy, pattern, cfg.root });

    try output.commandHelp(ctx, writer, "wt", buffer.items);
}

pub fn printCommand(ctx: output.Context, spec: *const command.Spec, writer: *std.Io.Writer) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.allocator);
    var buffered = buffer.writer(ctx.allocator);

    try buffered.print(
        \\{s}
        \\
        \\Usage:
        \\  {s}
        \\
        \\Details:
        \\  {s}
        \\
    ,
        .{ spec.summary, spec.usage, spec.details },
    );

    if (spec.aliases.len > 0) {
        try buffered.writeAll("Aliases:\n");
        for (spec.aliases) |alias| {
            try buffered.print("  {s}\n", .{alias});
        }
        try buffered.writeByte('\n');
    }

    const command_name = try std.fmt.allocPrint(ctx.allocator, "wt {s}", .{spec.name});
    defer ctx.allocator.free(command_name);
    try output.commandHelp(ctx, writer, command_name, buffer.items);
}
