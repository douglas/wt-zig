const builtin = @import("builtin");
const std = @import("std");
const config = @import("config.zig");
const cow_copy = @import("cow_copy.zig");
const fs = @import("fs.zig");

pub fn copyFiles(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo_name: []const u8,
    main_path: []const u8,
    worktree_path: []const u8,
    stderr: *std.Io.Writer,
) void {
    // Security: resolve symlinks in root paths so bounds checks cannot be bypassed
    // by a symlinked parent directory (e.g., main_path -> /etc).
    const resolved_main = std.fs.cwd().realpathAlloc(allocator, main_path) catch |err| {
        stderr.print("warning: copy_files: failed to resolve main path: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    defer allocator.free(resolved_main);

    const resolved_wt = std.fs.cwd().realpathAlloc(allocator, worktree_path) catch |err| {
        stderr.print("warning: copy_files: failed to resolve worktree path: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    defer allocator.free(resolved_wt);

    // Resolve effective copy strategy: config override or auto-detect on the actual filesystem.
    const strategy = if (cfg.copy_files.strategy) |s|
        cow_copy.CopyStrategy.fromString(s) orelse blk: {
            stderr.print("warning: copy_files: unknown strategy '{s}', using native_clone\n", .{s}) catch {};
            break :blk cow_copy.CopyStrategy.native_clone;
        }
    else blk: {
        const detected = cow_copy.detect(allocator, resolved_main);
        stderr.print("note: copy strategy: {s} (auto-detected)\n", .{@tagName(detected)}) catch {};
        break :blk detected;
    };

    copyPaths(allocator, cfg.copy_files.paths, resolved_main, resolved_wt, strategy, stderr);
    copyDirs(allocator, cfg.copy_files.dirs, resolved_main, resolved_wt, strategy, stderr);

    for (cfg.copy_files.repo_overrides) |override| {
        if (std.mem.eql(u8, override.repo_name, repo_name)) {
            copyPaths(allocator, override.paths, resolved_main, resolved_wt, strategy, stderr);
        }
    }
}

fn copyPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    resolved_main: []const u8,
    resolved_wt: []const u8,
    strategy: cow_copy.CopyStrategy,
    stderr: *std.Io.Writer,
) void {
    for (paths) |relative_path| {
        copyOne(allocator, relative_path, resolved_main, resolved_wt, strategy, stderr);
    }
}

fn copyDirs(
    allocator: std.mem.Allocator,
    dirs: []const []const u8,
    resolved_main: []const u8,
    resolved_wt: []const u8,
    strategy: cow_copy.CopyStrategy,
    stderr: *std.Io.Writer,
) void {
    for (dirs) |relative_path| {
        copyOneDir(allocator, relative_path, resolved_main, resolved_wt, strategy, stderr);
    }
}

fn copyOneDir(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    resolved_main: []const u8,
    resolved_wt: []const u8,
    strategy: cow_copy.CopyStrategy,
    stderr: *std.Io.Writer,
) void {
    // Security: same checks as copyOne — reject absolute paths and traversal.
    if (std.fs.path.isAbsolute(relative_path)) {
        stderr.print("warning: copy_files: {s} is an absolute path, skipping\n", .{relative_path}) catch {};
        return;
    }

    const source = std.fs.path.join(allocator, &.{ resolved_main, relative_path }) catch return;
    defer allocator.free(source);
    const dest = std.fs.path.join(allocator, &.{ resolved_wt, relative_path }) catch return;
    defer allocator.free(dest);

    const abs_source = std.fs.path.resolve(allocator, &.{source}) catch return;
    defer allocator.free(abs_source);
    if (!isChildPath(abs_source, resolved_main)) {
        stderr.print("warning: copy_files: {s} escapes main worktree, skipping\n", .{relative_path}) catch {};
        return;
    }

    const abs_dest = std.fs.path.resolve(allocator, &.{dest}) catch return;
    defer allocator.free(abs_dest);
    if (!isChildPath(abs_dest, resolved_wt)) {
        stderr.print("warning: copy_files: {s} escapes worktree directory, skipping\n", .{relative_path}) catch {};
        return;
    }

    // Skip if source does not exist.
    const stat = std.posix.fstatat(std.fs.cwd().fd, abs_source, 0) catch return;
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFDIR) {
        stderr.print("warning: copy_files: {s} is not a directory, skipping\n", .{relative_path}) catch {};
        return;
    }

    fs.ensureParentDir(allocator, abs_dest) catch |err| {
        stderr.print("warning: copy_files: failed to create parent for {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
        return;
    };

    cow_copy.copyDirWithStrategy(allocator, abs_source, abs_dest, strategy) catch |err| {
        stderr.print("warning: copy_files: failed to copy dir {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
    };
}

fn copyOne(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    resolved_main: []const u8,
    resolved_wt: []const u8,
    strategy: cow_copy.CopyStrategy,
    stderr: *std.Io.Writer,
) void {
    // Security: reject absolute paths (traversal is caught by bounds check below)
    if (std.fs.path.isAbsolute(relative_path)) {
        stderr.print("warning: copy_files: {s} is an absolute path, skipping\n", .{relative_path}) catch {};
        return;
    }

    const source = std.fs.path.join(allocator, &.{ resolved_main, relative_path }) catch return;
    defer allocator.free(source);

    const dest = std.fs.path.join(allocator, &.{ resolved_wt, relative_path }) catch return;
    defer allocator.free(dest);

    // Security: validate paths stay within their respective roots after join
    // (handles ".." in relative_path by normalizing then checking prefix)
    const abs_source = std.fs.path.resolve(allocator, &.{source}) catch return;
    defer allocator.free(abs_source);
    if (!isChildPath(abs_source, resolved_main)) {
        stderr.print("warning: copy_files: {s} escapes main worktree, skipping\n", .{relative_path}) catch {};
        return;
    }

    const abs_dest = std.fs.path.resolve(allocator, &.{dest}) catch return;
    defer allocator.free(abs_dest);
    if (!isChildPath(abs_dest, resolved_wt)) {
        stderr.print("warning: copy_files: {s} escapes worktree directory, skipping\n", .{relative_path}) catch {};
        return;
    }

    // Security: use lstat (no follow) to detect symlinks and verify regular file,
    // preventing TOCTOU races between check and read.
    const stat = std.posix.fstatat(std.fs.cwd().fd, abs_source, std.posix.AT.SYMLINK_NOFOLLOW) catch return;
    if ((stat.mode & std.posix.S.IFMT) == std.posix.S.IFLNK) {
        stderr.print("warning: copy_files: {s} is a symlink, skipping\n", .{relative_path}) catch {};
        return;
    }
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG) return; // not a regular file (missing, dir, etc.)

    fs.ensureParentDir(allocator, abs_dest) catch |err| {
        stderr.print("warning: copy_files: failed to create directory for {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
        return;
    };

    cow_copy.copyFileWithStrategy(allocator, abs_source, abs_dest, strategy) catch |err| {
        stderr.print("warning: copy_files: failed to copy {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
    };
}

/// Check if child is equal to or a subdirectory of parent.
fn isChildPath(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or child[parent.len] == std.fs.path.sep;
}

test "copyFiles copies files from main to worktree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    // Create source files
    const env_path = try std.fs.path.join(allocator, &.{ main_path, ".env" });
    defer allocator.free(env_path);
    try writeTestFile(env_path, "SECRET=abc");

    const nested_dir = try std.fs.path.join(allocator, &.{ main_path, "config" });
    defer allocator.free(nested_dir);
    try std.fs.makeDirAbsolute(nested_dir);
    const local_yml_path = try std.fs.path.join(allocator, &.{ main_path, "config", "local.yml" });
    defer allocator.free(local_yml_path);
    try writeTestFile(local_yml_path, "key: value");

    var cfg = config.testing_defaults;
    cfg.copy_files = .{ .paths = &.{ ".env", "config/local.yml" } };

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &discard);

    // Verify files were copied
    const dest_env = try std.fs.path.join(allocator, &.{ wt_path, ".env" });
    defer allocator.free(dest_env);
    const env_contents = try std.fs.cwd().readFileAlloc(allocator, dest_env, 1024);
    defer allocator.free(env_contents);
    try std.testing.expectEqualStrings("SECRET=abc", env_contents);

    const dest_yml = try std.fs.path.join(allocator, &.{ wt_path, "config", "local.yml" });
    defer allocator.free(dest_yml);
    const yml_contents = try std.fs.cwd().readFileAlloc(allocator, dest_yml, 1024);
    defer allocator.free(yml_contents);
    try std.testing.expectEqualStrings("key: value", yml_contents);
}

test "copyFiles skips missing source files silently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    var cfg = config.testing_defaults;
    cfg.copy_files = .{ .paths = &.{ ".env", "missing.txt" } };

    // Should not error — just silently skip
    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &discard);
}

test "copyFiles applies repo-specific overrides" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    // Create source files
    const env_path = try std.fs.path.join(allocator, &.{ main_path, ".env" });
    defer allocator.free(env_path);
    try writeTestFile(env_path, "GLOBAL=1");

    const env_local_path = try std.fs.path.join(allocator, &.{ main_path, ".env.local" });
    defer allocator.free(env_local_path);
    try writeTestFile(env_local_path, "LOCAL=1");

    const other_path = try std.fs.path.join(allocator, &.{ main_path, "other.txt" });
    defer allocator.free(other_path);
    try writeTestFile(other_path, "OTHER=1");

    const overrides = [_]config.CopyFilesRepoOverride{
        .{ .repo_name = "campaigns", .paths = &.{".env.local"} },
        .{ .repo_name = "other-repo", .paths = &.{"other.txt"} },
    };

    var cfg = config.testing_defaults;
    cfg.copy_files = .{
        .paths = &.{".env"},
        .repo_overrides = &overrides,
    };

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    copyFiles(allocator, &cfg, "campaigns", main_path, wt_path, &discard);

    // Global .env should be copied
    const dest_env = try std.fs.path.join(allocator, &.{ wt_path, ".env" });
    defer allocator.free(dest_env);
    const env_contents = try std.fs.cwd().readFileAlloc(allocator, dest_env, 1024);
    defer allocator.free(env_contents);
    try std.testing.expectEqualStrings("GLOBAL=1", env_contents);

    // campaigns-specific .env.local should be copied
    const dest_local = try std.fs.path.join(allocator, &.{ wt_path, ".env.local" });
    defer allocator.free(dest_local);
    const local_contents = try std.fs.cwd().readFileAlloc(allocator, dest_local, 1024);
    defer allocator.free(local_contents);
    try std.testing.expectEqualStrings("LOCAL=1", local_contents);

    // other-repo's other.txt should NOT be copied (wrong repo name)
    const dest_other = try std.fs.path.join(allocator, &.{ wt_path, "other.txt" });
    defer allocator.free(dest_other);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().readFileAlloc(allocator, dest_other, 1024));
}

