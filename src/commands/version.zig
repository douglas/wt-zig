const std = @import("std");
const build_options = @import("build_options");
const output = @import("../output.zig");

pub fn run(ctx: output.Context, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt version", "Usage: wt version");
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt version", .{ .version = build_options.version });
    } else {
        try stdout.print("wt version {s}\n", .{build_options.version});
    }
    return 0;
}
