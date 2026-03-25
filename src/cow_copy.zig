/// Platform-adaptive copy-on-write file and directory copying.
///
/// Strategy hierarchy (vibe-inspired, tried in order):
///   native_clone — clonefile(2) on macOS (APFS), FICLONE ioctl on Linux (Btrfs/XFS/bcachefs)
///   clone        — `cp -c` (macOS) or `cp --reflink=auto` (Linux)
///   rsync        — `rsync -a` with fallback to standard
///   standard     — copy_file_range(2) → read+write (always available)
///
/// For directories on Linux, native_clone is skipped (FICLONE is file-only).
/// Each tier falls through to the next on failure; saved strategy is a starting point only.
///
/// detect(allocator, probe_dir) probes the actual filesystem to find the best tier.
/// warmDiskCache walks the directory tree after creation to prime the OS page cache.
const builtin = @import("builtin");
const std = @import("std");
const proc = @import("process.zig");

// FICLONE ioctl constant (Linux): _IOW(0x94, 9, int) = 0x40049409
const FICLONE: u32 = 0x40049409;

// macOS clonefile(2) — not in Zig std; declared via the struct-namespace extern
// pattern so the symbol reference is dead-code-eliminated on non-macOS targets.
const DarwinSys = struct {
    extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
};

/// Copy strategy tier. Each tier falls through to the next on failure.
pub const CopyStrategy = enum {
    /// Platform-native FFI/syscall: clonefile(2) on APFS, FICLONE on Btrfs/XFS.
    native_clone,
    /// Shell command: `cp -c` (macOS) or `cp --reflink=auto` (Linux).
    clone,
    /// Shell command: `rsync -a`.
    rsync,
    /// Zig-native: copy_file_range(2) → read+write. Always available.
    standard,

    pub fn fromString(s: []const u8) ?CopyStrategy {
        if (std.mem.eql(u8, s, "native_clone")) return .native_clone;
        if (std.mem.eql(u8, s, "clone")) return .clone;
        if (std.mem.eql(u8, s, "rsync")) return .rsync;
        if (std.mem.eql(u8, s, "standard")) return .standard;
        return null;
    }
};

/// Detect the best available copy strategy by probing `probe_dir`.
/// probe_dir should be the main worktree path so we test on the actual filesystem.
/// Errors in detection fall silently to a lower tier.
pub fn detect(allocator: std.mem.Allocator, probe_dir: []const u8) CopyStrategy {
    const src = std.fs.path.join(allocator, &.{ probe_dir, ".wt-detect-src" }) catch return .standard;
    defer allocator.free(src);
    const dst = std.fs.path.join(allocator, &.{ probe_dir, ".wt-detect-dst" }) catch return .standard;
    defer allocator.free(dst);

    // Create a tiny source file for probing.
    const f = std.fs.createFileAbsolute(src, .{}) catch return .standard;
    f.close();
    defer std.fs.deleteFileAbsolute(src) catch {};
    defer std.fs.deleteFileAbsolute(dst) catch {};

    if (builtin.os.tag == .macos) {
        if (tryClonefileSingle(allocator, src, dst)) return .native_clone;
        std.fs.deleteFileAbsolute(dst) catch {};
    } else if (builtin.os.tag == .linux) {
        if (tryFiclone(src, dst)) return .native_clone;
        // dst may or may not exist; delete to give clone tier a clean start.
        std.fs.deleteFileAbsolute(dst) catch {};
    }

    // Try clone (cp --reflink=auto or cp -c).
    if (tryCloneCommand(allocator, src, dst)) {
        std.fs.deleteFileAbsolute(dst) catch {};
        return .clone;
    }

    // Try rsync.
    if (proc.quietSuccess(allocator, &.{ "rsync", "--version" }) catch false) return .rsync;

    return .standard;
}

/// Copy a single file from src to dst using the best available mechanism at or
/// below `strategy`. dst must not already exist. Parent directory must exist.
pub fn copyFileWithStrategy(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []const u8,
    strategy: CopyStrategy,
) !void {
    var tier: u8 = @intCast(@intFromEnum(strategy));
    while (tier <= @intFromEnum(CopyStrategy.standard)) : (tier += 1) {
        switch (@as(CopyStrategy, @enumFromInt(tier))) {
            .native_clone => {
                if (builtin.os.tag == .macos) {
                    if (tryClonefileSingle(allocator, src, dst)) return;
                } else if (builtin.os.tag == .linux) {
                    if (tryFiclone(src, dst)) return;
                }
                // Native clone unavailable on this filesystem; fall through.
            },
            .clone => {
                copyFileClone(allocator, src, dst) catch continue;
                return;
            },
            .rsync => {
                copyFileRsync(allocator, src, dst) catch continue;
                return;
            },
            .standard => {
                try copyFileKernel(src, dst);
                return;
            },
        }
    }
}

/// Copy a directory tree from src to dst using the best available mechanism at or
/// below `strategy`. dst must not already exist.
pub fn copyDirWithStrategy(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []const u8,
    strategy: CopyStrategy,
) !void {
    var tier: u8 = @intCast(@intFromEnum(strategy));
    // FICLONE is file-only on Linux; skip native_clone for directory copies.
    if (builtin.os.tag == .linux and tier == @intFromEnum(CopyStrategy.native_clone)) {
        tier = @intFromEnum(CopyStrategy.clone);
    }
    while (tier <= @intFromEnum(CopyStrategy.standard)) : (tier += 1) {
        switch (@as(CopyStrategy, @enumFromInt(tier))) {
            .native_clone => {
                // macOS only: clonefile works on directories (APFS).
                if (builtin.os.tag == .macos and tryClonefileDir(allocator, src, dst)) return;
            },
            .clone => {
                copyDirClone(allocator, src, dst) catch continue;
                return;
            },
            .rsync => {
                copyDirRsync(allocator, src, dst) catch continue;
                return;
            },
            .standard => {
                try copyDirWalk(allocator, src, dst);
                return;
            },
        }
    }
}

