const std = @import("std");
const output = @import("../output.zig");

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

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "worktree", "prune" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt prune", .{ .status = "pruned" });
        } else {
            try stdout.writeAll("Pruned stale worktree administrative files.\n");
        }
        return 0;
    }

    try stderr.print("failed to prune worktrees: {s}\n", .{std.mem.trim(u8, result.stderr, " \r\n\t")});
    return 1;
}
