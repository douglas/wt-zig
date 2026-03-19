const std = @import("std");
const config = @import("../config.zig");
const path = @import("../path.zig");

pub fn run(args: []const []const u8, cfg: *const config.Resolved, stdout: anytype, stderr: anytype) !u8 {
    if (args.len == 0) {
        try printHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 1) {
            try stderr.writeAll("Usage: wt config show\n");
            return 1;
        }
        try printShow(cfg, stdout);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "path")) {
        if (args.len != 1) {
            try stderr.writeAll("Usage: wt config path\n");
            return 1;
        }
        try stdout.print("{s}\n", .{cfg.config_file_path});
        return 0;
    }

    if (std.mem.eql(u8, args[0], "init")) {
        if (args.len != 1) {
            try stderr.writeAll("Usage: wt config init\n");
            return 1;
        }

        config.writeDefaultConfig(cfg.config_file_path) catch |err| switch (err) {
            error.ConfigFileAlreadyExists => {
                try stderr.print("config file already exists: {s}\n", .{cfg.config_file_path});
                return 1;
            },
            else => return err,
        };

        try stdout.print("Created config file: {s}\n", .{cfg.config_file_path});
        return 0;
    }

    try stderr.print("Unknown config command: {s}\n\n", .{args[0]});
    try printHelp(stderr);
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
