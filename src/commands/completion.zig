const std = @import("std");
const output = @import("../output.zig");

const command_words = "checkout co create default pr mr list ls remove rm done status cleanup migrate prune help shellenv init info config examples version jump j cd ui completion";

pub fn run(ctx: output.Context, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (args.len == 0) {
        try printHelp(ctx, stdout);
        return 0;
    }
    if (args.len != 1) {
        return output.usageError(ctx, stdout, stderr, "wt completion", "Usage: wt completion [bash|fish|powershell|zsh]");
    }

    if (std.mem.eql(u8, args[0], "bash")) {
        try stdout.writeAll(bashScript());
        return 0;
    }
    if (std.mem.eql(u8, args[0], "fish")) {
        try stdout.writeAll(fishScript());
        return 0;
    }
    if (std.mem.eql(u8, args[0], "powershell")) {
        try stdout.writeAll(powershellScript());
        return 0;
    }
    if (std.mem.eql(u8, args[0], "zsh")) {
        try stdout.writeAll(zshScript());
        return 0;
    }

    if (output.isJson(ctx)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "unknown completion shell: {s}", .{args[0]});
        defer ctx.allocator.free(message);
        try output.emitError(ctx, stdout, "wt completion", message);
    } else {
        try stderr.print("Unknown completion shell: {s}\n", .{args[0]});
    }
    return 1;
}

fn printHelp(ctx: output.Context, stdout: *std.Io.Writer) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.allocator);
    var writer = buffer.writer(ctx.allocator);

    try writer.writeAll(
        \\Generate the autocompletion script for wt for the specified shell.
        \\See each shell output for installation details.
        \\
        \\Usage:
        \\  wt completion [command]
        \\
        \\Available Commands:
        \\  bash        Generate the autocompletion script for bash
        \\  fish        Generate the autocompletion script for fish
        \\  powershell  Generate the autocompletion script for powershell
        \\  zsh         Generate the autocompletion script for zsh
        \\
    );

    try output.commandHelp(ctx, stdout, "wt completion", buffer.items);
}

fn bashScript() []const u8 {
    return 
    \\# bash completion for wt
    \\_wt_complete() {
    \\    local cur prev commands
    \\    COMPREPLY=()
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\    commands="
++ command_words ++
    \\"
    \\
    \\    if [ $COMP_CWORD -eq 1 ]; then
    \\        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\        return 0
    \\    fi
    \\
    \\    case "$prev" in
    \\        checkout|co|create)
    \\            local branches remotes
    \\            remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\            branches=$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)
    \\            COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        remove|rm)
    \\            local branches
    \\            branches=$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    \\            COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        config)
    \\            COMPREPLY=( $(compgen -W "init show path" -- "$cur") )
    \\            return 0
    \\            ;;
    \\    esac
    \\}
    \\complete -F _wt_complete wt
    \\
    ;
}

fn fishScript() []const u8 {
    return 
    \\# fish completion for wt
    \\set -l wt_commands checkout co create default pr mr list ls remove rm done status cleanup migrate prune help shellenv init info config examples version jump j cd ui completion
    \\
    \\complete -c wt -n "__fish_use_subcommand" -a "$wt_commands"
    \\complete -c wt -n "__fish_seen_subcommand_from config" -a "init show path"
    \\complete -c wt -n "__fish_seen_subcommand_from checkout co create" -a "(git branch -a --format='%(refname:short)' 2>/dev/null | sed 's#^.*/##' | sort -u)"
    \\complete -c wt -n "__fish_seen_subcommand_from remove rm" -a "(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\\[\\([^]]*\\)\\].*/\\1/p')"
    \\complete -c wt -n "__fish_seen_subcommand_from ui" -a "jump remove --force -f"
    \\
    ;
}

