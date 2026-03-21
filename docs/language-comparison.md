# Go vs Rust vs Zig for CLI Tools

A language-level comparison grounded in real data from two `wt` implementations (Go and Zig) plus projected characteristics for a hypothetical Rust port.

For Go-vs-Zig implementation specifics, see [comparison.md](comparison.md).

## Project at a Glance

| Metric | Go (`wt`) | Zig (`wt-zig`) | Rust (projected) |
|---|---|---|---|
| Impl lines | ~4,000 | ~6,900 | ~4,000–5,000 est. |
| Test lines | ~11,200 | (inline, 75 test blocks) | — |
| Source files | 13 impl + 18 test | 35 | ~15–20 est. |
| External deps | 3 direct, 7 total | 0 | ~5 direct, 40–50 transitive |
| Binary (stripped) | 4.7 MB | 251 KB | ~1–3 MB est. |
| Build (clean) | ~3 s | ~4 s (release) / ~1 s (debug) | ~90–120 s est. |
| Test count | 258 functions | 75 blocks | — |
| Error-handling sites | 276 (`if err != nil`) | 909 (`try`) + 29 (`errdefer`) | — |

All measurements taken on the same Linux host (go 1.26, zig 0.15.2). Rust estimates are based on ecosystem analysis of `clap` + `serde` + `toml` + `anyhow` CLI stacks.

## Binary Size

| Build | Go | Zig | Rust (est.) |
|---|---|---|---|
| Debug / default | 6.9 MB | ~18 MB | ~10–20 MB |
| Stripped / release | 4.7 MB (`-ldflags="-s -w"`) | 251 KB (`ReleaseSmall`, stripped, single-threaded) | ~1–3 MB (`--release`, stripped) |

**Why the differences:**

- **Go** bundles the garbage collector runtime, reflection metadata, and Cobra's command tree. Stripping symbols helps but the GC runtime is irreducible.
- **Zig** has no runtime. Zero external dependencies means no dead code from libraries. `ReleaseSmall` with aggressive flags (no stack protector, no unwind tables, no error tracing) produces a binary barely larger than the machine code itself.
- **Rust** has no GC, but `clap` (argument parsing) and `serde` (serialization) are substantial generic-heavy crates that monomorphize into real code. A `no_std` approach could go lower but would lose the ergonomic crate ecosystem.

Zig release build flags used:

```zig
.optimize = .ReleaseSmall,
.strip = true,
.single_threaded = true,
.unwind_tables = .none,
.omit_frame_pointer = true,
.error_tracing = false,
.stack_protector = false,
.stack_check = false,
.valgrind = false,
```

## Dependency Philosophy

**Go — curated direct deps, moderate transitive surface:**

```
require (
    github.com/creack/pty v1.1.24
    github.com/spf13/cobra v1.10.2
    gopkg.in/yaml.v3 v3.0.1
)
// + 4 indirect: mousetrap, pflag, sys, term
```

Three direct dependencies is restrained for a Go CLI. Cobra pulls in pflag and mousetrap; the PTY and YAML libraries are leaf deps. Total attack surface is manageable.

**Zig — zero external dependencies:**

```zig
// build.zig.zon
.paths = .{ "build.zig", "build.zig.zon", "README.md", "src" },
// No .dependencies field
```

Everything comes from `std` or is written from scratch: custom TOML parser, JSON streaming serializer, argument dispatcher. This is the most extreme dependency posture possible.

**Rust — rich ecosystem, deep transitive tree:**

A typical Rust CLI pulls in `clap` + `serde` + `toml` + `anyhow`. These are excellent crates, but:
- `clap` alone brings `clap_derive`, `clap_builder`, `clap_lex`, and proc-macro infrastructure
- `serde` + `serde_derive` pull in `syn`, `quote`, `proc-macro2`
- Total transitive count: 40–50 crates is typical

The Rust ecosystem enforces semver and has `cargo audit`, but the surface area is real. Every transitive dep is code that runs in your build and ships in your binary.

**Supply chain comparison:**

| | Go | Zig | Rust |
|---|---|---|---|
| Deps to audit | 7 | 0 | 40–50 |
| Lock file | `go.sum` | none needed | `Cargo.lock` |
| Audit tooling | `govulncheck` | N/A | `cargo audit` |
| Update burden | low | none | moderate |

## Error Handling

**Go — explicit but verbose:**

