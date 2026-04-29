const std = @import("std");
const output = @import("../output.zig");
const worktree = @import("../git/worktree.zig");

pub fn run(
    ctx: output.Context,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;

    var result = worktree.list(allocator, stderr) catch return 1;
    defer result.deinit(allocator);

    // entries[0] is always the main worktree; linked worktrees follow.
    const linked = if (result.entries.len > 1) result.entries[1..] else &.{};

    if (args.len == 0) {
        return output.usageError(ctx, stdout, stderr, "wt jump", "Usage: wt jump <query>");
    }

    const query = args[0];

    // Matching hierarchy (short-circuits on first hit).
    if (findBestMatch(allocator, linked, query)) |matched| {
        if (output.isJson(ctx)) {
            const branch = matched.branch orelse "";
            try output.emitSuccess(ctx, stdout, "wt jump", .{
                .branch = branch,
                .path = matched.path,
                .navigate_to = matched.path,
            });
            return 0;
        }
        return navigate(ctx, matched, stdout);
    }

    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt jump", "no worktree found matching query");
        return 1;
    }
    try stderr.print("No worktree found matching \"{s}\".\n", .{query});
    try stderr.print("hint: run 'wt checkout {s}' to create one\n", .{query});
    return 1;
}

fn navigate(ctx: output.Context, entry: worktree.Entry, stdout: *std.Io.Writer) !u8 {
    _ = ctx;
    try output.emitNavigateTo(stdout, entry.path);
    return 0;
}

/// Walk each match tier in priority order and return the single best entry.
/// If a tier has exactly one match, return it. If a tier has multiple matches,
/// pick the one with the shortest branch name (most specific). If no tier
/// matches, return null.
pub fn findBestMatch(
    allocator: std.mem.Allocator,
    entries: []const worktree.Entry,
    query: []const u8,
) ?worktree.Entry {
    const lower_query = std.ascii.allocLowerString(allocator, query) catch return null;
    defer allocator.free(lower_query);

    // Tier 1: exact (case-sensitive)
    if (findExact(entries, query)) |e| return e;

    // Tier 2: exact (case-insensitive)
    if (findExactIgnoreCase(entries, lower_query)) |e| return e;

    // Tier 3: word-boundary (after / - _), case-insensitive
    if (bestOf(entries, lower_query, isWordBoundaryMatch)) |e| return e;

    // Tier 4: substring (case-insensitive)
    if (bestOf(entries, lower_query, isSubstringMatch)) |e| return e;

    // Tier 5: fuzzy subsequence (min 3 chars)
    if (query.len >= 3) {
        if (bestOf(entries, lower_query, isFuzzyMatch)) |e| return e;
    }

    return null;
}

fn findExact(entries: []const worktree.Entry, query: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |b| {
            if (std.mem.eql(u8, b, query)) return entry;
        }
    }
    return null;
}

fn findExactIgnoreCase(entries: []const worktree.Entry, lower_query: []const u8) ?worktree.Entry {
    for (entries) |entry| {
        if (entry.branch) |b| {
            if (b.len == lower_query.len) {
                var match = true;
                for (b, 0..) |ch, i| {
                    if (std.ascii.toLower(ch) != lower_query[i]) {
                        match = false;
                        break;
                    }
                }
                if (match) return entry;
            }
        }
    }
    return null;
}

/// Collect all entries where matchFn returns true, then return the shortest-
/// branch-name entry (most specific). Returns null if no matches.
fn bestOf(
    entries: []const worktree.Entry,
    lower_query: []const u8,
    matchFn: fn (branch: []const u8, lower_query: []const u8) bool,
) ?worktree.Entry {
    var best: ?worktree.Entry = null;
    var best_len: usize = std.math.maxInt(usize);
    for (entries) |entry| {
        if (entry.branch) |b| {
            // Work with lowercased branch for matching
            var lower_buf: [512]u8 = undefined;
            const lower_b = if (b.len <= lower_buf.len)
                std.ascii.lowerString(lower_buf[0..b.len], b)
            else
                b; // skip case-fold for very long names
            if (matchFn(lower_b, lower_query)) {
                if (b.len < best_len) {
                    best = entry;
                    best_len = b.len;
                }
            }
        }
    }
    return best;
}

