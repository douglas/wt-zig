const std = @import("std");

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn ensureDir(allocator: std.mem.Allocator, pathname: []const u8) !void {
    if (!std.fs.path.isAbsolute(pathname)) {
        return std.fs.cwd().makePath(pathname);
    }

    if (pathname.len == 0 or std.mem.eql(u8, pathname, "/")) return;

    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);
    try current.append(allocator, std.fs.path.sep);

    var parts = std.mem.splitScalar(u8, pathname[1..], std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (current.items.len > 1) {
            try current.append(allocator, std.fs.path.sep);
        }
        try current.appendSlice(allocator, part);
        std.fs.makeDirAbsolute(current.items) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

pub fn ensureParentDir(allocator: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDir(allocator, parent);
}

pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    try ensureParentDir(allocator, path);

    if (!std.fs.path.isAbsolute(path)) {
        return std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
