# wt-zig Level-Up Guide

This guide is for a developer who already knows how to work in a codebase, has likely written Ruby before, and now needs to become effective maintaining `wt-zig`.

The goal is not to teach all of Zig. The goal is to teach enough Zig, enough of this application's structure, and enough of the local workflow that you can safely:

- fix bugs
- add or change commands
- refactor shared logic
- update docs and examples
- ship changes without breaking parity

## Start With The Right Mental Model

If you come from Ruby, the biggest adjustment is that Zig makes ownership, allocation, and failure paths explicit.

In Ruby, you often think:

- "I need this value"
- "I can reshape this object"
- "The runtime will manage the rest"

In this repo, you need to think:

- who owns this memory?
- which allocator produced it?
- who frees it?
- is this borrowed data or owned data?
- what error can happen here, and where should it be handled?

That sounds heavier than it feels in practice. Once you follow the repo patterns consistently, the code becomes predictable.

## What This Application Is

`wt-zig` is a Zig-native port of the Go `wt` CLI. It is already complete under the repo's practical-parity standard, which means:

- it covers the current command surface
- it passes local build and test checks
- `zig build parity` reports no Zig-only failures relative to the Go baseline

That matters because most work in this repo is not greenfield product design anymore. Most work is one of these:

- bug fix
- parity fix
- maintainability refactor
- docs improvement

## Read These First

Before touching code, read these in order:

1. [README.md](../README.md)
2. [architecture.md](architecture.md)
3. [port-status.md](port-status.md)
4. [comparison.md](comparison.md)

Use them differently:

- `README.md` tells you what the project is and how to run it.
- `architecture.md` tells you the rules and boundaries.
- `port-status.md` tells you how the port evolved and what verification means here.
- `comparison.md` explains why the Zig version is shaped differently from the Go version.

## How The Repo Is Organized

These are the important layers:

- `src/app.zig`
  Root dispatcher. Parses root flags, loads config, builds output context, dispatches commands.
- `src/command.zig`
  Command registry and help metadata.
- `src/output.zig`
  Shared text/JSON output behavior.
- `src/config.zig`
  Public config loading API.
- `src/config_support.zig`
  Config path resolution, config parsing, default-config writing.
- `src/path.zig`
  Worktree strategy and path rendering.
- `src/fs.zig`
  Shared file and directory helpers.
- `src/process.zig`
  Shared wrapper for `std.process.Child.run`.
- `src/git/`
  Git-facing helpers for repo discovery, worktree listing, and PR/MR lookups.
- `src/commands/*.zig`
  Thin command entrypoints.
- `src/commands/*_support.zig`
  Extracted command-specific support logic when a command grows too large.

The design intent is simple:

- command files orchestrate
- shared helpers do reusable work
- support modules hold logic that was too big to leave inline

If you are deciding where code belongs, prefer that model.

## The Most Important Local Rule

Keep command entrypoints thin.

Good command file responsibilities:

- parse arguments
- call shared logic
- map errors to user-facing messages
- emit text or JSON output

Bad command file responsibilities:

- owning a large parsing subsystem
- owning lots of process invocation details
- mixing argument parsing, planning, mutation, and rendering in one long file

If a command gets large, split by behavior. In this repo, the preferred seams are:

- parsing
- planning
- filesystem mutation
- rendering

## Zig Habits That Matter Here

### 1. Allocation is part of the design

You will see `allocator` passed almost everywhere. That is not noise; that is how ownership stays visible.

Follow these rules:

- use the allocator passed into the current context or function
- free what you allocate unless ownership is intentionally transferred
- prefer `defer` and `errdefer` immediately after allocation
- avoid hiding ownership in convenience wrappers unless the repo already does that

If you are unsure whether memory is owned, inspect whether the value was created with `dupe`, `allocPrint`, `path.join`, `toOwnedSlice`, or another allocating API.

### 2. Borrowed slices are normal

A lot of Zig code passes `[]const u8` around. Sometimes that slice is borrowed from an existing buffer, sometimes it is newly owned.

Be careful when:

- trimming strings
- splitting buffers into lines
- returning slices derived from temporary buffers

If the source buffer will be freed, duplicate the slice before returning it.

### 3. Errors are values, not exceptions

Zig uses error unions and `try` instead of exceptions.

In practice:

- use `try` when the caller should decide what to do
- use `catch` when you are at a boundary and need to map to user-facing behavior
- map domain failures into stable CLI messages in command entrypoints

This is similar to being disciplined with Ruby exception boundaries, except the language forces you to be explicit.

### 4. Prefer explicit structs over loose hashes

Ruby often encourages passing around flexible hashes or objects. In Zig, small named structs are usually better. They make intent, ownership, and output shape clearer.

This repo already uses that pattern in places like output context, config types, migrate plan items, and command outcomes. Continue that pattern.

## How Output Works

`src/output.zig` owns the text-vs-JSON distinction.

You should not invent ad hoc JSON or output behavior in a command if the shared output layer already models it.

General rule:

- use text mode for human-readable messages
- use JSON mode only through shared helpers and stable payload structs

If a command has both modes, keep the business logic shared and keep only the rendering different.

## How Process Execution Works

Use `src/process.zig` for captured subprocess execution.

Do not scatter new `std.process.Child.run` calls across commands unless there is a very good reason. The shared helper exists so that:

- stdout/stderr handling stays consistent
- success checks stay consistent
- trimming logic stays consistent
- refactors remain easy

If you need a new process pattern, extend the shared helper rather than cloning a command-local variant.

## How Config Works

