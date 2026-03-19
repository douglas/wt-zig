const std = @import("std");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("Usage: wt prune\n");
        return 1;
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "worktree", "prune" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        try stdout.writeAll("Pruned stale worktree administrative files.\n");
        return 0;
    }

    try stderr.print("failed to prune worktrees: {s}\n", .{std.mem.trim(u8, result.stderr, " \r\n\t")});
    return 1;
}
