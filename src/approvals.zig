const std = @import("std");
const config = @import("config.zig");
const fs = @import("fs.zig");
const prompt = @import("prompt.zig");

pub const ApprovalError = error{CommandApprovalRequired};

pub const State = struct {
    path: []const u8,
    project_id: []const u8,
    commands: []const []const u8,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.project_id);
        for (self.commands) |command| allocator.free(command);
        allocator.free(self.commands);
    }
};

pub const ApproveResult = struct {
    path: []const u8,
    project_id: []const u8,
    added: usize,
    total: usize,

    pub fn deinit(self: *ApproveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.project_id);
    }
};

const ProjectState = struct {
    id: []const u8,
    commands: []const []const u8,
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
    const project_id = try projectIdentifier(allocator, cfg);
    errdefer allocator.free(project_id);

    if (!cfg.config_repo_found) {
        return .{ .path = path, .project_id = project_id, .added = 0, .total = 0 };
    }

    var parsed = try config.parseFile(allocator, cfg.config_repo_path);
    defer parsed.deinit(allocator);

    var state = try loadFromPath(allocator, path, project_id);
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

    try saveProjectCommands(allocator, path, project_id, saved_commands);
    return .{ .path = path, .project_id = project_id, .added = added, .total = saved_commands.len };
}

pub fn load(allocator: std.mem.Allocator, cfg: *const config.Resolved) !State {
    const path = try approvalPath(allocator, cfg);
    defer allocator.free(path);
    const project_id = try projectIdentifier(allocator, cfg);
    defer allocator.free(project_id);
    return loadFromPath(allocator, path, project_id);
}

pub fn clear(allocator: std.mem.Allocator, cfg: *const config.Resolved) ![]const u8 {
    const path = try approvalPath(allocator, cfg);
    errdefer allocator.free(path);
    const project_id = try projectIdentifier(allocator, cfg);
    defer allocator.free(project_id);

    const projects = try loadProjectsFromPath(allocator, path);
    defer freeProjects(allocator, projects);

    for (projects) |*project| {
        if (!std.mem.eql(u8, project.id, project_id)) continue;
        for (project.commands) |command| allocator.free(command);
        allocator.free(project.commands);
        project.commands = try allocator.alloc([]const u8, 0);
        try saveProjects(allocator, path, projects);
        return path;
    }

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

    if (!canPromptForApproval()) {
        return ApprovalError.CommandApprovalRequired;
    }

    if (!try prompt.confirmPrompt(allocator, "Allow and remember project commands?", stderr)) {
        return ApprovalError.CommandApprovalRequired;
    }

    var merged = std.ArrayList([]const u8).empty;
    errdefer {
        for (merged.items) |command| allocator.free(command);
        merged.deinit(allocator);
    }

    for (state.commands) |command| {
        try appendUniqueOwned(allocator, &merged, command);
    }
    _ = try appendMissingCommands(allocator, &merged, commands);

    const saved_commands = try merged.toOwnedSlice(allocator);
    defer {
        for (saved_commands) |command| allocator.free(command);
        allocator.free(saved_commands);
    }

    try saveProjectCommands(allocator, state.path, state.project_id, saved_commands);
}

fn canPromptForApproval() bool {
    if (std.fs.File.stdin().isTty()) return true;
    const value = std.posix.getenv("WT_USE_STDIN") orelse return false;
    return std.mem.eql(u8, value, "1");
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

fn projectIdentifier(allocator: std.mem.Allocator, cfg: *const config.Resolved) ![]const u8 {
    const repo_root = if (cfg.config_repo_found and cfg.config_repo_path.len != 0)
        std.fs.path.dirname(cfg.config_repo_path) orelse "."
    else
        std.fs.path.dirname(cfg.config_file_path) orelse ".";

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", repo_root, "remote", "get-url", "origin" },
    }) catch {
        return allocator.dupe(u8, std.fs.path.basename(repo_root));
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    }) {
        const remote = std.mem.trim(u8, result.stdout, " \r\n\t");
        if (try parseRemoteProjectId(allocator, remote)) |id| return id;
    }

    return allocator.dupe(u8, std.fs.path.basename(repo_root));
}

