# wt vs wt-zig

This document compares the original Go implementation ([`wt`](https://github.com/timvw/wt)) with the Zig port in this repository.

## Status

`wt-zig` is complete under this repo's practical-parity standard:

- full current command-surface coverage
- `zig build` and `zig build test` pass
- `./scripts/parity-harness.sh` reports no Zig-only failures relative to the Go baseline

On the maintained Linux host baseline, the latest parity run (2026-04-25) reports:

- Go harness: `Passed: 95`, `Failed: 3`, `Skipped: 4`
- Zig harness: `Passed: 97`, `Failed: 1`, `Skipped: 4`

The shared remaining failure is inherited from the Go baseline in this environment and is not treated as an open `wt-zig` regression:

- `config/config_show_defaults`

The current Go-only failures in this environment are:

- `status/status_shows_worktree_branch`
- `status/status_shows_dirty_state`

## High-Level Difference

The Go version is the original upstream-style implementation. It has the stronger packaging and ecosystem story today, and it is the more familiar codebase for typical CLI contributors.

The Zig version is a native port with the same practical feature set, but it uses a different internal architecture. Instead of a Cobra-driven command tree, it is organized around a native dispatcher plus focused shared modules for config, output, prompts, path resolution, git integration, and command handlers.

## What Is Better In Go

- Broader distribution story. The Go repo already documents Homebrew, Scoop, WinGet, Linux packages, and `go install`.
- More familiar stack for most contributors. Go, Cobra, and common Go CLI tooling are easier to approach for a wider group of developers.
- Smaller default binary. The Go build is about `6.9M`; the Zig debug build is about `18M` (though `zig build release` produces a ~271 KB stripped binary).
- Better choice if one implementation needs to remain the canonical external reference.

## What Is Better In Zig

- More explicit internal separation of concerns. Shared logic lives in dedicated modules instead of being spread across a framework-shaped command tree.
- Stronger parity verification loop. This repo includes `scripts/parity-harness.sh`, which builds both CLIs, runs the Go e2e suite against both, and flags Zig-only regressions.
- Lower third-party dependency surface at the project level. The Zig project metadata is minimal compared with the Go module dependency set.
- Better fit if this repo is the one you want to evolve deliberately, because the design decisions and parity criteria are documented directly in [port-status.md](port-status.md).

The Zig version also includes features not present in Go `wt`:

- `wt done [--force|-f]` — remove the current linked worktree and navigate back to the project root, without needing to name the branch or use an interactive selector
- `wt jump <query>` / `wt j <query>` — fuzzy navigation to a linked worktree by branch name
- `wt ui [jump|remove] [--force|-f]` — gum-powered interactive jump/remove UI

The later maintenance passes made that Zig advantage more concrete:

- output behavior now flows through an explicit runtime context instead of mutable global state
- process execution now has a single shared wrapper in `src/process.zig`
- larger command implementations were split into support modules instead of continuing to grow inline
- all I/O uses concrete `*std.Io.Writer` instead of comptime-generic `anytype`, eliminating monomorphization bloat
- hook dispatch uses `inline for` + `@field` over `std.meta.fields`, so new hooks only need a struct field
- maintainer-facing docs now include both [architecture.md](architecture.md) and [LEVELUP.md](LEVELUP.md)

That means `wt-zig` is no longer just "the port in Zig". It is also the codebase with the more intentional internal maintenance story.

## When To Use Which

Use Go `wt` when:

- you want the original implementation
- you care about existing packaging and install channels
- you want the most contributor-friendly stack
- you want the implementation that best matches the public upstream posture

Use Zig `wt-zig` when:

- you want the port that has been hardened locally with the parity harness
- you prefer the current modular architecture
- you want to keep iterating in Zig rather than in Go
- you are operating primarily on the same environment where parity was verified

A practical default is:

- use `wt-zig` as the daily driver
- keep Go `wt` as the reference implementation and fallback

## Maintenance Tradeoffs

If the question is "which is easier for me to maintain in this repo?", the answer is probably `wt-zig`.

Reasons:

- the Zig code is already structured around reusable layers
- the parity harness gives a direct regression signal against the Go implementation
- the repo handoff notes document the architecture and maintenance boundaries
- the latest refactor pass extracted stable support seams for config, process execution, `init`, and `migrate`
- there is now an onboarding path for maintainers moving from Ruby-style application development into Zig, via [LEVELUP.md](LEVELUP.md)

If the question is "which is easier for the average outside contributor to maintain?", the answer is probably `wt`.

Reasons:

- Go is more widely used
- Cobra-style CLIs are familiar
- the Go toolchain and dependency model are more common in day-to-day contributor environments

## Drawbacks

Go drawbacks:

- larger dependency surface through Cobra, pflag, YAML, PTY, and terminal support packages
- more framework-driven command structure
- weaker parity-specific instrumentation than this Zig repo now has

Zig drawbacks:

- larger debug binary than Go (though `zig build release` produces a much smaller stripped binary)
- smaller contributor pool
- more stdlib/toolchain sharp edges, especially in Zig `0.15.2`
- practical parity does not mean byte-for-byte identical output in every edge case
- some maintainability wins in Zig come from being disciplined about ownership and helper boundaries; that is powerful, but it demands more care than a typical Ruby or Go CLI codebase

## What We Learned During The Port

The biggest practical lesson is that the long-term value of the Zig version is not just raw feature parity. It is that the repo now makes several important things explicit:

- where output mode is decided
- where process execution is normalized
- where config parsing/path logic lives
- where command orchestration stops and support logic begins

That makes `wt-zig` easier to reason about when debugging behavior regressions.

The second big lesson is that parity needs tooling, not confidence. The parity harness ended up being one of the strongest parts of the Zig repo because it turned "I think this matches Go" into a repeatable check.

The third big lesson is that Zig benefits from small support modules once a command crosses a certain size. Leaving everything inline works for early porting speed, but extracted support modules are a better end state for a maintained codebase.

## Recommendation

If you want one implementation to use every day on this machine, use `wt-zig`.

If you want one implementation to treat as the canonical public-facing or contributor-default codebase, keep using `wt`.

If you want to keep both:

- `wt` remains the upstream-style reference
- `wt-zig` remains the maintained parity port and likely the better place for controlled internal evolution
