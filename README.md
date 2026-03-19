# wt-zig

`wt-zig` is a Zig-native port of [`/home/douglas/src/wt`](/home/douglas/src/wt), built incrementally instead of as a line-by-line Cobra rewrite.

## Phase 1

The first slice keeps the scope intentionally small:

- bootstrap a Zig 0.15.2 project
- provide a native command dispatcher
- implement `help`, `version`, and `list`
- make `list` use `git worktree list --porcelain`
- leave clean seams for later config, path, hook, and PR/MR modules

## Commands

```text
wt help
wt version
wt list
wt ls
```

## Development

```text
zig build
zig build run -- help
zig build run -- version
zig build run -- list
zig build test
zig fmt --check .
```
