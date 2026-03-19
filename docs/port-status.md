# Port Status

This document is the durable handoff for the Zig port of [`/home/douglas/src/wt`](/home/douglas/src/wt).

## Current State

The port is intentionally incremental, not a line-by-line Cobra rewrite. The current Zig CLI already covers the core non-interactive worktree lifecycle plus initial shell integration:

- `help`, `version`, `list`
- `config show`, `config path`, `config init`
- `checkout` / `co`
- `create`
- `remove` / `rm`
- `prune`
- `cleanup`
- `pr`
- `mr`
- `info`
- `shellenv`
- `init`

## Implemented Architecture

The port currently breaks down into these modules:

- `src/app.zig`: root argument parsing and native command dispatch
- `src/command.zig`: command registry and help metadata
- `src/config.zig`: config resolution, TOML-subset parsing, and starter config generation
- `src/path.zig`: strategy defaults, token rendering, directory creation, and worktree-path cleanup
- `src/git/worktree.zig`: `git worktree list --porcelain` parsing
- `src/git/repo.zig`: repo discovery, default base resolution, branch checks, and merged-branch lookup
- `src/git/pr.zig`: PR/MR identifier parsing and `gh` / `glab` branch lookup
- `src/hooks.zig`: hook lookup, environment construction, and pre/post execution
- `src/commands/*.zig`: thin command entry points around the shared layers

Important design decisions:

- The CLI uses a Zig-native dispatcher instead of a Cobra-style command tree.
- `git worktree list --porcelain` is the source of truth for worktree discovery.
- Shared behavior is pulled downward into reusable helpers when a second command needs it.
  Example: `checkoutBranch` in `src/commands/checkout.zig` now underpins plain checkout plus PR/MR checkout.
- The first slices bias toward explicit, non-interactive behavior so each phase can be verified with real temp repos.

## Completed Phases

### Phase 1: Zig CLI bootstrap

- Bootstrapped the Zig 0.15.2 project.
- Added the initial dispatcher and command registry.
- Implemented `help`, `version`, and `list`.
- Grounded `list` on `git worktree list --porcelain`.

Commit: `d3861de`

### Phase 2: config loading and precedence

- Added defaults, config path resolution, and TOML-subset parsing.
- Implemented config precedence: `--config` > `WT_CONFIG` > default config location.
- Added `wt config show` and `wt config path`.

Commit: `9183c90`

### Phase 3: path strategy resolution

- Added strategy aliases and default patterns.
- Implemented path token rendering and separator handling.
- Added custom-pattern validation.

Commit: `b079860`

### Phase 4: checkout and create

- Added non-interactive `checkout` / `co` and `create`.
- Added repo discovery and branch inspection helpers.
- Added worktree creation on top of the config/path layers.

Commit: `d78c682`

### Phase 5: richer list and info output

- Added `wt info`.
- Improved `list` output to surface branch and state more clearly.

Commit: `31bafe6`

### Phase 6: command hooks

- Added `src/hooks.zig`.
- Wired pre/post hooks into `checkout` and `create`.
- `WT_HOOKS_DISABLED=1` skips all hooks.
- Pre-hooks abort; post-hooks warn and continue.

Commit: `fc9ff6d`

### Phase 7: remove, prune, and cleanup

- Added `remove`, `prune`, and merged-branch `cleanup`.
- Reused shared worktree discovery instead of shell text parsing.
- Added `cleanupWorktreePath` to remove empty repo buckets under `WORKTREE_ROOT`.

Commit: `dbec961`

### Phase 8: PR and MR checkout

- Added `pr` and `mr`.
- Added `src/git/pr.zig` for numeric-or-URL parsing and `gh` / `glab` lookup.
- Refactored the shared checkout path so PR/MR checkout reuses path, hook, and existence logic.
- Added fetch fallback via PR/MR refspecs for fork-style refs.

Commit: `fb6e89e`

### Phase 9: shellenv

- Added `wt shellenv`.
- First slice emits a minimal bash/zsh wrapper that follows `wt navigating to:` markers.

Commit: `7fa2c18`

### Phase 10: config init

- Added `wt config init`.
- Writes a starter config at the resolved config path.
- Refuses to overwrite an existing config file.

Commit: `c1f3244`

### Phase 11: init shell install

- Added `wt init [bash|zsh]`.
- Installs an idempotent marked shell block into the detected rc file.
- Respects `ZDOTDIR` for zsh.

Commit: `240121a`

## Verification Patterns

The port has been verified repeatedly with both unit/build checks and temp-repo smoke tests.

Standard checks:

```text
zig fmt --check build.zig build.zig.zon src/*.zig src/commands/*.zig src/git/*.zig
zig build
zig build test
```

In the Codex sandbox, Zig needs explicit cache locations:

```text
ZIG_GLOBAL_CACHE_DIR=/home/douglas/src/wt-zig/.zig-global-cache
ZIG_LOCAL_CACHE_DIR=/home/douglas/src/wt-zig/.zig-cache
```

Useful smoke-test patterns that already proved valuable:

- temp git repos for `checkout`, `create`, `remove`, and `cleanup`
- temp bare `origin` repos plus stub `gh` / `glab` executables for `pr` and `mr`
- temp home directories for `init` and temp config paths for `config init`
- disabling signing in temp repos with `git config commit.gpgsign false`

## Important Learnings

- Do not assume absolute-path helpers exist in Zig stdlib; some convenience APIs are absent in Zig 0.15.2.
- Creating absolute parent directories needed explicit walking logic; `cwd.makePath` on absolute paths was not enough.
- Runtime config values must be copied into owned storage during load so temporary `EnvMap` allocations do not leak invalid references.
- Shared command behavior should move into reusable helpers only after a second command needs it.
  This kept the first slices simple while still allowing later reuse.
- For PR/MR checkout, `git fetch origin <branch>` is not enough for every workflow; fallback refspec fetches matter for fork-style refs.

## Remaining Port Gaps

The major unported areas from the Go CLI are now smaller and more isolated:

- richer `init` support:
  - uninstall
  - dry-run
  - no-prompt / activation guidance
  - PowerShell support
- richer `shellenv` output:
  - completions
  - PowerShell shellenv
- interactive flows:
  - branch/worktree selection for `checkout`, `remove`, `pr`, `mr`
  - confirmations where the Go CLI prompts
- migration support
- any remaining shell-install polish beyond the minimal Unix slice

## Codex Setup Notes

The local feature workflow currently uses prompts, not skills:

- `~/.codex/prompts/start-feature.md`
- `~/.codex/prompts/close-feature.md`

They exist and are usable, but they are not installed under `~/.codex/skills`.

Separately, broken Claude-ported skills were repaired by:

- adding valid top-of-file frontmatter
- adding minimal `agents/openai.yaml`

Skills repaired:

- `ruby-style`
- `minitest-style`
- `basecamp-rails-best-practices`

If Codex still behaves as if those skills are missing, restart the session so discovery reloads their metadata.
