const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");
const prompt = @import("prompt.zig");

pub const ApprovalError = error{CommandApprovalRequired};

pub const State = struct {
    path: []const u8,
    commands: []const []const u8,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.commands) |command| allocator.free(command);
        allocator.free(self.commands);
    }
};

pub const ApproveResult = struct {
    path: []const u8,
    added: usize,
    total: usize,

    pub fn deinit(self: *ApproveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn ensureAliasApproved(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    alias_name: []const u8,
    stderr: *std.Io.Writer,
) !void {
    if (try bypassApprovals(allocator, cfg)) return;
    if (!cfg.config_repo_found) return;

    var parsed = try config.parseFile(allocator, cfg.config_repo_path);
    defer parsed.deinit(allocator);

    const commands = projectAliasCommands(parsed.aliases, alias_name) orelse return;
    try ensureCommandsApproved(allocator, cfg, "alias", alias_name, commands, stderr);
}

pub fn ensureHookApproved(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    hook_name: []const u8,
    stderr: *std.Io.Writer,
) !void {
    if (try bypassApprovals(allocator, cfg)) return;
    if (!cfg.config_repo_found) return;

    var parsed = try config.parseFile(allocator, cfg.config_repo_path);
    defer parsed.deinit(allocator);

    const commands = projectHookCommands(parsed.hooks, hook_name);
    try ensureCommandsApproved(allocator, cfg, "hook", hook_name, commands, stderr);
}

pub fn approveProjectCommands(allocator: std.mem.Allocator, cfg: *const config.Resolved) !ApproveResult {
    const path = try approvalPath(allocator, cfg);
    errdefer allocator.free(path);

    if (!cfg.config_repo_found) {
        return .{ .path = path, .added = 0, .total = 0 };
    }

    var parsed = try config.parseFile(allocator, cfg.config_repo_path);
    defer parsed.deinit(allocator);

    var state = try loadFromPath(allocator, path);
    defer state.deinit(allocator);

    var commands = std.ArrayList([]const u8).empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    for (state.commands) |command| {
        try appendUniqueOwned(allocator, &commands, command);
    }

    var added: usize = 0;
    for (parsed.aliases) |alias| {
        added += try appendMissingCommands(allocator, &commands, alias.commands);
    }

    inline for (comptime std.meta.fields(config.Hooks)) |field| {
        added += try appendMissingCommands(allocator, &commands, @field(parsed.hooks, field.name));
    }

    const saved_commands = try commands.toOwnedSlice(allocator);
    defer {
        for (saved_commands) |command| allocator.free(command);
        allocator.free(saved_commands);
    }

    try saveCommands(allocator, path, saved_commands);
    return .{ .path = path, .added = added, .total = saved_commands.len };
}

pub fn load(allocator: std.mem.Allocator, cfg: *const config.Resolved) !State {
    const path = try approvalPath(allocator, cfg);
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn clear(allocator: std.mem.Allocator, cfg: *const config.Resolved) ![]const u8 {
    const path = try approvalPath(allocator, cfg);
    const delete_result = if (std.fs.path.isAbsolute(path))
        std.fs.deleteFileAbsolute(path)
    else
        std.fs.cwd().deleteFile(path);
    delete_result catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return path;
}

fn ensureCommandsApproved(
    allocator: std.mem.Allocator,
    cfg: *const config.Resolved,
    kind: []const u8,
    name: []const u8,
    commands: []const []const u8,
    stderr: *std.Io.Writer,
) !void {
    if (commands.len == 0) return;

    var state = try load(allocator, cfg);
    defer state.deinit(allocator);

    var missing_count: usize = 0;
    for (commands) |command| {
        if (!containsCommand(state.commands, command)) missing_count += 1;
    }
    if (missing_count == 0) return;

    try stderr.print("project {s} \"{s}\" requires approval for command(s):\n", .{ kind, name });
    for (commands) |command| {
        if (containsCommand(state.commands, command)) continue;
        const safe = prompt.sanitizeForTerminal(allocator, command) catch command;
        defer if (safe.ptr != command.ptr) allocator.free(safe);
        try stderr.print("  {s}\n", .{safe});
    }
    try stderr.writeAll(
        "Run `wt config approvals add` to approve project commands, rerun with `--yes` to bypass once, or set WT_APPROVALS_DISABLED=1.\n",
    );
    return ApprovalError.CommandApprovalRequired;
}

fn bypassApprovals(allocator: std.mem.Allocator, cfg: *const config.Resolved) !bool {
    if (cfg.approvals_bypass) return true;

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    if (env.get("WT_APPROVALS_DISABLED")) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
    }
    if (env.get("WORKTRUNK_APPROVALS_DISABLED")) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
    }
    return false;
}

fn approvalPath(allocator: std.mem.Allocator, cfg: *const config.Resolved) ![]const u8 {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    if (env.get("WT_APPROVALS_PATH")) |path| {
        return allocator.dupe(u8, path);
    }
    if (env.get("WORKTRUNK_APPROVALS_PATH")) |path| {
        return allocator.dupe(u8, path);
    }

    const dir = std.fs.path.dirname(cfg.config_file_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "approvals.toml" });
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !State {
    const buffer = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = try allocator.dupe(u8, path),
            .commands = &.{},
        },
        else => return err,
    };
    defer allocator.free(buffer);

    return .{
        .path = try allocator.dupe(u8, path),
        .commands = try parseApprovedCommands(allocator, buffer),
    };
}

