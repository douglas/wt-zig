const std = @import("std");

pub const Format = enum {
    text,
    json,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    format: Format,
};

pub fn isJson(ctx: Context) bool {
    return ctx.format == .json;
}

pub fn parseFormat(raw: []const u8) !Format {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "text")) return .text;
    if (std.ascii.eqlIgnoreCase(trimmed, "json")) return .json;
    return error.UnsupportedFormat;
}

pub fn emitSuccess(
    ctx: Context,
    stdout: *std.Io.Writer,
    command: []const u8,
    data: anytype,
) !void {
    if (!isJson(ctx)) return;
    const json_value = try std.json.Stringify.valueAlloc(ctx.allocator, data, .{ .emit_null_optional_fields = false });
    defer ctx.allocator.free(json_value);
    try stdout.writeAll("{\"ok\":true,\"command\":");
    try writeQuoted(stdout, command);
    try stdout.writeAll(",\"data\":");
    try stdout.writeAll(json_value);
    try stdout.writeAll("}\n");
}

pub fn emitError(ctx: Context, stdout: *std.Io.Writer, command: []const u8, message: []const u8) !void {
    if (!isJson(ctx)) return;
    try stdout.writeAll("{\"ok\":false,\"command\":");
    try writeQuoted(stdout, command);
    try stdout.writeAll(",\"error\":");
    try writeQuoted(stdout, message);
    try stdout.writeAll("}\n");
}

pub fn usageError(ctx: Context, stdout: *std.Io.Writer, stderr: *std.Io.Writer, command: []const u8, message: []const u8) !u8 {
    if (isJson(ctx)) {
        try emitError(ctx, stdout, command, message);
    } else {
        try stderr.print("{s}\n", .{message});
    }
    return 1;
}

pub fn commandHelp(
    ctx: Context,
    stdout: *std.Io.Writer,
    command: []const u8,
    help_text: []const u8,
) !void {
    if (!isJson(ctx)) {
        try stdout.writeAll(help_text);
        return;
    }
    try emitSuccess(ctx, stdout, command, .{ .help = help_text });
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) !void {
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
    const ctx = Context{
        .allocator = allocator,
        .format = .json,
    };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try emitSuccess(ctx, &adapted.new_interface, "wt version", .{ .version = "1.2.3" });
    try adapted.new_interface.flush();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"command\":\"wt version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"version\":\"1.2.3\"") != null);
}
