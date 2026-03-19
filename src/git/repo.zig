const std = @import("std");
const path_mod = @import("../path.zig");
const worktree = @import("worktree.zig");

pub fn getDefaultBase(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "symbolic-ref", "refs/remotes/origin/HEAD" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| if (code == 0)
            normalizeBaseRef(allocator, std.mem.trim(u8, result.stdout, " \r\n\t"))
        else
            allocator.dupe(u8, "main"),
        else => allocator.dupe(u8, "main"),
    };
}

pub fn getRepoInfo(allocator: std.mem.Allocator) !path_mod.RepoInfo {
    const repo_root = try gitOutput(allocator, &.{ "rev-parse", "--show-toplevel" });
    errdefer allocator.free(repo_root);

    const trimmed_root = std.mem.trim(u8, repo_root, " \r\n\t");
    const root = try allocator.dupe(u8, trimmed_root);
    allocator.free(repo_root);
    defer allocator.free(root);

    var repo_name = std.fs.path.basename(root);
    if (std.mem.endsWith(u8, repo_name, ".git")) {
        repo_name = repo_name[0 .. repo_name.len - ".git".len];
    }

    var host: []const u8 = "";
    var owner: []const u8 = "";
    if (gitOutput(allocator, &.{ "remote", "get-url", "origin" })) |remote_url| {
        defer allocator.free(remote_url);
        if (parseRemoteURL(std.mem.trim(u8, remote_url, " \r\n\t"))) |parsed| {
            repo_name = parsed.name;
            host = parsed.host;
            owner = parsed.owner;
        }
    } else |_| {}

    const default_base = try getDefaultBase(allocator);
    defer allocator.free(default_base);

    const main_path = try getMainWorktreePath(allocator, default_base, repo_name, root);
    errdefer allocator.free(main_path);

    return .{
        .main = main_path,
        .host = try allocator.dupe(u8, host),
        .owner = try allocator.dupe(u8, owner),
        .name = try allocator.dupe(u8, repo_name),
    };
}

pub fn branchExists(allocator: std.mem.Allocator, branch: []const u8) !bool {
    const local_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    defer allocator.free(local_ref);

    if (try gitQuietSuccess(allocator, &.{ "show-ref", "--verify", "--quiet", local_ref })) {
        return true;
    }

    const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{branch});
    defer allocator.free(remote_ref);
    return gitQuietSuccess(allocator, &.{ "show-ref", "--verify", "--quiet", remote_ref });
}

pub fn getMergedBranches(allocator: std.mem.Allocator, base: []const u8) ![][]u8 {
    const output = try gitOutput(
        allocator,
        &.{ "branch", "--merged", base, "--format=%(refname:short)" },
    );
    defer allocator.free(output);

    return parseBranchLines(allocator, output, base);
}

pub const ParsedRemote = struct {
    host: []const u8,
    owner: []const u8,
    name: []const u8,
};

pub fn parseRemoteURL(remote_url: []const u8) ?ParsedRemote {
    const trimmed = std.mem.trim(u8, remote_url, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.indexOf(u8, trimmed, "://") != null) {
        const uri = std.Uri.parse(trimmed) catch return null;
        const host = uri.host orelse return null;
        const path = std.mem.trim(u8, uri.path.percent_encoded, "/");
        return parseRemotePath(host.percent_encoded, path);
    }

    const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    var host = trimmed[0..colon_index];
    const path = std.mem.trim(u8, trimmed[colon_index + 1 ..], "/");
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at_index| {
        host = host[at_index + 1 ..];
    }

    return parseRemotePath(host, path);
}

fn parseRemotePath(host: []const u8, remote_path: []const u8) ?ParsedRemote {
    var parts = std.mem.splitScalar(u8, remote_path, '/');
    var count: usize = 0;
    var last: []const u8 = "";
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        last = part;
        count += 1;
    }

    if (count < 2 or last.len == 0) return null;
    const name = std.mem.trimRight(u8, last, "/");
    const repo_name = if (std.mem.endsWith(u8, name, ".git")) name[0 .. name.len - 4] else name;
    const owner_len = remote_path.len - last.len - 1;
    if (owner_len <= 0) return null;

    return .{
        .host = host,
        .owner = remote_path[0..owner_len],
        .name = repo_name,
    };
}

