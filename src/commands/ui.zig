const std = @import("std");
const config = @import("../config.zig");
const output = @import("../output.zig");
const prompt = @import("../prompt.zig");
const remove_cmd = @import("remove.zig");
const worktree = @import("../git/worktree.zig");

const Mode = enum {
    jump,
    remove,
};

const ParsedArgs = struct {
    mode: ?Mode = null,
    force: bool = false,
};

const Choice = struct {
    label: []u8,
    value: []const u8,
};

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseArgs(args) catch {
        return output.usageError(ctx, stdout, stderr, "wt ui", "Usage: wt ui [jump|remove] [--force|-f]");
    };

    if (output.isJson(ctx)) {
        try output.emitError(ctx, stdout, "wt ui", "wt ui is interactive; run without --format json");
        return 1;
    }

    if (parsed.force and (parsed.mode == null or parsed.mode.? != .remove)) {
        return output.usageError(ctx, stdout, stderr, "wt ui", "--force is only supported with `wt ui remove`");
    }

    if (!(try gumAvailable(ctx.allocator))) {
        try stderr.writeAll("gum is required for wt ui. Install gum and try again.\n");
        return 1;
    }

    const mode = parsed.mode orelse ((chooseMode(ctx.allocator, stderr) catch |err| switch (err) {
        error.GumNotFound => {
            try stderr.writeAll("gum is required for wt ui. Install gum and try again.\n");
            return 1;
        },
        else => return err,
    }) orelse {
        try stderr.writeAll("selection cancelled\n");
        return 1;
    });

    return switch (mode) {
        .jump => runJumpUi(ctx.allocator, stdout, stderr),
        .remove => runRemoveUi(ctx, cfg, parsed.force, stdout, stderr),
    };
}

fn runJumpUi(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (listed.entries.len == 0) {
        try stderr.writeAll("no worktrees found\n");
        return 1;
    }

    var choices = std.ArrayList(Choice).empty;
    defer {
        for (choices.items) |choice| allocator.free(choice.label);
        choices.deinit(allocator);
    }

    for (listed.entries) |entry| {
        const branch = displayBranch(entry);
        const safe_branch = try safeForDisplay(allocator, branch);
        defer if (safe_branch.free_on_exit) allocator.free(safe_branch.value);
        const safe_path = try safeForDisplay(allocator, entry.path);
        defer if (safe_path.free_on_exit) allocator.free(safe_path.value);

        const label = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ safe_branch.value, safe_path.value });
        try choices.append(allocator, .{
            .label = label,
            .value = entry.path,
        });
    }

    const selected = gumChoose(allocator, "Select worktree to navigate to", choices.items) catch |err| switch (err) {
        error.GumNotFound => {
            try stderr.writeAll("gum is required for wt ui. Install gum and try again.\n");
            return 1;
        },
        else => return err,
    };
    defer if (selected) |value| allocator.free(value);
    if (selected == null) {
        try stderr.writeAll("selection cancelled\n");
        return 1;
    }

    const matched = matchChoice(choices.items, selected.?);
    if (matched == null) {
        try stderr.writeAll("invalid selection\n");
        return 1;
    }

    try output.emitNavigateTo(stdout, matched.?);
    return 0;
}

fn runRemoveUi(
    ctx: output.Context,
    cfg: *const config.Resolved,
    force: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = ctx.allocator;

    var listed = worktree.list(allocator, stderr) catch return 1;
    defer listed.deinit(allocator);

    if (listed.entries.len <= 1) {
        try stderr.writeAll("no linked worktrees to remove\n");
        return 1;
    }

    var choices = std.ArrayList(Choice).empty;
    defer {
        for (choices.items) |choice| allocator.free(choice.label);
        choices.deinit(allocator);
    }

    for (listed.entries[1..]) |entry| {
        const branch = entry.branch orelse continue;
        const safe_branch = try safeForDisplay(allocator, branch);
        defer if (safe_branch.free_on_exit) allocator.free(safe_branch.value);
        const safe_path = try safeForDisplay(allocator, entry.path);
        defer if (safe_path.free_on_exit) allocator.free(safe_path.value);

        const label = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ safe_branch.value, safe_path.value });
        try choices.append(allocator, .{
            .label = label,
            .value = branch,
        });
    }

    if (choices.items.len == 0) {
        try stderr.writeAll("no branch-linked worktrees to remove\n");
        return 1;
    }

    const selected = gumChoose(allocator, "Select worktree to remove", choices.items) catch |err| switch (err) {
        error.GumNotFound => {
            try stderr.writeAll("gum is required for wt ui. Install gum and try again.\n");
            return 1;
        },
        else => return err,
    };
    defer if (selected) |value| allocator.free(value);
    if (selected == null) {
        try stderr.writeAll("selection cancelled\n");
        return 1;
    }

    const branch = matchChoice(choices.items, selected.?) orelse {
        try stderr.writeAll("invalid selection\n");
        return 1;
    };

    const safe_branch = try safeForDisplay(allocator, branch);
    defer if (safe_branch.free_on_exit) allocator.free(safe_branch.value);
    const confirm_message = try std.fmt.allocPrint(allocator, "Remove worktree for branch {s}?", .{safe_branch.value});
    defer allocator.free(confirm_message);

    const confirmed = gumConfirm(allocator, confirm_message) catch |err| switch (err) {
        error.GumNotFound => {
            try stderr.writeAll("gum is required for wt ui. Install gum and try again.\n");
            return 1;
        },
        else => return err,
    };
    if (!confirmed) {
        try stderr.writeAll("selection cancelled\n");
        return 1;
    }

    var remove_args = std.ArrayList([]const u8).empty;
    defer remove_args.deinit(allocator);
    if (force) try remove_args.append(allocator, "--force");
    try remove_args.append(allocator, branch);
    const owned_args = try remove_args.toOwnedSlice(allocator);
    defer allocator.free(owned_args);

    return remove_cmd.run(ctx, cfg, owned_args, stdout, stderr);
}

