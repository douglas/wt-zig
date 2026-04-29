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
    \\    local log_file exit_code cd_path cd_file exec_file
    \\    log_file=$(mktemp -t wt.XXXXXX)
    \\    cd_file=$(mktemp -t wt-cd.XXXXXX)
    \\    exec_file=$(mktemp -t wt-exec.XXXXXX)
    \\
    \\    if [ "$(uname)" = "Darwin" ]; then
    \\        WT_DIRECTIVE_CD_FILE="$cd_file" WT_DIRECTIVE_EXEC_FILE="$exec_file" script -q "$log_file" /bin/sh -c 'command wt "$@"' wt "$@"
    \\    else
    \\        WT_DIRECTIVE_CD_FILE="$cd_file" WT_DIRECTIVE_EXEC_FILE="$exec_file" script -q -c "command wt $*" "$log_file"
    \\    fi
    \\    exit_code=$?
    \\    if [ -s "$cd_file" ]; then
    \\        cd_path=$(cat "$cd_file")
    \\    else
    \\        cd_path=$(grep '^wt navigating to: ' "$log_file" | tail -1 | sed 's/^wt navigating to: //')
    \\    fi
    \\    rm -f "$log_file" "$cd_file"
    \\    cd_path=${cd_path%$'\r'}
    \\
    \\    if [ $exit_code -eq 0 ] && [ -n "$cd_path" ]; then
    \\        cd "$cd_path"
    \\    fi
    \\    if [ $exit_code -eq 0 ] && [ -s "$exec_file" ]; then
    \\        source "$exec_file"
    \\        exit_code=$?
    \\    fi
    \\    rm -f "$exec_file"
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
    \\        commands="switch sw cd jump j checkout co create default pr mr list ls remove rm done status step cleanup merge migrate prune help shellenv init info config examples version ui completion"
    \\
    \\        if [ $COMP_CWORD -eq 1 ]; then
    \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\            return 0
    \\        fi
    \\
    \\        case "$prev" in
    \\            switch|sw|cd|jump|j|checkout|co|create)
    \\                local branches remotes
    \\                remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                branches=$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)
    \\                COMPREPLY=( $(compgen -W "$branches --create -c --base --execute -x" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            remove|rm)
    \\                local branches
    \\                branches=$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    \\                COMPREPLY=( $(compgen -W "$branches --force -f --no-delete-branch --force-delete -D" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            done)
    \\                COMPREPLY=( $(compgen -W "--force -f --no-delete-branch --force-delete -D" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            list|ls)
    \\                COMPREPLY=( $(compgen -W "--full" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            step)
    \\                COMPREPLY=( $(compgen -W "commit copy-ignored diff prune push rebase squash" -- "$cur") )
    \\                return 0
    \\                ;;
    \\            merge)
    \\                COMPREPLY=( $(compgen -W "--no-remove --no-ff --squash --rebase --push --no-hooks --message -m" -- "$cur") )
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
    \\            'switch:Switch to, create, or checkout a worktree'
    \\            'sw:Switch to, create, or checkout a worktree'
    \\            'cd:Switch to, create, or checkout a worktree'
    \\            'jump:Switch to, create, or checkout a worktree'
    \\            'j:Switch to, create, or checkout a worktree'
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
    \\            'step:Run focused workflow steps'
    \\            'cleanup:Remove worktrees for merged branches'
    \\            'merge:Merge current branch into a target branch'
    \\            'migrate:Migrate existing worktrees to configured paths'
    \\            'prune:Remove worktree administrative files'
    \\            'help:Show help'
    \\            'shellenv:Output shell function for auto-cd'
    \\            'init:Initialize shell integration'
    \\            'info:Show worktree location configuration'
    \\            'config:Manage wt configuration'
    \\            'examples:Show practical command examples'
    \\            'version:Show version information'
    \\            'ui:Open an interactive worktree UI'
    \\            'completion:Generate completion script'
    \\        )
    \\
    \\        if (( CURRENT == 2 )); then
    \\            _describe 'command' commands
    \\        elif (( CURRENT == 3 )); then
    \\            case "$words[2]" in
    \\                switch|sw|cd|jump|j|checkout|co|create)
    \\                    local remotes
    \\                    remotes=$(git remote 2>/dev/null | paste -sd'|' -)
    \\                    branches=(${(f)"$(git branch -a --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' | sed -E "s#^($remotes)/##" | sort -u)"})
    \\                    branches+=('--create:Create a new branch' '-c:Create a new branch' '--base:Base branch' '--execute:Run command after switching' '-x:Run command after switching')
    \\                    _describe 'branch' branches
    \\                    ;;
    \\                remove|rm)
    \\                    branches=(${(f)"$(git worktree list 2>/dev/null | tail -n +2 | sed -n 's/.*\[\([^]]*\)\].*/\1/p')"} '--force:Force worktree removal' '-f:Force worktree removal' '--no-delete-branch:Keep the branch' '--force-delete:Delete branch even when unsafe' '-D:Delete branch even when unsafe')
    \\                    _describe 'branch' branches
    \\                    ;;
    \\                done)
    \\                    local -a done_flags
    \\                    done_flags=('--force:Force worktree removal' '-f:Force worktree removal' '--no-delete-branch:Keep the branch' '--force-delete:Delete branch even when unsafe' '-D:Delete branch even when unsafe')
    \\                    _describe 'done flag' done_flags
    \\                    ;;
    \\                list|ls)
    \\                    local -a list_flags
    \\                    list_flags=('--full:Include current, dirty, and upstream status')
    \\                    _describe 'list flag' list_flags
    \\                    ;;
    \\                step)
    \\                    local -a step_cmds
    \\                    step_cmds=('commit:Commit staged or selected changes' 'copy-ignored:Copy ignored files and directories between worktrees' 'diff:Show all changes since branching' 'prune:Remove worktrees for merged branches' 'push:Fast-forward a target branch' 'rebase:Rebase onto a target branch' 'squash:Squash branch changes into one commit')
    \\                    _describe 'step command' step_cmds
    \\                    ;;
    \\                merge)
    \\                    local -a merge_flags
    \\                    merge_flags=('--no-remove:Keep source worktree after merge' '--no-ff:Create a merge commit' '--squash:Squash before merge' '--rebase:Rebase before merge' '--push:Push after merge' '--no-hooks:Skip merge pipeline hooks' '--message:Commit message for squash' '-m:Commit message for squash')
    \\                    _describe 'merge flag' merge_flags
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
    \\        & wt.exe @args
    \\        $exitCode = $LASTEXITCODE
    \\        $global:LASTEXITCODE = $exitCode
    \\        return
    \\    }
    \\
    \\    $cdFile = [System.IO.Path]::GetTempFileName()
    \\    $execFile = [System.IO.Path]::GetTempFileName()
    \\    try {
    \\        $env:WT_DIRECTIVE_CD_FILE = $cdFile
    \\        $env:WT_DIRECTIVE_EXEC_FILE = $execFile
    \\        $output = & wt.exe @args
    \\        $exitCode = $LASTEXITCODE
    \\        Write-Output $output
    \\    }
    \\    finally {
    \\        Remove-Item Env:\WT_DIRECTIVE_CD_FILE -ErrorAction SilentlyContinue
    \\        Remove-Item Env:\WT_DIRECTIVE_EXEC_FILE -ErrorAction SilentlyContinue
    \\    }
    \\
    \\    if ($exitCode -eq 0) {
    \\        if ((Test-Path $cdFile) -and (Get-Item $cdFile).Length -gt 0) {
    \\            $cdPath = (Get-Content -Path $cdFile -Raw).Trim()
    \\        } else {
    \\            $cdPath = $output | Select-String -Pattern "^wt navigating to: " | ForEach-Object { $_.Line.Substring(18) }
    \\        }
    \\        if ($cdPath) {
    \\            Set-Location -LiteralPath $cdPath
    \\        }
    \\    }
    \\    if ($exitCode -eq 0 -and (Test-Path $execFile) -and (Get-Item $execFile).Length -gt 0) {
    \\        Invoke-Expression (Get-Content -Path $execFile -Raw)
    \\        $exitCode = $LASTEXITCODE
    \\    }
    \\    Remove-Item $cdFile, $execFile -ErrorAction SilentlyContinue
    \\    $global:LASTEXITCODE = $exitCode
    \\}
    \\
    \\# PowerShell completion
    \\Register-ArgumentCompleter -CommandName wt -ScriptBlock {
    \\    param($commandName, $wordToComplete, $commandAst, $fakeBoundParameters)
    \\
    \\    $commands = @('switch', 'sw', 'cd', 'jump', 'j', 'checkout', 'co', 'create', 'default', 'pr', 'mr', 'list', 'ls', 'remove', 'rm', 'done', 'status', 'step', 'cleanup', 'merge', 'migrate', 'prune', 'help', 'shellenv', 'init', 'info', 'config', 'examples', 'version', 'ui', 'completion')
    \\
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
    \\            @('commit', 'copy-ignored', 'diff', 'prune', 'push', 'rebase', 'squash') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    \\            }
    \\        } elseif ($subCommand -eq 'merge') {
    \\            @('--no-remove', '--no-ff', '--squash', '--rebase', '--push', '--no-hooks', '--message', '-m') | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
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
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "commands=\"switch sw cd jump j checkout co create default pr mr list ls remove rm done status step cleanup merge migrate prune help shellenv init info config examples version ui completion\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "awk '/^wt navigating to: /") == null);
    }
}

test "shellenv emits json note in json mode" {
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

    const exit_code = try run(
        .{ .allocator = allocator, .format = .json },
        &.{},
        &stdout_adapted.new_interface,
        &stderr_adapted.new_interface,
    );
    try stdout_adapted.new_interface.flush();
    try stderr_adapted.new_interface.flush();

    try std.testing.expectEqual(0, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"command\":\"wt shellenv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "\"note\":\"shellenv outputs shell script text; run without --format json to source it\"") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}