fn parseRemoteProjectId(allocator: std.mem.Allocator, remote: []const u8) !?[]const u8 {
    if (remote.len == 0) return null;

    if (std.mem.indexOf(u8, remote, "://")) |scheme_end| {
        const rest = remote[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        const path_part = stripGitSuffix(rest[slash + 1 ..]);
        if (host.len == 0 or path_part.len == 0) return null;
        const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host, path_part });
        return @as(?[]const u8, id);
    }

    if (std.mem.indexOfScalar(u8, remote, ':')) |colon| {
        const before = remote[0..colon];
        const at = std.mem.lastIndexOfScalar(u8, before, '@');
        const host = if (at) |index| before[index + 1 ..] else before;
        const path_part = stripGitSuffix(remote[colon + 1 ..]);
        if (host.len == 0 or path_part.len == 0) return null;
        const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host, path_part });
        return @as(?[]const u8, id);
    }

    return null;
}

fn stripGitSuffix(value: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, value, ".git"))
        value[0 .. value.len - ".git".len]
    else
        value;
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8, project_id: []const u8) !State {
    const buffer = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = try allocator.dupe(u8, path),
            .project_id = try allocator.dupe(u8, project_id),
            .commands = try allocator.alloc([]const u8, 0),
        },
        else => return err,
    };
    defer allocator.free(buffer);

    return .{
        .path = try allocator.dupe(u8, path),
        .project_id = try allocator.dupe(u8, project_id),
        .commands = try parseApprovedCommands(allocator, buffer, project_id),
    };
}

fn saveProjectCommands(
    allocator: std.mem.Allocator,
    path: []const u8,
    project_id: []const u8,
    commands: []const []const u8,
) !void {
    var projects = try loadProjectsFromPath(allocator, path);
    defer {
        freeProjects(allocator, projects);
    }

    var replaced = false;
    for (projects) |*project| {
        if (!std.mem.eql(u8, project.id, project_id)) continue;
        for (project.commands) |command| allocator.free(command);
        allocator.free(project.commands);
        project.commands = try dupeCommands(allocator, commands);
        replaced = true;
        break;
    }

    if (!replaced) {
        const grown = try allocator.realloc(projects, projects.len + 1);
        projects = grown;
        projects[projects.len - 1] = .{
            .id = try allocator.dupe(u8, project_id),
            .commands = try dupeCommands(allocator, commands),
        };
    }

    try saveProjects(allocator, path, projects);
}

fn saveProjects(allocator: std.mem.Allocator, path: []const u8, projects: []const ProjectState) !void {
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
        \\
    );

    for (projects) |project| {
        if (project.commands.len == 0) continue;

        try writer.interface.writeAll("\n[projects.");
        try writeTomlString(&writer.interface, project.id);
        try writer.interface.writeAll("]\napproved-commands = [\n");
        for (project.commands) |command| {
            try writer.interface.writeAll("  ");
            try writeTomlString(&writer.interface, command);
            try writer.interface.writeAll(",\n");
        }
        try writer.interface.writeAll("]\n");
    }
    try writer.interface.flush();
}

fn parseApprovedCommands(allocator: std.mem.Allocator, buffer: []const u8, project_id: []const u8) ![]const []const u8 {
    const projects = try parseApprovalProjects(allocator, buffer);
    defer freeProjects(allocator, projects);

    for (projects) |project| {
        if (!std.mem.eql(u8, project.id, project_id)) continue;
        return dupeCommands(allocator, project.commands);
    }

    return parseLegacyApprovedCommands(allocator, buffer);
}

fn loadProjectsFromPath(allocator: std.mem.Allocator, path: []const u8) ![]ProjectState {
    const buffer = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(ProjectState, 0),
        else => return err,
    };
    defer allocator.free(buffer);
    return parseApprovalProjects(allocator, buffer);
}