fn displayBranch(entry: worktree.Entry) []const u8 {
    if (entry.branch) |branch| return branch;
    if (entry.detached) return "(detached)";
    if (entry.bare) return "(bare)";
    return "(main)";
}

fn chooseMode(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !?Mode {
    _ = stderr;
    var options = std.ArrayList(Choice).empty;
    defer {
        for (options.items) |item| allocator.free(item.label);
        options.deinit(allocator);
    }
    try options.append(allocator, .{
        .label = try allocator.dupe(u8, "jump"),
        .value = "jump",
    });
    try options.append(allocator, .{
        .label = try allocator.dupe(u8, "remove"),
        .value = "remove",
    });
    try options.append(allocator, .{
        .label = try allocator.dupe(u8, "quit"),
        .value = "quit",
    });

    const selected = try gumChoose(allocator, "wt ui action", options.items);
    defer if (selected) |value| allocator.free(value);
    if (selected == null) return null;

    if (std.mem.eql(u8, selected.?, "jump")) return .jump;
    if (std.mem.eql(u8, selected.?, "remove")) return .remove;
    return null;
}

fn gumAvailable(allocator: std.mem.Allocator) !bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gum", "--version" },
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn gumChoose(allocator: std.mem.Allocator, header: []const u8, choices: []const Choice) !?[]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "gum", "choose", "--height", "20", "--header", header });
    for (choices) |choice| try argv.append(allocator, choice.label);

    const owned_argv = try argv.toOwnedSlice(allocator);
    defer allocator.free(owned_argv);

    const result = runGumCaptureStdout(allocator, owned_argv) catch |err| switch (err) {
        error.FileNotFound => return error.GumNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);

    return switch (result.term) {
        .Exited => |code| if (code == 0) blk: {
            const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
            if (trimmed.len == 0) break :blk null;
            break :blk try allocator.dupe(u8, trimmed);
        } else null,
        else => null,
    };
}

fn gumConfirm(allocator: std.mem.Allocator, message: []const u8) !bool {
    const result = runGumCaptureStdout(allocator, &.{ "gum", "confirm", message }) catch |err| switch (err) {
        error.FileNotFound => return error.GumNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const GumCaptureResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
};

fn runGumCaptureStdout(allocator: std.mem.Allocator, argv: []const []const u8) !GumCaptureResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const captured = try child.stdout.?.readToEndAlloc(allocator, 64 * 1024);
    errdefer allocator.free(captured);
    const term = try child.wait();

    return .{
        .term = term,
        .stdout = captured,
    };
}

const SafeSlice = struct {
    value: []const u8,
    free_on_exit: bool,
};

fn safeForDisplay(allocator: std.mem.Allocator, value: []const u8) !SafeSlice {
    const safe = try prompt.sanitizeForTerminal(allocator, value);
    return .{
        .value = safe,
        .free_on_exit = safe.ptr != value.ptr,
    };
}

fn matchChoice(choices: []const Choice, selected: []const u8) ?[]const u8 {
    for (choices) |choice| {
        if (std.mem.eql(u8, choice.label, selected)) return choice.value;
    }
    return null;
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    var parsed = ParsedArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            parsed.force = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "jump")) {
            if (parsed.mode != null) return error.InvalidArguments;
            parsed.mode = .jump;
            continue;
        }

        if (std.mem.eql(u8, arg, "remove")) {
            if (parsed.mode != null) return error.InvalidArguments;
            parsed.mode = .remove;
            continue;
        }

        return error.InvalidArguments;
    }

    return parsed;
}

test "parseArgs accepts remove with force" {
    const parsed = try parseArgs(&.{ "remove", "--force" });
    try std.testing.expectEqual(Mode.remove, parsed.mode.?);
    try std.testing.expect(parsed.force);
}

test "parseArgs accepts jump mode" {
    const parsed = try parseArgs(&.{"jump"});
    try std.testing.expectEqual(Mode.jump, parsed.mode.?);
    try std.testing.expect(!parsed.force);
}

test "parseArgs rejects unknown arguments" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"wat"}));
}
