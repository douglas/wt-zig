const std = @import("std");

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("Usage: wt shellenv\n");
        return 1;
    }

    try stdout.writeAll(
        \\wt() {
        \\    local output exit_code cd_path
        \\
        \\    output=$(command wt "$@")
        \\    exit_code=$?
        \\    printf '%s\n' "$output"
        \\    cd_path=$(printf '%s\n' "$output" | awk '/^wt navigating to: / { path = substr($0, 18) } END { print path }')
        \\    if [ "$exit_code" -eq 0 ] && [ -n "$cd_path" ]; then
        \\        cd "$cd_path"
        \\    fi
        \\    return "$exit_code"
        \\}
        \\
    );

    return 0;
}
