/// Experimental OverlayFS-backed workspace management (Linux only).
///
/// WARNING: This is experimental. The base worktree (lowerdir) MUST NOT be
/// modified while an overlay is mounted. Doing so leads to undefined behavior
/// per the Linux overlayfs documentation.
///
/// Requires fuse-overlayfs(1) to be installed (available on most distros as the
/// `fuse-overlayfs` package). Unprivileged mounts via Linux user namespaces are
/// not used because they are namespace-scoped and would not survive across shell
/// sessions.
///
/// Directory structure per workspace:
///   <state_dir>/<name>/
///       upper/    — CoW layer that receives all changes
///       work/     — overlayfs internal workdir (opaque to the user)
///       merged/   — the mounted workspace the user works in
///
/// State is tracked in <state_dir>/overlays.tsv (tab-separated, one row per
/// workspace). This is checked and pruned on each list/remove call.
const builtin = @import("builtin");
const std = @import("std");
const proc = @import("process.zig");

pub const Entry = struct {
    name: []const u8,
    merged: []const u8,
    upper: []const u8,
    lowerdir: []const u8,
};

const STATE_FILENAME = "overlays.tsv";

/// Return the per-repo overlay state directory. Caller must free.
pub fn stateDir(
    allocator: std.mem.Allocator,
    env_map: *const std.process.EnvMap,
    repo_name: []const u8,
) ![]const u8 {
    const data_home: []const u8 = if (env_map.get("XDG_DATA_HOME")) |d|
        try allocator.dupe(u8, d)
    else blk: {
        const home = env_map.get("HOME") orelse return error.MissingHomeDirectory;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer allocator.free(data_home);
    return std.fs.path.join(allocator, &.{ data_home, "wt", "overlays", repo_name });
}

/// Create and mount a new overlay workspace. Returns the merged directory path
/// (caller must free). Emits an error if the workspace name already exists in
/// the state file.
pub fn create(
    allocator: std.mem.Allocator,
    name: []const u8,
    lowerdir: []const u8,
    dir: []const u8,
) ![]const u8 {
    // Check for name collision in existing state
    const existing = try list(allocator, dir);
    defer {
        for (existing) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.merged);
            allocator.free(entry.upper);
            allocator.free(entry.lowerdir);
        }
        allocator.free(existing);
    }
    for (existing) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return error.OverlayAlreadyExists;
    }

    // Build workspace directory structure
    const ws_dir = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(ws_dir);

    const upper = try std.fs.path.join(allocator, &.{ ws_dir, "upper" });
    defer allocator.free(upper);
    const work = try std.fs.path.join(allocator, &.{ ws_dir, "work" });
    defer allocator.free(work);
    const merged = try std.fs.path.join(allocator, &.{ ws_dir, "merged" });
    errdefer allocator.free(merged);

    std.fs.cwd().makePath(upper) catch {};
    std.fs.cwd().makePath(work) catch {};
    std.fs.cwd().makePath(merged) catch {};

    try mountFuseOverlayfs(allocator, lowerdir, upper, work, merged);

    try appendState(allocator, dir, name, merged, upper, lowerdir);

    return merged;
}

/// Unmount and remove an overlay workspace. If keep_upper is true the upper/
/// directory (containing user changes) is preserved; otherwise the entire
/// workspace directory is deleted.
pub fn remove(
    allocator: std.mem.Allocator,
    name: []const u8,
    dir: []const u8,
    keep_upper: bool,
) !void {
    const existing = try list(allocator, dir);
    defer {
        for (existing) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.merged);
            allocator.free(entry.upper);
            allocator.free(entry.lowerdir);
        }
        allocator.free(existing);
    }

    var found: ?Entry = null;
    for (existing) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            found = entry;
            break;
        }
    }
    if (found == null) return error.OverlayNotFound;
    const entry = found.?;

    if (isMounted(entry.merged)) {
        try unmount(allocator, entry.merged);
    }

    if (!keep_upper) {
        // Remove the entire workspace directory
        const ws_dir = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(ws_dir);
        std.fs.deleteTreeAbsolute(ws_dir) catch {};
    }

    try removeFromState(allocator, dir, name);
}

/// Return all tracked overlay entries for this repo. Caller must free each
/// entry's strings and the slice itself.
pub fn list(allocator: std.mem.Allocator, dir: []const u8) ![]Entry {
    const state_path = try std.fs.path.join(allocator, &.{ dir, STATE_FILENAME });
    defer allocator.free(state_path);

    const data = std.fs.cwd().readFileAlloc(allocator, state_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(data);

    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.merged);
            allocator.free(e.upper);
            allocator.free(e.lowerdir);
        }
        entries.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, '\t');
        const name = parts.next() orelse continue;
        const merged = parts.next() orelse continue;
        const upper = parts.next() orelse continue;
        const lowerdir = parts.next() orelse continue;

        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .merged = try allocator.dupe(u8, merged),
            .upper = try allocator.dupe(u8, upper),
            .lowerdir = try allocator.dupe(u8, lowerdir),
        });
    }

    return entries.toOwnedSlice(allocator);
}

