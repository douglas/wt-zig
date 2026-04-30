# wt-zig - Git Worktree Manager

A fast, simple Git worktree helper written in Zig.
This repository is a Zig-native port of [`timvw/wt`](https://github.com/timvw/wt), maintained to practical parity with the Go baseline.

## Features

- Configurable worktree strategies: `global`, `sibling-repo`, `parent-branches`, and more
- `wt switch` as the primary create/checkout/navigate workflow, with `wt cd` and `wt jump` as aliases
- Interactive selection menus with fuzzy matching for checkout, remove, pr, and mr commands
- GitHub PR support via `wt pr` command (uses `gh` CLI)
- GitLab MR support via `wt mr` command (uses `glab` CLI)
- Pre/post command hooks for create/checkout/start/remove/pr/mr
- Stale worktree detection via `wt cleanup --stale`
- Status dashboard with per-worktree branch, path, dirty state, and ahead/behind tracking
- Per-repo `.wt.toml` config overrides
- Configured `[aliases]` for project-local workflow shortcuts
- Shell integration with auto-cd functionality
- Shell completion generation via `wt completion` for bash, zsh, fish, and powershell
- Optional `gum`-powered interactive UI via `wt ui` for jump/remove flows
- Additional Zig-port commands: `wt done` and Worktrunk-inspired `wt switch`

## Quick Start

```bash
zig build
./zig-out/bin/wt init
```

## Usage

### Checkout & Create

```bash
# Switch to an existing worktree, or checkout an existing branch into one
wt switch feature-branch
wt sw feature-branch
wt cd feature-branch              # legacy navigation alias
wt jump feature-branch            # legacy navigation alias

# Worktrunk-style shortcuts
wt switch ^                       # main worktree
wt switch @                       # current worktree
wt switch -                       # worktree containing OLDPWD
wt switch pr:123                  # GitHub PR shortcut
wt switch mr:123                  # GitLab MR shortcut

# Explicit legacy checkout still works
wt checkout feature-branch
wt co feature-branch

# Create new branch in worktree (defaults to main/master as base)
wt switch --create my-feature
wt switch -c my-feature --base develop
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
wt list --full                    # include current/dirty/upstream status
wt switch feature
wt cd feature                      # alias for switch
wt jump feature                    # alias for switch
wt switch --create feature -x claude -- "work on this"
wt ui                              # gum-powered action picker (jump/remove; requires gum)
wt ui remove --force               # interactive remove picker with force flag
wt remove old-branch               # removes worktree; deletes branch when safe
wt remove old-branch --no-delete-branch
wt remove old-branch --force-delete
wt rm old-branch
wt rm                              # current linked worktree, or interactive picker outside one
wt done                            # remove current linked worktree; delete branch when safe
wt done --no-delete-branch         # keep branch after removing current worktree
wt step diff                       # all changes since branching, including untracked
wt step diff -- --stat             # forward args to git diff
wt step copy-ignored               # copy gitignored files from main to current worktree
wt step copy-ignored --dry-run      # preview ignored file copies
wt step copy-ignored --force        # overwrite existing ignored files
wt step commit -m "ship it"         # stage and commit with an explicit message
wt step squash -m "one commit"      # squash branch changes since the default base
wt step rebase                      # rebase current branch onto the default base
wt step push                        # fast-forward the target branch to the current branch
wt step eval [--dry-run] <template>  # render a template for each worktree
wt step for-each -- <command> [args...]  # run a command for each worktree
wt step prune --dry-run             # wrapper around cleanup for merged worktrees
wt merge                           # merge current branch into default branch, then cleanup
wt merge --no-remove               # keep source worktree after merging
wt merge --rebase --push           # opt into extra pipeline steps
```

`wt step copy-ignored` copies ignored files and directories from another worktree. Without flags it copies from the main worktree into the current worktree, skips existing destination entries, and uses copy-on-write when the filesystem supports it. Add `.worktreeinclude` to copy only matching ignored paths, for example `.env`, `node_modules/`, or `target/`. Configure `[step.copy-ignored] exclude = ["cache/", "*.sqlite", "!cache/keep.sqlite"]` to skip noisy ignored paths while allowing negated exceptions.

`wt step eval [--dry-run] <template>` renders a template for each worktree. `wt step for-each -- <command> [args...]` runs a command for each worktree, and template variables such as `{.branch}` and `{.repo.Name}` can be used in the forwarded command args.

`wt merge` keeps compatible defaults: it merges the current branch into the default base and removes the source worktree after success. Pipeline steps such as `--rebase`, `--squash`, `--push`, `--no-ff`, `--no-hooks`, and `--message` are opt-in flags, not default behavior.

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
wt config alias show
wt config alias dry-run ship -- --force
wt config init
wt config path
wt hook show
# Place a .wt.toml in a repo root to override global config for that repo
```

Config aliases can define custom commands. Single-string aliases run one shell command; array aliases run commands serially, and extra CLI args are appended to the last command.
`wt config alias show` surfaces the resolved alias catalog, `wt config alias dry-run <name> [-- <args>...]` previews the exact shell commands without executing them, and `wt hook show` displays the configured hook commands.

```toml
[aliases]
recent = "git branch --sort=-committerdate"
ship = ["git status --short", "git push"]
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
wt --format json list --full
wt --format json examples
```

In `json` mode, shell integration does not auto-navigate. For commands that normally prompt interactively, pass explicit arguments when using `--format json`.

### Use with AI Assistants

This repo includes local skill plugins adapted for `wt-zig`:

- Claude Code plugin: [plugins/wt](plugins/wt/)
- OpenAI Codex skill: [plugins/codex/skills/wt](plugins/codex/skills/wt/)

## Documentation

| Topic | Description |
| --- | --- |
| [Port Status](docs/port-status.md) | Phase history, parity criteria, and verification notes |
| [Test Coverage](docs/test-coverage.md) | Coverage matrix and prioritized next test additions |
| [Go vs Zig Comparison](docs/comparison.md) | Practical comparison of the Go and Zig implementations |
| [Go vs Rust vs Zig](docs/language-comparison.md) | Language comparison grounded in real `wt` data |
| [Architecture](docs/architecture.md) | Maintainer-facing architecture and quality rules |
| [LEVELUP](docs/LEVELUP.md) | Onboarding guide for contributors |
| [Claude Skill Plugin](plugins/wt/) | Local Claude skill plugin for wt workflows |
| [Codex Skill](plugins/codex/skills/wt/) | Local OpenAI Codex skill for wt workflows |

## Development

```bash
zig build
zig build check
zig build run -- help
zig build run -- version
zig build run -- list
zig build run -- config show
zig build test
zig build smoke
zig build release
zig build parity
zig fmt --check .
./scripts/smoke-workflows.sh
./scripts/parity-harness.sh
```

`zig build release` is the canonical optimized binary build used by the release workflow.
`zig build smoke` runs fixture-based workflow checks for configured aliases,
step primitives, and the opt-in merge pipeline.

## How It Works

The tool wraps Git's native worktree commands with an organized layout and consistent CLI behavior:

1. Organized structure: keeps worktrees for a repo together
2. Smart defaults: resolves repo metadata and default branch
3. Duplicate prevention: avoids creating an already-existing worktree
4. Auto-cd support: shell integration navigates after switch/create/checkout/jump
5. JSON mode: emits machine-readable output for automation

## License

GNU Affero General Public License v3.0 (AGPL-3.0-or-later)
