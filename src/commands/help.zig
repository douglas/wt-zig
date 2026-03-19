const std = @import("std");
const command = @import("../command.zig");

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len == 0) {
        try printRoot(stdout);
        return 0;
    }

    if (args.len > 1) {
        try stderr.writeAll("Usage: wt help [command]\n");
        return 1;
    }

    const spec = command.find(args[0]) orelse {
        try stderr.print("Unknown command: {s}\n", .{args[0]});
        return 1;
    };

    try printCommand(spec, stdout);
    return 0;
}

pub fn printRoot(writer: anytype) !void {
    try writer.writeAll(
        \\wt manages Git worktrees with a small Zig-native CLI.
        \\
        \\Usage:
        \\  wt <command> [options]
        \\
        \\Commands:
        \\
    );

    for (command.all) |spec| {
        try writer.print("  {s}\n      {s}\n", .{ spec.display, spec.summary });
    }

    try writer.writeAll(
        \\
        \\Options:
        \\  -h, --help
        \\      Show help for wt or a specific command
        \\  --config <path>
        \\      Load configuration from a specific TOML file
        \\
        \\Current phases include config loading, path resolution, checkout/create,
        \\hooks, remove/prune/cleanup/migrate, PR/MR checkout, shellenv, and init support.
        \\
        \\Run `wt help <command>` for command-specific usage.
        \\
    );
}

pub fn printCommand(spec: *const command.Spec, writer: anytype) !void {
    try writer.print(
        \\{s}
        \\
        \\Usage:
        \\  {s}
        \\
        \\Details:
        \\  {s}
        \\
    ,
        .{ spec.summary, spec.usage, spec.details },
    );

    if (spec.aliases.len > 0) {
        try writer.writeAll("Aliases:\n");
        for (spec.aliases) |alias| {
            try writer.print("  {s}\n", .{alias});
        }
        try writer.writeByte('\n');
    }
}