/// Returns true if path is currently an active mount point (Linux only).
/// Always returns false on non-Linux platforms.
pub fn isMounted(path: []const u8) bool {
    if (builtin.os.tag != .linux) return false;
    // Use a stack allocator to avoid heap allocation in this best-effort check.
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const alloc = fba.allocator();
    const data = std.fs.cwd().readFileAlloc(alloc, "/proc/mounts", backing.len) catch return false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // Each line: device mountpoint fstype options dump pass
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // device
        const mp = parts.next() orelse continue;
        if (std.mem.eql(u8, mp, path)) return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

fn mountFuseOverlayfs(
    allocator: std.mem.Allocator,
    lowerdir: []const u8,
    upper: []const u8,
    work: []const u8,
    merged: []const u8,
) !void {
    const opts = try std.fmt.allocPrint(
        allocator,
        "lowerdir={s},upperdir={s},workdir={s}",
        .{ lowerdir, upper, work },
    );
    defer allocator.free(opts);

    var result = try proc.run(allocator, &.{ "fuse-overlayfs", "-o", opts, merged });
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.MountFailed;
}

fn unmount(allocator: std.mem.Allocator, merged: []const u8) !void {
    // Try fusermount3 first (FUSE 3.x), then fusermount (FUSE 2.x)
    for ([_][]const u8{ "fusermount3", "fusermount" }) |cmd| {
        var result = proc.run(allocator, &.{ cmd, "-u", merged }) catch continue;
        defer result.deinit(allocator);
        if (result.succeeded()) return;
    }
    return error.UnmountFailed;
}

fn appendState(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    merged: []const u8,
    upper: []const u8,
    lowerdir: []const u8,
) !void {
    std.fs.cwd().makePath(dir) catch {};
    const state_path = try std.fs.path.join(allocator, &.{ dir, STATE_FILENAME });
    defer allocator.free(state_path);

    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\t{s}\t{s}\n", .{
        name, merged, upper, lowerdir,
    });
    defer allocator.free(line);

    const f = try std.fs.cwd().createFile(state_path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
}

fn removeFromState(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
) !void {
    const state_path = try std.fs.path.join(allocator, &.{ dir, STATE_FILENAME });
    defer allocator.free(state_path);

    const data = std.fs.cwd().readFileAlloc(allocator, state_path, 4 * 1024 * 1024) catch return;
    defer allocator.free(data);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        // First tab-field is the name
        const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse 0;
        if (std.mem.eql(u8, trimmed[0..tab], name)) continue;
        try buf.appendSlice(allocator, trimmed);
        try buf.append(allocator, '\n');
    }

    const f = try std.fs.cwd().createFile(state_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(buf.items);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "stateDir constructs XDG path" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/data");

    const dir = try stateDir(allocator, &env, "my-repo");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/data/wt/overlays/my-repo", dir);
}

test "stateDir falls back to HOME" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");

    const dir = try stateDir(allocator, &env, "repo");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/home/user/.local/share/wt/overlays/repo", dir);
}

test "list returns empty slice when state file absent" {
    const allocator = std.testing.allocator;
    const entries = try list(allocator, "/tmp/wt-nonexistent-state-xyz");
    try std.testing.expectEqual(0, entries.len);
    allocator.free(entries);
}

test "appendState and list round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendState(allocator, root, "ws1", "/merged1", "/upper1", "/lower1");
    try appendState(allocator, root, "ws2", "/merged2", "/upper2", "/lower2");

    const entries = try list(allocator, root);
    defer {
        for (entries) |e| {
            allocator.free(e.name);
            allocator.free(e.merged);
            allocator.free(e.upper);
            allocator.free(e.lowerdir);
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("ws1", entries[0].name);
    try std.testing.expectEqualStrings("/merged1", entries[0].merged);
    try std.testing.expectEqualStrings("ws2", entries[1].name);
    try std.testing.expectEqualStrings("/lower2", entries[1].lowerdir);
}

test "removeFromState removes correct entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendState(allocator, root, "ws1", "/merged1", "/upper1", "/lower1");
    try appendState(allocator, root, "ws2", "/merged2", "/upper2", "/lower2");
    try removeFromState(allocator, root, "ws1");

    const entries = try list(allocator, root);
    defer {
        for (entries) |e| {
            allocator.free(e.name);
            allocator.free(e.merged);
            allocator.free(e.upper);
            allocator.free(e.lowerdir);
        }
        allocator.free(entries);
    }

    try std.testing.expectEqual(1, entries.len);
    try std.testing.expectEqualStrings("ws2", entries[0].name);
}