fn saveCommands(allocator: std.mem.Allocator, path: []const u8, commands: []const []const u8) !void {
    try fs.ensureParentDir(allocator, path);

    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var writer = file.writer(&file_buf);
    try writer.interface.writeAll(
        \\# wt project command approvals
        \\# Project hooks and aliases from .wt.toml must be approved before execution.
        \\approved_commands = [
        \\
    );
    for (commands) |command| {
        try writer.interface.writeAll("  ");
        try writeTomlString(&writer.interface, command);
        try writer.interface.writeAll(",\n");
    }
    try writer.interface.writeAll("]\n");
    try writer.interface.flush();
}

fn parseApprovedCommands(allocator: std.mem.Allocator, buffer: []const u8) ![]const []const u8 {
    var commands = std.ArrayList([]const u8).empty;
    errdefer {
        for (commands.items) |command| allocator.free(command);
        commands.deinit(allocator);
    }

    var in_array = false;
    var lines = std.mem.splitScalar(u8, buffer, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

        if (!in_array) {
            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            if (!std.mem.eql(u8, key, "approved_commands") and
                !std.mem.eql(u8, key, "approved-commands"))
            {
                continue;
            }

            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
            if (value.len == 0 or value[0] != '[') continue;
            try appendQuotedStrings(allocator, &commands, value);
            in_array = std.mem.indexOfScalar(u8, value, ']') == null;
            continue;
        }

        try appendQuotedStrings(allocator, &commands, line);
        if (std.mem.indexOfScalar(u8, line, ']') != null) in_array = false;
    }

    return commands.toOwnedSlice(allocator);
}

fn appendQuotedStrings(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]const u8),
    line: []const u8,
) !void {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (line[index] != '"') continue;
        const parsed = try parseTomlStringAt(allocator, line, index);
        index = parsed.next_index;
        try appendUniqueOwned(allocator, commands, parsed.value);
        allocator.free(parsed.value);
    }
}

const ParsedString = struct {
    value: []const u8,
    next_index: usize,
};

fn parseTomlStringAt(allocator: std.mem.Allocator, line: []const u8, start: usize) !ParsedString {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index = start + 1;
    while (index < line.len) : (index += 1) {
        const ch = line[index];
        if (ch == '"') {
            return .{ .value = try out.toOwnedSlice(allocator), .next_index = index };
        }
        if (ch == '\\' and index + 1 < line.len) {
            index += 1;
            const escaped = line[index];
            try out.append(allocator, switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => escaped,
            });
            continue;
        }
        try out.append(allocator, ch);
    }

    return error.InvalidApprovalsFile;
}

fn writeTomlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

fn projectAliasCommands(aliases: []const config.Alias, alias_name: []const u8) ?[]const []const u8 {
    for (aliases) |alias| {
        if (std.mem.eql(u8, alias.name, alias_name)) return alias.commands;
    }
    return null;
}

fn projectHookCommands(hooks: config.Hooks, hook_name: []const u8) []const []const u8 {
    inline for (comptime std.meta.fields(config.Hooks)) |field| {
        if (std.mem.eql(u8, hook_name, field.name)) {
            return @field(hooks, field.name);
        }
    }
    return &.{};
}

fn appendMissingCommands(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]const u8),
    candidates: []const []const u8,
) !usize {
    var added: usize = 0;
    for (candidates) |candidate| {
        if (containsCommand(commands.items, candidate)) continue;
        try commands.append(allocator, try allocator.dupe(u8, candidate));
        added += 1;
    }
    return added;
}

fn appendUniqueOwned(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]const u8),
    command: []const u8,
) !void {
    if (containsCommand(commands.items, command)) return;
    try commands.append(allocator, try allocator.dupe(u8, command));
}

fn containsCommand(commands: []const []const u8, command: []const u8) bool {
    for (commands) |approved| {
        if (std.mem.eql(u8, approved, command)) return true;
    }
    return false;
}

test "parseApprovedCommands reads wt and worktrunk key spellings" {
    const allocator = std.testing.allocator;
    const parsed = try parseApprovedCommands(
        allocator,
        "approved_commands = [\"echo one\"]\napproved-commands = [\"echo two\"]\n",
    );
    defer {
        for (parsed) |command| allocator.free(command);
        allocator.free(parsed);
    }

    try std.testing.expectEqual(2, parsed.len);
    try std.testing.expectEqualStrings("echo one", parsed[0]);
    try std.testing.expectEqualStrings("echo two", parsed[1]);
}

test "ensureAliasApproved blocks project aliases until approved" {
    const allocator = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(.{
        .sub_path = ".wt.toml",
        .data =
        \\[aliases]
        \\ship = "git push"
        \\
        ,
    });

    const root = try dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const repo_config_path = try std.fs.path.join(allocator, &.{ root, ".wt.toml" });
    defer allocator.free(repo_config_path);
    const user_config_path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(user_config_path);

    var cfg = config.testing_defaults;
    cfg.config_file_path = user_config_path;
    cfg.config_repo_path = repo_config_path;
    cfg.config_repo_found = true;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buf);
    try std.testing.expectError(
        ApprovalError.CommandApprovalRequired,
        ensureAliasApproved(allocator, &cfg, "ship", &stderr),
    );

    var result = try approveProjectCommands(allocator, &cfg);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.added);
    try ensureAliasApproved(allocator, &cfg, "ship", &stderr);
}
