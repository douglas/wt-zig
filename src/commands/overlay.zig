/// wt overlay — experimental OverlayFS-backed workspace management (Linux only).
///
/// EXPERIMENTAL: This command is not yet stable. The base worktree (lowerdir)
/// MUST NOT be modified while an overlay is mounted.
///
/// Usage:
///   wt overlay <name>          Create and mount a new overlay workspace
///   wt overlay --rm <name>     Unmount and remove a workspace
///   wt overlay --rm --keep <name>  Unmount but keep the upper (changes) layer
///   wt overlay --list          List tracked overlay workspaces
const builtin = @import("builtin");
const std = @import("std");
const output = @import("../output.zig");
const overlay = @import("../overlay.zig");
const git_repo = @import("../git/repo.zig");

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (builtin.os.tag != .linux) {
        try stderr.writeAll("wt overlay is only supported on Linux\n");
        return 1;
    }

    const allocator = ctx.allocator;
    const parsed = parseArgs(args) catch {
        return printUsage(ctx, stdout, stderr);
    };

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var info = try git_repo.getRepoInfo(allocator);
    defer git_repo.freeRepoInfo(allocator, &info);

    const dir = try overlay.stateDir(allocator, &env_map, info.name);
    defer allocator.free(dir);

    switch (parsed.mode) {
        .list => return runList(ctx, dir, stdout, stderr),
        .create => |name| return runCreate(ctx, allocator, name, info.main, dir, stdout, stderr),
        .remove => |opts| return runRemove(ctx, allocator, opts.name, dir, opts.keep, stdout, stderr),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-operations
// ─────────────────────────────────────────────────────────────────────────────

fn runCreate(
    ctx: output.Context,
    allocator: std.mem.Allocator,
    name: []const u8,
    lowerdir: []const u8,
    dir: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    // Emit the experimental warning to stderr so it doesn't pollute JSON output.
    if (!output.isJson(ctx)) {
        try stderr.writeAll(
            "⚠ EXPERIMENTAL: Do not modify the base worktree while this overlay is mounted.\n",
        );
    }

    const merged = overlay.create(allocator, name, lowerdir, dir) catch |err| switch (err) {
        error.OverlayAlreadyExists => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt overlay", "overlay workspace already exists");
            } else {
                try stderr.writeAll("overlay workspace already exists\n");
            }
            return 1;
        },
        error.MountFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt overlay", "mount failed — is fuse-overlayfs installed?");
            } else {
                try stderr.writeAll("mount failed — is fuse-overlayfs installed?\n");
                try stderr.writeAll("Install it with: pacman -S fuse-overlayfs  OR  apt install fuse-overlayfs\n");
            }
            return 1;
        },
        else => return err,
    };
    defer allocator.free(merged);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt overlay", .{
            .status = "created",
            .name = name,
            .lowerdir = lowerdir,
            .merged = merged,
            .navigate_to = merged,
        });
    } else {
        try stdout.writeAll("Overlay workspace created at: ");
        try stdout.writeAll(merged);
        try stdout.writeByte('\n');
        try output.emitNavigateTo(stdout, merged);
    }
    return 0;
}

fn runRemove(
    ctx: output.Context,
    allocator: std.mem.Allocator,
    name: []const u8,
    dir: []const u8,
    keep: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    overlay.remove(allocator, name, dir, keep) catch |err| switch (err) {
        error.OverlayNotFound => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt overlay", "overlay workspace not found");
            } else {
                try stderr.writeAll("overlay workspace not found\n");
            }
            return 1;
        },
        error.UnmountFailed => {
            if (output.isJson(ctx)) {
                try output.emitError(ctx, stdout, "wt overlay", "unmount failed — try: fusermount3 -u <merged>");
            } else {
                try stderr.writeAll("unmount failed — try: fusermount3 -u <merged path>\n");
            }
            return 1;
        },
        else => return err,
    };

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt overlay", .{
            .status = "removed",
            .name = name,
        });
    } else {
        try stdout.writeAll("Overlay workspace removed: ");
        try stdout.writeAll(name);
        try stdout.writeByte('\n');
    }
    return 0;
}

fn runList(
    ctx: output.Context,
    dir: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = stderr;
    const allocator = ctx.allocator;
    const entries = try overlay.list(allocator, dir);
    defer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.merged);
            allocator.free(entry.upper);
            allocator.free(entry.lowerdir);
        }
        allocator.free(entries);
    }

    if (output.isJson(ctx)) {
        try stdout.writeAll("[");
        for (entries, 0..) |entry, i| {
            if (i > 0) try stdout.writeAll(",");
            const mounted = overlay.isMounted(entry.merged);
            try stdout.print(
                "{{\"name\":\"{s}\",\"merged\":\"{s}\",\"mounted\":{s}}}",
                .{ entry.name, entry.merged, if (mounted) "true" else "false" },
            );
        }
        try stdout.writeAll("]\n");
        return 0;
    }

    if (entries.len == 0) {
        try stdout.writeAll("No overlay workspaces.\n");
        return 0;
    }

    for (entries) |entry| {
        const mounted = overlay.isMounted(entry.merged);
        try stdout.print("{s}\t{s}\t{s}\n", .{
            entry.name,
            entry.merged,
            if (mounted) "(mounted)" else "(unmounted)",
        });
    }
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Argument parsing
// ─────────────────────────────────────────────────────────────────────────────

const RemoveOpts = struct { name: []const u8, keep: bool };
const Mode = union(enum) {
    list,
    create: []const u8,
    remove: RemoveOpts,
};
const ParsedArgs = struct { mode: Mode };

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var i: usize = 0;
    var rm = false;
    var keep = false;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--list") or std.mem.eql(u8, args[i], "-l")) {
            return .{ .mode = .list };
        }
        if (std.mem.eql(u8, args[i], "--rm") or std.mem.eql(u8, args[i], "--remove")) {
            rm = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--keep")) {
            keep = true;
            continue;
        }
        // positional: workspace name
        const name = args[i];
        if (rm) return .{ .mode = .{ .remove = .{ .name = name, .keep = keep } } };
        return .{ .mode = .{ .create = name } };
    }

    if (rm) return error.MissingName;
    return .{ .mode = .list }; // no args → list
}

fn printUsage(
    ctx: output.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    return output.usageError(ctx, stdout, stderr, "wt overlay", "Usage: wt overlay <name> | --rm [--keep] <name> | --list");
}

test "parseArgs create" {
    const parsed = try parseArgs(&.{"my-ws"});
    try std.testing.expectEqualStrings("my-ws", parsed.mode.create);
}

test "parseArgs list" {
    const parsed = try parseArgs(&.{"--list"});
    try std.testing.expectEqual(Mode.list, parsed.mode);
}

test "parseArgs remove" {
    const parsed = try parseArgs(&.{ "--rm", "my-ws" });
    try std.testing.expectEqualStrings("my-ws", parsed.mode.remove.name);
    try std.testing.expect(!parsed.mode.remove.keep);
}

test "parseArgs remove with keep" {
    const parsed = try parseArgs(&.{ "--rm", "--keep", "ws1" });
    try std.testing.expectEqualStrings("ws1", parsed.mode.remove.name);
    try std.testing.expect(parsed.mode.remove.keep);
}

test "parseArgs no args defaults to list" {
    const parsed = try parseArgs(&.{});
    try std.testing.expectEqual(Mode.list, parsed.mode);
}