fn normalizeBaseRef(allocator: std.mem.Allocator, ref: []const u8) ![]const u8 {
    const prefix = "refs/remotes/origin/";
    if (std.mem.startsWith(u8, ref, prefix)) {
        return allocator.dupe(u8, ref[prefix.len..]);
    }

    return allocator.dupe(u8, ref);
}

fn parseBranchLines(allocator: std.mem.Allocator, output: []const u8, base: []const u8) ![][]u8 {
    var branches = std.ArrayList([]u8).empty;
    errdefer {
        for (branches.items) |branch| allocator.free(branch);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const branch = std.mem.trim(u8, line, " \r\n\t");
        if (branch.len == 0 or
            std.mem.eql(u8, branch, base) or
            std.mem.eql(u8, branch, "main") or
            std.mem.eql(u8, branch, "master"))
        {
            continue;
        }

        try branches.append(allocator, try allocator.dupe(u8, branch));
    }

    return branches.toOwnedSlice(allocator);
}

fn getMainWorktreePath(
    allocator: std.mem.Allocator,
    default_base: []const u8,
    repo_name: []const u8,
    repo_root: []const u8,
) ![]const u8 {
    var result = try worktree.list(allocator, std.io.null_writer);
    defer result.deinit(allocator);

    if (result.entries.len > 0) {
        if (default_base.len != 0) {
            for (result.entries) |entry| {
                if (entry.branch) |branch| {
                    if (std.mem.eql(u8, branch, default_base)) {
                        return allocator.dupe(u8, entry.path);
                    }
                }
            }
        }

        for (result.entries) |entry| {
            if (std.mem.eql(u8, std.fs.path.basename(entry.path), repo_name)) {
                return allocator.dupe(u8, entry.path);
            }
        }

        return allocator.dupe(u8, result.entries[0].path);
    }

    return allocator.dupe(u8, repo_root);
}

fn gitOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.append(allocator, "git");
    try args.appendSlice(allocator, argv);

    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = owned,
    });
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.GitCommandFailed;
    }

    return result.stdout;
}

fn gitQuietSuccess(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.append(allocator, "git");
    try args.appendSlice(allocator, argv);
    const owned = try args.toOwnedSlice(allocator);
    defer allocator.free(owned);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = owned,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term == .Exited and result.term.Exited == 0;
}

test "parseRemoteURL handles https and scp forms" {
    const github = parseRemoteURL("https://github.com/acme/test-repo.git") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("github.com", github.host);
    try std.testing.expectEqualStrings("acme", github.owner);
    try std.testing.expectEqualStrings("test-repo", github.name);

    const gitlab = parseRemoteURL("git@gitlab.com:group/subgroup/project.git") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("gitlab.com", gitlab.host);
    try std.testing.expectEqualStrings("group/subgroup", gitlab.owner);
    try std.testing.expectEqualStrings("project", gitlab.name);
}

test "parseRemoteURL rejects invalid inputs" {
    try std.testing.expectEqual(@as(?ParsedRemote, null), parseRemoteURL(""));
    try std.testing.expectEqual(@as(?ParsedRemote, null), parseRemoteURL("https://github.com"));
    try std.testing.expectEqual(@as(?ParsedRemote, null), parseRemoteURL("git@github.com:repo.git"));
}

test "parseBranchLines filters base and empty lines" {
    const allocator = std.testing.allocator;
    const branches = try parseBranchLines(allocator, "main\nfeature/a\nmaster\n\nfeature/b\n", "main");
    defer {
        for (branches) |branch| allocator.free(branch);
        allocator.free(branches);
    }

    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectEqualStrings("feature/a", branches[0]);
    try std.testing.expectEqualStrings("feature/b", branches[1]);
}
