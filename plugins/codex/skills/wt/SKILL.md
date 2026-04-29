---
name: wt
description: "Use this skill when the user asks about `wt`, git worktrees, configured wt aliases, or commands like `wt switch` (`wt sw`, `wt cd`, `wt jump`), `wt create`, `wt checkout` (`wt co`), `wt list` (`wt ls`), `wt remove` (`wt rm`), `wt done`, `wt step diff`, `wt step copy-ignored`, `wt step commit`, `wt step squash`, `wt step rebase`, `wt step push`, `wt step prune`, `wt merge`, `wt ui`, `wt pr`, `wt mr`, `wt status`, `wt config`, `wt init`, `wt completion`, or `wt shellenv`."
---

# wt-zig Skill for Codex

`wt-zig` is a fast Git worktree helper written in Zig. It wraps `git worktree` with an organized layout, practical defaults, and a command surface aimed at daily branch/worktree workflows.

## Default Workflow

1. Create or checkout a branch into its own worktree.
2. Work inside that worktree without switching branches in the main checkout.
3. Open PR/MR from the worktree branch.
4. Remove the worktree after merge.

## Core Commands

- `wt create <branch> [base]`
- `wt switch <target>` / `wt sw <target>` / `wt cd <target>` / `wt jump <target>`
- `wt switch --create <branch> [--base <base>]`
- `wt switch --execute <command> -- <args...>`
- `wt checkout <branch>` / `wt co <branch>`
- `wt list [--full]` / `wt ls`
- `wt remove [branches...]` / `wt rm [branches...]` (removes worktrees; deletes branches when safe)
- `wt remove --no-delete-branch` (remove worktree and keep branch)
- `wt remove --force-delete` / `-D` (delete branch even when unsafe)
- `wt rm` (current linked worktree, or interactive remove picker outside one)
- `wt ui [jump|remove] [--force|-f]` (gum-powered action picker)
- `wt done [--force] [--no-delete-branch] [--force-delete]`
- `wt step diff [target] [-- <git diff args>...]`
- `wt step copy-ignored [--from <branch>] [--to <branch>] [--dry-run] [--force]`
- `wt step commit --message <message> [--stage all|tracked|none]`
- `wt step squash [target] --message <message> [--stage all|tracked|none]`
- `wt step rebase [target]`
- `wt step push [target]`
- `wt step prune`
- `wt merge [target] [--no-remove] [--no-ff] [--squash] [--rebase] [--push] [--no-hooks] [--message <message>]`
- `wt pr [number|url]`
- `wt mr [number|url]`
- `wt status`
- `wt info`
- `wt config show|path|init`
- `wt cleanup --stale`
- `wt prune`
- `wt init`
- `wt completion [bash|zsh|fish|powershell]`

## Output Modes

Prefer explicit args for automation and agent workflows:

```bash
wt --format json list
wt --format json info
wt --format json config show
wt --format json version
```

## Config and Hooks

- Global config: `~/.config/wt/config.toml` (or `WT_CONFIG` / `--config`)
- Per-repo override: `.wt.toml` in repo root
- Hook blocks support pre/post create/checkout/start/remove/pr/mr with `WT_*` env variables.
- `[aliases]` entries define custom wt commands; repo aliases override global aliases, and extra CLI args are appended to the last command.
- `[step.copy-ignored] exclude = [...]` skips ignored copy candidates with gitignore-like patterns; use `!pattern` entries for exceptions.
- `wt merge` defaults stay compatible: merge into the default base and clean up the source worktree. Pipeline steps are opt-in through flags like `--rebase`, `--squash`, and `--push`.

## Guidance for Codex

- Prefer `wt switch` over branch switching in the main checkout.
- Use `wt ls` or `wt status` before removal/cleanup operations.
- In non-interactive contexts, pass explicit arguments instead of relying on prompts.
- If `gum` is installed, prefer `wt rm` or `wt ui` for interactive remove/jump workflows.
- If the user asks for navigation behavior, mention shell integration (`wt init`, `wt shellenv`) and aliases (`wt sw`, `wt cd`, `wt jump`).
