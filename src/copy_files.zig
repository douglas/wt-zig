const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");

pub fn copyFiles(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    repo_name: []const u8,
    main_path: []const u8,
    worktree_path: []const u8,
    stderr: *std.Io.Writer,
) void {
    copyPaths(allocator, cfg.copy_files.paths, main_path, worktree_path, stderr);

    for (cfg.copy_files.repo_overrides) |override| {
        if (std.mem.eql(u8, override.repo_name, repo_name)) {
            copyPaths(allocator, override.paths, main_path, worktree_path, stderr);
        }
    }
}

fn copyPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    main_path: []const u8,
    worktree_path: []const u8,
    stderr: *std.Io.Writer,
) void {
    for (paths) |relative_path| {
        copyOne(allocator, relative_path, main_path, worktree_path, stderr);
    }
}

fn copyOne(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    main_path: []const u8,
    worktree_path: []const u8,
    stderr: *std.Io.Writer,
) void {
    const source = std.fs.path.join(allocator, &.{ main_path, relative_path }) catch return;
    defer allocator.free(source);

    const dest = std.fs.path.join(allocator, &.{ worktree_path, relative_path }) catch return;
    defer allocator.free(dest);

    const contents = std.fs.cwd().readFileAlloc(allocator, source, 10 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            stderr.print("warning: copy_files: failed to read {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
            return;
        },
    };
    defer allocator.free(contents);

    fs.ensureParentDir(allocator, dest) catch |err| {
        stderr.print("warning: copy_files: failed to create directory for {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
        return;
    };

    if (std.fs.path.isAbsolute(dest)) {
        const file = std.fs.createFileAbsolute(dest, .{ .truncate = true }) catch |err| {
            stderr.print("warning: copy_files: failed to write {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
            return;
        };
        defer file.close();
        file.writeAll(contents) catch |err| {
            stderr.print("warning: copy_files: failed to write {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
        };
    } else {
        std.fs.cwd().writeFile(.{ .sub_path = dest, .data = contents }) catch |err| {
            stderr.print("warning: copy_files: failed to write {s}: {s}\n", .{ relative_path, @errorName(err) }) catch {};
        };
    }
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

fn writeTestFile(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
