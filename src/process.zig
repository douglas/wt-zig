const std = @import("std");

pub const Captured = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn succeeded(self: Captured) bool {
        return switch (self.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    pub fn trimmedStdout(self: Captured) []const u8 {
        return std.mem.trim(u8, self.stdout, " \r\n\t");
    }

    pub fn trimmedStderr(self: Captured) []const u8 {
        return std.mem.trim(u8, self.stderr, " \r\n\t");
    }
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !Captured {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });

    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn quietSuccess(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    var result = try run(allocator, argv);
    defer result.deinit(allocator);
    return result.succeeded();
}

test "quietSuccess reports exit code status" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try quietSuccess(allocator, &.{ "sh", "-c", "exit 0" }));
    try std.testing.expect(!(try quietSuccess(allocator, &.{ "sh", "-c", "exit 3" })));
}

test "trimmed output helpers remove surrounding whitespace" {
    var captured = Captured{
        .term = .{ .Exited = 0 },
        .stdout = try std.testing.allocator.dupe(u8, "  hello\n"),
        .stderr = try std.testing.allocator.dupe(u8, "\nnope \t"),
    };
    defer captured.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", captured.trimmedStdout());
    try std.testing.expectEqualStrings("nope", captured.trimmedStderr());
}
