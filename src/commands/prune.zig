const std = @import("std");
const output = @import("../output.zig");
const proc = @import("../process.zig");

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const allocator = ctx.allocator;
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt prune", "Usage: wt prune");
    }

    var result = try proc.run(allocator, &.{ "git", "worktree", "prune" });
    defer result.deinit(allocator);

    if (result.succeeded()) {
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt prune", .{ .status = "pruned" });
        } else {
            try stdout.writeAll("Pruned stale worktree administrative files.\n");
        }
        return 0;
    }

    try stderr.print("failed to prune worktrees: {s}\n", .{result.trimmedStderr()});
    return 1;
}
