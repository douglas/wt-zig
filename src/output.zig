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
    try stdout.writeAll("{\"ok\":true,\"command\":");
    try writeQuoted(stdout, command);
    try stdout.writeAll(",\"data\":");
    try writeJson(stdout, data);
    try stdout.writeAll("}\n");
}

pub fn emitNavigateTo(stdout: *std.Io.Writer, path: []const u8) !void {
    try writeDirectiveFile(&.{ "WT_DIRECTIVE_CD_FILE", "WORKTRUNK_DIRECTIVE_CD_FILE" }, path);
    try stdout.writeAll("wt navigating to: ");
    try stdout.writeAll(path);
    try stdout.writeByte('\n');
}

pub fn emitExecute(command: []const u8) !bool {
    const path = directiveFilePath(&.{ "WT_DIRECTIVE_EXEC_FILE", "WORKTRUNK_DIRECTIVE_EXEC_FILE" }) orelse return false;
    try appendLine(path, command);
    return true;
}

fn writeDirectiveFile(env_names: []const []const u8, value: []const u8) !void {
    const path = directiveFilePath(env_names) orelse return;
    try writeFile(path, value);
}

fn directiveFilePath(env_names: []const []const u8) ?[]const u8 {
    for (env_names) |name| {
        if (std.posix.getenv(name)) |path| {
            if (path.len > 0) return path;
        }
    }
    return null;
}

fn writeFile(path: []const u8, value: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(value);
    try file.writeAll("\n");
}

fn appendLine(path: []const u8, value: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(value);
    try file.writeAll("\n");
}

fn isStringLike(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    if (info.pointer.size == .slice) return info.pointer.child == u8;
    if (info.pointer.size != .one) return false;
    const child = @typeInfo(info.pointer.child);
    if (child != .array) return false;
    return child.array.child == u8;
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime isStringLike(T)) return writeQuoted(writer, value);

    switch (info) {
        .optional => {
            if (value) |v| return writeJson(writer, v) else return writer.writeAll("null");
        },
        .bool => return writer.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return writer.print("{d}", .{value}),
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                try writer.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writeJson(writer, item);
                }
                return writer.writeByte(']');
            }
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                try writer.writeByte('[');
                inline for (s.fields, 0..) |f, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writeJson(writer, @field(value, f.name));
                }
                return writer.writeByte(']');
            }
            try writer.writeByte('{');
            var first = true;
            inline for (s.fields) |f| {
                const skip = comptime @typeInfo(f.type) == .optional;
                if (!skip or @field(value, f.name) != null) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeQuoted(writer, f.name);
                    try writer.writeByte(':');
                    try writeJson(writer, @field(value, f.name));
                }
            }
            return writer.writeByte('}');
        },
        .array => {
            try writer.writeByte('[');
            for (value, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJson(writer, item);
            }
            return writer.writeByte(']');
        },
        else => return writer.writeAll("null"),
    }
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
        try stderr.writeAll(message);
        try stderr.writeByte('\n');
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

fn expectJson(buffer: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, buffer, needle) != null);
}

test "emitSuccess writes json envelope" {
    const allocator = std.testing.allocator;
    const ctx = Context{ .allocator = allocator, .format = .json };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try emitSuccess(ctx, &adapted.new_interface, "wt version", .{ .version = "1.2.3" });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "\"ok\":true");
    try expectJson(buffer.items, "\"command\":\"wt version\"");
    try expectJson(buffer.items, "\"version\":\"1.2.3\"");
}

test "writeJson skips null optional struct fields" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try writeJson(&adapted.new_interface, .{ .name = "a", .value = @as(?[]const u8, null) });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"name\":\"a\"}");
}

test "writeJson handles nested structs" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try writeJson(&adapted.new_interface, .{ .outer = .{ .inner = "v" } });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"outer\":{\"inner\":\"v\"}}");
}

test "writeJson handles bool and int fields" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try writeJson(&adapted.new_interface, .{ .ok = true, .count = @as(u32, 42) });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"ok\":true,\"count\":42}");
}

test "writeJson handles slices of structs" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    const Item = struct { name: []const u8 };
    const items = [_]Item{ .{ .name = "a" }, .{ .name = "b" } };
    try writeJson(&adapted.new_interface, .{ .items = @as([]const Item, &items) });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"items\":[{\"name\":\"a\"},{\"name\":\"b\"}]}");
}

test "writeJson handles tuples" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    try writeJson(&adapted.new_interface, .{ .notes = .{ "first", "second" } });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"notes\":[\"first\",\"second\"]}");
}

test "writeJson handles empty slices" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var al_writer = buffer.writer(allocator);
    var io_buf: [4096]u8 = undefined;
    var adapted = al_writer.adaptToNewApi(&io_buf);

    const empty: []const []const u8 = &.{};
    try writeJson(&adapted.new_interface, .{ .items = empty });
    try adapted.new_interface.flush();
    try expectJson(buffer.items, "{\"items\":[]}");
}
