# wt-zig

`wt-zig` is a Zig-native port of [`/home/douglas/src/wt`](/home/douglas/src/wt), built incrementally instead of as a line-by-line Cobra rewrite.

## Current Scope

The current slices keep the scope intentionally small:

- bootstrap a Zig 0.15.2 project
- provide a native command dispatcher
- add config loading with defaults, `WT_CONFIG`, `--config`, and env overrides
- implement `help`, `version`, and `list`
- make `list` use `git worktree list --porcelain`
- expose `wt config show` and `wt config path`
- leave clean seams for later path, hook, and PR/MR modules

## Commands

```text
wt help
wt version
wt list
wt ls
wt config show
wt config path
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
