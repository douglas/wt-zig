const std = @import("std");
const command = @import("command.zig");
const config = @import("config.zig");
const config_cmd = @import("commands/config.zig");
const checkout_cmd = @import("commands/checkout.zig");
const create_cmd = @import("commands/create.zig");
const help_cmd = @import("commands/help.zig");
const list_cmd = @import("commands/list.zig");
const version_cmd = @import("commands/version.zig");

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const raw_args = if (argv.len > 1) argv[1..] else &.{};
    const parsed = parseRootArgs(raw_args) catch |err| {
        switch (err) {
            error.MissingConfigPath => try stderr.writeAll("Missing value for --config\n"),
        }
        return 1;
    };
    const args = parsed.positional;

    if (parsed.root_help or args.len == 0 or isHelpFlag(args[0])) {
        try help_cmd.printRoot(stdout);
        return 0;
    }

    var loaded_config = try config.load(allocator, .{ .cli_config_path = parsed.cli_config_path });
    defer loaded_config.deinit();

    if (std.mem.eql(u8, args[0], "help")) {
        return help_cmd.run(args[1..], stdout, stderr);
    }

    const spec = command.find(args[0]) orelse {
        try stderr.print("Unknown command: {s}\n\n", .{args[0]});
        try help_cmd.printRoot(stderr);
        return 1;
    };

    if (args.len > 1 and isHelpFlag(args[1])) {
        try help_cmd.printCommand(spec, stdout);
        return 0;
    }

    return switch (spec.kind) {
        .help => help_cmd.run(args[1..], stdout, stderr),
        .version => version_cmd.run(args[1..], stdout, stderr),
        .list => list_cmd.run(allocator, args[1..], stdout, stderr),
        .config => config_cmd.run(args[1..], &loaded_config.resolved, stdout, stderr),
        .checkout => checkout_cmd.run(allocator, &loaded_config.resolved, args[1..], stdout, stderr),
        .create => create_cmd.run(allocator, &loaded_config.resolved, args[1..], stdout, stderr),
    };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

const ParsedRootArgs = struct {
    cli_config_path: ?[]const u8,
    positional: []const []const u8,
    root_help: bool,
};

fn parseRootArgs(args: []const []const u8) !ParsedRootArgs {
    var index: usize = 0;
    var cli_config_path: ?[]const u8 = null;
    var root_help = false;

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

        break;
    }

    return .{
        .cli_config_path = cli_config_path,
        .positional = args[index..],
        .root_help = root_help,
    };
}

test "parseRootArgs handles config flag and command" {
    const parsed = try parseRootArgs(&.{ "--config", "/tmp/wt.toml", "config", "show" });
    try std.testing.expectEqualStrings("/tmp/wt.toml", parsed.cli_config_path.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.positional.len);
    try std.testing.expectEqualStrings("config", parsed.positional[0]);
}
