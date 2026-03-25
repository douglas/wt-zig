/// Platform-adaptive copy-on-write file and directory copying.
///
/// Strategy hierarchy:
///   macOS:  clonefile(2) → copy_file_range fallback → read+write
///   Linux:  FICLONE ioctl → copy_file_range → read+write
///   Other:  read+write
///
/// For directories on macOS, a single clonefile(2) call clones the entire
/// tree atomically on APFS. On Linux, directories are walked and each file
/// is copied with the file strategy. The walk respects fd limits.
///
/// Disk cache warming: warmDiskCache walks the directory tree stat-ing every
/// entry so that subsequent tool calls (grep, find, git status) are served
/// from the OS page cache. Intended to be run in a detached background thread.
const builtin = @import("builtin");
const std = @import("std");

// FICLONE ioctl constant (Linux): _IOW(0x94, 9, int) = 0x40049409
const FICLONE: u32 = 0x40049409;

// macOS clonefile(2) — not in Zig std; declared via the struct-namespace extern
// pattern so the symbol reference is dead-code-eliminated on non-macOS targets.
const DarwinSys = struct {
    extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
};

/// Copy a single file from src to dst using the best available mechanism.
/// dst must not already exist. Parent directory must already exist.
pub fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    if (builtin.os.tag == .macos) {
        if (tryClonefileSingle(allocator, src, dst)) return;
    }
    try copyFileKernel(src, dst);
}

/// Copy a directory tree from src to dst using the best available mechanism.
/// dst must not already exist.
pub fn copyDir(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    if (builtin.os.tag == .macos) {
        // On APFS, clonefile on a directory clones the entire tree atomically O(1).
        if (tryClonefileDir(allocator, src, dst)) return;
    }
    // Linux and fallback: walk the tree, CoW each file.
    try copyDirWalk(allocator, src, dst);
}

/// Walk the worktree directory tree, stat-ing every entry to warm the OS page/
/// metadata cache. Best-effort: errors are silently ignored. Intended to run in
/// a detached background thread after worktree creation.
pub fn warmDiskCache(path: []const u8) void {
    warmDiskCacheDir(path);
}

// ──────────────────────────────────────────────────────────────────────────────
// macOS clonefile helpers
// ──────────────────────────────────────────────────────────────────────────────

fn tryClonefileSingle(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const src_z = allocator.dupeZ(u8, src) catch return false;
    defer allocator.free(src_z);
    const dst_z = allocator.dupeZ(u8, dst) catch return false;
    defer allocator.free(dst_z);
    const rc = DarwinSys.clonefile(src_z, dst_z, 0);
    return rc == 0;
}