```go
info, err := getRepoInfo()
if err != nil {
    return fmt.Errorf("failed to get repo info: %w", err)
}
listed, err := listWorktrees()
if err != nil {
    return fmt.Errorf("failed to list worktrees: %w", err)
}
```

276 `if err != nil` blocks in the `wt` codebase. Every fallible call needs two lines of ceremony. Error wrapping with `%w` is idiomatic but manual.

**Zig — error unions with `try` and `errdefer`:**

```zig
var info = try git_repo.getRepoInfo(allocator);
defer git_repo.freeRepoInfo(allocator, &info);

var listed = worktree.list(allocator, stderr) catch return error.GitCommandFailed;
defer listed.deinit(allocator);
```

909 `try` sites and 29 `errdefer` sites in `wt-zig`. `try` propagates errors in one keyword. `errdefer` runs cleanup only on error paths — a pattern neither Go nor Rust has natively. The `catch` with `switch` allows inline error discrimination:

```zig
const outcome = checkoutBranch(allocator, cfg, branch, .{}, stderr) catch |err| switch (err) {
    error.BranchDoesNotExist => { /* handle */ },
    error.HookCommandFailed => { /* handle */ },
    else => return err,
};
```

**Rust — the most ergonomic:**

```rust
let info = get_repo_info()?;
let listed = list_worktrees()
    .map_err(|_| Error::GitCommandFailed)?;
```

Rust's `?` operator is the gold standard for error propagation. Chainable with `.map_err()`, `.context()` (anyhow), or `.with_context()`. The type system enforces exhaustive error handling. The trade-off is that designing good error types requires upfront thought.

**Summary:**

| | Go | Zig | Rust |
|---|---|---|---|
| Propagation | `if err != nil { return err }` | `try` | `?` |
| Error-path cleanup | manual / `defer` | `errdefer` | `Drop` trait |
| Discrimination | type switch | `catch \|err\| switch` | `match` |
| Ergonomics | verbose but clear | concise with unique `errdefer` | most ergonomic |

## Memory Management

**Go — garbage collected:**

Simplest developer experience. Allocate freely, the GC cleans up. For a CLI tool that runs for milliseconds, GC pause latency is irrelevant. The cost is binary size (GC runtime) and a ceiling on how small the binary can get.

**Zig — explicit allocators:**

Every allocation goes through an explicit `std.mem.Allocator`. The `wt-zig` codebase passes allocators through function parameters, uses `defer`/`errdefer` for cleanup, and the test suite uses `std.testing.allocator` which detects leaks automatically. Arena allocators are available for batch allocation patterns.

This is more work than GC but gives precise control and zero hidden allocations. For `wt-zig`, it means the release binary has no allocator runtime overhead beyond the system allocator.

**Rust — ownership and borrowing:**

Compile-time memory safety through the borrow checker. No GC, no manual free. The learning curve is the steepest of the three — lifetime annotations, ownership transfers, and the borrow checker's constraints require restructuring how you think about data flow.

For a CLI tool, Rust's ownership model is somewhat over-provisioned. The same guarantees that prevent data races in concurrent servers add friction in a single-threaded command dispatcher. But they also prevent entire classes of bugs at compile time.

**For CLI tools specifically:** All three approaches are adequate. Go's GC is invisible at CLI scale. Zig's explicit allocators are manageable with discipline. Rust's ownership model prevents bugs but costs learning time. The differences matter more in long-running services or libraries.

## Build and Cross-Compilation

**Go:**

```sh
GOOS=linux GOARCH=amd64 go build -o wt .
GOOS=darwin GOARCH=arm64 go build -o wt .
```

Simplest cross-compilation story. Two environment variables, no extra toolchains. Clean build: ~3 s.

**Zig:**

```sh
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
```

Zig bundles a C cross-compiler toolchain. Cross-compilation works out of the box, including C interop targets. Clean debug build: ~1 s. Clean release build: ~4 s.

**Rust:**

```sh
rustup target add x86_64-unknown-linux-gnu
cargo build --release --target x86_64-unknown-linux-gnu
```

Mature but requires installing target toolchains. Cross-compilation to non-native targets often needs a linker (e.g., `cross` or `cargo-zigbuild`). Clean build: ~90–120 s for a CLI with typical deps.

**Comparison:**

