# Changelog

## Unreleased

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
