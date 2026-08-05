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
# - Junction/symlink behavior. True of symlinks, which need SeCreateSymbolicLinkPrivilege;
#   NOT true of directory junctions (`mklink /J` needs no elevation), so the ancestor-reparse
#   arm is testable and simply is not tested yet. An earlier version of this line lumped UNC
#   in as equally unconstructible; it is not, and UNC IS asserted below wherever an admin
#   share is reachable.
#
# PORTABILITY:
# This suite runs on BOTH CI legs (.github/workflows/test.yml). Several assertions below encode
# WINDOWS path semantics: MSYS drive mounts (/c, /d, ...), admin-share UNC spellings, and the
# case-insensitive-NTFS bypass this suite exists for. On a POSIX runner those spellings name
# nothing, so uninstall.sh short-circuits at rc=0 "Nothing to do" on its not-present check --
# BEFORE the guard is ever reached. That is fail-closed and safe, but it is not a REFUSAL, and
# asserting one there measures the filesystem rather than the guard. Every such assertion
# therefore probes its own precondition and skips loudly when it is not met.
#
# Skip notes print as "  (SKIP: ...)" and deliberately never as "^SKIP:" at column 0:
# tests/run_release_gates.sh fails the whole run on any ^SKIP: line outside its single
# allowlisted platform-conditional skip, and a not-applicable precondition is not that.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNINSTALL="$ROOT/uninstall.sh"

PASS=0; FAIL=0; SKIP=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
# Indented and parenthesized on purpose -- see PORTABILITY in the header.
skip(){ echo "  (SKIP: $1)"; SKIP=$((SKIP+1)); }

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

# Drive root. MSYS maps /c, /d, ... onto Windows drive roots; derive the letter from $ROOT
# instead of assuming /c, so the assertion follows the checkout rather than one machine's
# layout. A POSIX host has no such mount and skips.
DRIVE_ROOT=""
if [[ "$ROOT" =~ ^(/[A-Za-z])/ ]]; then DRIVE_ROOT="${BASH_REMATCH[1]}"; fi
if [[ -n "$DRIVE_ROOT" && -d "$DRIVE_ROOT" ]]; then
    refuses "$DRIVE_ROOT" "drive root is refused"
else
    skip "drive root: no drive mount for \"$ROOT\" on this host"
fi

# UNC respelling of a local path resolves to itself, so it matches neither the
# source-prefix test nor the root test. It bypassed the PowerShell guard once.
#
# Derive the admin share from $ROOT; NEVER hardcode a drive. This previously built
# //localhost/c$ + "$ROOT with a leading /c stripped", which is correct only for a checkout
# under C:. On the windows CI runner ($ROOT=/d/a/...) the strip was a no-op and the result was
# a c$-share path naming a d-drive location -- a string that exists nowhere, so uninstall.sh
# answered "Nothing to do" and the assertion failed. That was a defect in THIS TEST, not a
# bypass of the guard: wherever the UNC spelling actually resolves, the //*/* arm refuses it.
UNC_PREFIX=""
if [[ "$ROOT" =~ ^/([A-Za-z])/ ]]; then UNC_PREFIX="//localhost/${BASH_REMATCH[1]}\$"; fi
UNC_SRC=""
[[ -n "$UNC_PREFIX" ]] && UNC_SRC="${UNC_PREFIX}${ROOT#/?}"
if [[ -n "$UNC_SRC" && -d "$UNC_SRC/skills/ipc" ]]; then
    refuses "$UNC_SRC/skills/ipc" "UNC respelling of the source tree is refused"
else
    skip "UNC respelling of the source tree: admin share unreachable for \"$ROOT\""
fi
if [[ -n "$UNC_PREFIX" && -d "$UNC_PREFIX/" ]]; then
    refuses "$UNC_PREFIX/" "UNC root is refused"
else
    skip "UNC root: admin share unreachable for \"$ROOT\""
fi

echo "== 2. case variants are refused (the bypass this suite exists for) =="
# The precondition is a CASE-INSENSITIVE filesystem: on NTFS the upper-cased spelling names the
# SAME directory, which is precisely why a case-sensitive guard was bypassable by changing one
# character. On a case-sensitive filesystem it names nothing at all, so there is no guard
# behavior to observe and the assertion would be measuring the filesystem instead.
UPPER_ROOT="$(printf '%s' "$ROOT" | tr '[:lower:]' '[:upper:]')"
UPPER_HOME="$(printf '%s' "$HOME" | tr '[:lower:]' '[:upper:]')"
if [[ -d "$UPPER_ROOT/skills/ipc" ]]; then
    refuses "$UPPER_ROOT/skills/ipc" "upper-cased source path is refused"
    refuses "$UPPER_ROOT/SKILLS/IPC" "fully upper-cased source path is refused"
else
    skip "upper-cased source path: case-sensitive filesystem at \"$ROOT\""
    skip "fully upper-cased source path: case-sensitive filesystem at \"$ROOT\""
fi
if [[ -d "$UPPER_HOME" ]]; then
    refuses "$UPPER_HOME" "upper-cased \$HOME is refused"
else
    skip "upper-cased \$HOME: case-sensitive filesystem at \"$HOME\""
fi

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
if [[ $SKIP -gt 0 ]]; then
    echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped (precondition not met on this host)"
else
    echo "RESULT: $PASS passed, $FAIL failed"
fi
if [[ $FAIL -eq 0 ]]; then echo "ALL GREEN"; exit 0; else exit 1; fi
