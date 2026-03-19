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
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("config_support.zig"));
    std.testing.refAllDecls(@import("config_types.zig"));
    std.testing.refAllDecls(@import("fs.zig"));
    std.testing.refAllDecls(@import("hooks.zig"));
    std.testing.refAllDecls(@import("output.zig"));
    std.testing.refAllDecls(@import("path.zig"));
    std.testing.refAllDecls(@import("process.zig"));
    std.testing.refAllDecls(@import("prompt.zig"));
    std.testing.refAllDecls(@import("commands/config.zig"));
    std.testing.refAllDecls(@import("commands/checkout.zig"));
    std.testing.refAllDecls(@import("commands/create.zig"));
    std.testing.refAllDecls(@import("commands/info.zig"));
    std.testing.refAllDecls(@import("commands/init.zig"));
    std.testing.refAllDecls(@import("commands/init_support.zig"));
    std.testing.refAllDecls(@import("commands/migrate.zig"));
    std.testing.refAllDecls(@import("commands/migrate_support.zig"));
    std.testing.refAllDecls(@import("commands/remove.zig"));
    std.testing.refAllDecls(@import("commands/cleanup.zig"));
    std.testing.refAllDecls(@import("commands/prune.zig"));
    std.testing.refAllDecls(@import("git/pr.zig"));
    std.testing.refAllDecls(@import("git/repo.zig"));
    std.testing.refAllDecls(@import("git/worktree.zig"));
}