Treat `src/config.zig` as the public entrypoint and `src/config_support.zig` as its internal support layer.

The important behavior:

- config path resolution follows the repo's precedence rules
- parsed file values are copied into owned storage
- env overrides are applied after file values
- commands consume the resolved config, not raw file state

If you are fixing a config bug, first decide which layer it belongs to:

- path resolution bug
- parsing bug
- precedence bug
- rendering/display bug

That will usually tell you which file to edit.

## How Git And Worktree Logic Works

The source of truth for worktree state is `git worktree list --porcelain`.

That is important. Do not fall back to shell text parsing when the structured porcelain output already exists.

Typical responsibilities:

- `src/git/worktree.zig`
  parse current worktrees
- `src/git/repo.zig`
  repo discovery, branch lists, merged branches, remote parsing, repo metadata
- `src/git/pr.zig`
  PR/MR lookup and open item listing

If you need to change a command that operates on git state, look for the helper first before changing the command body.

## How To Fix A Bug Safely

Use this sequence:

1. Reproduce the bug locally.
2. Find the layer that owns the behavior.
3. Add or update a focused test near that logic.
4. Change the smallest layer that can truly fix it.
5. Run the verification ladder.

Common mapping:

- wrong help or JSON envelope: `src/output.zig` or command rendering
- wrong config resolution: `src/config.zig` or `src/config_support.zig`
- wrong path strategy behavior: `src/path.zig`
- wrong git/worktree discovery: `src/git/`
- wrong CLI flow but right helper behavior: command file

If the behavior is supposed to match the Go implementation, compare with [`wt`](https://github.com/timvw/wt) before deciding what "correct" means.

## How To Add A Small Feature

For a normal feature, follow the repo workflow first:

- `/start-feature <description>`
- implementation
- `/close-feature`

Implementation checklist:

1. Add or update command metadata if the surface changes.
2. Put shared behavior in the right helper layer.
3. Keep command entrypoints thin.
4. Add tests near the changed logic.
5. Update docs if the user-facing behavior changed.
6. Run verification.

If you are tempted to put lots of new logic directly into a command file, stop and ask whether it belongs in:

- `src/process.zig`
- `src/config_support.zig`
- a `src/git/*` helper
- a `src/commands/*_support.zig` module

## How To Write Good Docs Here

This repo already has several kinds of docs:

- status/handoff docs
- architecture docs
- comparison docs
- README usage docs

When adding docs:

- make them serve a distinct purpose
- avoid repeating entire sections from existing docs
- link related docs instead of copying them
- keep README discoverable and high-level
- keep implementation detail in `docs/`

If you add a new maintainership or workflow doc, add a short README pointer so future developers can find it.

## The Verification Ladder

Before shipping code changes, run:

```text
zig fmt --check .
zig build
zig build test
zig build check
zig build parity
zig build release          # stripped ReleaseSmall binary (~272 KB)
```

In the Codex sandbox, use the explicit cache dirs already documented in the repo:

```text
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache
ZIG_LOCAL_CACHE_DIR=.zig-cache
```

`zig build parity` matters more than a normal unit test pass when behavior changes, because this repo’s completion standard is parity against the Go baseline, not just internal consistency.

## How To Think About Parity

Not every change should chase byte-for-byte identity, but any user-visible behavior change should be assumed suspicious until verified.

When touching behavior:

- compare with the Go implementation
- preserve current accepted baseline behavior
- treat new Zig-only parity failures as regressions

On this host, two scenario failures are inherited from the Go baseline. Those are not open Zig regressions unless the baseline changes.

## Ruby-To-Zig Translation Tips

If you think in Ruby, these translations help:

- Ruby object with implicit lifetime -> Zig struct plus explicit allocator and cleanup
- Ruby exception boundary -> Zig `try`/`catch` boundary
- Ruby string manipulation on owned strings -> Zig slices that may or may not own memory
- Ruby "just shell out here" -> Zig helper in `process.zig` or `src/git/`
- Ruby service object -> Zig helper module or small function group

The skill to build is not "write Zig like Ruby." It is "bring your design instincts from Ruby, but express them with Zig's explicit ownership and smaller abstractions."

Good Ruby instincts that still apply:

- name things clearly
- isolate responsibilities
- keep side effects near boundaries
- write readable code first
- refactor repeated logic into a stable abstraction only after it is truly repeated

## A Good First Reading Path Through Code

If you want to learn this repo quickly, read in this order:

1. `src/main.zig`
2. `src/app.zig`
3. `src/output.zig`
4. `src/command.zig`
5. `src/config.zig`
6. `src/path.zig`
7. one simple command like `src/commands/version.zig`
8. one medium command like `src/commands/create.zig`
9. one extracted command pair like `src/commands/init.zig` plus `src/commands/init_support.zig`
10. one git helper like `src/git/repo.zig`

That progression gives you:

- entrypoint
- dispatch
- shared output
- config
- path logic
- simple command shape
- medium command shape
- extracted-support pattern
- git integration

## What Not To Do

Avoid these:

- adding new mutable global state
- using `std.heap.page_allocator` in normal runtime paths
- scattering new raw `Child.run` usage through commands
- returning borrowed slices from freed buffers
- mixing parsing, planning, mutation, and rendering in one long function
- making docs changes that silently drift from actual behavior

## Final Rule Of Thumb

When in doubt, make the code more explicit, not more clever.

In this repo, good Zig style means:

- visible ownership
- thin command boundaries
- stable helper layers
- small, named result structs
- shared output behavior
- parity-first verification

If you preserve those properties, you will usually be moving the codebase in the right direction.
