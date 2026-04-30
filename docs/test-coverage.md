# Test Coverage Matrix

This matrix tracks how thoroughly each major `wt-zig` area is covered by unit tests.

Legend:
- `High`: core behavior and key edge cases covered
- `Medium`: happy path covered; important edge cases still missing
- `Low`: limited direct tests

| Area | Coverage | Notes |
| --- | --- | --- |
| Root dispatch and command registry (`app.zig`, `command.zig`, `aliases.zig`) | Medium | Built-in and configured alias resolution, root arg parsing, and dispatch-level unknown-command behavior are covered; deeper dispatch branches still rely mostly on command-level tests and smoke coverage. |
| Output and JSON envelope helpers (`output.zig`) | High | Serializer/envelope behavior is well covered across scalar, optional, nested, and slice types. |
| Config, aliases, and path resolution (`config*.zig`, `aliases.zig`, `path.zig`) | High | Precedence, alias parsing/merging, copy-ignored excludes, defaults, rendering, and cleanup behavior are directly tested. |
| Copy and filesystem safety (`copy_files.zig`, `cow_copy.zig`, `trash.zig`) | High | Traversal/symlink guards, strategy fallthrough, and copy behavior are covered. |
| Git parsing helpers (`git/*.zig`) | Medium | Parsing and repo helper behavior are tested; PR/MR missing-CLI failure mappings are covered; other command-level git-failure mappings are mostly validated via parity harness. |
| Hook behavior (`hooks.zig`) | High | Hook env construction and pre/post/start failure handling are covered. |
| Approval management for configured command strings | High | Unit coverage verifies project alias blocking, project-scoped approval parsing, and approval persistence; smoke coverage exercises unapproved markers, PTY-backed prompt accept/reject flows, and explicit approval add/show before running repo-local aliases. |
| Multi-worktree relocation (`wt step relocate`) | High | Parser coverage plus fixture smoke coverage verify branch-filtered dry-run, swap/cycle relocation, clobber backups, dirty skips, and locked skips with real git worktrees. |
| Branch promotion (`wt step promote`) | Medium | Fixture smoke coverage verifies promote/restore branch swaps and gitignored file/directory staging across both worktrees. |
| Command argument parsing (`commands/*`) | Medium | Most commands cover parse helpers; some run-path validation branches remain untested. |
| Completion command (`commands/completion.zig`) | High | Help, bash output, unknown-shell behavior, and multi-arg usage errors are covered in text and JSON modes; command catalogs expose `hook`, `config alias`, and step template discoverability. |
| Shellenv command (`commands/shellenv.zig`) | High | Generated shell blocks, JSON response path, and extra-arg usage errors are covered; shell catalogs mirror `hook`, `config alias`, approval, promote, and relocate discoverability. |
| Interactive command runtime flows (`switch/checkout/remove/pr/mr/ui`) | Medium | `wt switch` shortcut/alias navigation, no-match behavior, `wt done` removal, and `wt ui` JSON rejection are covered; external PR/MR and gum-driven UI flows still lean on parity/e2e/manual checks. |

## Newly Added In This Pass

1. Root parse: missing `--format` value returns `error.MissingFormatValue`.
2. Root parse: unsupported `--format` value returns `error.UnsupportedFormatValue`.
3. `wt completion` unknown shell in text mode returns exit `1` with stderr message.
4. `wt completion` unknown shell in JSON mode returns exit `1` with JSON error envelope.
5. `wt shellenv` JSON mode returns success envelope with the expected note.
6. `wt step copy-ignored` parsing, ignored-entry parsing, `.worktreeinclude` filtering, skip/force copying, and symlink copy helpers.
7. Start hook parsing, lookup, info display, and pre/post-start execution behavior.
8. Configured alias parsing/merging and shell-quoted final-argument appending.
9. `wt step commit`, `squash`, `rebase`, `push`, and `prune` parsing or wrapper coverage.
10. Merge pipeline flag parsing for opt-in `--squash`, `--rebase`, `--push`, `--no-hooks`, and `--message`.
11. Fixture-based CLI smoke coverage for configured aliases, `wt step commit`, `wt step squash`, and `wt merge --rebase --no-remove`.
12. Completion/shellenv command-catalog checks for `hook`, `config alias`, and `step eval` / `step for-each` discoverability.
13. Approval-management behavior for configured alias and hook command strings, including saved approvals and fixture-smoke approval setup.
14. `wt step relocate` parser coverage plus fixture-smoke branch-filter and swap/cycle relocation.
15. `wt step promote` dirty-worktree refusal and ignored-file staging/swap parity.
16. `wt shellenv` extra-arg usage errors in text and JSON modes.
17. `wt completion` multi-arg usage errors in text and JSON modes.
18. `wt ui` JSON-mode rejection before gum lookup.
19. Fixture-based smoke coverage for `wt switch` shortcuts/aliases and no-match text/JSON behavior.
20. Fixture-based smoke coverage for `wt done` removing the current linked worktree and navigating back.
21. PTY-backed smoke coverage for approval prompt rejection and acceptance.
22. Fixture-based smoke coverage for `wt step relocate --clobber` backup behavior.
23. Fixture-based smoke coverage for `wt step relocate` dirty and locked worktree skips.
24. Dispatch-level unknown-command behavior in text and JSON modes through `app.run`.
25. PR/MR missing-platform-CLI error mappings for text and JSON modes.

## Next 5 High-Value Tests

1. Restore or configure the Go baseline checkout so `zig build parity` can run locally again.
2. PR/MR success-path fixture coverage with stub `gh` and `glab` binaries.
3. Gum-powered `wt ui` jump/remove smoke coverage with a stub `gum` binary.
4. JSON envelope coverage for more command-level git failure paths.
5. Cross-shell validation for generated shellenv completion blocks beyond static string checks.