fn powershellScript() []const u8 {
    return 
    \\Register-ArgumentCompleter -CommandName wt -ScriptBlock {
    \\    param($commandName, $wordToComplete, $commandAst, $fakeBoundParameters)
    \\
    \\    $commands = @('checkout', 'co', 'create', 'default', 'pr', 'mr', 'list', 'ls', 'remove', 'rm', 'done', 'status', 'cleanup', 'migrate', 'prune', 'help', 'shellenv', 'init', 'info', 'config', 'examples', 'version', 'jump', 'j', 'cd', 'ui', 'completion')
    \\    $position = $commandAst.CommandElements.Count - 1
    \\
    \\    if ($position -eq 0) {
    \\        $commands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($position -eq 1) {
    \\        $subCommand = $commandAst.CommandElements[1].Value
    \\        if ($subCommand -in @('checkout', 'co', 'create')) {
    \\            $remotes = (git remote 2>$null) -join '|'
    \\            $branches = git branch -a --format='%(refname:short)' 2>$null | Where-Object { $_ -notmatch 'HEAD' } | ForEach-Object { $_ -replace "^($remotes)/", '' } | Sort-Object -Unique
    \\            $branches | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -in @('remove', 'rm')) {
    \\            $branches = git worktree list 2>$null | Select-Object -Skip 1 | ForEach-Object {
    \\                if ($_ -match '\[([^\]]+)\]') { $matches[1] }
    \\            }
    \\            $branches | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'config') {
    \\            @('init', 'show', 'path') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'ui') {
    \\            @('jump', 'remove', '--force', '-f') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        }
    \\    }
    \\}
    \\
    ;
}

fn zshScript() []const u8 {
    return 
    \\#compdef wt
    \\_wt_complete_zsh() {
    \\    local -a commands branches
    \\    commands=(
    \\        'checkout:Checkout existing branch in new worktree'
    \\        'co:Checkout existing branch in new worktree'
    \\        'create:Create new branch in worktree'
    \\        'default:Navigate to the main worktree'
    \\        'pr:Checkout GitHub PR in worktree'
    \\        'mr:Checkout GitLab MR in worktree'
    \\        'list:List all worktrees'
    \\        'ls:List all worktrees'
    \\        'remove:Remove a worktree'
    \\        'rm:Remove a worktree'
    \\        'done:Remove current linked worktree'
    \\        'status:Show status dashboard of all worktrees'
    \\        'cleanup:Remove worktrees for merged branches'
    \\        'migrate:Migrate existing worktrees to configured paths'
    \\        'prune:Remove worktree administrative files'
    \\        'help:Show help'
    \\        'shellenv:Output shell function for auto-cd'
    \\        'init:Initialize shell integration'
    \\        'info:Show worktree location configuration'
    \\        'config:Manage wt configuration'
    \\        'examples:Show practical command examples'
    \\        'version:Show version information'
    \\        'jump:Navigate to a worktree by branch name'
    \\        'j:Navigate to a worktree by branch name'
    \\        'cd:Navigate to a worktree by branch name'
    \\        'ui:Open an interactive worktree UI'
    \\        'completion:Generate shell completion scripts'
    \\    )
    \\
    \\    if (( CURRENT == 2 )); then
    \\        _describe 'command' commands
    \\    elif (( CURRENT == 3 )); then
    \\        case "$words[2]" in
    \\            checkout|co|create)
    \\                local remotes
    \\                remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                branches=(${(f)"$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)"})
    \\                _describe 'branch' branches
    \\                ;;
    \\            remove|rm)
    \\                branches=(${(f)"$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"})
    \\                _describe 'branch' branches
    \\                ;;
    \\            config)
    \\                local -a config_cmds
    \\                config_cmds=('init:Create a default configuration file' 'show:Show effective configuration with sources' 'path:Print the config file path')
    \\                _describe 'config command' config_cmds
    \\                ;;
    \\            ui)
    \\                local -a ui_cmds
    \\                ui_cmds=('jump:Select and navigate to a worktree' 'remove:Select and remove a worktree' '--force:Force removal (remove mode)' '-f:Force removal (remove mode)')
    \\                _describe 'ui mode' ui_cmds
    \\                ;;
    \\            completion)
    \\                local -a shell_cmds
    \\                shell_cmds=('bash:Generate bash completion' 'fish:Generate fish completion' 'powershell:Generate PowerShell completion' 'zsh:Generate zsh completion')
    \\                _describe 'shell' shell_cmds
    \\                ;;
    \\        esac
    \\    fi
    \\}
    \\if (( $+functions[compdef] )); then
    \\    compdef _wt_complete_zsh wt
    \\fi
    \\
    ;
}

test "completion prints help without args" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [1024]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(
        .{ .allocator = allocator, .format = .text },
        &.{},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(0, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Generate the autocompletion script for wt") != null);
}

test "completion bash script contains completer" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [1024]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(
        .{ .allocator = allocator, .format = .text },
        &.{"bash"},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try std.testing.expectEqual(0, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "complete -F _wt_complete wt") != null);
}

test "completion reports unknown shell in text mode" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [1024]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(
        .{ .allocator = allocator, .format = .text },
        &.{"unknown"},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(1, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "Unknown completion shell: unknown") != null);
    try std.testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
}

test "completion reports unknown shell in json mode" {
    const allocator = std.testing.allocator;
    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);
    var stdout_writer = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_writer.adaptToNewApi(&stdout_io_buf);
    var stderr_writer = stderr_buffer.writer(allocator);
    var stderr_io_buf: [1024]u8 = undefined;
    var stderr_adapted = stderr_writer.adaptToNewApi(&stderr_io_buf);

    const exit_code = try run(
        .{ .allocator = allocator, .format = .json },
        &.{"unknown"},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(1, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"command\":\"wt completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"error\":\"unknown completion shell: unknown\"") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}
