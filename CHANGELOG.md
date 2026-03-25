# Changelog

## 0.4.1 — 2026-03-25

### Fixed

- Interactive prompts (`checkout`, `remove`, `pr`, `cleanup`) now accept digit input — buffered stderr was not flushed before reading from `/dev/tty`, causing the prompt to appear but keystrokes to be silently dropped

### Changed

- `wt jump` now requires a query argument (per vibe spec); calling it with no arguments now prints a usage error instead of showing an interactive picker of all worktrees
- `wt jump` prints a creation hint (`hint: run 'wt checkout <query>' to create one`) when no worktree matches the query

## 0.4.0 — 2026-03-25

### Added

- `wt jump <query>` (alias `j`) — navigate to an existing worktree by fuzzy branch name; 5-tier matching hierarchy: exact → case-insensitive → word-boundary → substring → fuzzy subsequence
- `[copy_files] dirs` config key — CoW-copy directories (e.g. `node_modules`, `target/`) from the main worktree into new worktrees
- `[copy_files] strategy` config key — pin copy strategy (`native_clone`, `clone`, `rsync`, `standard`); auto-detected from the actual worktree filesystem if omitted; `wt info` shows effective strategy
- 4-tier copy strategy hierarchy (vibe-inspired): `native_clone` (clonefile/FICLONE) → `clone` (cp --reflink=auto/cp -c) → `rsync` → `standard` (copy_file_range → read+write); each tier falls through to the next on failure
- Disk cache warming — after worktree creation, a detached background thread walks the new worktree and `stat(2)`s every file to prime the OS page/metadata cache so subsequent tool calls are served from memory
- Fast trash-based removal — `wt remove` now uses an atomic `rename(2)` to the platform trash directory (`~/.Trash` on macOS, `~/.local/share/Trash/files/` on Linux) followed by `git worktree prune`; falls back to `git worktree remove` on cross-device rename (EXDEV)

### Changed

- `git worktree list --porcelain` is now called exactly once per `create`/`checkout`/`remove` invocation (was called twice — once inside `getRepoInfo` and once in the command itself)

## 0.3.0 — 2026-03-23

### Added

- GitHub Actions CI workflow — runs build + test on push to main and PRs
- GitHub Actions release workflow — cross-compiles for Linux (amd64/arm64) and macOS (Intel/Apple Silicon), creates GitHub release with tarballs, and publishes AUR package automatically on tag push

## 0.2.1 — 2026-03-23

### Security

- Fixed TOCTOU race condition in copy_files symlink detection — now uses lstat via `fstatat(AT.SYMLINK_NOFOLLOW)` for atomic detection
- Added root path resolution before bounds checking in copy_files to prevent symlinked parent directory bypass
- Added `isChildPath` bounds validation to reject paths escaping source/destination roots
- Moved boundary validation before `deleteTreeAbsolute` in worktree path cleanup
- Added `sanitizeForTerminal` to strip control characters from all untrusted terminal output (branch names, git stderr, user input) across 12 command files
- Added config file regular-file validation to prevent hangs on FIFOs/devices
- Replaced fragile realpath-comparison symlink check with proper lstat in shell config installation
- Fixed PowerShell `Set-Location` to use `-LiteralPath` preventing special character interpretation
- Added `--` end-of-options separator in `git worktree add` commands to prevent flag injection
- Used `--merged=<base>` format in `git branch` to prevent base branch flag injection
- Added security documentation about quoting hook variables in config template

## 0.2.0 — 2026-03-20

### Added

- `[copy_files]` config section — automatically copy files from the main worktree into new worktrees (e.g. `.env`, `config/local.yml`), with per-repo overrides via `[copy_files.<repo-name>]` subsections
- `zig build release` step — produces a stripped ReleaseSmall binary (~251 KB)
- Custom streaming JSON serializer in `output.zig` — writes directly to the writer with no allocations
- `output.emitNavigateTo` helper — shared navigation marker output across commands
- `config.testing_defaults` constant — reduces boilerplate in test config struct literals

### Changed

- All I/O now uses concrete `*std.Io.Writer` instead of comptime-generic `anytype`, eliminating monomorphization and reducing binary size
- Hook dispatch (`getHooks`, `setHookField`) uses `inline for` + `@field` over `std.meta.fields` — adding a hook now only requires a new field in the `Hooks` struct
- Scalar config key matching uses else-if chain for early exit
- Removed unnecessary `@as` casts in test assertions (Zig 0.15 `expectEqual` accepts `comptime_int` directly)
- Release build uses full optimization flags (single_threaded, no unwind tables/frame pointer/stack protector/valgrind)
- Replaced `std.json.Stringify` with zero-allocation streaming serializer, eliminating the Stringify module from the binary
- Converted `print("{s}", .{msg})` patterns to `writeAll(msg)` across commands, avoiding format-string parsing overhead
- Removed `@constCast` from test data in `cleanup.zig` — uses mutable array copies instead

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
