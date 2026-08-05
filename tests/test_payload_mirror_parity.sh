#!/usr/bin/env bash
# RENDERED-PAYLOAD <-> COMMITTED-EXAMPLE MIRROR PARITY SENTINEL (hermetic; file-drop only).
#
# WHY: skills/ipc/examples/example-dispatch-payload.md is documentation that claims to
# mirror the payload handoff_to_codex.sh actually renders. Nothing enforced that claim, so
# either side could gain, lose or rename a section and every gate stayed green.
#
# SENTINELED (`^## ` heading parity against a REAL render, not against script text):
# - MINIMAL render (clean fixture worktree, every optional env unset) produces EXACTLY the
#   example's heading set -- both directions, no allowlist.
# - MAXIMAL render (dirty worktree + every optional env set) is a superset of the example,
#   and each extra heading is declared in CONDITIONAL_HEADINGS below with its gating variable.
# - Each declared conditional heading is ABSENT from the minimal render and PRESENT in the
#   maximal one, so a heading that silently became unconditional (or stopped rendering at
#   all) fails here instead of drifting into the example unnoticed.
# - The payload title line matches the example's, and the render contains no unexpanded
#   `${...}` (a broken heredoc would otherwise ship interpolation markers to Codex).
#
# Comparison is on RENDERED text by construction: two headings interpolate ${MAIN_BRANCH},
# so grepping the wrapper source for heading literals cannot decide parity.
#
# SAFETY: file-drop mode ONLY. Never --ipc, no Codex/Desktop/router process, no focus, no
# deep link. CODEX_IPC_ROOT and HOME are both redirected into this suite's mktemp dir and
# the fixture is a throwaway git repo, so no real transport root, session state or repo is
# read or written. Retention is pinned to keep-only (0) so no sweep can run.
#
# EXCLUDED: body text below the headings, heading ORDER, and the example's synthetic
# placeholder ids/paths (deliberately fake; they cannot match a live render).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout
# (tests/ inside the skill root, scripts/ and examples/ as siblings).
WRAPPER=""
EXAMPLE=""
for _base in "$ROOT/skills/ipc" "$ROOT"; do
    if [[ -f "$_base/scripts/handoff_to_codex.sh" && -f "$_base/examples/example-dispatch-payload.md" ]]; then
        WRAPPER="$_base/scripts/handoff_to_codex.sh"
        EXAMPLE="$_base/examples/example-dispatch-payload.md"
        break
    fi
done

PASS=0
FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# A missing wrapper/example is a hard failure, never a skip: this suite exists precisely to
# prove the pair stays in step, and a silent skip would restore the gap it closes.
if [[ -z "$WRAPPER" || -z "$EXAMPLE" ]]; then
    echo "FATAL: handoff_to_codex.sh + example-dispatch-payload.md not found in repo or installed layout" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "FATAL: git is required to build the hermetic fixture repository" >&2
    exit 1
fi

# ---- allowlist: headings that may appear in a render but NOT in the example -------------
# Format: <exact heading><TAB><name of the variable that gates it>. Adding a row here is a
# deliberate, reviewable act; an undeclared extra heading fails the suite.
CONDITIONAL_HEADINGS=$(printf '%s\n' \
    "## Uncommitted changes	UNCOMMITTED (git status --short is non-empty)" \
    "## Suggested reasoning effort	CODEX_REASONING_EFFORT")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TASK_TEXT="Review src/example.js for edge cases and add the missing null-input guard."

