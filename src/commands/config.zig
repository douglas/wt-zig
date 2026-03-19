const std = @import("std");
const config = @import("../config.zig");
const output = @import("../output.zig");
const path = @import("../path.zig");

pub fn run(args: []const []const u8, cfg: *const config.Resolved, stdout: anytype, stderr: anytype) !u8 {
    if (args.len == 0) {
        try printHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 1) {
            return output.usageError(stdout, stderr, "wt config show", "Usage: wt config show");
        }
        if (output.isJson()) {
            try printShowJson(std.heap.page_allocator, cfg, stdout);
        } else {
            try printShow(cfg, stdout);
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "path")) {
        if (args.len != 1) {
            return output.usageError(stdout, stderr, "wt config path", "Usage: wt config path");
        }
        if (output.isJson()) {
            try output.emitSuccess(std.heap.page_allocator, stdout, "wt config path", .{ .path = cfg.config_file_path });
        } else {
            try stdout.print("{s}\n", .{cfg.config_file_path});
        }
        return 0;
    }

    if (std.mem.eql(u8, args[0], "init")) {
        const force = parseInitForce(args[1..]) catch {
            return output.usageError(stdout, stderr, "wt config init", "Usage: wt config init [--force]");
        };

        config.writeDefaultConfig(cfg.config_file_path, force) catch |err| switch (err) {
            error.ConfigFileAlreadyExists => {
                if (output.isJson()) {
                    const message = try std.fmt.allocPrint(std.heap.page_allocator, "config file already exists: {s}", .{cfg.config_file_path});
                    defer std.heap.page_allocator.free(message);
                    try output.emitError(stdout, "wt config init", message);
                } else {
                    try stderr.print("config file already exists: {s}\n", .{cfg.config_file_path});
                }
                return 1;
            },
            else => return err,
        };

        if (output.isJson()) {
            try output.emitSuccess(std.heap.page_allocator, stdout, "wt config init", .{
                .path = cfg.config_file_path,
                .status = "created",
            });
        } else {
            try stdout.print("Created config file: {s}\n", .{cfg.config_file_path});
        }
        return 0;
    }

    if (output.isJson()) {
        const message = try std.fmt.allocPrint(std.heap.page_allocator, "Unknown config command: {s}", .{args[0]});
        defer std.heap.page_allocator.free(message);
        try output.emitError(stdout, "wt config", message);
    } else {
        try stderr.print("Unknown config command: {s}\n\n", .{args[0]});
        try printHelp(stderr);
    }
    return 1;
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Manage wt configuration.
        \\
        \\Usage:
        \\  wt config <command>
        \\
        \\Commands:
        \\  init
        \\      Create a starter config file at the resolved config path
        \\  show
        \\      Print the effective configuration and its sources
        \\  path
        \\      Print the resolved config file path
        \\
    );
}

pub fn printShow(cfg: *const config.Resolved, writer: anytype) !void {
    const config_status = if (cfg.config_file_found) "found" else "not found";
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "(none)";
    const pattern_source = if (pattern_info) |info| info.source else cfg.sources.pattern;

    try writer.print(
        \\Config file: {s} ({s})
        \\
        \\Effective configuration:
        \\  root = {s} ({s})
        \\  strategy = {s} ({s})
        \\  pattern = {s} ({s})
        \\  separator = "{s}" ({s})
        \\
    ,
        .{
            cfg.config_file_path,
            config_status,
            cfg.root,
            cfg.sources.root,
            cfg.strategy,
            cfg.sources.strategy,
            pattern,
            pattern_source,
            cfg.separator,
            cfg.sources.separator,
        },
    );
}

fn printShowJson(allocator: std.mem.Allocator, cfg: *const config.Resolved, stdout: anytype) !void {
    const pattern_info = path.resolvePattern(cfg) catch null;
    const pattern = if (pattern_info) |info| info.pattern else "(none)";
    const pattern_source = if (pattern_info) |info| info.source else cfg.sources.pattern;

    try output.emitSuccess(allocator, stdout, "wt config show", .{
        .config_file = .{
            .path = cfg.config_file_path,
            .status = if (cfg.config_file_found) "found" else "not found",
        },
        .effective = .{
            .root = .{ .value = cfg.root, .source = cfg.sources.root },
            .strategy = .{ .value = cfg.strategy, .source = cfg.sources.strategy },
            .pattern = .{ .value = pattern, .source = pattern_source },
            .separator = .{ .value = cfg.separator, .source = cfg.sources.separator },
        },
    });
}

fn parseInitForce(args: []const []const u8) !bool {
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
            continue;
        }

        return error.InvalidArguments;
    }

    return force;
}