fn tryClonefileDir(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    // Same syscall — clonefile works on both files and directories on APFS.
    return tryClonefileSingle(allocator, src, dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// File copy: FICLONE → copy_file_range → read+write
// ──────────────────────────────────────────────────────────────────────────────

fn copyFileKernel(src: []const u8, dst: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    const dst_file = try std.fs.createFileAbsolute(dst, .{ .truncate = true });
    defer dst_file.close();

    if (builtin.os.tag == .linux) {
        // Try FICLONE ioctl first (Btrfs/XFS/bcachefs reflink).
        const rc = std.os.linux.ioctl(dst_file.handle, FICLONE, @intCast(src_file.handle));
        if (rc == 0) return;
        // EOPNOTSUPP / EINVAL / EXDEV: fall through to copy_file_range.
    }

    if (builtin.os.tag == .linux or builtin.os.tag == .freebsd) {
        // copy_file_range: kernel-side copy (may use CoW on supported fs).
        const stat = try src_file.stat();
        const size = stat.size;
        if (size > 0) {
            var remaining = size;
            var off_in: u64 = 0;
            var off_out: u64 = 0;
            while (remaining > 0) {
                const chunk = @min(remaining, 1 << 30); // 1 GiB max per call
                const copied = std.posix.copy_file_range(
                    src_file.handle,
                    off_in,
                    dst_file.handle,
                    off_out,
                    @intCast(chunk),
                    0,
                ) catch break; // fall through to read+write on error
                if (copied == 0) break;
                off_in += copied;
                off_out += copied;
                remaining -= @intCast(copied);
            }
            if (remaining == 0) return;
            // Partial copy: truncate and retry with read+write.
            try dst_file.setEndPos(0);
            try dst_file.seekTo(0);
            try src_file.seekTo(0);
        } else {
            return; // empty file, dst already created
        }
    }

    // Fallback: userspace read+write (max 10 MiB per file, matching copy_files.zig).
    try copyFileReadWrite(src_file, dst_file);
}

fn copyFileReadWrite(src_file: std.fs.File, dst_file: std.fs.File) !void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src_file.read(&buf);
        if (n == 0) break;
        try dst_file.writeAll(buf[0..n]);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Directory walk (Linux fallback + non-APFS macOS fallback)
// ──────────────────────────────────────────────────────────────────────────────

fn copyDirWalk(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    try std.fs.makeDirAbsolute(dst);
    var src_dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_child = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_child);
        const dst_child = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_child);

        switch (entry.kind) {
            .directory => try copyDirWalk(allocator, src_child, dst_child),
            .file => try copyFileKernel(src_child, dst_child),
            .sym_link => {
                // Recreate symlinks.
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.posix.readlink(src_child, &link_buf) catch continue;
                std.posix.symlink(target, dst_child) catch {};
            },
            else => {}, // skip devices, sockets, etc.
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Disk cache warming
// ──────────────────────────────────────────────────────────────────────────────

fn warmDiskCacheDir(path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        _ = dir.statFile(entry.name) catch {};
        if (entry.kind == .directory) {
            // Build child path on the stack for recursion; skip if name is too long.
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, entry.name }) catch continue;
            warmDiskCacheDir(child);
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

test "copyFile copies content correctly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const src = try std.fs.path.join(allocator, &.{ root, "src.txt" });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ root, "dst.txt" });
    defer allocator.free(dst);

    // Write source
    const sf = try std.fs.createFileAbsolute(src, .{});
    try sf.writeAll("hello cow");
    sf.close();

    try copyFile(allocator, src, dst);

    const contents = try std.fs.cwd().readFileAlloc(allocator, dst, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("hello cow", contents);
}

test "copyDir copies directory tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const src_dir = try std.fs.path.join(allocator, &.{ root, "src" });
    defer allocator.free(src_dir);
    const dst_dir = try std.fs.path.join(allocator, &.{ root, "dst" });
    defer allocator.free(dst_dir);

    try std.fs.makeDirAbsolute(src_dir);
    const f1 = try std.fs.path.join(allocator, &.{ src_dir, "a.txt" });
    defer allocator.free(f1);
    const sf1 = try std.fs.createFileAbsolute(f1, .{});
    try sf1.writeAll("file-a");
    sf1.close();

    // Nested dir
    const sub = try std.fs.path.join(allocator, &.{ src_dir, "sub" });
    defer allocator.free(sub);
    try std.fs.makeDirAbsolute(sub);
    const f2 = try std.fs.path.join(allocator, &.{ sub, "b.txt" });
    defer allocator.free(f2);
    const sf2 = try std.fs.createFileAbsolute(f2, .{});
    try sf2.writeAll("file-b");
    sf2.close();

    try copyDir(allocator, src_dir, dst_dir);

    const c1 = try std.fs.path.join(allocator, &.{ dst_dir, "a.txt" });
    defer allocator.free(c1);
    const c1_contents = try std.fs.cwd().readFileAlloc(allocator, c1, 64);
    defer allocator.free(c1_contents);
    try std.testing.expectEqualStrings("file-a", c1_contents);

    const c2 = try std.fs.path.join(allocator, &.{ dst_dir, "sub", "b.txt" });
    defer allocator.free(c2);
    const c2_contents = try std.fs.cwd().readFileAlloc(allocator, c2, 64);
    defer allocator.free(c2_contents);
    try std.testing.expectEqualStrings("file-b", c2_contents);
}

test "warmDiskCache does not crash on non-existent path" {
    warmDiskCache("/tmp/wt-zig-nonexistent-path-xyz");
}
