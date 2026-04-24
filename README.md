# wt-zig - Git Worktree Manager

A fast, simple Git worktree helper written in Zig.
This repository is a Zig-native port of [`timvw/wt`](https://github.com/timvw/wt), maintained to practical parity with the Go baseline.

## Features

- Configurable worktree strategies: `global`, `sibling-repo`, `parent-branches`, and more
- Simple commands for common worktree operations
- Interactive selection menus with fuzzy matching for checkout, remove, pr, and mr commands
- GitHub PR support via `wt pr` command (uses `gh` CLI)
- GitLab MR support via `wt mr` command (uses `glab` CLI)
- Pre/post command hooks for create/checkout/remove/pr/mr
- Stale worktree detection via `wt cleanup --stale`
- Status dashboard with per-worktree branch, path, dirty state, and ahead/behind tracking
- Per-repo `.wt.toml` config overrides
- Shell integration with auto-cd functionality
- Shell completion generation via `wt completion` for bash, zsh, fish, and powershell
- Optional `gum`-powered interactive UI via `wt ui` for jump/remove flows
- Additional Zig-port commands: `wt done` and `wt jump` (`wt j`, `wt cd`)

## Quick Start

```bash
zig build
./zig-out/bin/wt init
```

## Usage

### Checkout & Create

```bash
# Checkout existing branch in new worktree
wt checkout feature-branch
wt co feature-branch
wt co                             # interactive: fuzzy-search from available branches

# Create new branch in worktree (defaults to main/master as base)
wt create my-feature
wt create my-feature develop      # specify base branch
```

### PRs & MRs

```bash
# Checkout GitHub PR (requires gh CLI)
wt pr 123
wt pr https://github.com/org/repo/pull/123
wt pr                              # interactive: fuzzy-search from open PRs

# Checkout GitLab MR (requires glab CLI)
wt mr 123
wt mr https://gitlab.com/org/repo/-/merge_requests/123
wt mr                              # interactive: fuzzy-search from open MRs
```

### List, Navigate & Remove

```bash
wt list
wt ls
wt jump feature
wt j feature
wt cd feature
wt ui                              # gum-powered action picker (jump/remove)
wt ui remove --force               # interactive remove picker with force flag
wt remove old-branch
wt rm old-branch
wt done                            # remove current linked worktree
```

### Maintenance & Misc

```bash
wt migrate
wt migrate --force
wt cleanup --stale
wt cleanup --stale --stale-days 7
wt prune
wt completion bash
wt version
wt examples
wt --help
```

### Info & Config

```bash
wt info
wt config show
wt config init
wt config path
# Place a .wt.toml in a repo root to override global config for that repo
```

### Status Dashboard

```bash
wt status
```

Shows each worktree's branch, path, dirty/clean state, and ahead/behind counts versus upstream.

### JSON Output (`--format json`)

Most commands support machine-readable JSON output:

```bash
wt --format json version
wt --format json info
wt --format json config show
wt --format json list
wt --format json examples
```

In `json` mode, shell integration does not auto-navigate. For commands that normally prompt interactively, pass explicit arguments when using `--format json`.

### Use with Claude Code

This repo includes a local Claude skill plugin at [plugins/wt](plugins/wt/) adapted for `wt-zig`.

## Documentation

| Topic | Description |
| --- | --- |
| [Port Status](docs/port-status.md) | Phase history, parity criteria, and verification notes |
| [Go vs Zig Comparison](docs/comparison.md) | Practical comparison of the Go and Zig implementations |
| [Go vs Rust vs Zig](docs/language-comparison.md) | Language comparison grounded in real `wt` data |
| [Architecture](docs/architecture.md) | Maintainer-facing architecture and quality rules |
| [LEVELUP](docs/LEVELUP.md) | Onboarding guide for contributors |
| [Claude Skill Plugin](plugins/wt/) | Local Claude skill plugin for wt workflows |

## Development

```bash
zig build
zig build check
zig build run -- help
zig build run -- version
zig build run -- list
zig build run -- config show
zig build test
zig build release
zig build parity
zig fmt --check .
./scripts/parity-harness.sh
```

## How It Works

The tool wraps Git's native worktree commands with an organized layout and consistent CLI behavior:

1. Organized structure: keeps worktrees for a repo together
2. Smart defaults: resolves repo metadata and default branch
3. Duplicate prevention: avoids creating an already-existing worktree
4. Auto-cd support: shell integration navigates after create/checkout/jump
5. JSON mode: emits machine-readable output for automation

## License

GNU Affero General Public License v3.0 (AGPL-3.0-or-later)
