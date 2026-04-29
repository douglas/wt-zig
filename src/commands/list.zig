const std = @import("std");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");
const status_cmd = @import("status.zig");
const worktree = @import("../git/worktree.zig");

const ParsedArgs = struct {
    full: bool = false,
};

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseArgs(args) catch return output.usageError(ctx, stdout, stderr, "wt list", "Usage: wt list [--full]");

    var result = worktree.list(ctx.allocator, stderr) catch return 1;
    defer result.deinit(ctx.allocator);

    if (parsed.full) {
        const cwd = std.process.getCwdAlloc(ctx.allocator) catch "";
        defer if (cwd.len != 0) ctx.allocator.free(cwd);
        const statuses = try status_cmd.collect(ctx.allocator, result.entries, cwd);
        defer ctx.allocator.free(statuses);

        if (output.isJson(ctx)) {
            try output.emitSuccess(ctx, stdout, "wt list", .{ .worktrees = statuses });
            return 0;
        }

        for (statuses) |status| {
            try status_cmd.printStatusLine(stdout, status);
        }
        return 0;
    }

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

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--full")) {
            parsed.full = true;
            continue;
        }
        return error.InvalidArguments;
    }
    return parsed;
}

test "parseArgs accepts full mode" {
    const parsed = try parseArgs(&.{"--full"});
    try std.testing.expect(parsed.full);
}

test "parseArgs rejects unknown list args" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"branch"}));
}