test "copyFiles skips symlinked source files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    // Create a real file and a symlink to it
    const real_file = try std.fs.path.join(allocator, &.{ main_path, "real.txt" });
    defer allocator.free(real_file);
    try writeTestFile(real_file, "real content");

    const link_path = try std.fs.path.join(allocator, &.{ main_path, "link.txt" });
    defer allocator.free(link_path);
    try std.posix.symlink("real.txt", link_path);

    var cfg = config.testing_defaults;
    cfg.copy_files = .{ .paths = &.{ "real.txt", "link.txt" } };

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &stderr);

    // Real file should be copied
    const dest_real = try std.fs.path.join(allocator, &.{ wt_path, "real.txt" });
    defer allocator.free(dest_real);
    const real_contents = try std.fs.cwd().readFileAlloc(allocator, dest_real, 1024);
    defer allocator.free(real_contents);
    try std.testing.expectEqualStrings("real content", real_contents);

    // Symlink should NOT be copied
    const dest_link = try std.fs.path.join(allocator, &.{ wt_path, "link.txt" });
    defer allocator.free(dest_link);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().readFileAlloc(allocator, dest_link, 1024));
}

test "copyFiles rejects path traversal attempts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    // Create a file outside main that traversal would reach
    const outside_file = try std.fs.path.join(allocator, &.{ root, "secret.txt" });
    defer allocator.free(outside_file);
    try writeTestFile(outside_file, "SECRET");

    var cfg = config.testing_defaults;
    cfg.copy_files = .{ .paths = &.{ "../secret.txt", "/etc/passwd" } };

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &stderr);

    // Neither file should be copied
    const dest_secret = try std.fs.path.join(allocator, &.{ wt_path, "../secret.txt" });
    defer allocator.free(dest_secret);
    const abs_dest = try std.fs.path.resolve(allocator, &.{dest_secret});
    defer allocator.free(abs_dest);
    // The file at root/secret.txt should still exist but not be in worktree
    const wt_secret = try std.fs.path.join(allocator, &.{ wt_path, "secret.txt" });
    defer allocator.free(wt_secret);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().readFileAlloc(allocator, wt_secret, 1024));
}

