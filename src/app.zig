const std = @import("std");
const command = @import("command.zig");
const help_cmd = @import("commands/help.zig");
const list_cmd = @import("commands/list.zig");
const version_cmd = @import("commands/version.zig");

pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const args = if (argv.len > 1) argv[1..] else &.{};

    if (args.len == 0 or isHelpFlag(args[0])) {
        try help_cmd.printRoot(stdout);
        return 0;
    }

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
    };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}
