const std = @import("std");

pub const Format = enum {
    text,
    json,
};

var current_format: Format = .text;

pub fn setFormat(format: Format) void {
    current_format = format;
}

pub fn getFormat() Format {
    return current_format;
}

pub fn isJson() bool {
    return current_format == .json;
}

pub fn parseFormat(raw: []const u8) !Format {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "text")) return .text;
    if (std.ascii.eqlIgnoreCase(trimmed, "json")) return .json;
    return error.UnsupportedFormat;
}

pub fn emitSuccess(
    allocator: std.mem.Allocator,
    stdout: anytype,
    command: []const u8,
    data: anytype,
) !void {
    if (!isJson()) return;
    const json_value = try std.json.Stringify.valueAlloc(allocator, data, .{ .emit_null_optional_fields = false });
    defer allocator.free(json_value);
    try stdout.writeAll("{\"ok\":true,\"command\":");
    try writeQuoted(stdout, command);
    try stdout.writeAll(",\"data\":");
    try stdout.writeAll(json_value);
    try stdout.writeAll("}\n");
}

pub fn emitError(stdout: anytype, command: []const u8, message: []const u8) !void {
    if (!isJson()) return;
    try stdout.writeAll("{\"ok\":false,\"command\":");
    try writeQuoted(stdout, command);
    try stdout.writeAll(",\"error\":");
    try writeQuoted(stdout, message);
    try stdout.writeAll("}\n");
}

pub fn usageError(stdout: anytype, stderr: anytype, command: []const u8, message: []const u8) !u8 {
    if (isJson()) {
        try emitError(stdout, command, message);
    } else {
        try stderr.print("{s}\n", .{message});
    }
    return 1;
}

pub fn commandHelp(
    allocator: std.mem.Allocator,
    stdout: anytype,
    command: []const u8,
    help_text: []const u8,
) !void {
    if (!isJson()) {
        try stdout.writeAll(help_text);
        return;
    }
    try emitSuccess(allocator, stdout, command, .{ .help = help_text });
}

fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (ch < 0x20) {
                try writer.print("\\u{x:0>4}", .{@as(u16, ch)});
            } else {
                try writer.writeByte(ch);
            }
        },
    };
    try writer.writeByte('"');
}

test "parseFormat accepts text and json" {
    try std.testing.expectEqual(Format.text, try parseFormat("text"));
    try std.testing.expectEqual(Format.json, try parseFormat("JSON"));
    try std.testing.expectError(error.UnsupportedFormat, parseFormat("yaml"));
}

test "emitSuccess writes json envelope" {
    const allocator = std.testing.allocator;
    setFormat(.json);
    defer setFormat(.text);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try emitSuccess(allocator, &writer, "wt version", .{ .version = "1.2.3" });
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"command\":\"wt version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"version\":\"1.2.3\"") != null);
}
