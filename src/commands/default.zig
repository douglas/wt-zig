const std = @import("std");
const git_repo = @import("../git/repo.zig");
const output = @import("../output.zig");

pub fn run(ctx: output.Context, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt default", "Usage: wt default");
    }

    var info = try git_repo.getRepoInfo(ctx.allocator);
    defer git_repo.freeRepoInfo(ctx.allocator, &info);

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt default", .{
            .path = info.main,
            .navigate_to = info.main,
        });
        return 0;
    }

    try stdout.writeAll("Navigating to main worktree: ");
    try stdout.writeAll(info.main);
    try stdout.writeByte('\n');
    try output.emitNavigateTo(stdout, info.main);
    return 0;
}

test "default rejects extra args" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [1024]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [1024]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(
        .{ .allocator = allocator, .format = .text },
        &.{"extra"},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(1, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "Usage: wt default") != null);
}
