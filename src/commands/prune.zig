const std = @import("std");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const prompt = @import("../prompt.zig");

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
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

    const msg = result.trimmedStderr();
    const safe = prompt.sanitizeForTerminal(allocator, msg) catch msg;
    defer if (safe.ptr != msg.ptr) allocator.free(safe);
    try stderr.print("failed to prune worktrees: {s}\n", .{safe});
    return 1;
}
