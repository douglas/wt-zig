const std = @import("std");
const app = @import("app.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout = std.fs.File.stdout().deprecatedWriter();
    var stderr = std.fs.File.stderr().deprecatedWriter();

    const exit_code = try app.run(allocator, argv, &stdout, &stderr);
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

test {
    std.testing.refAllDecls(@import("app.zig"));
    std.testing.refAllDecls(@import("command.zig"));
    std.testing.refAllDecls(@import("git/worktree.zig"));
}
