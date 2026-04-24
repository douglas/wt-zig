const builtin = @import("builtin");
const std = @import("std");
const output = @import("../output.zig");

pub fn run(ctx: output.Context, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (args.len != 0) {
        return output.usageError(ctx, stdout, stderr, "wt shellenv", "Usage: wt shellenv");
    }

    if (output.isJson(ctx)) {
        try output.emitSuccess(ctx, stdout, "wt shellenv", .{
            .note = "shellenv outputs shell script text; run without --format json to source it",
        });
        return 0;
    }

    if (builtin.os.tag == .windows) {
        try stdout.writeAll(powershellShellenv());
        return 0;
    }

    try stdout.writeAll(unixShellenv());
    return 0;
}

fn unixShellenv() []const u8 {
    return 
    \\wt() {
    \\    # Avoid wrapping shellenv generation itself through script(1)
    \\    # to prevent control characters in process substitution output.
    \\    if [ "$1" = "shellenv" ]; then
    \\        command wt "$@"
    \\        return $?
    \\    fi
    \\
    \\    # In JSON mode, keep stdout machine-readable and skip auto-navigation.
    \\    case " $* " in
    \\        *" --format json "*|*" --format=json "*)
    \\            command wt "$@"
    \\            return $?
    \\            ;;
    \\    esac
    \\
    \\    # Use script(1) to provide a PTY for interactive commands.
    \\    local log_file exit_code cd_path
    \\    log_file=$(mktemp -t wt.XXXXXX)
    \\
    \\    if [ "$(uname)" = "Darwin" ]; then
    \\        script -q "$log_file" /bin/sh -c 'command wt "$@"' wt "$@"
    \\    else
    \\        script -q -c "command wt $*" "$log_file"
    \\    fi
    \\    exit_code=$?
    \\    cd_path=$(grep '^wt navigating to: ' "$log_file" | tail -1 | sed 's/^wt navigating to: //')
    \\    rm -f "$log_file"
    \\    cd_path=${cd_path%$'\r'}
    \\
    \\    if [ $exit_code -eq 0 ] && [ -n "$cd_path" ]; then
    \\        cd "$cd_path"
    \\    fi
    \\    return $exit_code
    \\}
    \\
    \\# Bash completion
    \\if [ -n "$BASH_VERSION" ]; then
    \\    _wt_complete() {
    \\        local cur prev commands
    \\        COMPREPLY=()
    \\        cur="${COMP_WORDS[COMP_CWORD]}"
    \\        prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\        commands="checkout co create default pr mr list ls remove rm done status cleanup migrate prune help shellenv init info config examples version jump j cd ui completion"
    \\
    \\        if [ $COMP_CWORD -eq 1 ]; then
    \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\            return 0
    \\        fi
    \\
    \\        case "$prev" in
    \\            checkout|co|create)
    \\                local branches remotes
    \\                remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                branches=$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)
    \\                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            remove|rm)
    \\                local branches
    \\                branches=$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    \\                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            config)
    \\                COMPREPLY=( $(compgen -W "init show path" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            ui)
    \\                COMPREPLY=( $(compgen -W "jump remove --force -f" -- "$cur") )
    \\                return 0
    \\                ;;
    \\        esac
    \\    }
    \\    complete -F _wt_complete wt
    \\fi
    \\
    \\# Zsh completion
    \\if [ -n "$ZSH_VERSION" ]; then
    \\    _wt_complete_zsh() {
    \\        local -a commands branches
    \\        commands=(
    \\            'checkout:Checkout existing branch in new worktree'
    \\            'co:Checkout existing branch in new worktree'
    \\            'create:Create new branch in worktree'
    \\            'default:Navigate to the main worktree'
    \\            'pr:Checkout GitHub PR in worktree'
    \\            'mr:Checkout GitLab MR in worktree'
    \\            'list:List all worktrees'
    \\            'ls:List all worktrees'
    \\            'remove:Remove a worktree'
    \\            'rm:Remove a worktree'
    \\            'done:Remove current linked worktree'
    \\            'status:Show status dashboard of all worktrees'
    \\            'cleanup:Remove worktrees for merged branches'
    \\            'migrate:Migrate existing worktrees to configured paths'
    \\            'prune:Remove worktree administrative files'
    \\            'help:Show help'
    \\            'shellenv:Output shell function for auto-cd'
    \\            'init:Initialize shell integration'
    \\            'info:Show worktree location configuration'
    \\            'config:Manage wt configuration'
    \\            'examples:Show practical command examples'
    \\            'version:Show version information'
    \\            'jump:Navigate to a worktree by branch name'
    \\            'j:Navigate to a worktree by branch name'
    \\            'cd:Navigate to a worktree by branch name'
    \\            'ui:Open an interactive worktree UI'
    \\            'completion:Generate completion script'
    \\        )
    \\
    \\        if (( CURRENT == 2 )); then
    \\            _describe 'command' commands
    \\        elif (( CURRENT == 3 )); then
    \\            case "$words[2]" in
    \\                checkout|co|create)
    \\                    local remotes
    \\                    remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                    branches=(${(f)"$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)"})
    \\                    _describe 'branch' branches
    \\                    ;;
    \\                remove|rm)
    \\                    branches=(${(f)"$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"})
    \\                    _describe 'branch' branches
    \\                    ;;
    \\                config)
    \\                    local -a config_cmds
    \\                    config_cmds=(
    \\                        'init:Create a default configuration file'
    \\                        'show:Show effective configuration with sources'
    \\                        'path:Print the config file path'
    \\                    )
    \\                    _describe 'config command' config_cmds
    \\                    ;;
    \\                ui)
    \\                    local -a ui_cmds
    \\                    ui_cmds=(
    \\                        'jump:Select and navigate to a worktree'
    \\                        'remove:Select and remove a worktree'
    \\                        '--force:Force removal (remove mode)'
    \\                        '-f:Force removal (remove mode)'
    \\                    )
    \\                    _describe 'ui mode' ui_cmds
    \\                    ;;
    \\            esac
    \\        fi
    \\    }
    \\    if (( $+functions[compdef] )); then
    \\        compdef _wt_complete_zsh wt
    \\    fi
    \\fi
    ;
}