/// True if lower_query appears immediately after a word boundary
/// (start of string, or after / - _) in branch.
fn isWordBoundaryMatch(branch: []const u8, lower_query: []const u8) bool {
    if (std.mem.startsWith(u8, branch, lower_query)) return true;
    var i: usize = 1;
    while (i < branch.len) : (i += 1) {
        const prev = branch[i - 1];
        if (prev == '/' or prev == '-' or prev == '_') {
            if (std.mem.startsWith(u8, branch[i..], lower_query)) return true;
        }
    }
    return false;
}

fn isSubstringMatch(branch: []const u8, lower_query: []const u8) bool {
    return std.mem.indexOf(u8, branch, lower_query) != null;
}

/// Subsequence match: every character of lower_query must appear in branch in
/// order (but not necessarily contiguously).
fn isFuzzyMatch(branch: []const u8, lower_query: []const u8) bool {
    var bi: usize = 0;
    for (lower_query) |ch| {
        while (bi < branch.len) : (bi += 1) {
            if (branch[bi] == ch) {
                bi += 1;
                break;
            }
        } else return false;
    }
    return true;
}

test "exact match" {
    const entries = [_]worktree.Entry{
        .{ .path = "/wt/main", .head = null, .branch = "main", .bare = false, .detached = false, .locked = null, .prunable = null },
        .{ .path = "/wt/feat-login", .head = null, .branch = "feat/login", .bare = false, .detached = false, .locked = null, .prunable = null },
        .{ .path = "/wt/fix-bug", .head = null, .branch = "fix/bug-123", .bare = false, .detached = false, .locked = null, .prunable = null },
    };
    const matched = findExact(&entries, "feat/login");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("feat/login", matched.?.branch.?);
}

test "word boundary match: partial suffix" {
    const lower_branch = "feat/login";
    try std.testing.expect(isWordBoundaryMatch(lower_branch, "login"));
    try std.testing.expect(!isWordBoundaryMatch(lower_branch, "ogin"));
    try std.testing.expect(isWordBoundaryMatch("fix-auth-bug", "auth"));
    try std.testing.expect(isWordBoundaryMatch("fix_config", "config"));
}

test "substring match" {
    try std.testing.expect(isSubstringMatch("feat/login-flow", "login"));
    try std.testing.expect(!isSubstringMatch("feat/signup", "login"));
}

test "fuzzy match" {
    try std.testing.expect(isFuzzyMatch("feat/login", "feli")); // f-e...l-i
    try std.testing.expect(isFuzzyMatch("feat/login", "flo")); // f...l...o is not contiguous but subsequence
    try std.testing.expect(!isFuzzyMatch("feat/login", "xyz"));
    try std.testing.expect(isFuzzyMatch("feat/login", "feat")); // exact prefix still works
}

test "findBestMatch priority: word boundary beats substring" {
    const allocator = std.testing.allocator;
    const entries = [_]worktree.Entry{
        .{ .path = "/wt/fix-relogin", .head = null, .branch = "fix/relogin", .bare = false, .detached = false, .locked = null, .prunable = null },
        .{ .path = "/wt/feat-login", .head = null, .branch = "feat/login", .bare = false, .detached = false, .locked = null, .prunable = null },
    };
    // "login" is a word-boundary match for feat/login, and substring of fix/relogin.
    // Word boundary tier fires first, feat/login is shorter so it wins.
    const matched = findBestMatch(allocator, &entries, "login");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("feat/login", matched.?.branch.?);
}

test "findBestMatch: no match returns null" {
    const allocator = std.testing.allocator;
    const entries = [_]worktree.Entry{
        .{ .path = "/wt/main", .head = null, .branch = "main", .bare = false, .detached = false, .locked = null, .prunable = null },
    };
    try std.testing.expect(findBestMatch(allocator, &entries, "zzz") == null);
}
