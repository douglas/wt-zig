const output = @import("../output.zig");
const std = @import("std");
const config = @import("../config.zig");
const pr = @import("pr.zig");
const pr_git = @import("../git/pr.zig");

pub fn run(
    ctx: output.Context,
    cfg: *const config.Resolved,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    return pr.runRemoteCommand(ctx, cfg, args, stdout, stderr, pr_git.RemoteType.gitlab);
}
