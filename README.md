# wt-zig

`wt-zig` is a Zig-native port of [`/home/douglas/src/wt`](/home/douglas/src/wt), built incrementally instead of as a line-by-line Cobra rewrite.

## Current Scope

The current slices keep the scope intentionally small:

- bootstrap a Zig 0.15.2 project
- provide a native command dispatcher
- add config loading with defaults, `WT_CONFIG`, `--config`, and env overrides
- add `wt config init` to create a starter config file at the resolved path
- resolve effective worktree patterns from strategy aliases and custom templates
- add non-interactive `checkout` and `create` flows on top of the path layer
- add `wt info` to expose resolved strategy, pattern, root, separator, and hooks
- run configured pre/post hooks for `checkout`, `create`, `remove`, `pr`, and `mr`
- add non-interactive `remove`, `prune`, and merged-branch `cleanup` flows
- add non-interactive `pr` and `mr` flows that resolve branches through `gh` and `glab`
- add `shellenv` output for bash/zsh auto-`cd` integration
- add `init` for bash/zsh rc-file installation of the `shellenv` block
- implement `help`, `version`, and `list`
- make `list` use `git worktree list --porcelain`
- expose `wt config show` and `wt config path`, including effective pattern display
- leave clean seams for later interactive prompts, shell install flows, migration, and richer remote features

## Commands

```text
wt help
wt version
wt list
wt ls
wt checkout <branch>
wt co <branch>
wt create <branch> [base-branch]
wt remove <branch>
wt rm <branch>
wt prune
wt cleanup
wt pr <number|url>
wt mr <number|url>
wt shellenv
wt init [bash|zsh]
wt info
wt config show
wt config path
wt config init
```

## Development

```text
zig build
zig build run -- help
zig build run -- version
zig build run -- list
zig build run -- config show
zig build test
zig fmt --check .
```