# ---- hermetic fixture repository ---------------------------------------------------------
# A throwaway repo with an origin/HEAD symref, so MAIN_BRANCH resolves deterministically and
# the render carries real branch/commit/diff context instead of the not-a-repo fallbacks.
FIX="$TMP/fixture-repo"
mkdir -p "$FIX"
build_fixture() {
    git init -q "$FIX" >/dev/null 2>&1 || return 1
    git -C "$FIX" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || return 1
    git -C "$FIX" config user.email "fixture@example.invalid" || return 1
    git -C "$FIX" config user.name "Parity Fixture" || return 1
    git -C "$FIX" config commit.gpgsign false || return 1
    mkdir -p "$FIX/src"
    printf 'module.exports = function example() { return 1; };\n' > "$FIX/src/example.js"
    git -C "$FIX" add -A >/dev/null 2>&1 || return 1
    git -C "$FIX" commit -q -m "example: initial scaffold" >/dev/null 2>&1 || return 1
    git -C "$FIX" update-ref refs/remotes/origin/main HEAD || return 1
    git -C "$FIX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || return 1
    git -C "$FIX" checkout -q -b feature/example >/dev/null 2>&1 || return 1
    printf 'module.exports = function example(x) { return x + 1; };\n' > "$FIX/src/example.js"
    git -C "$FIX" commit -q -am "example: add feature scaffold" >/dev/null 2>&1 || return 1
}
if ! build_fixture; then
    echo "FATAL: could not build the hermetic git fixture in $FIX" >&2
    exit 1
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# ---- render ------------------------------------------------------------------------------
# Sets R_RC / R_OUT / R_FILE. Every environment knob the payload reads is pinned explicitly
# so an inherited value from the caller's shell cannot change what is rendered. That includes
# CODEX_IPC_GIT_CONTEXT: minimal unsets it (so the render exercises the shipped bounded
# default), maximal pins `full`. Heading parity must hold under both, since bounding changes
# section BODIES only and never adds, drops or renames a heading -- which is exactly the
# property this suite is here to keep true.
R_RC=0; R_OUT=""; R_FILE=""
do_render() { # do_render <tag> <optional-env 0|1>
    # Separate declarations: `local` expands ALL of its words before it assigns any of
    # them, so `local a=$1 b=$TMP/$a` would read an unbound `a` under `set -u`.
    local tag="$1" opt="$2"
    local ipcroot="$TMP/ipc-$tag" fakehome="$TMP/home-$tag" found
    mkdir -p "$ipcroot" "$fakehome"
    if [[ "$opt" -eq 1 ]]; then
        R_OUT="$( cd "$FIX" && env HOME="$fakehome" CODEX_IPC_ROOT="$ipcroot" \
            CLAUDE_SESSION_ID="parity-fixture" CODEX_IPC_RETENTION_DAYS=0 \
            CODEX_IPC_INCLUDE_TRANSCRIPT=1 CODEX_REASONING_EFFORT=high \
            CODEX_IPC_GIT_CONTEXT=full \
            bash "$WRAPPER" "$TASK_TEXT" 2>&1 )"
    else
        R_OUT="$( cd "$FIX" && env -u CODEX_IPC_INCLUDE_TRANSCRIPT -u CODEX_REASONING_EFFORT \
            -u CLAUDE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID -u CODEX_IPC_GIT_CONTEXT \
            HOME="$fakehome" CODEX_IPC_ROOT="$ipcroot" \
            CLAUDE_SESSION_ID="parity-fixture" CODEX_IPC_RETENTION_DAYS=0 \
            bash "$WRAPPER" "$TASK_TEXT" 2>&1 )"
    fi
    R_RC=$?
    found="$(find "$ipcroot" -type f -name '*.task.md' 2>/dev/null)"
    if [[ "$(printf '%s\n' "$found" | grep -c .)" -eq 1 ]]; then
        R_FILE="$found"
    else
        R_FILE=""
    fi
}

# Heading extraction: strip CR (Windows checkouts) and trailing blanks, then sort unique.
headings() { grep -a '^## ' "$1" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u; }

echo "== rendered-payload / example mirror parity =="
echo "  wrapper: ${WRAPPER#$ROOT/}"
echo "  example: ${EXAMPLE#$ROOT/}"

headings "$EXAMPLE" > "$TMP/h-example"
if [[ -s "$TMP/h-example" ]]; then
    ok "example declares $(grep -c . < "$TMP/h-example") '## ' headings"
else
    no "example declares no '## ' headings (file empty, moved, or format changed)"
fi

# ---- minimal render (clean tree, no optional env) ----------------------------------------
do_render min 0
if [[ "$R_RC" -eq 0 ]]; then ok "minimal file-drop render exited 0"; else
    no "minimal file-drop render exited $R_RC"; printf '%s\n' "$R_OUT" | sed 's/^/    /'
fi
if [[ -n "$R_FILE" && -f "$R_FILE" ]]; then
    ok "minimal render published exactly one envelope inside the fixture transport root"
else
    no "minimal render did not publish exactly one *.task.md under the fixture transport root"
fi
MIN_FILE="$R_FILE"
[[ -n "$MIN_FILE" ]] && headings "$MIN_FILE" > "$TMP/h-min" || : > "$TMP/h-min"

# ---- maximal render (dirty tree + every optional env) ------------------------------------
printf 'scratch\n' > "$FIX/uncommitted-scratch.txt"
if [[ -n "$(cd "$FIX" && git status --short 2>/dev/null)" ]]; then
    ok "fixture worktree is dirty for the maximal render"
else
    no "fixture worktree could not be made dirty (conditional heading untestable)"
fi
do_render max 1
if [[ "$R_RC" -eq 0 ]]; then ok "maximal file-drop render exited 0"; else
    no "maximal file-drop render exited $R_RC"; printf '%s\n' "$R_OUT" | sed 's/^/    /'