test "copyFiles uses configured strategy and copies file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    const env_path = try std.fs.path.join(allocator, &.{ main_path, ".env" });
    defer allocator.free(env_path);
    try writeTestFile(env_path, "KEY=val");

    var cfg = config.testing_defaults;
    // Explicit strategy — no auto-detection should occur.
    cfg.copy_files = .{ .paths = &.{".env"}, .strategy = "standard" };

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &discard);

    const dest_env = try std.fs.path.join(allocator, &.{ wt_path, ".env" });
    defer allocator.free(dest_env);
    const contents = try std.fs.cwd().readFileAlloc(allocator, dest_env, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("KEY=val", contents);
}

test "copyFiles copies directories via dirs config" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const main_path = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_path);
    const wt_path = try std.fs.path.join(allocator, &.{ root, "worktree" });
    defer allocator.free(wt_path);

    try std.fs.makeDirAbsolute(main_path);
    try std.fs.makeDirAbsolute(wt_path);

    // Create a source directory with a nested file.
    const src_cache = try std.fs.path.join(allocator, &.{ main_path, "node_modules" });
    defer allocator.free(src_cache);
    try std.fs.makeDirAbsolute(src_cache);
    const pkg_file = try std.fs.path.join(allocator, &.{ src_cache, "pkg.js" });
    defer allocator.free(pkg_file);
    try writeTestFile(pkg_file, "module.exports={}");

    var cfg = config.testing_defaults;
    cfg.copy_files = .{ .dirs = &.{"node_modules"}, .strategy = "standard" };

    var discard_buf: [4096]u8 = undefined;
    var discard = std.Io.Writer.fixed(&discard_buf);
    copyFiles(allocator, &cfg, "test-repo", main_path, wt_path, &discard);

    // Directory and its contents should be copied.
    const dest_file = try std.fs.path.join(allocator, &.{ wt_path, "node_modules", "pkg.js" });
    defer allocator.free(dest_file);
    const contents = try std.fs.cwd().readFileAlloc(allocator, dest_file, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("module.exports={}", contents);
}

test "isChildPath validates path containment" {
    try std.testing.expect(isChildPath("/a/b/c", "/a/b"));
    try std.testing.expect(isChildPath("/a/b", "/a/b"));
    try std.testing.expect(!isChildPath("/a/bc", "/a/b"));
    try std.testing.expect(!isChildPath("/other/path", "/a/b"));
}

fn writeTestFile(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
