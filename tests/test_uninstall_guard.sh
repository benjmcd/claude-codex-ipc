#!/usr/bin/env bash
# UNINSTALLER DANGEROUS-TARGET SENTINEL (hermetic; nothing is ever deleted)
#
# SENTINELED:
# - uninstall.sh refuses a --target that resolves into this source tree, to $HOME, or to a
#   filesystem root, INCLUDING case variants. NTFS is case-insensitive while `pwd -P`
#   preserves directory-name case, so a case-sensitive guard is bypassed by changing one
#   character of the caller's argument. That bypass shipped once; this suite exists to stop
#   it recurring.
# - The same refusal applies to worktree copies of the skill, which also carry the
#   `name: ipc` marker and are therefore invisible to a marker-only guard.
# - The guard does NOT over-block: a real install root still produces a deletion plan, and
#   an absent target still short-circuits cleanly.
#
# EXCLUDED:
# - uninstall.ps1 / install.ps1. Covered by the sibling suite test_uninstall_guard.ps1, which
#   carries the hostile-spelling matrix for that side. It did not exist until 2026-07-27, and
#   its absence is exactly why the PowerShell guard was bypassable three separate times while
#   THIS suite passed. Do not read a green bash run as evidence about PowerShell.
# - Any real deletion. Every invocation here passes --dry-run; a bug in this suite cannot
#   remove anything.
# - Junction/symlink and UNC behavior (not constructible hermetically without elevation).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNINSTALL="$ROOT/uninstall.sh"

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if [[ ! -f "$UNINSTALL" ]]; then
    echo "SKIP: uninstall.sh not present at $UNINSTALL (installed-skill layout)"
    exit 0
fi

# Refusal is exit 1 with the refusal banner. --dry-run is always passed, so even a
# regression that defeats the guard cannot delete: it would print a plan and exit 0,
# which is exactly what these assertions catch.
refuses(){ # refuses <target> <label>
    local target="$1" label="$2" out rc
    out="$("$UNINSTALL" --dry-run --target "$target" 2>&1)"; rc=$?
    if [[ $rc -eq 1 ]] && printf '%s\n' "$out" | grep -q 'refusing dangerous --target'; then
        ok "$label"
    else
        no "$label (rc=$rc)"
        printf '%s\n' "$out" | sed -n '1,5p'
    fi
}

allows(){ # allows <target> <label> -- must still reach the deletion plan
    local target="$1" label="$2" out rc
    out="$("$UNINSTALL" --dry-run --target "$target" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && printf '%s\n' "$out" | grep -q '^Deletion plan'; then
        ok "$label"
    else
        no "$label (rc=$rc)"
        printf '%s\n' "$out" | sed -n '1,5p'
    fi
}

echo "== 1. dangerous targets are refused =="
refuses "$ROOT/skills/ipc" "canonical source tree is refused"
refuses "$ROOT/./skills/ipc" "canonical source via dot-segment is refused"
refuses "$ROOT/skills/ipc/" "canonical source with trailing slash is refused"
refuses "$HOME" "\$HOME is refused"
refuses "/" "filesystem root is refused"
refuses "/c" "drive root is refused"

# UNC respelling of a local path resolves to itself, so it matches neither the
# source-prefix test nor the root test. It bypassed the PowerShell guard once.
refuses "//localhost/c\$$(printf '%s' "$ROOT" | sed 's|^/c||')/skills/ipc" "UNC respelling of the source tree is refused"
refuses "//localhost/c\$/" "UNC root is refused"

echo "== 2. case variants are refused (the bypass this suite exists for) =="
UPPER_ROOT="$(printf '%s' "$ROOT" | tr '[:lower:]' '[:upper:]')"
refuses "$UPPER_ROOT/skills/ipc" "upper-cased source path is refused"
refuses "$UPPER_ROOT/SKILLS/IPC" "fully upper-cased source path is refused"
UPPER_HOME="$(printf '%s' "$HOME" | tr '[:lower:]' '[:upper:]')"
refuses "$UPPER_HOME" "upper-cased \$HOME is refused"

echo "== 3. worktree copies carry the marker and are refused =="
shopt -s nullglob
_wt_found=0
for _wt in "$ROOT"/worktrees/*/skills/ipc; do
    [[ -f "$_wt/SKILL.md" ]] || continue
    _wt_found=1
    refuses "$_wt" "worktree copy $(basename "$(dirname "$(dirname "$_wt")")") is refused"
done
shopt -u nullglob
[[ $_wt_found -eq 1 ]] || echo "  (no worktree copies present; nothing to assert)"

echo "== 4. the guard does not over-block =="
_root_found=0
for _r in "$HOME/.claude/skills/ipc" "$HOME/.agents/skills/ipc" "$HOME/.codex/skills/ipc"; do
    [[ -f "$_r/SKILL.md" ]] || continue
    _root_found=1
    allows "$_r" "installed root $_r still produces a deletion plan"
done
[[ $_root_found -eq 1 ]] || echo "  (no installed roots present; nothing to assert)"

_absent="$HOME/.claude/skills/ipc-absent-$$"
out="$("$UNINSTALL" --dry-run --target "$_absent" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$out" | grep -q '^Nothing to do'; then
    ok "absent target short-circuits cleanly"
else
    no "absent target short-circuits cleanly (rc=$rc)"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then echo "ALL GREEN"; exit 0; else exit 1; fi
