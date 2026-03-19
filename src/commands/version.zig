const std = @import("std");
const build_options = @import("build_options");

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("Usage: wt version\n");
        return 1;
    }

    try stdout.print("wt version {s}\n", .{build_options.version});
    return 0;
}
