const builtin = @import("builtin");
const std = @import("std");

pub const err_cancelled = error.SelectionCancelled;

pub fn selectItem(
    allocator: std.mem.Allocator,
    label: []const u8,
    items: []const []const u8,
    stderr: anytype,
) !struct { index: usize, value: []const u8 } {
    var tty = try openTty();
    defer if (tty.close_on_exit) tty.file.close();

    try stderr.print("{s}:\n", .{label});
    for (items, 0..) |item, index| {
        try stderr.print("  {d}) {s}\n", .{ index + 1, item });
    }
    try stderr.print("Enter number [1-{d}]: ", .{items.len});

    const line = try readLine(allocator, tty.file);
    defer allocator.free(line);
    if (line.len == 0) return err_cancelled;
    if (containsCancel(line)) return err_cancelled;

    const parsed = std.fmt.parseInt(usize, line, 10) catch return error.InvalidSelection;
    if (parsed == 0 or parsed > items.len) return error.InvalidSelection;

    return .{
        .index = parsed - 1,
        .value = items[parsed - 1],
    };
}

pub fn confirmPrompt(
    allocator: std.mem.Allocator,
    label: []const u8,
    stderr: anytype,
) !bool {
    var tty = try openTty();
    defer if (tty.close_on_exit) tty.file.close();

    try stderr.print("{s} [y/N]: ", .{label});
    const line = try readLine(allocator, tty.file);
    defer allocator.free(line);
    if (line.len == 0 or containsCancel(line)) return false;

    return line[0] == 'y' or line[0] == 'Y';
}

const TtyHandle = struct {
    file: std.fs.File,
    close_on_exit: bool,
};

fn openTty() !TtyHandle {
    if (useStdinFallback()) {
        return .{ .file = std.fs.File.stdin(), .close_on_exit = false };
    }

    if (builtin.os.tag != .windows) {
        const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch {
            return .{ .file = std.fs.File.stdin(), .close_on_exit = false };
        };
        return .{ .file = file, .close_on_exit = true };
    }

    return .{ .file = std.fs.File.stdin(), .close_on_exit = false };
}

fn readLine(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    if (builtin.os.tag != .windows) {
        return readLineRaw(allocator, file);
    }

    var buffer: [256]u8 = undefined;
    var reader = file.reader(&buffer);
    const maybe = try reader.interface.takeDelimiter('\n');
    const line = maybe orelse return allocator.dupe(u8, "");
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn readLineRaw(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const handle = file.handle;
    const old_state = std.posix.tcgetattr(handle) catch return readLineFallback(allocator, file);
    var raw = old_state;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.os.linux.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.os.linux.V.TIME)] = 0;
    std.posix.tcsetattr(handle, .FLUSH, raw) catch return readLineFallback(allocator, file);
    defer std.posix.tcsetattr(handle, .FLUSH, old_state) catch {};

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var byte: [1]u8 = undefined;
    const stderr = std.fs.File.stderr();

    while (true) {
        const read_len = file.read(&byte) catch return err_cancelled;
        if (read_len == 0) return err_cancelled;

        switch (byte[0]) {
            0x1b, 0x03 => return err_cancelled,
            '\r', '\n' => {
                try stderr.writeAll("\r\n");
                return bytes.toOwnedSlice(allocator);
            },
            0x7f => {
                if (bytes.items.len > 0) {
                    _ = bytes.pop();
                    try stderr.writeAll("\x08 \x08");
                }
            },
            '0'...'9' => {
                try bytes.append(allocator, byte[0]);
                try stderr.writeAll(&byte);
            },
            else => {},
        }
    }
}

fn readLineFallback(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var buffer: [256]u8 = undefined;
    var reader = file.reader(&buffer);
    const maybe = try reader.interface.takeDelimiter('\n');
    const line = maybe orelse return err_cancelled;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (containsCancel(trimmed)) return err_cancelled;
    return allocator.dupe(u8, trimmed);
}

fn useStdinFallback() bool {
    const value = std.posix.getenv("WT_USE_STDIN") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn containsCancel(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\x1b\x03") != null;
}

test "containsCancel recognizes ESC and ctrl-c bytes" {
    try std.testing.expect(containsCancel("\x1b"));
    try std.testing.expect(containsCancel("\x03"));
    try std.testing.expect(!containsCancel("12"));
}
