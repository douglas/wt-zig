# Changelog

## Unreleased

### Added

- `[copy_files]` config section — automatically copy files from the main worktree into new worktrees (e.g. `.env`, `config/local.yml`), with per-repo overrides via `[copy_files.<repo-name>]` subsections

## 0.1.0 — 2026-03-20

First tagged release. The Zig port covers the full Go `wt` command surface under
the repo's practical-parity standard, plus the new `done` command.

### Added

- `help`, `version`, `list` / `ls`
- `checkout` / `co`, `create`
- `remove` / `rm`, `prune`, `cleanup`, `migrate`
- `done` — remove the current linked worktree and navigate back to the project root
- `pr`, `mr` — checkout GitHub PRs and GitLab MRs in worktrees
- `info`, `config show`, `config path`, `config init`
- `examples` — full examples catalog in text and JSON
- `shellenv`, `init` — shell integration for bash, zsh, and PowerShell
- Global `--format json` support across all commands
- Interactive selectors for `checkout`, `remove`, `pr`, and `mr` in text mode
- Confirmation prompts for `cleanup` in text mode
- Pre/post hooks for `checkout`, `create`, `remove`, `pr`, and `mr`
- Config loading with defaults, `WT_CONFIG`, `--config`, and env overrides
- Strategy-based worktree path resolution with custom patterns
- Parity harness (`zig build parity`) for regression testing against the Go baseline
