#!/usr/bin/env bash
set -euo pipefail

repo_root="${WT_ZIG_REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
wt_bin="${WT_ZIG_BIN:-$repo_root/zig-out/bin/wt}"
run_root="$(mktemp -d /tmp/wt-zig-smoke.XXXXXX)"
trap 'rm -rf "$run_root"' EXIT

home_dir="$run_root/home"
repo_dir="$run_root/repo"
feature_dir="$run_root/feature"
config_file="$repo_dir/.wt.toml"

mkdir -p "$home_dir"

export HOME="$home_dir"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export WT_CONFIG="$config_file"
export WT_APPROVALS_PATH="$run_root/approvals.toml"

fail() {
    printf 'smoke failed: %s\n' "$1" >&2
    exit 1
}

run_git() {
    git -C "$1" "${@:2}"
}

run_wt() {
    local cwd="$1"
    shift
    (
        cd "$cwd"
        "$wt_bin" "$@"
    )
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'smoke failed: %s\nexpected:\n%s\nactual:\n%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    case "$haystack" in
        *"$needle"* ) ;;
        *) fail "$label did not contain: $needle" ;;
    esac
}

write_lines() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "$path"
}

assert_clean_tree() {
    local status
    status="$(run_git "$1" status --short)"
    assert_eq "" "$status" "expected clean tree at $1"
}

assert_file_eq() {
    local path="$1"
    local expected="$2"
    local label="$3"
    if [[ ! -f "$path" ]]; then
        fail "$label missing file: $path"
    fi
    assert_eq "$expected" "$(<"$path")" "$label"
}

git -c init.defaultBranch=main init "$repo_dir" >/dev/null
git -C "$repo_dir" symbolic-ref HEAD refs/heads/main
git -C "$repo_dir" config user.name "wt smoke"
git -C "$repo_dir" config user.email "wt-smoke@example.com"

write_lines "$repo_dir/base.txt" "base"
git -C "$repo_dir" add base.txt
git -C "$repo_dir" commit -m "base" >/dev/null

write_lines "$config_file" \
    "[aliases]" \
    "echo = \"printf '%s\\n' alias\"" \
    "ship = [\"printf '%s\\n' status\", \"printf '%s\\n' ship\"]" \
    "" \
    "[hooks]" \
    "pre_start = [\"echo pre start\"]"

run_wt "$repo_dir" config approvals add >/dev/null
assert_contains "$(run_wt "$repo_dir" config approvals show)" "printf '%s\\n' alias" "approvals include alias command"

alias_output="$(run_wt "$repo_dir" echo one two)"
assert_eq $'alias\none\ntwo' "$alias_output" "alias output"
assert_contains "$(run_wt "$repo_dir" config alias show)" "ship:" "alias catalog"
alias_dry_run_output="$(run_wt "$repo_dir" config alias dry-run ship -- --force)"
assert_contains "$alias_dry_run_output" "printf '%s\\n' status" "alias dry-run first command"
assert_contains "$alias_dry_run_output" "printf '%s\\n' ship '--force'" "alias dry-run final command"
assert_contains "$(run_wt "$repo_dir" hook show)" "pre_start: echo pre start" "hook catalog"
assert_eq "main" "$(run_wt "$repo_dir" step eval "{{ branch }}")" "step eval branch"

git -C "$repo_dir" worktree add "$feature_dir" -b feature >/dev/null
for_each_output="$(run_wt "$repo_dir" step for-each -- printf '%s\n' "{{ branch }}")"
assert_contains "$for_each_output" "main" "for-each main branch"
assert_contains "$for_each_output" "feature" "for-each feature branch"

write_lines "$feature_dir/feature.txt" "feature-1"
run_wt "$feature_dir" step commit -m "feature commit" >/dev/null
assert_eq "feature commit" "$(git -C "$feature_dir" log -1 --pretty=%s)" "step commit subject"

write_lines "$feature_dir/feature.txt" "feature-2"
run_wt "$feature_dir" step squash main --message "feature squash" >/dev/null
assert_eq "feature squash" "$(git -C "$feature_dir" log -1 --pretty=%s)" "step squash subject"
assert_clean_tree "$feature_dir"

promote_main="$run_root/promote-main"
promote_feature="$run_root/promote-feature"
git -c init.defaultBranch=main init "$promote_main" >/dev/null
git -C "$promote_main" symbolic-ref HEAD refs/heads/main
git -C "$promote_main" config user.name "wt smoke"
git -C "$promote_main" config user.email "wt-smoke@example.com"
write_lines "$promote_main/base.txt" "base"
git -C "$promote_main" add base.txt
git -C "$promote_main" commit -m "base" >/dev/null
write_lines "$promote_main/.gitignore" "build/" "*.log"
git -C "$promote_main" add .gitignore
git -C "$promote_main" commit -m "add gitignore" >/dev/null
git -C "$promote_main" worktree add "$promote_feature" -b promote-feature >/dev/null 2>&1
mkdir -p "$promote_main/build" "$promote_feature/build"
write_lines "$promote_main/build/main-artifact" "main build"
write_lines "$promote_main/app.log" "main log"
write_lines "$promote_feature/build/feature-artifact" "feature build"
write_lines "$promote_feature/debug.log" "feature log"
run_wt "$promote_feature" step promote promote-feature >/dev/null
assert_eq "promote-feature" "$(git -C "$promote_main" branch --show-current)" "promote main branch"
assert_eq "main" "$(git -C "$promote_feature" branch --show-current)" "promote linked branch"
assert_file_eq "$promote_main/build/feature-artifact" "feature build" "promote main ignored directory"
assert_file_eq "$promote_main/debug.log" "feature log" "promote main ignored file"
assert_file_eq "$promote_feature/build/main-artifact" "main build" "promote linked ignored directory"
assert_file_eq "$promote_feature/app.log" "main log" "promote linked ignored file"
run_wt "$promote_main" step promote >/dev/null
assert_eq "main" "$(git -C "$promote_main" branch --show-current)" "promote restore main branch"
assert_eq "promote-feature" "$(git -C "$promote_feature" branch --show-current)" "promote restore linked branch"
assert_file_eq "$promote_main/build/main-artifact" "main build" "promote restore main ignored directory"
assert_file_eq "$promote_main/app.log" "main log" "promote restore main ignored file"
assert_file_eq "$promote_feature/build/feature-artifact" "feature build" "promote restore linked ignored directory"
assert_file_eq "$promote_feature/debug.log" "feature log" "promote restore linked ignored file"

write_lines "$repo_dir/main.txt" "main-advance"
git -C "$repo_dir" add main.txt
git -C "$repo_dir" commit -m "main advance" >/dev/null

merge_output="$(run_wt "$feature_dir" merge main --rebase --no-remove)"
case "$merge_output" in
    *"Rebasing feature onto main..."* ) ;;
    *) fail "merge output did not report the rebase step" ;;
esac
case "$merge_output" in
    *"Merging feature into main..."* ) ;;
    *) fail "merge output did not report the merge step" ;;
esac

assert_eq "$(git -C "$repo_dir" rev-parse HEAD)" "$(git -C "$feature_dir" rev-parse feature)" "merge fast-forwarded main to feature"
assert_clean_tree "$feature_dir"

if [[ ! -d "$feature_dir" ]]; then
    fail "feature worktree was removed despite --no-remove"
fi

printf 'smoke workflows passed\n'
