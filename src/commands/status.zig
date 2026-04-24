const std = @import("std");
const output = @import("../output.zig");
const proc = @import("../process.zig");
const worktree = @import("../git/worktree.zig");

const WorktreeStatus = struct {
    path: []const u8,
    branch: []const u8,
    head: ?[]const u8 = null,
    dirty: bool,
    ahead: i32,
    behind: i32,
    current: bool,
    has_upstream: bool,
};

pub fn run(ctx: output.Context, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt status", "Usage: wt status");
    }

    var listed = worktree.list(ctx.allocator, stderr) catch return 1;
    defer listed.deinit(ctx.allocator);

    const cwd = std.process.getCwdAlloc(ctx.allocator) catch "";
    defer if (cwd.len != 0) ctx.allocator.free(cwd);

    var statuses = std.ArrayList(WorktreeStatus).empty;
    defer statuses.deinit(ctx.allocator);

    for (listed.entries) |entry| {
        const dirty = try getDirtyState(ctx.allocator, entry.path);
        const tracking = try getAheadBehind(ctx.allocator, entry.path);
        try statuses.append(ctx.allocator, .{
            .path = entry.path,
            .branch = entry.branch orelse "(detached)",
            .head = entry.head,
            .dirty = dirty,
            .ahead = tracking.ahead,
            .behind = tracking.behind,
            .current = cwd.len != 0 and std.mem.eql(u8, entry.path, cwd),
            .has_upstream = tracking.has_upstream,
        });
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt status", .{ .worktrees = statuses.items });
        return 0;
    }

    for (statuses.items) |status| {
        try printStatusLine(stdout, status);
    }
    return 0;
}

fn printStatusLine(stdout: *std.Io.Writer, status: WorktreeStatus) !void {
    if (!isColorEnabled()) {
        return printStatusLinePlain(stdout, status);
    }

    try writeColor(stdout, if (status.current) "*" else " ", if (status.current) "1;36" else null);
    try stdout.writeByte(' ');
    try writeColor(stdout, status.branch, "1");
    try stdout.writeByte(' ');
    try stdout.writeAll(status.path);
    try stdout.writeByte(' ');
    try writeColor(stdout, if (status.dirty) "dirty" else "clean", if (status.dirty) "31" else "32");
    try stdout.writeByte(' ');
    if (!status.has_upstream) {
        try writeColor(stdout, "no upstream", "2");
    } else {
        var ahead_buffer: [32]u8 = undefined;
        var behind_buffer: [32]u8 = undefined;
        const ahead = try std.fmt.bufPrint(&ahead_buffer, "^{d}", .{status.ahead});
        const behind = try std.fmt.bufPrint(&behind_buffer, "v{d}", .{status.behind});
        try writeColor(stdout, ahead, if (status.ahead > 0) "33" else null);
        try stdout.writeByte(' ');
        try writeColor(stdout, behind, if (status.behind > 0) "33" else null);
    }
    try stdout.writeByte('\n');
}

fn printStatusLinePlain(stdout: *std.Io.Writer, status: WorktreeStatus) !void {
    const marker = if (status.current) "*" else " ";
    const state = if (status.dirty) "dirty" else "clean";
    var tracking_buffer: [64]u8 = undefined;
    const tracking = if (!status.has_upstream)
        "no upstream"
    else
        try std.fmt.bufPrint(&tracking_buffer, "^{d} v{d}", .{ status.ahead, status.behind });

    try stdout.print("{s} {s} {s} {s} {s}\n", .{
        marker,
        status.branch,
        status.path,
        state,
        tracking,
    });
}

fn isColorEnabled() bool {
    if (std.posix.getenv("NO_COLOR") != null) return false;
    return std.fs.File.stdout().isTty();
}

fn writeColor(stdout: *std.Io.Writer, text: []const u8, code: ?[]const u8) !void {
    if (code) |value| {
        try stdout.writeAll("\x1b[");
        try stdout.writeAll(value);
        try stdout.writeAll("m");
        try stdout.writeAll(text);
        try stdout.writeAll("\x1b[0m");
        return;
    }
    try stdout.writeAll(text);
}

const AheadBehind = struct {
    ahead: i32 = 0,
    behind: i32 = 0,
    has_upstream: bool = false,
};

fn getDirtyState(allocator: std.mem.Allocator, path: []const u8) !bool {
    var result = try proc.run(allocator, &.{ "git", "-C", path, "status", "--porcelain" });
    defer result.deinit(allocator);
    if (!result.succeeded()) return false;
    return std.mem.trim(u8, result.stdout, " \r\n\t").len != 0;
}

fn getAheadBehind(allocator: std.mem.Allocator, path: []const u8) !AheadBehind {
    var result = try proc.run(allocator, &.{ "git", "-C", path, "rev-list", "--left-right", "--count", "HEAD...@{upstream}" });
    defer result.deinit(allocator);
    if (!result.succeeded()) return .{};

    const parsed = parseAheadBehind(result.trimmedStdout()) catch return .{};
    return .{
        .ahead = parsed.ahead,
        .behind = parsed.behind,
        .has_upstream = true,
    };
}

const ParsedAheadBehind = struct {
    ahead: i32,
    behind: i32,
};

fn parseAheadBehind(raw: []const u8) !ParsedAheadBehind {
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyRevListOutput;

    const tab_index = std.mem.indexOfScalar(u8, trimmed, '\t') orelse return error.InvalidRevListOutput;
    const ahead_str = trimmed[0..tab_index];
    const behind_str = trimmed[tab_index + 1 ..];

    return .{
        .ahead = try std.fmt.parseInt(i32, ahead_str, 10),
        .behind = try std.fmt.parseInt(i32, behind_str, 10),
    };
}

test "parseAheadBehind parses tab-separated counts" {
    const parsed = try parseAheadBehind("3\t7");
    try std.testing.expectEqual(3, parsed.ahead);
    try std.testing.expectEqual(7, parsed.behind);
}

test "parseAheadBehind rejects malformed output" {
    try std.testing.expectError(error.InvalidRevListOutput, parseAheadBehind("3 7"));
}