fn powershellShellenv() []const u8 {
    return 
    \\# PowerShell integration (Windows)
    \\# Detected via runtime.GOOS, compatible with $PSVersionTable
    \\# NOTE: Requires wt.exe to be in PATH or current directory
    \\
    \\function wt {
    \\    $output = & wt.exe @args
    \\    $exitCode = $LASTEXITCODE
    \\    Write-Output $output
    \\
    \\    $isJson = $false
    \\    for ($i = 0; $i -lt $args.Count; $i++) {
    \\        if ($args[$i] -eq '--format' -and $i + 1 -lt $args.Count -and $args[$i + 1] -eq 'json') {
    \\            $isJson = $true
    \\        }
    \\        if ($args[$i] -eq '--format=json') {
    \\            $isJson = $true
    \\        }
    \\    }
    \\    if ($isJson) {
    \\        $global:LASTEXITCODE = $exitCode
    \\        return
    \\    }
    \\
    \\    if ($exitCode -eq 0) {
    \\        $cdPath = $output | Select-String -Pattern "^wt navigating to: " | ForEach-Object { $_.Line.Substring(18) }
    \\        if ($cdPath) {
    \\            Set-Location -LiteralPath $cdPath
    \\        }
    \\    }
    \\    $global:LASTEXITCODE = $exitCode
    \\}
    \\
    \\# PowerShell completion
    \\Register-ArgumentCompleter -CommandName wt -ScriptBlock {
    \\    param($commandName, $wordToComplete, $commandAst, $fakeBoundParameters)
    \\
    \\    $commands = @('checkout', 'co', 'create', 'default', 'pr', 'mr', 'list', 'ls', 'remove', 'rm', 'done', 'status', 'cleanup', 'migrate', 'prune', 'help', 'shellenv', 'init', 'info', 'config', 'examples', 'version', 'jump', 'j', 'cd', 'ui', 'completion')
    \\
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
    ;
}

test "shellenv includes json guard and completion blocks" {
    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout_al = stdout_buffer.writer(allocator);
    var stdout_io_buf: [4096]u8 = undefined;
    var stdout_adapted = stdout_al.adaptToNewApi(&stdout_io_buf);
    var stderr_al = stderr_buffer.writer(allocator);
    var stderr_io_buf: [4096]u8 = undefined;
    var stderr_adapted = stderr_al.adaptToNewApi(&stderr_io_buf);

    const ctx = output.Context{
        .allocator = allocator,
        .format = .text,
    };
    const exit_code = try run(ctx, &.{}, &stdout_adapted.new_interface, &stderr_adapted.new_interface);
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();
    try std.testing.expectEqual(0, exit_code);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Register-ArgumentCompleter") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Set-Location -LiteralPath $cdPath") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--format json") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--format json") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "complete -F _wt_complete wt") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "if (( $+functions[compdef] ))") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "commands=\"checkout co create default pr mr list ls remove rm done status cleanup migrate prune help shellenv init info config examples version jump j cd ui completion\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "awk '/^wt navigating to: /") == null);
    }
}
