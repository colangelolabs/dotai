#!/usr/bin/env bash
# Runs install.sh in throwaway HOME and CLAUDE_CONFIG_DIR directories and
# checks its output and exit code. Never touches the real home.
#
#   bash tests/install-test.sh
#   DOTAI_INSTALL_SH=<path> bash tests/install-test.sh   # test another copy of the script
set -euo pipefail

# A regressed installer could write to the real root (an empty target becomes /rules).
if [[ $(id -u) -eq 0 ]]; then
    echo "refusing to run as root" >&2
    exit 1
fi

src="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="${DOTAI_INSTALL_SH:-$src/install.sh}"
[[ -z ${DOTAI_INSTALL_SH:-} ]] || echo "testing $installer"
# mktemp has its own assignment so set -e stops the script when it fails,
# before the trap exists.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
# Physical path, so expected strings match what the script prints where
# the temp directory sits behind a symlink (/var on macOS).
work="$(CDPATH= cd -- "$tmp" && pwd -P)"

failures=0
fail() { echo "  FAIL: $1"; failures=$((failures + 1)); }
expect_eq() { [[ $2 == "$3" ]] || fail "$1: expected '$3', got '$2'"; }
expect_line() { grep -Fxq -- "$2" <<<"$out" || fail "$1: no line '$2' in: $out"; }

# A fresh HOME, config directory and repo copy; sets home, cfg, repo.
new_case() {
    echo "$1"
    local c
    c="$(mktemp -d "$work/case.XXXXXX")"
    home="$c/home" cfg="$c/config" repo="$c/repo"
    mkdir "$home" "$cfg" "$repo"
    cp "$installer" "$repo/install.sh"
    cp -R "$src/rules" "$repo/rules"
}

# run <script> [args]: sets out (stdout and stderr) and rc. CLAUDE_CONFIG_DIR
# is $cfg when use_cfg is true, otherwise unset.
use_cfg=true
run() {
    if $use_cfg; then
        out="$(env -u VOICE_SAMPLES_DIR HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$@" 2>&1)" && rc=0 || rc=$?
    else
        out="$(env -u VOICE_SAMPLES_DIR -u CLAUDE_CONFIG_DIR HOME="$home" bash "$@" 2>&1)" && rc=0 || rc=$?
    fi
}

new_case "no config directory: exit 1, nothing created"
use_cfg=false
run "$repo/install.sh"
expect_eq "exit code" "$rc" 1
expect_eq "message" "$out" "no agent config directory found (looked for CLAUDE_CONFIG_DIR, ~/.claude, ~/.claude-personal)"
expect_eq "home contents" "$(ls -A "$home")" ""
use_cfg=true

new_case "fresh link, then a rerun"
run "$repo/install.sh"
expect_eq "exit code" "$rc" 0
expect_line "link" "linked    $cfg/rules -> $repo/rules"
expect_eq "link target" "$(readlink "$cfg/rules")" "$repo/rules"
run "$repo/install.sh"
expect_eq "rerun exit code" "$rc" 0
expect_line "rerun" "ok        $cfg/rules -> $repo/rules"
run "$repo/install.sh" --status
expect_line "status" "ok        $cfg/rules -> $repo/rules"

new_case "real rules directory is moved aside"
mkdir "$cfg/rules"
echo keep > "$cfg/rules/mine.md"
run "$repo/install.sh" --status
expect_line "status" "NOT LINKED $cfg/rules (a real directory)"
run "$repo/install.sh"
expect_eq "exit code" "$rc" 0
expect_line "link" "linked    $cfg/rules -> $repo/rules"
[[ $out == "kept      $cfg/rules.before-dotai."* ]] || fail "no 'kept' line in: $out"
set -- "$cfg"/rules.before-dotai.*
expect_eq "moved directory count" "$#" 1
expect_eq "moved directory content" "$(cat "$1/mine.md")" keep
expect_eq "link target" "$(readlink "$cfg/rules")" "$repo/rules"

new_case "dangling link whose parent is gone"
ln -s "$home/old-clone/rules" "$cfg/rules"
run "$repo/install.sh" --status
expect_line "status" "WRONG     $cfg/rules -> $home/old-clone/rules"
run "$repo/install.sh"
expect_eq "exit code" "$rc" 0
expect_line "replaced" "linked    $cfg/rules -> $repo/rules"
expect_eq "link target" "$(readlink "$cfg/rules")" "$repo/rules"

new_case "repo reached through a symlink"
ln -s "$repo" "$home/alias"
run "$home/alias/install.sh"
expect_eq "exit code" "$rc" 0
expect_line "link" "linked    $cfg/rules -> $repo/rules"
expect_eq "link target" "$(readlink "$cfg/rules")" "$repo/rules"

new_case "link whose target and repo rules directory are both unreachable"
rm -rf "$repo/rules"
ln -s "$home/missing" "$cfg/rules"
run "$repo/install.sh" --status
expect_line "status" "WRONG     $cfg/rules -> $home/missing"

if [[ $failures -ne 0 ]]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all passed"