/// Copy a single file from src to dst using the best available mechanism.
/// Convenience wrapper using native_clone as the starting tier.
pub fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    try copyFileWithStrategy(allocator, src, dst, .native_clone);
}

/// Copy a directory tree from src to dst using the best available mechanism.
/// Convenience wrapper using native_clone as the starting tier.
pub fn copyDir(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    try copyDirWithStrategy(allocator, src, dst, .native_clone);
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
// Linux FICLONE helper
// ──────────────────────────────────────────────────────────────────────────────

fn tryFiclone(src: []const u8, dst: []const u8) bool {
    if (builtin.os.tag != .linux) return false;
    const src_file = std.fs.openFileAbsolute(src, .{}) catch return false;
    defer src_file.close();
    // createFileAbsolute with truncate=true to open (or create) dst.
    const dst_file = std.fs.createFileAbsolute(dst, .{ .truncate = true }) catch return false;
    const rc = std.os.linux.ioctl(dst_file.handle, FICLONE, @intCast(src_file.handle));
    dst_file.close();
    if (rc == 0) return true;
    // FICLONE failed (EOPNOTSUPP etc.): delete the empty dst so callers can retry.
    std.fs.deleteFileAbsolute(dst) catch {};
    return false;
}

// ──────────────────────────────────────────────────────────────────────────────
// Shell command helpers: clone (cp --reflink / cp -c) and rsync
// ──────────────────────────────────────────────────────────────────────────────

fn tryCloneCommand(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    const cmd: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "cp", "-c", src, dst }
    else
        &.{ "cp", "--reflink=auto", src, dst };
    return proc.quietSuccess(allocator, cmd) catch false;
}

fn copyFileClone(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cmd: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "cp", "-c", src, dst }
    else
        &.{ "cp", "--reflink=auto", src, dst };
    const ok = proc.quietSuccess(allocator, cmd) catch false;
    if (!ok) return error.CloneFailed;
}

fn copyDirClone(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cmd: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "cp", "-rc", src, dst }
    else
        &.{ "cp", "-r", "--reflink=auto", src, dst };
    const ok = proc.quietSuccess(allocator, cmd) catch false;
    if (!ok) return error.CloneFailed;
}

fn copyFileRsync(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const ok = proc.quietSuccess(allocator, &.{ "rsync", "-a", src, dst }) catch false;
    if (!ok) return error.RsyncFailed;
}

fn copyDirRsync(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    // rsync -a src/ dst copies src's *contents* into dst (creating dst if needed).
    const src_slash = try std.fmt.allocPrint(allocator, "{s}/", .{src});
    defer allocator.free(src_slash);
    const ok = proc.quietSuccess(allocator, &.{ "rsync", "-a", src_slash, dst }) catch false;
    if (!ok) return error.RsyncFailed;
}

// ──────────────────────────────────────────────────────────────────────────────
// File copy: copy_file_range → read+write (standard tier)
// ──────────────────────────────────────────────────────────────────────────────

fn copyFileKernel(src: []const u8, dst: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    const dst_file = try std.fs.createFileAbsolute(dst, .{ .truncate = true });
    defer dst_file.close();

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

    // Fallback: userspace read+write.
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
// Directory walk (standard tier)
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

test "CopyStrategy.fromString round-trips" {
    try std.testing.expectEqual(CopyStrategy.native_clone, CopyStrategy.fromString("native_clone").?);
    try std.testing.expectEqual(CopyStrategy.clone, CopyStrategy.fromString("clone").?);
    try std.testing.expectEqual(CopyStrategy.rsync, CopyStrategy.fromString("rsync").?);
    try std.testing.expectEqual(CopyStrategy.standard, CopyStrategy.fromString("standard").?);
    try std.testing.expect(CopyStrategy.fromString("unknown") == null);
}

test "detect returns a valid strategy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const strategy = detect(allocator, root);
    // Just verify it's a valid enum value — the specific result is platform-dependent.
    _ = @tagName(strategy);
}

test "copyFileWithStrategy standard copies content correctly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const src = try std.fs.path.join(allocator, &.{ root, "src.txt" });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ root, "dst.txt" });
    defer allocator.free(dst);

    const sf = try std.fs.createFileAbsolute(src, .{});
    try sf.writeAll("hello strategy");
    sf.close();

    try copyFileWithStrategy(allocator, src, dst, .standard);

    const contents = try std.fs.cwd().readFileAlloc(allocator, dst, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("hello strategy", contents);
}

test "copyDirWithStrategy standard copies directory tree" {
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

    try copyDirWithStrategy(allocator, src_dir, dst_dir, .standard);

    const c1 = try std.fs.path.join(allocator, &.{ dst_dir, "a.txt" });
    defer allocator.free(c1);
    const c1_contents = try std.fs.cwd().readFileAlloc(allocator, c1, 64);
    defer allocator.free(c1_contents);
    try std.testing.expectEqualStrings("file-a", c1_contents);
}

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
