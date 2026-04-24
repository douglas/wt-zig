#!/usr/bin/env bash
set -euo pipefail

WT_GO_REPO="${WT_GO_REPO:-/home/douglas/src/wt}"
WT_ZIG_REPO="${WT_ZIG_REPO:-/home/douglas/src/wt-zig}"
WT_PARITY_SHELLS="${WT_PARITY_SHELLS:-bash}"
WT_GO_BIN="${WT_GO_BIN:-/tmp/wt-go-parity}"
WT_ZIG_BIN="${WT_ZIG_BIN:-$WT_ZIG_REPO/zig-out/bin/wt}"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$WT_ZIG_REPO/.zig-global-cache}"
ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$WT_ZIG_REPO/.zig-cache}"
GOCACHE="${GOCACHE:-/tmp/wt-go-cache}"
GOMODCACHE="${GOMODCACHE:-/home/douglas/go/pkg/mod}"
GOFLAGS="${GOFLAGS:--mod=readonly}"
GOPROXY="${GOPROXY:-off}"
GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-/dev/null}"
GIT_CONFIG_NOSYSTEM="${GIT_CONFIG_NOSYSTEM:-1}"

build_binaries() {
  mkdir -p "$GOCACHE"
  (
    cd "$WT_GO_REPO" &&
      GOCACHE="$GOCACHE" \
      GOMODCACHE="$GOMODCACHE" \
      GOFLAGS="$GOFLAGS" \
      GOPROXY="$GOPROXY" \
      GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
      GIT_CONFIG_NOSYSTEM="$GIT_CONFIG_NOSYSTEM" \
      go build -o "$WT_GO_BIN" .
  )
  (cd "$WT_ZIG_REPO" && ZIG_GLOBAL_CACHE_DIR="$ZIG_GLOBAL_CACHE_DIR" ZIG_LOCAL_CACHE_DIR="$ZIG_LOCAL_CACHE_DIR" zig build -Dversion=dev)
}

run_go_harness() {
  local target_bin="$1"
  local label="$2"
  local log_path="$3"
  echo "== Go e2e scenarios against $label =="
  set +e
  (
    cd "$WT_GO_REPO" &&
      GOCACHE="$GOCACHE" \
      GOMODCACHE="$GOMODCACHE" \
      GOFLAGS="$GOFLAGS" \
      GOPROXY="$GOPROXY" \
      GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
      GIT_CONFIG_NOSYSTEM="$GIT_CONFIG_NOSYSTEM" \
      go run ./e2e -wt "$target_bin" -shells "$WT_PARITY_SHELLS" -scenarios "$WT_GO_REPO/e2e/scenarios"
  ) | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

compare_output() {
  local label="$1"
  shift
  local go_out zig_out go_status zig_status
  set +e
  go_out="$("$WT_GO_BIN" "$@" 2>&1)"
  go_status="$?"
  zig_out="$("$WT_ZIG_BIN" "$@" 2>&1)"
  zig_status="$?"
  set -e

  if [[ "$label" == "root json help" || "$label" == "json help" ]]; then
    # wt-zig intentionally keeps extra root commands (done/jump) for backwards
    # compatibility. Ignore those two lines when comparing JSON help text.
    go_out="$(normalize_root_json_help "$go_out")"
    zig_out="$(normalize_root_json_help "$zig_out")"
  fi

  if [[ "$go_status" != "$zig_status" ]] || [[ "$go_out" != "$zig_out" ]]; then
    echo "!! direct output mismatch: $label"
    echo "go exit: $go_status"
    echo "zig exit: $zig_status"
    diff -u <(printf '%s\n' "$go_out") <(printf '%s\n' "$zig_out") || true
    return 1
  fi
  return 0
}

normalize_root_json_help() {
  printf '%s' "$1" | sed -E \
    -e 's/\\n  done        Remove current linked worktree\\n/\\n/g' \
    -e 's/\\n  jump        Navigate to a worktree by branch name\\n/\\n/g'
}

collect_failures() {
  local log_path="$1"
  local output_path="$2"
  if ! rg '^FAIL:' "$log_path" | sed 's/^FAIL: //' | sort -u > "$output_path"; then
    : > "$output_path"
  fi
}

report_failure_delta() {
  local go_failures="$1"
  local zig_failures="$2"
  local go_only zig_only
  go_only="$(comm -23 "$go_failures" "$zig_failures" || true)"
  zig_only="$(comm -13 "$go_failures" "$zig_failures" || true)"

  if [[ -n "$go_only" ]]; then
    echo "== Go-only harness failures =="
    printf '%s\n' "$go_only"
  fi

  if [[ -n "$zig_only" ]]; then
    echo "== Zig-only harness failures =="
    printf '%s\n' "$zig_only"
    return 1
  fi

  echo "== Harness parity =="
  echo "No Zig-only scenario failures relative to the Go baseline."
  return 0
}

main() {
  local tmp_dir go_log zig_log go_failures zig_failures
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT
  go_log="$tmp_dir/go.log"
  zig_log="$tmp_dir/zig.log"
  go_failures="$tmp_dir/go.failures"
  zig_failures="$tmp_dir/zig.failures"

  build_binaries
  run_go_harness "$WT_GO_BIN" "wt (Go)" "$go_log" || true
  run_go_harness "$WT_ZIG_BIN" "wt-zig" "$zig_log" || true
  collect_failures "$go_log" "$go_failures"
  collect_failures "$zig_log" "$zig_failures"
  report_failure_delta "$go_failures" "$zig_failures"

  echo "== Direct command comparisons =="
  compare_output "root json help" --format json
  compare_output "json version" --format json version
  compare_output "json help" --format json help
  compare_output "json shellenv" --format json shellenv
  compare_output "json unknown command" --format json wat
}

main "$@"
