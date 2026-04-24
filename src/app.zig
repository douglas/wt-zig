const std = @import("std");
const command = @import("command.zig");
const config = @import("config.zig");
const output = @import("output.zig");
const cleanup_cmd = @import("commands/cleanup.zig");
const completion_cmd = @import("commands/completion.zig");
const config_cmd = @import("commands/config.zig");
const default_cmd = @import("commands/default.zig");
const done_cmd = @import("commands/done.zig");
const checkout_cmd = @import("commands/checkout.zig");
const create_cmd = @import("commands/create.zig");
const examples_cmd = @import("commands/examples.zig");
const help_cmd = @import("commands/help.zig");
const info_cmd = @import("commands/info.zig");
const init_cmd = @import("commands/init.zig");
const list_cmd = @import("commands/list.zig");
const migrate_cmd = @import("commands/migrate.zig");
const mr_cmd = @import("commands/mr.zig");
const pr_cmd = @import("commands/pr.zig");
const prune_cmd = @import("commands/prune.zig");
const remove_cmd = @import("commands/remove.zig");
const shellenv_cmd = @import("commands/shellenv.zig");
const status_cmd = @import("commands/status.zig");
const version_cmd = @import("commands/version.zig");
const jump_cmd = @import("commands/jump.zig");
const ui_cmd = @import("commands/ui.zig");

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const raw_args = if (argv.len > 1) argv[1..] else &.{};
    var parsed = parseRootArgs(allocator, raw_args) catch |err| {
        switch (err) {
            error.MissingConfigPath => try stderr.writeAll("Missing value for --config\n"),
            error.MissingFormatValue => try stderr.writeAll("Missing value for --format\n"),
            error.UnsupportedFormatValue => try stderr.writeAll("unsupported --format value (supported: text, json)\n"),
            error.OutOfMemory => return err,
        }
        return 1;
    };
    defer parsed.deinit(allocator);
    const ctx = output.Context{
        .allocator = allocator,
        .format = parsed.output_format,
    };
    const args = parsed.positional;

    var loaded_config = try config.load(allocator, .{ .cli_config_path = parsed.cli_config_path });
    defer loaded_config.deinit();

    if (parsed.root_help or args.len == 0 or isHelpFlag(args[0])) {
        try help_cmd.printRoot(ctx, &loaded_config.resolved, stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "help")) {
        return help_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr);
    }

    const spec = command.find(args[0]) orelse {
        if (output.isJson(ctx)) {
            try stderr.print("unknown command \"{s}\" for \"wt\"\n", .{args[0]});
        } else {
            try stderr.print("Unknown command: {s}\n\n", .{args[0]});
            try help_cmd.printRoot(ctx, &loaded_config.resolved, stderr);
        }
        return 1;
    };

    if (args.len > 1 and isHelpFlag(args[1])) {
        try help_cmd.printCommand(ctx, spec, stdout);
        return 0;
    }

    return switch (spec.kind) {
        .help => help_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .version => version_cmd.run(ctx, args[1..], stdout, stderr),
        .list => list_cmd.run(ctx, args[1..], stdout, stderr),
        .status => status_cmd.run(ctx, args[1..], stdout, stderr),
        .default => default_cmd.run(ctx, args[1..], stdout, stderr),
        .config => config_cmd.run(ctx, args[1..], &loaded_config.resolved, stdout, stderr),
        .completion => completion_cmd.run(ctx, args[1..], stdout, stderr),
        .checkout => checkout_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .create => create_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .info => info_cmd.run(ctx, &loaded_config.resolved, stdout, stderr),
        .remove => remove_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .done => done_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .prune => prune_cmd.run(ctx, args[1..], stdout, stderr),
        .cleanup => cleanup_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .migrate => migrate_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .pr => pr_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .mr => mr_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
        .examples => examples_cmd.run(ctx, args[1..], stdout, stderr),
        .shellenv => shellenv_cmd.run(ctx, args[1..], stdout, stderr),
        .init => init_cmd.run(ctx, args[1..], stdout, stderr),
        .jump => jump_cmd.run(ctx, args[1..], stdout, stderr),
        .ui => ui_cmd.run(ctx, &loaded_config.resolved, args[1..], stdout, stderr),
    };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

const ParsedRootArgs = struct {
    cli_config_path: ?[]const u8,
    output_format: output.Format,
    positional: []const []const u8,
    root_help: bool,

    pub fn deinit(self: *ParsedRootArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positional);
    }
};

fn parseRootArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedRootArgs {
    var cli_config_path: ?[]const u8 = null;
    var output_format: output.Format = .text;
    var root_help = false;
    var positional: std.ArrayList([]const u8) = .empty;
    errdefer positional.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            root_help = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigPath;
            cli_config_path = args[index];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--config=")) {
            cli_config_path = arg["--config=".len..];
            continue;
        }

        if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return error.MissingFormatValue;
            output_format = output.parseFormat(args[index]) catch return error.UnsupportedFormatValue;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--format=")) {
            output_format = output.parseFormat(arg["--format=".len..]) catch return error.UnsupportedFormatValue;
            continue;
        }

        try positional.append(allocator, arg);
    }

    return .{
        .cli_config_path = cli_config_path,
        .output_format = output_format,
        .positional = try positional.toOwnedSlice(allocator),
        .root_help = root_help,
    };
}

test "parseRootArgs handles config flag and command" {
    var parsed = try parseRootArgs(std.testing.allocator, &.{ "--config", "/tmp/wt.toml", "config", "show" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/wt.toml", parsed.cli_config_path.?);
    try std.testing.expectEqual(2, parsed.positional.len);
    try std.testing.expectEqualStrings("config", parsed.positional[0]);
}

test "parseRootArgs handles format anywhere" {
    var parsed = try parseRootArgs(std.testing.allocator, &.{ "help", "--format", "json" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(output.Format.json, parsed.output_format);
    try std.testing.expectEqualStrings("help", parsed.positional[0]);
}

test "parseRootArgs rejects missing format value" {
    try std.testing.expectError(error.MissingFormatValue, parseRootArgs(std.testing.allocator, &.{"--format"}));
}

test "parseRootArgs rejects unsupported format value" {
    try std.testing.expectError(error.UnsupportedFormatValue, parseRootArgs(std.testing.allocator, &.{ "--format", "yaml" }));
}
