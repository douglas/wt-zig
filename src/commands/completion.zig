const std = @import("std");
const output = @import("../output.zig");

const command_words = "switch sw cd jump j checkout co create default pr mr list ls remove rm done status step cleanup merge migrate prune help hook shellenv init info config examples version ui completion";

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
    \\        switch|sw|cd|jump|j|checkout|co|create)
    \\            local branches remotes
    \\            remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\            branches=$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)
    \\            COMPREPLY=( $(compgen -W "$branches --create -c --base --execute -x" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        remove|rm)
    \\            local branches
    \\            branches=$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    \\            COMPREPLY=( $(compgen -W "$branches --force -f --no-delete-branch --force-delete -D" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        done)
    \\            COMPREPLY=( $(compgen -W "--force -f --no-delete-branch --force-delete -D" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        list|ls)
    \\            COMPREPLY=( $(compgen -W "--full" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        step)
    \\            COMPREPLY=( $(compgen -W "commit copy-ignored diff eval for-each prune push rebase squash" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        merge)
    \\            COMPREPLY=( $(compgen -W "--no-remove --no-ff --squash --rebase --push --no-hooks --message -m" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        config)
    \\            COMPREPLY=( $(compgen -W "init show path alias" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        hook)
    \\            COMPREPLY=( $(compgen -W "show" -- "$cur") )
    \\            return 0
    \\            ;;
    \\        ui)
    \\            COMPREPLY=( $(compgen -W "jump remove --force -f" -- "$cur") )
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
    \\set -l wt_commands switch sw cd jump j checkout co create default pr mr list ls remove rm done status step cleanup merge migrate prune help hook shellenv init info config examples version ui completion
    \\
    \\complete -c wt -n "__fish_use_subcommand" -a "$wt_commands"
    \\complete -c wt -n "__fish_seen_subcommand_from config" -a "init show path alias"
    \\complete -c wt -n "__fish_seen_subcommand_from hook" -a "show"
    \\complete -c wt -n "__fish_seen_subcommand_from switch sw cd jump j checkout co create" -a "(git branch -a --format='%(refname:short)' 2>/dev/null | sed 's#^.*/##' | sort -u)"
    \\complete -c wt -n "__fish_seen_subcommand_from switch sw cd jump j" -a "--create -c --base --execute -x"
    \\complete -c wt -n "__fish_seen_subcommand_from remove rm" -a "(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\\[\\([^]]*\\)\\].*/\\1/p')"
    \\complete -c wt -n "__fish_seen_subcommand_from remove rm done" -a "--force -f --no-delete-branch --force-delete -D"
    \\complete -c wt -n "__fish_seen_subcommand_from list ls" -a "--full"
    \\complete -c wt -n "__fish_seen_subcommand_from step" -a "commit copy-ignored diff prune push rebase squash"
    \\complete -c wt -n "__fish_seen_subcommand_from merge" -a "--no-remove --no-ff --squash --rebase --push --no-hooks --message -m"
    \\complete -c wt -n "__fish_seen_subcommand_from ui" -a "jump remove --force -f"
    \\
    ;
}

fn powershellScript() []const u8 {
    return 
    \\Register-ArgumentCompleter -CommandName wt -ScriptBlock {
    \\    param($commandName, $wordToComplete, $commandAst, $fakeBoundParameters)
    \\
    \\    $commands = @('switch', 'sw', 'cd', 'jump', 'j', 'checkout', 'co', 'create', 'default', 'pr', 'mr', 'list', 'ls', 'remove', 'rm', 'done', 'status', 'step', 'cleanup', 'merge', 'migrate', 'prune', 'help', 'hook', 'shellenv', 'init', 'info', 'config', 'examples', 'version', 'ui', 'completion')
    \\    $position = $commandAst.CommandElements.Count - 1
    \\
    \\    if ($position -eq 0) {
    \\        $commands | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\        }
    \\    } elseif ($position -eq 1) {
    \\        $subCommand = $commandAst.CommandElements[1].Value
    \\        if ($subCommand -in @('switch', 'sw', 'cd', 'jump', 'j', 'checkout', 'co', 'create')) {
    \\            $remotes = (git remote 2>$null) -join '|'
    \\            $branches = git branch -a --format='%(refname:short)' 2>$null | Where-Object { $_ -notmatch 'HEAD' } | ForEach-Object { $_ -replace "^($remotes)/", '' } | Sort-Object -Unique
    \\            ($branches + @('--create', '-c', '--base', '--execute', '-x')) | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -in @('remove', 'rm')) {
    \\            $branches = git worktree list 2>$null | Select-Object -Skip 1 | ForEach-Object {
    \\                if ($_ -match '\[([^\]]+)\]') { $matches[1] }
    \\            }
    \\            ($branches + @('--force', '-f', '--no-delete-branch', '--force-delete', '-D')) | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'done') {
    \\            @('--force', '-f', '--no-delete-branch', '--force-delete', '-D') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -in @('list', 'ls')) {
    \\            @('--full') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'step') {
    \\            @('commit', 'copy-ignored', 'diff', 'eval', 'for-each', 'prune', 'push', 'rebase', 'squash') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'merge') {
    \\            @('--no-remove', '--no-ff', '--squash', '--rebase', '--push', '--no-hooks', '--message', '-m') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'config') {
    \\            @('init', 'show', 'path', 'alias') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'hook') {
    \\            @('show') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
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
    \\        'switch:Switch to, create, or checkout a worktree'
    \\        'sw:Switch to, create, or checkout a worktree'
    \\        'cd:Switch to, create, or checkout a worktree'
    \\        'jump:Switch to, create, or checkout a worktree'
    \\        'j:Switch to, create, or checkout a worktree'
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
    \\        'step:Run focused workflow steps'
    \\        'cleanup:Remove worktrees for merged branches'
    \\        'merge:Merge current branch into a target branch'
    \\        'migrate:Migrate existing worktrees to configured paths'
    \\        'prune:Remove worktree administrative files'
    \\        'help:Show help'
    \\        'hook:Inspect configured hook commands'
    \\        'shellenv:Output shell function for auto-cd'
    \\        'init:Initialize shell integration'
    \\        'info:Show worktree location configuration'
    \\        'config:Manage wt configuration'
    \\        'examples:Show practical command examples'
    \\        'version:Show version information'
    \\        'ui:Open an interactive worktree UI'
    \\        'completion:Generate shell completion scripts'
    \\    )
    \\
    \\    if (( CURRENT == 2 )); then
    \\        _describe 'command' commands
    \\    elif (( CURRENT == 3 )); then
    \\        case "$words[2]" in
    \\            switch|sw|cd|jump|j|checkout|co|create)
    \\                local remotes
    \\                remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                branches=(${(f)"$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)"})
    \\                branches+=('--create:Create a new branch' '-c:Create a new branch' '--base:Base branch' '--execute:Run command after switching' '-x:Run command after switching')
    \\                _describe 'branch' branches
    \\                ;;
    \\            remove|rm)
    \\                branches=(${(f)"$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"} '--force:Force worktree removal' '-f:Force worktree removal' '--no-delete-branch:Keep the branch' '--force-delete:Delete branch even when unsafe' '-D:Delete branch even when unsafe')
    \\                _describe 'branch' branches
    \\                ;;
    \\            done)
    \\                local -a done_flags
    \\                done_flags=('--force:Force worktree removal' '-f:Force worktree removal' '--no-delete-branch:Keep the branch' '--force-delete:Delete branch even when unsafe' '-D:Delete branch even when unsafe')
    \\                _describe 'done flag' done_flags
    \\                ;;
    \\            list|ls)
    \\                local -a list_flags
    \\                list_flags=('--full:Include current, dirty, and upstream status')
    \\                _describe 'list flag' list_flags
    \\                ;;
    \\            step)
    \\                local -a step_cmds
    \\                step_cmds=('commit:Commit staged or selected changes' 'copy-ignored:Copy ignored files and directories between worktrees' 'diff:Show all changes since branching' 'eval:Evaluate a template for each worktree' 'for-each:Run a command for each worktree' 'prune:Remove worktrees for merged branches' 'push:Fast-forward a target branch' 'rebase:Rebase onto a target branch' 'squash:Squash branch changes into one commit')
    \\                _describe 'step command' step_cmds
    \\                ;;
    \\            merge)
    \\                local -a merge_flags
    \\                merge_flags=('--no-remove:Keep source worktree after merge' '--no-ff:Create a merge commit' '--squash:Squash before merge' '--rebase:Rebase before merge' '--push:Push after merge' '--no-hooks:Skip merge pipeline hooks' '--message:Commit message for squash' '-m:Commit message for squash')
    \\                _describe 'merge flag' merge_flags
    \\                ;;
    \\            config)
    \\                local -a config_cmds
    \\                config_cmds=('init:Create a default configuration file' 'show:Show effective configuration with sources' 'path:Print the config file path' 'alias:Inspect configured aliases')
    \\                _describe 'config command' config_cmds
    \\                ;;
    \\            hook)
    \\                local -a hook_cmds
    \\                hook_cmds=('show:Inspect configured hook commands')
    \\                _describe 'hook command' hook_cmds
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
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "ui)") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "jump remove --force -f") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "commit copy-ignored diff eval for-each prune push rebase squash") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "commands=\"switch sw cd jump j checkout co create default pr mr list ls remove rm done status step cleanup merge migrate prune help hook shellenv init info config examples version ui completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "init show path alias") != null);
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
