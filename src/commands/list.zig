const std = @import("std");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");
const worktree = @import("../git/worktree.zig");

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt list", "Usage: wt list");
    }

    var result = worktree.list(ctx.allocator, stderr) catch return 1;
    defer result.deinit(ctx.allocator);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt list", .{ .worktrees = result.entries });
        return 0;
    }

    if (result.entries.len == 0) {
        try stdout.writeAll("No worktrees found.\n");
        return 0;
    }

    const allocator = ctx.allocator;
    for (result.entries) |entry| {
        try stdout.writeAll(entry.path);

        if (entry.head) |head| {
            const safe = prompt.sanitizeForTerminal(allocator, head) catch head;
            defer if (safe.ptr != head.ptr) allocator.free(safe);
            try stdout.print(" {s}", .{safe});
        }

        if (entry.branch) |branch| {
            const safe = prompt.sanitizeForTerminal(allocator, branch) catch branch;
            defer if (safe.ptr != branch.ptr) allocator.free(safe);
            try stdout.print(" [{s}]", .{safe});
        } else if (entry.detached) {
            try stdout.writeAll(" [detached]");
        } else if (entry.bare) {
            try stdout.writeAll(" [bare]");
        }

        if (entry.locked) |reason| {
            if (reason.len == 0) {
                try stdout.writeAll(" locked");
            } else {
                const safe = prompt.sanitizeForTerminal(allocator, reason) catch reason;
                defer if (safe.ptr != reason.ptr) allocator.free(safe);
                try stdout.print(" locked={s}", .{safe});
            }
        }

        if (entry.prunable) |reason| {
            if (reason.len == 0) {
                try stdout.writeAll(" prunable");
            } else {
                const safe = prompt.sanitizeForTerminal(allocator, reason) catch reason;
                defer if (safe.ptr != reason.ptr) allocator.free(safe);
                try stdout.print(" prunable={s}", .{safe});
            }
        }

        try stdout.writeByte('\n');
    }

    return 0;
}