fn parseApprovalProjects(allocator: std.mem.Allocator, buffer: []const u8) ![]ProjectState {
    var projects = std.ArrayList(ProjectState).empty;
    errdefer {
        freeProjects(allocator, projects.items);
        projects.deinit(allocator);
    }

    var current_project: ?usize = null;
    var in_array = false;
    var lines = std.mem.splitScalar(u8, buffer, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "[") and std.mem.endsWith(u8, line, "]")) {
            in_array = false;
            current_project = null;
            const id = try parseProjectHeader(allocator, line);
            if (id) |project_id| {
                errdefer allocator.free(project_id);
                try projects.append(allocator, .{
                    .id = project_id,
                    .commands = &.{},
                });
                current_project = projects.items.len - 1;
            }
            continue;
        }

        const project_index = current_project orelse continue;
        if (!in_array) {
            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            if (!isApprovedCommandsKey(key)) continue;

            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
            if (value.len == 0 or value[0] != '[') continue;
            try appendQuotedStringsToProject(allocator, &projects.items[project_index], value);
            in_array = std.mem.indexOfScalar(u8, value, ']') == null;
            continue;
        }

        try appendQuotedStringsToProject(allocator, &projects.items[project_index], line);
        if (std.mem.indexOfScalar(u8, line, ']') != null) in_array = false;
    }

    return projects.toOwnedSlice(allocator);
}

fn parseLegacyApprovedCommands(allocator: std.mem.Allocator, buffer: []const u8) ![]const []const u8 {
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
            if (!isApprovedCommandsKey(key)) continue;

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

fn parseProjectHeader(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const inner = line[1 .. line.len - 1];
    if (!std.mem.startsWith(u8, inner, "projects.")) return null;

    const raw = inner["projects.".len..];
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        const parsed = try parseTomlStringAt(allocator, raw, 0);
        return parsed.value;
    }
    const id = try allocator.dupe(u8, raw);
    return @as(?[]const u8, id);
}

fn isApprovedCommandsKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "approved_commands") or
        std.mem.eql(u8, key, "approved-commands");
}

fn appendQuotedStringsToProject(
    allocator: std.mem.Allocator,
    project: *ProjectState,
    line: []const u8,
) !void {
    const old = project.commands;
    var commands = std.ArrayList([]const u8).empty;
    defer commands.deinit(allocator);
    try commands.appendSlice(allocator, project.commands);
    try appendQuotedStrings(allocator, &commands, line);
    project.commands = try commands.toOwnedSlice(allocator);
    allocator.free(old);
}

fn dupeCommands(allocator: std.mem.Allocator, commands: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |command| allocator.free(command);
        out.deinit(allocator);
    }
    for (commands) |command| {
        try out.append(allocator, try allocator.dupe(u8, command));
    }
    return out.toOwnedSlice(allocator);
}

fn freeProjects(allocator: std.mem.Allocator, projects: []const ProjectState) void {
    for (projects) |project| {
        allocator.free(project.id);
        for (project.commands) |command| allocator.free(command);
        allocator.free(project.commands);
    }
    allocator.free(projects);
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
        "repo",
    );
    defer {
        for (parsed) |command| allocator.free(command);
        allocator.free(parsed);
    }

    try std.testing.expectEqual(2, parsed.len);
    try std.testing.expectEqualStrings("echo one", parsed[0]);
    try std.testing.expectEqualStrings("echo two", parsed[1]);
}

test "parseApprovedCommands reads project scoped approvals first" {
    const allocator = std.testing.allocator;
    const parsed = try parseApprovedCommands(
        allocator,
        "[projects.\"github.com/acme/repo\"]\napproved-commands = [\"npm test\"]\n\n[projects.other]\napproved-commands = [\"cargo test\"]\n",
        "github.com/acme/repo",
    );
    defer {
        for (parsed) |command| allocator.free(command);
        allocator.free(parsed);
    }

    try std.testing.expectEqual(1, parsed.len);
    try std.testing.expectEqualStrings("npm test", parsed[0]);
}

test "parseRemoteProjectId normalizes common remote formats" {
    const allocator = std.testing.allocator;

    const https = (try parseRemoteProjectId(allocator, "https://github.com/acme/repo.git")).?;
    defer allocator.free(https);
    try std.testing.expectEqualStrings("github.com/acme/repo", https);

    const ssh = (try parseRemoteProjectId(allocator, "git@gitlab.com:team/sub/repo.git")).?;
    defer allocator.free(ssh);
    try std.testing.expectEqualStrings("gitlab.com/team/sub/repo", ssh);
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
