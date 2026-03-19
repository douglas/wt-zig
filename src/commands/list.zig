const std = @import("std");
const output = @import("../output.zig");
const worktree = @import("../git/worktree.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.len != 0) {
        return output.usageError(stdout, stderr, "wt list", "Usage: wt list");
    }

    var result = worktree.list(allocator, stderr) catch return 1;
    defer result.deinit(allocator);

    if (output.isJson()) {
        try output.emitSuccess(allocator, stdout, "wt list", .{ .worktrees = result.entries });
        return 0;
    }

    if (result.entries.len == 0) {
        try stdout.writeAll("No worktrees found.\n");
        return 0;
    }

    for (result.entries) |entry| {
        try stdout.writeAll(entry.path);

        if (entry.head) |head| {
            try stdout.print(" {s}", .{head});
        }

        if (entry.branch) |branch| {
            try stdout.print(" [{s}]", .{branch});
        } else if (entry.detached) {
            try stdout.writeAll(" [detached]");
        } else if (entry.bare) {
            try stdout.writeAll(" [bare]");
        }

        if (entry.locked) |reason| {
            if (reason.len == 0) {
                try stdout.writeAll(" locked");
            } else {
                try stdout.print(" locked={s}", .{reason});
            }
        }

        if (entry.prunable) |reason| {
            if (reason.len == 0) {
                try stdout.writeAll(" prunable");
            } else {
                try stdout.print(" prunable={s}", .{reason});
            }
        }

        try stdout.writeByte('\n');
    }

    return 0;
}
