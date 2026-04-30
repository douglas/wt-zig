# Port Status

This document is the durable handoff for the Zig port of [`wt`](https://github.com/timvw/wt).

## Current State

The port is intentionally incremental, not a line-by-line Cobra rewrite. The current Zig CLI now covers the full current `wt` command surface in both text mode and the global `--format json` mode:

- `help`, `version`, `list`, `status`, `default`
- `config show`, `config path`, `config init`
- `completion`
- `switch` / `sw` / `cd` / `jump` / `j`
- `checkout` / `co`
- `create`
- `remove` / `rm`
- `done`
- `ui`
- `step eval`
- `step for-each`
- `prune`
- `cleanup`
- `migrate`
- `pr`
- `mr`
- `examples`
- `info`
- `shellenv`
- `init`
- `hook`
- configured `[aliases]`
- `config alias` discoverability

## Port Complete

The port is complete under the repo's practical-parity standard:

- full current `wt` command-surface coverage in Zig
- `zig build` and `zig build test` pass
- `./scripts/parity-harness.sh` reports no Zig-only failures relative to the Go baseline
- 4-tier copy strategy system: `native_clone` (clonefile/FICLONE) → `clone` (cp --reflink) → `rsync` → `standard`; auto-detected per operation, configurable via `[copy_files] strategy`
- `wt switch <target>` / `sw` / `cd` / `jump` / `j` for Worktrunk-style navigation and checkout
- configured `[aliases]` for custom workflow commands, with per-repo aliases overriding global aliases
- `wt ui [jump|remove] [--force|-f]` for gum-powered interactive jump/remove flows

The current accepted baseline on this host (latest run: 2026-04-25) is:

- Go harness result: `Passed: 94`, `Failed: 4`, `Skipped: 4`
- Zig harness result: `Passed: 97`, `Failed: 1`, `Skipped: 4`

The remaining shared failing scenario is inherited from the Go baseline in this environment and is not treated as an open `wt-zig` gap:

- `config/config_show_defaults`

Current Go-only failures in this environment:

- `init/init_uninstall`
- `status/status_shows_worktree_branch`
- `status/status_shows_dirty_state`

## Implemented Architecture

The port currently breaks down into these modules:

- `src/app.zig`: root argument parsing and native command dispatch
- `src/command.zig`: command registry and help metadata
- `src/config.zig`: config resolution, TOML-subset parsing, and starter config generation
- `src/output.zig`: global text/JSON output mode helpers and help/error envelopes
- `src/path.zig`: strategy defaults, token rendering, directory creation, and worktree-path cleanup
- `src/git/worktree.zig`: `git worktree list --porcelain` parsing
- `src/git/repo.zig`: repo discovery, default base resolution, branch checks, merged-branch lookup, and interactive branch/worktree inventories
- `src/git/pr.zig`: PR/MR identifier parsing, open-item discovery, and `gh` / `glab` branch lookup
- `src/hooks.zig`: hook lookup, environment construction, and pre/post execution
- `src/prompt.zig`: text-mode selection and confirmation prompts
- `src/commands/*.zig`: thin command entry points around the shared layers

Important design decisions:

- The CLI uses a Zig-native dispatcher instead of a Cobra-style command tree.
- Root parsing strips `--config` and `--format` anywhere in argv before dispatch so command handlers stay focused on command-local arguments.
- `git worktree list --porcelain` is the source of truth for worktree discovery.
- Shared behavior is pulled downward into reusable helpers when a second command needs it.
  Example: `checkoutBranch` in `src/commands/checkout.zig` now underpins plain checkout plus PR/MR checkout.
- Interactive selection now follows the Go raw-input behavior more closely, while still keeping stdin fallback for tests and automation harnesses.

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
- `cleanup --dry-run` now previews merged-branch removals without deleting worktrees.
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

### Phase 12: richer Unix init and shellenv

- Expanded `wt init` with `--dry-run`, `--uninstall`, and `--no-prompt`.
- Made `init` update existing marked blocks instead of only appending once.
- Upgraded `wt shellenv` to include the JSON auto-cd guard plus bash/zsh completions.

Commit: `da36846`

### Phase 13: PowerShell shell integration

- Added `wt init [powershell|pwsh]`.
- Resolved the PowerShell profile path from `$PROFILE` first, then the standard profile fallback.
- Emitted PowerShell install blocks with `Invoke-Expression (& wt shellenv)`.
- Upgraded `wt shellenv` to emit PowerShell auto-navigation and completion output on Windows.

### Phase 14: examples catalog

- Added `wt examples`.
- Ported a text-mode examples catalog covering the current command set.

Commit: `2ee74d4`

### Phase 15: full parity for JSON and interactive flows

- Added root-level `--format json` parsing and JSON help/error envelopes.
- Added interactive selectors for `checkout`, `remove`, `pr`, and `mr`.
- Added confirmation prompts and `--force` support for `cleanup`.
- Added JSON output support across `version`, `list`, `config`, `checkout`, `create`, `remove`, `cleanup`, `migrate`, `pr`, `mr`, `prune`, `shellenv`, `info`, `init`, and `examples`.
- Added `wt config init --force`.
- Upgraded the examples catalog and help metadata to describe the now-implemented JSON and interactive behavior.

### Phase 16: exact parity harness and compatibility fixes

- Added `scripts/parity-harness.sh` to build both CLIs, run the Go e2e harness against each binary, report Zig-only failures relative to the Go baseline, and compare representative direct outputs for root help, version, shellenv, and unknown-command errors.
- Fixed repo-name resolution inside linked worktrees by preferring `git rev-parse --git-common-dir` over the current worktree path when deriving `repo.Name`.
- Fixed a lifetime bug in remote-derived repo metadata so parsed `origin` host/owner/name values no longer point into freed buffers.
- Tightened prompt behavior around `WT_USE_STDIN=1`, raw numeric selection, and cancellation semantics to better match the Go prompt layer.
- Fixed remaining parity mismatches in `checkout` fetch fallback, `cleanup --force` wording, `help` JSON command paths, and `examples` output/argument rejection.
- Verified `wt-zig` maintains harness parity with no Zig-only failures relative to the Go baseline.
- Current baseline snapshot in this environment: Go `Passed: 94`, `Failed: 4`, `Skipped: 4`; Zig `Passed: 97`, `Failed: 1`, `Skipped: 4`.
- Shared failure: `config/config_show_defaults`; current Go-only failures: `init/init_uninstall`, `status/status_shows_worktree_branch`, `status/status_shows_dirty_state`.

### Phase 17: done command

- Added `wt done [--force|-f]` to remove the current linked worktree.
- Detects which worktree the cwd is inside, skipping the main worktree.
- Reuses `removeWorktree` from `remove.zig` for hooks, git removal, and path cleanup.
- Emits the `wt navigating to:` marker so shell integration auto-cds back to the project root.

### Phase 18: done discoverability and release build compatibility

- Added `done` to root help, shellenv completion lists, and the examples catalog.
- Re-enabled `zig build release` by skipping background cache warming in single-threaded builds.

### Phase 19: Worktrunk-style switch command

- Added `wt switch` as the primary create/checkout/navigate command.
- Preserved legacy navigation names by mapping `wt cd`, `wt jump`, and `wt j` to `switch`; added `wt sw`.
- Reused the existing fuzzy worktree matcher for navigation.
- Added `wt switch --create|-c <branch> [--base <branch>]`.
- Added shortcuts: `^` for the main worktree, `@` for the current worktree, `-` for the worktree containing `OLDPWD`, `pr:N` for GitHub PRs, and `mr:N` for GitLab MRs.
- Updated shell completions, shellenv command lists, README, and local skill docs.

### Phase 20: Rich list mode

- Added `wt list --full` for Worktrunk-inspired local status inventory.
- Reused the `status` collector so `list --full` includes current marker, dirty/clean state, and upstream ahead/behind counts.
- Kept default `wt list` output unchanged and fast.

### Phase 21: safer remove/done branch cleanup

- `wt remove` now accepts multiple branches and, with no arguments, removes the current linked worktree when run inside one.
- `wt remove` and `wt done` safely delete the removed worktree branch by default when it is integrated with the default base.
- Added `--no-delete-branch` to retain branches and `--force-delete` / `-D` to delete a branch even when unsafe.
- JSON removal output now includes `branch_deleted`, `branch_delete_reason`, and `branch_retained_reason` metadata.
- `wt cleanup` keeps its prior worktree-only semantics by explicitly retaining branches.

### Phase 22: step diff

- Added `wt step diff [target] [-- <git diff args>...]`.
- Diffs from `git merge-base HEAD <target>` so output represents all changes since branching.
- Copies the real Git index to a temporary index and runs `git add --intent-to-add .` there so untracked files appear without mutating the real index.
- Forwards arguments after `--` directly to `git diff`, including `--stat`, `--name-only`, and pathspecs.
- Rejects JSON mode because output is intentionally raw git diff text.

### Phase 23: directive shell integration and switch execute

- Added directive-file shell integration alongside the existing `wt navigating to:` marker.
- Text navigation commands now write raw target paths to `WT_DIRECTIVE_CD_FILE` or `WORKTRUNK_DIRECTIVE_CD_FILE` when set.
- Shell wrappers create separate CD and EXEC temp files, consume raw CD directives without shell parsing, and source/evaluate EXEC directives after navigation.
- Added `wt switch --execute|-x <command> [-- <args>...]`.
- `--execute` writes to the EXEC directive file when shell integration is active; without a wrapper, it runs through `sh -c` in the target worktree.

### Phase 24: local merge workflow

- Added `wt merge [target] [--no-remove] [--no-ff] [--squash] [--rebase] [--push] [--no-hooks] [--message <message>]`.
- The command merges the current branch into the target branch, defaulting to the repository default base.
- Compatible defaults remain intentionally small: fast-forward merges are used by default, source cleanup runs after success, and pipeline steps do not run unless requested.
- `--no-ff` creates a merge commit when the target branch has an active worktree.
- `--rebase`, `--squash`, and `--push` are opt-in pipeline steps.
- After a successful merge, the source worktree is removed and the source branch is cleaned up by default.
- `--no-remove` keeps the source worktree and branch after integration.

### Phase 25: copy ignored and start hooks

- Added `wt step copy-ignored [--from <branch>] [--to <branch>] [--dry-run] [--force]`.
- The source defaults to the main worktree and the destination defaults to the current worktree.
- Ignored entries are discovered with `git ls-files --ignored --exclude-standard -o --directory -z`.
- `.worktreeinclude` can constrain copies to selected ignored paths, with built-in exclusions for VCS metadata and tool-state directories.
- `[step.copy-ignored] exclude = [...]` adds configurable gitignore-style exclusions, including negated exceptions such as `!cache/keep.sqlite`.
- Copies use the existing copy-on-write strategy ladder and preserve executable file permissions in the Zig fallback path.
- Added `pre_start` / `post_start` hooks. `pre_start` runs synchronously after a new worktree is created, while `post_start` is detached and logs output under the repository git common directory.

### Phase 26: aliases, step primitives, and discovery polish

- Added configured `[aliases]` dispatch. Aliases may be single strings or arrays, run through the shell, and append extra CLI args to the final command.
- Repo `.wt.toml` aliases override global aliases with the same name.
- Added `wt step commit`, `wt step squash`, `wt step rebase`, `wt step push`, and `wt step prune` as direct workflow primitives.
- Kept merge defaults compatible while exposing the optional pipeline flags in help, examples, and completions.
- Updated docs, examples, shell completions, and local assistant skills for alias, copy-ignored exclude, step primitive, merge pipeline, and prune-wrapper discoverability.

### Phase 27: hook and alias discoverability polish

- Added `hook` to shell completion catalogs and documented `wt hook show` for inspecting configured hooks.
- Added `config alias` to shell completion catalogs and documented `wt config alias show` / `wt config alias dry-run` for alias inspection and previewing commands.

### Phase 28: step template discoverability polish

- Added `step eval` and `step for-each` to shell completion catalogs.
- Documented `wt step eval [--dry-run] <template>` and `wt step for-each -- <command> [args...]`, including template variables in `for-each` command args.

## Verification Patterns

The port has been verified repeatedly with both unit/build checks and temp-repo smoke tests.

Standard checks:

```text
zig fmt --check build.zig build.zig.zon src/*.zig src/commands/*.zig src/git/*.zig
zig build
zig build test
zig build check
zig build smoke
zig build parity
zig build release          # stripped ReleaseSmall binary (~271 KB)
```

In the Codex sandbox, Zig needs explicit cache locations:

```text
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache
ZIG_LOCAL_CACHE_DIR=.zig-cache
```

Useful smoke-test patterns that already proved valuable:

- temp git repos for `checkout`, `create`, `remove`, and `cleanup`
- temp bare `origin` repos plus stub `gh` / `glab` executables for `pr` and `mr`
- temp home directories for `init` and temp config paths for `config init`
- stdin-driven interactive selection with `WT_USE_STDIN=1`
- disabling signing in temp repos with `git config commit.gpgsign false`
- running `./scripts/parity-harness.sh` to compare full e2e results against the Go baseline instead of assuming zero failing scenarios

## Important Learnings

- Do not assume absolute-path helpers exist in Zig stdlib; some convenience APIs are absent in Zig 0.15.2.
- Creating absolute parent directories needed explicit walking logic; `cwd.makePath` on absolute paths was not enough.
- Runtime config values must be copied into owned storage during load so temporary `EnvMap` allocations do not leak invalid references.
- Shared command behavior should move into reusable helpers only after a second command needs it.
  This kept the first slices simple while still allowing later reuse.
- For PR/MR checkout, `git fetch origin <branch>` is not enough for every workflow; fallback refspec fetches matter for fork-style refs.
- Root JSON output and command-local interactive behavior are easier to maintain when they are centralized in small shared helpers instead of duplicated inside each command.

## Remaining Work

No intentional feature gaps remain versus the original Go CLI command surface. Worktrunk-inspired post-parity features should be treated as new product work and documented as opt-in behavior when they change workflow defaults.
