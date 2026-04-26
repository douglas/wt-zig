---
name: wt
description: "Use this skill when the user asks about `wt`, git worktrees, or commands like `wt create`, `wt checkout` (`wt co`), `wt list` (`wt ls`), `wt remove` (`wt rm`), `wt done`, `wt jump` (`wt j`, `wt cd`), `wt ui`, `wt pr`, `wt mr`, `wt status`, `wt config`, `wt init`, `wt completion`, or `wt shellenv`."
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
- `wt checkout <branch>` / `wt co <branch>`
- `wt list` / `wt ls`
- `wt jump <query>` / `wt j <query>` / `wt cd <query>`
- `wt remove <branch>` / `wt rm <branch>`
- `wt rm` (interactive remove picker; gum-first with text fallback)
- `wt ui [jump|remove] [--force|-f]` (gum-powered action picker)
- `wt done [--force]`
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
- Hook blocks support pre/post create/checkout/remove/pr/mr with `WT_*` env variables.

## Guidance for Codex

- Prefer `wt create`/`wt co` over branch switching in the main checkout.
- Use `wt ls` or `wt status` before removal/cleanup operations.
- In non-interactive contexts, pass explicit arguments instead of relying on prompts.
- If `gum` is installed, prefer `wt rm` or `wt ui` for interactive remove/jump workflows.
- If the user asks for navigation behavior, mention shell integration (`wt init`, `wt shellenv`) and aliases (`wt j`, `wt cd`).
