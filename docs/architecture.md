# wt-zig Architecture

This repo is meant to be a maintainable Zig CLI, not just a direct feature port.

## Core Rules

- Keep command entrypoints thin.
- Pass execution state explicitly.
- Keep allocator flow visible.
- Move shared logic down only after a second real use case appears.
- Keep text and JSON behavior consistent through shared output helpers.

## Execution Model

`src/app.zig` is the root dispatcher. It parses root flags, loads config once, builds an explicit output context, and passes that context into command entrypoints.

That context is the source of truth for:

- allocator ownership for command rendering
- output mode selection
- JSON envelope generation

Avoid reintroducing mutable global state for formatting or command behavior.

## Module Boundaries

Preferred layering:

- `src/commands/*.zig`: command-local arg parsing and user-facing orchestration
- shared helpers under `src/`: config, fs, output, path, process, prompt, hooks
- git-specific shell/process interactions under `src/git/`

When shared behavior becomes real infrastructure, give it a stable helper instead of repeating ad hoc command logic. Current examples:

- `src/process.zig` is the single place that wraps `std.process.Child.run`
- `src/config_support.zig` holds config path/file parsing and default-config writing
- `src/copy_files.zig` holds file-copy logic for the `[copy_files]` config feature
- `src/commands/init_support.zig` holds shell detection and shell-block file operations
- `src/commands/migrate_support.zig` holds migrate planning and execution

When a command grows too large, split by behavior, not by arbitrary file size. Good seams are:

- parsing
- planning
- filesystem mutation
- rendering

## Allocators and IO

- Runtime command paths should use the allocator passed into the current context.
- Avoid `std.heap.page_allocator` in normal command execution.
- Prefer shared helpers for file creation and absolute directory setup so ownership and behavior stay uniform.

## Output Conventions

- Text mode remains human-oriented and may include navigation markers.
- JSON mode must stay machine-readable and must not depend on shell wrapper behavior.
- Usage and error messages should flow through shared output helpers so command behavior stays aligned.

## Verification Ladder

Use this sequence locally before shipping changes:

```text
zig fmt --check .
zig build check
zig build parity
```

`zig build parity` is the reference verification step for behavior changes because it compares the Zig CLI against the Go baseline instead of assuming zero failing scenarios.