| | Go | Zig | Rust |
|---|---|---|---|
| Cross-compile setup | 2 env vars | built-in | `rustup target add` + linker |
| C interop | cgo (painful) | native | `cc` crate + `bindgen` |
| Clean build time | ~3 s | ~1–4 s | ~90–120 s |
| Incremental rebuild | fast | fast | fast (after initial) |

## Ecosystem and Maintainability

**Go — stable and predictable:**

The Go 1 compatibility promise means code written in 2015 still compiles. The standard library covers most CLI needs (flag parsing, JSON, HTTP, testing). Cobra adds subcommand dispatch, but you could write a Go `wt` without any deps at all. Largest ecosystem of the three for backend/CLI tooling.

**Zig — pre-1.0 but insulated by zero deps:**

Zig is pre-1.0 and breaking changes happen between releases (0.14 → 0.15 broke APIs). However, `wt-zig` has zero external dependencies, so the only upgrade surface is the compiler and standard library themselves. No crate or module ecosystem to tend. The risk is language-level churn; the mitigation is a small, self-contained codebase.

**Rust — mature ecosystem, active maintenance required:**

crates.io is mature with enforced semver. `cargo update`, `cargo audit`, and `dependabot` keep things current. But a 40–50 crate transitive tree means periodic maintenance: security advisories, breaking changes in major versions, yanked crates. The tooling is excellent; the work is real.

## Learning Curve and Contributor Accessibility

| | Go | Zig | Rust |
|---|---|---|---|
| Time to productive | 1–4 weeks | 1–2 months | 3–6 months |
| Key concepts to learn | goroutines, interfaces, error handling | allocators, comptime, error unions | ownership, lifetimes, traits, macros |
| Ecosystem familiarity | very high | low | moderate |
| Documentation quality | excellent | improving, pre-1.0 gaps | excellent |
| IDE support | mature (gopls) | improving (ZLS) | mature (rust-analyzer) |

Go has the widest contributor pool by a significant margin. Zig has the smallest. Rust's learning curve is front-loaded — once past the borrow checker, productivity is high.

## Lessons from the Actual Port

The Go → Zig port produced several insights that generalize beyond language choice. See [comparison.md](comparison.md) for the full Go-vs-Zig analysis.

**Zero deps is a real maintenance win.** The Go version's 7 dependencies are well-managed, but `wt-zig`'s zero-dep posture eliminated an entire category of maintenance work: no `dependabot` PRs, no security advisories to triage, no transitive breakage. A hypothetical Rust port's 40–50 transitive deps would be the opposite extreme.

**A parity harness matters more than language choice.** The strongest part of the Zig port is `scripts/parity-harness.sh`, which runs the Go e2e suite against both binaries and flags Zig-only regressions. This would work identically for a Rust port. The harness made the port trustworthy; the language made it possible.

**Comptime replaced what Rust would do with macros and generics.** Zig's `comptime` handles hook dispatch (`inline for` + `@field`), build-time configuration, and type-level iteration. Rust would use derive macros or const generics for similar patterns. Go would use reflection or code generation. Each approach works; they differ in debuggability and explicitness.

**Explicit allocators surfaced bugs that GC hid.** The Zig port's `std.testing.allocator` caught memory leaks that were invisible in Go's GC'd runtime. These weren't production-critical for a CLI, but the discipline transferred to better resource management overall.

## Recommendation Matrix

| If you want to... | Choose |
|---|---|
| Maximize contributor pool | **Go** — widest adoption, easiest onramp |
| Minimize binary size | **Zig** — 251 KB stripped, no runtime |
| Maximize compile-time safety | **Rust** — ownership + borrow checker + exhaustive matching |
| Minimize dependencies | **Zig** — zero external deps |
| Fastest iteration cycle | **Go** — fast builds, simple toolchain, GC removes memory management overhead |
| Best error handling ergonomics | **Rust** — `?` + `Result` + chainable combinators |
| Simplest cross-compilation | **Zig** — bundled C toolchain, single flag |
| Lowest maintenance burden | **Go** for ecosystem stability; **Zig** for zero-dep insulation |
| Best learning investment for 2025+ | **Rust** for career breadth; **Zig** for systems understanding |

There is no single best language for a CLI tool. Go is the pragmatic default. Zig is the minimalist's choice. Rust is the safety maximalist's choice. The `wt` project has working implementations in two of three, and the comparison data above is real — not projected.
