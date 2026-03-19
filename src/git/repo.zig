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

    var repo_name = try resolveRepoName(allocator, root);
    errdefer allocator.free(repo_name);
    var host = try allocator.dupe(u8, "");
    errdefer allocator.free(host);
    var owner = try allocator.dupe(u8, "");
    errdefer allocator.free(owner);
    if (gitOutput(allocator, &.{ "remote", "get-url", "origin" })) |remote_url| {
        defer allocator.free(remote_url);
        if (parseRemoteURL(std.mem.trim(u8, remote_url, " \r\n\t"))) |parsed| {
            allocator.free(repo_name);
            repo_name = try allocator.dupe(u8, parsed.name);
            allocator.free(host);
            host = try allocator.dupe(u8, parsed.host);
            allocator.free(owner);
            owner = try allocator.dupe(u8, parsed.owner);
        }
    } else |_| {}

    const default_base = try getDefaultBase(allocator);
    defer allocator.free(default_base);

    const main_path = try getMainWorktreePath(allocator, default_base, repo_name, root);
    errdefer allocator.free(main_path);

    return .{
        .main = main_path,
        .host = host,
        .owner = owner,
        .name = repo_name,
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

pub fn getAvailableBranches(allocator: std.mem.Allocator) ![][]u8 {
    const output = try gitOutput(
        allocator,
        &.{ "branch", "-a", "--format=%(refname:short)" },
    );
    defer allocator.free(output);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var branches = std.ArrayList([]u8).empty;
    errdefer {
        for (branches.items) |branch| allocator.free(branch);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var branch = std.mem.trim(u8, line, " \r\n\t");
        if (branch.len == 0) continue;
        if (std.mem.startsWith(u8, branch, "origin/HEAD")) continue;
        if (std.mem.indexOf(u8, branch, "->") != null) continue;
        if (std.mem.indexOf(u8, branch, "HEAD") != null) continue;
        if (std.mem.startsWith(u8, branch, "origin/")) branch = branch["origin/".len..];
        if (std.mem.startsWith(u8, branch, "upstream/")) branch = branch["upstream/".len..];
        if (std.mem.eql(u8, branch, "origin") or std.mem.eql(u8, branch, "upstream")) continue;
        if (seen.contains(branch)) continue;
        const owned = try allocator.dupe(u8, branch);
        try seen.put(owned, {});
        try branches.append(allocator, owned);
    }

    std.mem.sort([]u8, branches.items, {}, sortStringsAsc);
    return branches.toOwnedSlice(allocator);
}

pub fn getExistingWorktreeBranches(allocator: std.mem.Allocator) ![][]u8 {
    var result = try worktree.list(allocator, std.io.null_writer);
    defer result.deinit(allocator);

    if (result.entries.len <= 1) return allocator.alloc([]u8, 0);

    var branches = std.ArrayList([]u8).empty;
    errdefer {
        for (branches.items) |branch| allocator.free(branch);
        branches.deinit(allocator);
    }

    for (result.entries[1..]) |entry| {
        if (entry.branch) |branch| {
            try branches.append(allocator, try allocator.dupe(u8, branch));
        }
    }

    return branches.toOwnedSlice(allocator);
}

pub fn getMergedBranches(allocator: std.mem.Allocator, base: []const u8) ![][]u8 {
    const output = try gitOutput(
        allocator,
        &.{ "branch", "--merged", base, "--format=%(refname:short)" },
    );
    defer allocator.free(output);

    return parseBranchLines(allocator, output, base);
}

fn sortStringsAsc(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
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

fn resolveRepoName(allocator: std.mem.Allocator, repo_root: []const u8) ![]u8 {
    if (gitOutput(allocator, &.{ "rev-parse", "--git-common-dir" })) |common_dir_output| {
        defer allocator.free(common_dir_output);
        return resolveRepoNameFromCommonDir(allocator, repo_root, std.mem.trim(u8, common_dir_output, " \r\n\t"));
    } else |_| {}

    return allocator.dupe(u8, trimGitSuffix(std.fs.path.basename(repo_root)));
}

fn resolveRepoNameFromCommonDir(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    common_dir: []const u8,
) ![]u8 {
    if (common_dir.len == 0) {
        return allocator.dupe(u8, trimGitSuffix(std.fs.path.basename(repo_root)));
    }

    var joined_common_dir: ?[]u8 = null;
    defer if (joined_common_dir) |value| allocator.free(value);

    var resolved_input = common_dir;
    if (!std.fs.path.isAbsolute(common_dir)) {
        joined_common_dir = try std.fs.path.join(allocator, &.{ repo_root, common_dir });
        resolved_input = joined_common_dir.?;
    }

    const clean_common_dir = try std.fs.path.resolve(allocator, &.{resolved_input});
    defer allocator.free(clean_common_dir);

    const base = std.fs.path.basename(clean_common_dir);
    if (std.mem.eql(u8, base, ".git")) {
        return allocator.dupe(u8, trimGitSuffix(std.fs.path.basename(std.fs.path.dirname(clean_common_dir) orelse repo_root)));
    }

    return allocator.dupe(u8, trimGitSuffix(base));
}

fn trimGitSuffix(value: []const u8) []const u8 {
    if (std.mem.endsWith(u8, value, ".git")) {
        return value[0 .. value.len - ".git".len];
    }
    return value;
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

test "resolveRepoNameFromCommonDir uses shared git dir for linked worktrees" {
    const allocator = std.testing.allocator;

    const linked = try resolveRepoNameFromCommonDir(allocator, "/tmp/worktrees/test-repo/feature-a", "/tmp/repo/.git");
    defer allocator.free(linked);
    try std.testing.expectEqualStrings("repo", linked);

    const bare = try resolveRepoNameFromCommonDir(allocator, "/tmp/repo", "/tmp/repo.git");
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("repo", bare);
}

test "getAvailableBranches parsing strips remote prefixes and deduplicates" {
    const allocator = std.testing.allocator;
    const output =
        "main\norigin/main\norigin/feature/a\nfeature/a\norigin/HEAD -> origin/main\nupstream/feature/b\n";
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var branches = std.ArrayList([]u8).empty;
    defer {
        for (branches.items) |branch| allocator.free(branch);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var branch = std.mem.trim(u8, line, " \r\n\t");
        if (branch.len == 0) continue;
        if (std.mem.startsWith(u8, branch, "origin/HEAD")) continue;
        if (std.mem.indexOf(u8, branch, "->") != null) continue;
        if (std.mem.indexOf(u8, branch, "HEAD") != null) continue;
        if (std.mem.startsWith(u8, branch, "origin/")) branch = branch["origin/".len..];
        if (std.mem.startsWith(u8, branch, "upstream/")) branch = branch["upstream/".len..];
        if (seen.contains(branch)) continue;
        const owned = try allocator.dupe(u8, branch);
        try seen.put(owned, {});
        try branches.append(allocator, owned);
    }

    std.mem.sort([]u8, branches.items, {}, sortStringsAsc);
    try std.testing.expectEqual(@as(usize, 3), branches.items.len);
    try std.testing.expectEqualStrings("feature/a", branches.items[0]);
    try std.testing.expectEqualStrings("feature/b", branches.items[1]);
    try std.testing.expectEqualStrings("main", branches.items[2]);
}
