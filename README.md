# wt-zig

`wt-zig` is a Zig-native port of [`wt`](https://github.com/timvw/wt), built incrementally instead of as a line-by-line Cobra rewrite. The port is now complete under the repo's practical-parity standard: full command-surface coverage plus no Zig-only failures relative to the Go baseline on the maintained parity harness.

The detailed phase history, verification patterns, and completion criteria live in [docs/port-status.md](docs/port-status.md).
For a practical comparison of the Go and Zig implementations, see [docs/comparison.md](docs/comparison.md).
For a broader Go vs Rust vs Zig language comparison grounded in real `wt` data, see [docs/language-comparison.md](docs/language-comparison.md).
For the maintainer-facing architecture and code-quality rules, see [docs/architecture.md](docs/architecture.md).
For a maintainer onboarding guide aimed at developers ramping from Ruby-style application work into this Zig codebase, see [docs/LEVELUP.md](docs/LEVELUP.md).

## Current Scope

The current port now covers the full user-facing command surface from `wt`, including text and JSON output modes:

- bootstrap a Zig 0.15.2 project
- provide a native command dispatcher with global `--format <text|json>` support
- add config loading with defaults, `WT_CONFIG`, `--config`, and env overrides
- add `wt config init [--force]` to create or replace a starter config file at the resolved path
- resolve effective worktree patterns from strategy aliases and custom templates
- add `checkout` and `create` flows on top of the path layer
- add `wt info` to expose resolved strategy, pattern, root, separator, and hooks
- run configured pre/post hooks for `checkout`, `create`, `remove`, `pr`, and `mr`
- copy files from main worktree into new worktrees via `[copy_files]` config, with per-repo overrides
- copy directories (build caches) via `dirs` under `[copy_files]`; 4-tier copy strategy: `native_clone` (clonefile/FICLONE) → `clone` (cp --reflink=auto) → `rsync` → `standard`; auto-detected from the actual filesystem, configurable via `[copy_files] strategy`
- warm the OS page/metadata cache after worktree creation in a background thread so subsequent `grep`/`git status` calls are fast
- `wt jump <query>` — navigate to an existing worktree by fuzzy branch name (alias: `j`)
- fast worktree removal via atomic `rename(2)` to trash + `git worktree prune` (O(1) for large untracked directories)
- add `remove`, `done`, `prune`, `cleanup`, and `migrate`
- surface `done` consistently in root help, `shellenv` completion lists, and `wt examples`
- add `pr` and `mr` flows that resolve branches through `gh` and `glab`
- add interactive selectors for `checkout`, `remove`, `pr`, and `mr` in text mode
- add confirmation prompts for `cleanup` in text mode
- add `wt examples` to print the full examples catalog in text or JSON form
- add OS-appropriate `shellenv` output for bash/zsh and PowerShell integration
- add `init` for bash, zsh, and PowerShell shell-profile installation of the `shellenv` block
- implement `help`, `version`, and `list`
- make `list` use `git worktree list --porcelain`
- expose `wt config show` and `wt config path`, including effective pattern display
- keep shared JSON/output, prompt, and git helpers factored for future maintenance

Under the current completion bar, that command surface is considered finished when `./scripts/parity-harness.sh` reports no Zig-only failures relative to the Go baseline. On this host, the accepted baseline is `Passed: 88`, `Failed: 2`, `Skipped: 4` for both binaries, with the two failing scenarios inherited from the Go baseline.

## Commands

```text
wt help
wt version
wt list
wt ls
wt checkout [branch]
wt co [branch]
wt create <branch> [base-branch]
wt remove [branch] [--force|-f]
wt rm [branch] [--force|-f]
wt done [--force|-f]
wt prune
wt cleanup [--dry-run] [--force|-f]
wt migrate [--force|-f]
wt pr [number|url]
wt mr [number|url]
wt examples
wt shellenv
wt init [bash|zsh|powershell] [--dry-run] [--uninstall] [--no-prompt]
wt info
wt config show
wt config path
wt config init [--force]
wt jump <query>
wt j <query>
wt --format json <command>
```

## Development

```text
zig build
zig build check
zig build run -- help
zig build run -- version
zig build run -- list
zig build run -- config show
zig build test
zig build release          # stripped ReleaseSmall binary (~271 KB)
zig build parity
zig fmt --check .
./scripts/parity-harness.sh
```
