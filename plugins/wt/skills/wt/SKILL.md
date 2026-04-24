---
name: wt
description: "This skill should be used when the user asks about 'wt', 'worktree', 'worktrees', 'wt create', 'wt checkout', 'wt co', 'wt list', 'wt ls', 'wt remove', 'wt rm', 'wt done', 'wt jump', 'wt j', 'wt cd', 'wt pr', 'wt mr', or mentions managing git worktrees with wt-zig. Also use when the user asks how wt-zig works, how to use wt commands, or how to organize branches with worktrees."
---

# Working with wt-zig - Git Worktree Manager

wt-zig is a fast Git worktree helper written in Zig. It wraps `git worktree` with a convenient interface, organized directory structure, and practical defaults. Each branch gets its own directory.

## Core Philosophy

Never switch branches in the main checkout. Create a worktree per task to keep the main checkout clean and support parallel work.

## Commands

| Command | Purpose |
|---------|---------|
| `wt create <branch> [base]` | Create a new branch in a worktree (defaults to main/master as base) |
| `wt checkout <branch>` / `wt co <branch>` | Checkout an existing branch in a new worktree |
| `wt co` | Interactive branch picker in text mode |
| `wt list` / `wt ls` | List all worktrees |
| `wt remove <branch>` / `wt rm <branch>` | Remove a worktree |
| `wt rm` | Interactive worktree picker in text mode |
| `wt done [--force]` | Remove current linked worktree |
| `wt jump <query>` / `wt j <query>` / `wt cd <query>` | Navigate to a worktree by fuzzy branch name |
| `wt pr [number\|url]` | Checkout a GitHub PR (requires `gh` CLI) |
| `wt mr [number\|url]` | Checkout a GitLab MR (requires `glab` CLI) |
| `wt status` | Overview of all worktrees (branch/path/dirty/ahead-behind) |
| `wt info` | Show active strategy, pattern, and variables |
| `wt config show` | Show effective config with sources |
| `wt cleanup --stale` | Include stale worktrees (deleted remotes or old commits) |
| `wt prune` | Clean stale worktree admin files |
| `wt migrate` | Migrate worktrees to configured paths |
| `wt init` | Install shell integration block |
| `wt completion [bash\|zsh\|fish\|powershell]` | Generate shell completion script text |
| `wt examples` | Show practical examples |

## Worktree Layout Strategies

Configure via `~/.config/wt/config.toml` or per-repo `.wt.toml`.

| Strategy | Layout |
|----------|--------|
| `global` | `<root>/<repo>/<branch>` |
| `sibling-repo` | `../<repo>-worktrees/<branch>` |
| `parent-branches` | `../<branch>` |

The `pattern` setting controls the path template. Variables include worktree root, repo metadata, and branch.

## Configuration

- Global config file: `~/.config/wt/config.toml` (or `WT_CONFIG` / `--config`)
- Per-repo override: `.wt.toml` in repo root
- Common settings: `root`, `strategy`, `pattern`, `separator`, hooks
- Env overrides: `WORKTREE_ROOT`, `WORKTREE_STRATEGY`, `WORKTREE_PATTERN`, `WORKTREE_SEPARATOR`

## Hooks

wt-zig supports pre/post hooks for `create`, `checkout`, `remove`, `pr`, and `mr`.

Example:

```toml
[hooks]
post_create = ["cp .env $WT_PATH/.env"]
post_checkout = ["echo 'Switched to $WT_BRANCH'"]
```

Hook env vars include `WT_PATH`, `WT_BRANCH`, `WT_MAIN`, `WT_REPO_NAME`, `WT_REPO_HOST`, and `WT_REPO_OWNER`.

## JSON Output

Most commands support machine-readable output:

```bash
wt --format json list
wt --format json info
wt --format json config show
wt --format json version
```

In JSON mode, avoid interactive flows by passing explicit arguments.

## Shell Integration

After `wt init`, the shell function can auto-navigate after create/checkout/jump. In non-interactive agent contexts, use the returned path explicitly.

## Agent Workflow

```bash
# 1. Create worktree for a task
wt create feat/my-feature

# 2. Work in that worktree path

# 3. Run tests, commit, push
git add .
git commit -m "feat: my feature"
git push -u origin feat/my-feature

# 4. Open PR
gh pr create --title "feat: my feature" --body "Description"

# 5. Cleanup after merge
wt rm feat/my-feature
```

## When Helping Users

- Prefer `wt create` or `wt co` over branch switching in main checkout
- Use `wt ls` / `wt status` to inspect worktree state before destructive operations
- For PR/MR flows, prefer `wt pr` / `wt mr` when `gh` / `glab` are available
- For non-interactive agent flows, pass explicit arguments (avoid relying on prompts)
