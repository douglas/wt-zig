# Test Coverage Matrix

This matrix tracks how thoroughly each major `wt-zig` area is covered by unit tests.

Legend:
- `High`: core behavior and key edge cases covered
- `Medium`: happy path covered; important edge cases still missing
- `Low`: limited direct tests

| Area | Coverage | Notes |
| --- | --- | --- |
| Root dispatch and command registry (`app.zig`, `command.zig`) | Medium | Alias resolution is covered; root arg parsing now covers `--format` errors; dispatch-level unknown-command behavior still relies mostly on parity/e2e. |
| Output and JSON envelope helpers (`output.zig`) | High | Serializer/envelope behavior is well covered across scalar, optional, nested, and slice types. |
| Config and path resolution (`config*.zig`, `path.zig`) | High | Precedence, parsing, defaults, rendering, and cleanup behavior are directly tested. |
| Copy and filesystem safety (`copy_files.zig`, `cow_copy.zig`, `trash.zig`) | High | Traversal/symlink guards, strategy fallthrough, and copy behavior are covered. |
| Git parsing helpers (`git/*.zig`) | Medium | Parsing and repo helper behavior are tested; command-level git-failure mappings are mostly validated via parity harness. |
| Hook behavior (`hooks.zig`) | High | Hook env construction and pre/post failure handling are covered. |
| Command argument parsing (`commands/*`) | Medium | Most commands cover parse helpers; some run-path validation branches remain untested. |
| Completion command (`commands/completion.zig`) | Medium | Help and bash output covered; unknown-shell behavior (text/json) now covered. |
| Shellenv command (`commands/shellenv.zig`) | Medium | Generated shell blocks covered; JSON response path now covered. |
| Interactive command runtime flows (`checkout/remove/pr/mr/ui/jump`) | Medium | Many helpers are covered; interactive/runtime command behavior still leans on parity/e2e. |

## Newly Added In This Pass

1. Root parse: missing `--format` value returns `error.MissingFormatValue`.
2. Root parse: unsupported `--format` value returns `error.UnsupportedFormatValue`.
3. `wt completion` unknown shell in text mode returns exit `1` with stderr message.
4. `wt completion` unknown shell in JSON mode returns exit `1` with JSON error envelope.
5. `wt shellenv` JSON mode returns success envelope with the expected note.

## Next 5 High-Value Tests

1. `wt shellenv` extra-arg usage error in text and JSON modes.
2. `wt completion` multi-arg usage error in text and JSON modes.
3. `wt ui` JSON-mode rejection path (`wt ui is interactive; run without --format json`).
4. `wt jump` command-level usage/no-match behavior (text + JSON) with a temporary git worktree fixture.
5. JSON explicit-argument guard tests for interactive commands (`checkout`, `remove`, `pr`, `mr`).
