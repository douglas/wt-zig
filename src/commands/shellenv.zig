const std = @import("std");

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len != 0) {
        try stderr.writeAll("Usage: wt shellenv\n");
        return 1;
    }

    try stdout.writeAll(
        \\wt() {
        \\    # In JSON mode, keep stdout machine-readable and skip auto-navigation.
        \\    case " $* " in
        \\        *" --format json "*|*" --format=json "*)
        \\            command wt "$@"
        \\            return $?
        \\            ;;
        \\    esac
        \\
        \\    local output exit_code cd_path
        \\    output=$(command wt "$@")
        \\    exit_code=$?
        \\    printf '%s\n' "$output"
        \\    cd_path=$(printf '%s\n' "$output" | grep '^wt navigating to: ' | tail -1 | sed 's/^wt navigating to: //')
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
        \\        commands="checkout co create pr mr list ls remove rm cleanup migrate prune help shellenv init info config version"
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
        \\            'pr:Checkout GitHub PR in worktree'
        \\            'mr:Checkout GitLab MR in worktree'
        \\            'list:List all worktrees'
        \\            'ls:List all worktrees'
        \\            'remove:Remove a worktree'
        \\            'rm:Remove a worktree'
        \\            'cleanup:Remove worktrees for merged branches'
        \\            'migrate:Migrate existing worktrees to configured paths'
        \\            'prune:Remove worktree administrative files'
        \\            'help:Show help'
        \\            'shellenv:Output shell function for auto-cd'
        \\            'init:Initialize shell integration'
        \\            'info:Show worktree location configuration'
        \\            'config:Manage wt configuration'
        \\            'version:Show version information'
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
        \\            esac
        \\        fi
        \\    }
        \\    if (( $+functions[compdef] )); then
        \\        compdef _wt_complete_zsh wt
        \\    fi
        \\fi
    );

    return 0;
}

test "shellenv includes json guard and completion blocks" {
    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8).empty;
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8).empty;
    defer stderr_buffer.deinit(allocator);

    var stdout = stdout_buffer.writer(allocator);
    var stderr = stderr_buffer.writer(allocator);

    const exit_code = try run(&.{}, &stdout, &stderr);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "--format json") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "complete -F _wt_complete wt") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "if (( $+functions[compdef] ))") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "commands=\"checkout co create pr mr list ls remove rm cleanup migrate prune help shellenv init info config version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "awk '/^wt navigating to: /") == null);
}