fi
MAX_FILE="$R_FILE"
[[ -n "$MAX_FILE" ]] && headings "$MAX_FILE" > "$TMP/h-max" || : > "$TMP/h-max"

# ---- parity assertions --------------------------------------------------------------------
# 1. minimal render == example, exactly, in both directions.
MISSING_IN_MIN="$(LC_ALL=C comm -23 "$TMP/h-example" "$TMP/h-min")"
EXTRA_IN_MIN="$(LC_ALL=C comm -13 "$TMP/h-example" "$TMP/h-min")"
if [[ -z "$MISSING_IN_MIN" ]]; then
    ok "every example heading is present in the minimal render"
else
    no "example headings absent from the minimal render:"; printf '%s\n' "$MISSING_IN_MIN" | sed 's/^/      /'
fi
if [[ -z "$EXTRA_IN_MIN" ]]; then
    ok "the minimal render introduces no heading the example lacks"
else
    no "minimal render headings missing from the example (example is stale):"
    printf '%s\n' "$EXTRA_IN_MIN" | sed 's/^/      /'
fi

# 2. maximal render is a superset of the example, and its extras are all declared.
MISSING_IN_MAX="$(LC_ALL=C comm -23 "$TMP/h-example" "$TMP/h-max")"
if [[ -z "$MISSING_IN_MAX" ]]; then
    ok "every example heading is present in the maximal render"
else
    no "example headings absent from the maximal render:"; printf '%s\n' "$MISSING_IN_MAX" | sed 's/^/      /'
fi
printf '%s\n' "$CONDITIONAL_HEADINGS" | cut -f1 | LC_ALL=C sort -u > "$TMP/h-allow"
LC_ALL=C comm -13 "$TMP/h-example" "$TMP/h-max" > "$TMP/h-extra"
UNDECLARED="$(LC_ALL=C comm -23 "$TMP/h-extra" "$TMP/h-allow")"
if [[ -z "$UNDECLARED" ]]; then
    ok "every extra heading in the maximal render is declared in CONDITIONAL_HEADINGS"
else
    no "undeclared conditional heading(s) -- add to CONDITIONAL_HEADINGS with the gating variable, or to the example:"
    printf '%s\n' "$UNDECLARED" | sed 's/^/      /'
fi

# 3. each declared conditional heading is genuinely gated: absent minimal, present maximal.
while IFS=$'\t' read -r ch gate; do
    [[ -n "$ch" ]] || continue
    if grep -Fqx "$ch" "$TMP/h-min"; then
        no "conditional '$ch' rendered with $gate unset -- it is not conditional; the example must declare it"
    elif ! grep -Fqx "$ch" "$TMP/h-max"; then
        no "conditional '$ch' did not render with $gate set -- gate is wrong or the section was dropped"
    else
        ok "conditional '$ch' is gated by $gate"
    fi
done < <(printf '%s\n' "$CONDITIONAL_HEADINGS")

# 4. title-line parity and no unexpanded interpolation in the render.
EX_TITLE="$(head -1 "$EXAMPLE" | tr -d '\r')"
MIN_TITLE=""; [[ -n "$MIN_FILE" ]] && MIN_TITLE="$(head -1 "$MIN_FILE" | tr -d '\r')"
if [[ -n "$MIN_TITLE" && "$MIN_TITLE" == "$EX_TITLE" ]]; then
    ok "payload title line matches the example"
else
    no "payload title drifted: render='$MIN_TITLE' example='$EX_TITLE'"
fi
LEFTOVER=""
for f in "$MIN_FILE" "$MAX_FILE"; do
    [[ -n "$f" ]] || continue
    if grep -aq '\${' "$f"; then LEFTOVER="$LEFTOVER $f"; fi
done
if [[ -z "$LEFTOVER" ]]; then
    ok "no unexpanded \${...} survived into either render"
else
    no "unexpanded \${...} in render(s):$LEFTOVER"
fi

# 5. containment: nothing escaped the fixture transport root, and no reply was fabricated.
ESCAPED=0
for f in "$MIN_FILE" "$MAX_FILE"; do
    [[ -n "$f" ]] || continue
    case "$f" in "$TMP"/*) ;; *) ESCAPED=1 ;; esac
done
if [[ "$ESCAPED" -eq 0 ]]; then
    ok "every published envelope stayed inside the suite's temporary root"
else
    no "an envelope was published outside the suite's temporary root"
fi
if [[ -z "$(find "$TMP" -type f -name '*.reply.md' 2>/dev/null)" ]]; then
    ok "no reply file was created (file-drop writes only the task envelope)"
else
    no "a *.reply.md appeared; file-drop must not fabricate a reply"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
