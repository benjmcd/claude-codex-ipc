#!/usr/bin/env bash
# GIT-CONTEXT BOUNDING + PAYLOAD-ADVISORY SENTINEL (hermetic; file-drop only).
#
# WHY: before 0.1.11 the payload's three git-context sections were interpolated raw, with no
# ceiling. A dirty tree therefore put an unbounded `git status --short` / `git diff --stat`
# dump into every dispatch (CHANGELOG v0.1.9 and v0.1.10 both disclosed it and deferred it;
# one in-repo instance measured 230,175 B of context in a single dispatch). 0.1.11 bounds them
# by DEFAULT. This suite is the sentinel for that bound and for the two advisories added with it.
#
# THE FAILURE THIS SUITE EXISTS TO CATCH is not "the cap is wrong", it is the SIGPIPE class:
# implementing the cap as `git ... | head -c N` makes git take SIGPIPE, `set -euo pipefail`
# propagates it, and the wrapper's `||` fallback chains then substitute DIFFERENT-BUT-PLAUSIBLE
# content -- `git log --oneline -8` (all history) and `git diff --stat HEAD` (working tree) --
# while UNCOMMITTED falls through to "", whose `${UNCOMMITTED:+...}` gate DELETES the
# `## Uncommitted changes` heading and forges a clean tree. Hence assertion 2b (heading present
# AND body non-empty) and 2e (every kept line is a real, whole line of the true git output).
#
# ALSO SENTINELED: full-mode byte identity (the escape hatch and the rollback property),
# soft-resolution of an unrecognized CODEX_IPC_GIT_CONTEXT value (a note, never a refusal),
# the >=100 KB payload advisory, the nested-handoff advisory, and the invariant that both
# advisories are STDERR-ONLY with stdout byte-identical and the exit code unchanged.
#
# AC4 (falsifier discharge, recorded per owner acceptance): O2 assumes a receiving Codex
# session can re-run git at its own WORKDIR, so a bounded list is recoverable there. Existence
# proof in the operator's own transport corpus:
#   ~/.claude/ipc/2414bbfd-*/019f6ad7-9a72-*/1784297537-2035-da826d37908e277c.reply.md
# whose "Final Git and cleanup state" section reports in-sandbox `git status` branch output and
# `git diff --check main..HEAD` executed by the receiver at its own workspace. That corpus is
# operator-private and is NOT reachable from this suite or from CI; the citation is the record.
#
# NON-VACUITY, measured (2026-08-05): forcing UNCOMMITTED empty after bounding (the exact shape
# the SIGPIPE fallback produces) fails 6 assertions including the heading/body conjunct; deleting
# the line-boundary retreat and keeping the raw byte cut fails the whole-line assertion. The
# UTF-8 assertion did NOT fire under that second mutation -- a raw byte cut only splits a
# character when the boundary happens to land inside one, which is fixture-dependent.
#
# READ THE TWO ASSERTIONS THIS WAY, and do not swap their roles:
#   * 2e (whole-line) is THE CATCHER. It is deterministic: a byte-wise cut leaves a partial line,
#     and a partial line is never a whole line of the true git output, whatever bytes it carries.
#   * 2f (UTF-8 validity) is a BACKSTOP ONLY. It fires solely when the cut lands inside a
#     multibyte sequence, which depends on where the boundary happens to fall. A green 2f is NOT
#     evidence that byte-wise truncation would have been caught -- 2e is that evidence.
#   * 2g exists because a backstop over pure-ASCII content is not a backstop at all. It proves
#     the boundary actually sits in non-ASCII text in the commits section, so 2f has something to
#     back up there. Before 2026-08-05 the fixture's only non-ASCII lived in FILE PATHS, so the
#     RECENT_COMMITS boundary -- whose content is commit subjects -- was pure ASCII.
#
# SAFETY: file-drop mode ONLY. Never --ipc, no Codex/Desktop/router process, no focus, no deep
# link. CODEX_IPC_ROOT and HOME are both redirected into this suite's mktemp dir and the fixture
# is a throwaway git repo, so no real transport root, session state or repo is read or written.
# Retention is pinned to keep-only (0) so no sweep can run.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout.
WRAPPER=""
for _base in "$ROOT/skills/ipc" "$ROOT"; do
    if [[ -f "$_base/scripts/handoff_to_codex.sh" ]]; then
        WRAPPER="$_base/scripts/handoff_to_codex.sh"
        break
    fi
done

# ---- constants mirrored from the wrapper -------------------------------------------------
# These are CHOSEN ceilings, not measured ones. Assertion 1 proves the wrapper still declares
# exactly these values, so the numbers below can never drift away from the ones in force.
EXPECT_UNCOMMITTED_MAX=8192
EXPECT_DIFF_STAT_MAX=4096
EXPECT_RECENT_COMMITS_MAX=4096
EXPECT_WARN_BYTES=102400

# Pre-bounding commit, used for the full-mode byte-identity baseline. Resolved with `git show`,
# so it needs full history; where it is unreachable (shallow clone, installed layout with no
# repo) that ONE assertion reports unavailable and the structural identity check in 4a still
# runs. Both are needed: 4a proves the sections are the raw command output, 4b proves the whole
# payload is unchanged.
BASELINE_REF="2855e52a9c261c75bf5e469a1a14b21e9375e43a"

PASS=0
FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if [[ -z "$WRAPPER" ]]; then
    echo "FATAL: handoff_to_codex.sh not found in repo or installed layout" >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "FATAL: git is required to build the hermetic fixture repository" >&2
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "FATAL: node is required for the UTF-8 validity assertion (iconv is absent on Git Bash)" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# UTF-8 validity by round-trip: decoding invalid bytes yields U+FFFD, so re-encoding cannot
# reproduce the original buffer. One short-lived node per call (the gate runner's owned-Node
# peak bound is 2).
utf8_ok() { # utf8_ok <file>
    node -e 'const fs=require("fs");const b=fs.readFileSync(process.argv[1]);process.exit(Buffer.compare(Buffer.from(b.toString("utf8"),"utf8"),b)===0?0:1)' "$1"
}

# Body of one `## ` section of a rendered payload, with trailing blank lines removed. The
# heredoc puts a blank line before the next heading, so that blank is framing, not content.
section_body() { # section_body <payload-file> <exact heading line> -> stdout
    awk -v h="$2" 'BEGIN{on=0} $0==h{on=1;next} on && /^## /{exit} on{print}' "$1" \
        | awk '{lines[NR]=$0} END{last=NR; while(last>0 && lines[last]==""){last--} for(i=1;i<=last;i++) print lines[i]}'
}

# Byte size of a section BODY as it sits in the payload: section_body prints a trailing newline
# the interpolated variable does not carry, so subtract it.
section_bytes() { # section_bytes <body-file>
    local n; n=$(wc -c < "$1" | tr -d ' ')
    if [[ "$n" -gt 0 ]]; then echo $((n-1)); else echo 0; fi
}

echo "== git-context bounding + payload advisories =="
echo "  wrapper: ${WRAPPER#$ROOT/}"

# ---- 1. the wrapper still declares the caps this suite asserts ---------------------------
CAPS_OK=1
grep -q "^GIT_CONTEXT_UNCOMMITTED_MAX=${EXPECT_UNCOMMITTED_MAX}\$"      "$WRAPPER" || CAPS_OK=0
grep -q "^GIT_CONTEXT_DIFF_STAT_MAX=${EXPECT_DIFF_STAT_MAX}\$"          "$WRAPPER" || CAPS_OK=0
grep -q "^GIT_CONTEXT_RECENT_COMMITS_MAX=${EXPECT_RECENT_COMMITS_MAX}\$" "$WRAPPER" || CAPS_OK=0
grep -q "^PAYLOAD_WARN_BYTES=${EXPECT_WARN_BYTES}\$"                    "$WRAPPER" || CAPS_OK=0
if [[ "$CAPS_OK" -eq 1 ]]; then
    ok "wrapper declares the four named constants this suite asserts (${EXPECT_RECENT_COMMITS_MAX}/${EXPECT_DIFF_STAT_MAX}/${EXPECT_UNCOMMITTED_MAX}/${EXPECT_WARN_BYTES})"
else
    no "wrapper's git-context/advisory constants drifted from this suite's expectations"
fi

# ---- hermetic fixture repository -----------------------------------------------------------
# Deliberately oversized: every one of the three sections must exceed its cap, or the bounding
# assertions would be vacuous. Two paths carry non-ASCII characters and core.quotepath is off,
# so raw multibyte sequences reach the truncation boundary and a byte-wise cut would be caught
# by the UTF-8 assertion rather than passing on ASCII-only input.
FIX="$TMP/fixture-repo"
NFILES=320
NCOMMITS=30
# $'...' so the bytes reach the FILENAME; a plain "\xc3\xa9" in a redirect target is literal.
MB_ACCENT=$'caf\xc3\xa9-r\xc3\xa9sum\xc3\xa9-module.js'
MB_EURO=$'\xe2\x82\xac-pricing-table-component.js'
# Multibyte filler for COMMIT SUBJECTS (2-byte and 3-byte sequences both represented), so the
# recent-commits truncation boundary sits in non-ASCII text rather than in ASCII filler.
MB_SUBJECT_FILL=$'--caf\xc3\xa9-r\xc3\xa9sum\xc3\xa9-\xe2\x82\xac-\xc3\xa9\xc3\xa8\xc3\xaa--'
build_fixture() {
    mkdir -p "$FIX" || return 1
    git init -q "$FIX" >/dev/null 2>&1 || return 1
    git -C "$FIX" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || return 1
    git -C "$FIX" config user.email "fixture@example.invalid" || return 1
    git -C "$FIX" config user.name "Bound Fixture" || return 1
    git -C "$FIX" config commit.gpgsign false || return 1
    git -C "$FIX" config core.quotepath false || return 1
    # LF everywhere, on both legs: keeps the byte counts below platform-independent and stops
    # git from printing a CRLF-conversion warning per file into the suite's output.
    git -C "$FIX" config core.autocrlf false || return 1
    git -C "$FIX" config core.safecrlf false || return 1
    local i
    mkdir -p "$FIX/src"
    for ((i=0; i<NFILES; i++)); do
        printf 'module.exports = function widget%03d() { return %d; };\n' "$i" "$i" \
            > "$FIX/src/module-group-$(printf '%03d' $((i/16)))-component-$(printf '%03d' "$i").js"
    done
    printf 'export const caf = "cafe\xc3\xa9";\n' > "$FIX/src/$MB_ACCENT"
    printf 'export const eur = "\xe2\x82\xac";\n'  > "$FIX/src/$MB_EURO"
    git -C "$FIX" add -A >/dev/null 2>&1 || return 1
    git -C "$FIX" commit -q -m "fixture: initial scaffold" >/dev/null 2>&1 || return 1
    git -C "$FIX" update-ref refs/remotes/origin/main HEAD || return 1
    git -C "$FIX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || return 1
    git -C "$FIX" checkout -q -b feature/bounding >/dev/null 2>&1 || return 1
    # Long subjects so `git log --oneline main..HEAD` clears its 4096 B cap in few commits.
    # EVERY subject is multibyte-DENSE, so the RECENT_COMMITS cut necessarily lands between two
    # non-ASCII lines (asserted in 2g). Sprinkling the fill through the subject rather than
    # prefixing it once keeps the boundary in non-ASCII text wherever within a subject it falls.
    for ((i=0; i<NCOMMITS; i++)); do
        printf 'module.exports = function widget%03d() { return %d; };\n' "$i" $((i+1000)) \
            > "$FIX/src/module-group-$(printf '%03d' $((i/16)))-component-$(printf '%03d' "$i").js"
        git -C "$FIX" commit -q -am \
            "fixture: committed change $(printf '%03d' "$i") ${MB_SUBJECT_FILL} a deliberately long subject line ${MB_SUBJECT_FILL} so that git log --oneline over this branch ${MB_SUBJECT_FILL} exceeds the recent-commits byte ceiling ${MB_SUBJECT_FILL} in few commits" \
            >/dev/null 2>&1 || return 1
    done
    # Dirty the whole tree: this is the section that used to be unbounded.
    for ((i=0; i<NFILES; i++)); do
        printf 'module.exports = function widget%03d() { return %d; }; // uncommitted\n' "$i" $((i+2000)) \
            > "$FIX/src/module-group-$(printf '%03d' $((i/16)))-component-$(printf '%03d' "$i").js"
    done
    printf 'export const caf = "cafe\xc3\xa9"; // uncommitted\n' > "$FIX/src/$MB_ACCENT"
    printf 'export const eur = "\xe2\x82\xac"; // uncommitted\n'  > "$FIX/src/$MB_EURO"
}
if ! build_fixture; then
    echo "FATAL: could not build the hermetic git fixture in $FIX" >&2
    exit 1
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Ground truth, captured by running the SAME commands the wrapper runs, in the fixture.
( cd "$FIX" && git status --short )                > "$TMP/truth-uncommitted"
( cd "$FIX" && git diff --stat main )              > "$TMP/truth-diffstat"
( cd "$FIX" && git log --oneline main..HEAD )      > "$TMP/truth-commits"
TRUTH_UNCOMMITTED_LINES=$(wc -l < "$TMP/truth-uncommitted" | tr -d ' ')
TRUTH_UNCOMMITTED_BYTES=$(section_bytes "$TMP/truth-uncommitted")
TRUTH_DIFFSTAT_BYTES=$(section_bytes "$TMP/truth-diffstat")
TRUTH_COMMITS_BYTES=$(section_bytes "$TMP/truth-commits")
if [[ "$TRUTH_UNCOMMITTED_BYTES" -gt "$EXPECT_UNCOMMITTED_MAX" \
   && "$TRUTH_DIFFSTAT_BYTES"    -gt "$EXPECT_DIFF_STAT_MAX" \
   && "$TRUTH_COMMITS_BYTES"     -gt "$EXPECT_RECENT_COMMITS_MAX" ]]; then
    ok "fixture exceeds all three caps (uncommitted ${TRUTH_UNCOMMITTED_BYTES} B / diffstat ${TRUTH_DIFFSTAT_BYTES} B / commits ${TRUTH_COMMITS_BYTES} B)"
else
    no "fixture is too small to exercise the caps (uncommitted ${TRUTH_UNCOMMITTED_BYTES} B / diffstat ${TRUTH_DIFFSTAT_BYTES} B / commits ${TRUTH_COMMITS_BYTES} B) -- every bounding assertion below would be vacuous"
fi

# ---- render helper -------------------------------------------------------------------------
# Sets R_RC / R_STDOUT / R_STDERR / R_FILE. stdout and stderr are captured to SEPARATE files:
# proving the advisories never touch stdout is the whole point of assertion 5c.
R_RC=0; R_STDOUT=""; R_STDERR=""; R_FILE=""
IPCROOT="$TMP/ipc"
FAKEHOME="$TMP/home"
mkdir -p "$IPCROOT" "$FAKEHOME"
do_render() { # do_render <tag> <git-context-value|-> <task> [wrapper-override]
    local tag="$1" mode="$2" task="$3" wrapper="${4:-$WRAPPER}"
    local before after
    R_STDOUT="$TMP/out-$tag"; R_STDERR="$TMP/err-$tag"
    before="$(find "$IPCROOT" -type f -name '*.task.md' 2>/dev/null | LC_ALL=C sort)"
    if [[ "$mode" == "-" ]]; then
        ( cd "$FIX" && env -u CODEX_IPC_GIT_CONTEXT -u CODEX_IPC_INCLUDE_TRANSCRIPT \
            -u CODEX_REASONING_EFFORT -u CLAUDE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
            HOME="$FAKEHOME" CODEX_IPC_ROOT="$IPCROOT" CLAUDE_SESSION_ID="bound-fixture" \
            CODEX_IPC_RETENTION_DAYS=0 \
            bash "$wrapper" "$task" ) > "$R_STDOUT" 2> "$R_STDERR"
    else
        ( cd "$FIX" && env -u CODEX_IPC_INCLUDE_TRANSCRIPT -u CODEX_REASONING_EFFORT \
            -u CLAUDE_TRANSCRIPT -u CLAUDE_CODE_SESSION_ID \
            HOME="$FAKEHOME" CODEX_IPC_ROOT="$IPCROOT" CLAUDE_SESSION_ID="bound-fixture" \
            CODEX_IPC_RETENTION_DAYS=0 CODEX_IPC_GIT_CONTEXT="$mode" \
            bash "$wrapper" "$task" ) > "$R_STDOUT" 2> "$R_STDERR"
    fi
    R_RC=$?
    after="$(find "$IPCROOT" -type f -name '*.task.md' 2>/dev/null | LC_ALL=C sort)"
    R_FILE="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep . | head -1)"
}

SMALL_TASK="Review src/example.js for edge cases and add the missing null-input guard."

# ---- 2. bounded (DEFAULT) render -------------------------------------------------------------
do_render bounded-default - "$SMALL_TASK"
if [[ "$R_RC" -eq 0 && -n "$R_FILE" ]]; then
    ok "default render (CODEX_IPC_GIT_CONTEXT unset) exited 0 and published one envelope"
else
    no "default render exited $R_RC / published '$R_FILE'"
    sed 's/^/    /' "$R_STDERR"
fi
BOUNDED_FILE="$R_FILE"
BOUNDED_STDOUT="$R_STDOUT"

if [[ -n "$BOUNDED_FILE" ]]; then
    section_body "$BOUNDED_FILE" "## Uncommitted changes"               > "$TMP/b-uncommitted"
    section_body "$BOUNDED_FILE" "## Files changed vs main"             > "$TMP/b-diffstat"
    section_body "$BOUNDED_FILE" "## Commits on this branch (not yet on main)" > "$TMP/b-commits"

    # 2a. each section is within its cap.
    B_UNC=$(section_bytes "$TMP/b-uncommitted")
    B_DIF=$(section_bytes "$TMP/b-diffstat")
    B_COM=$(section_bytes "$TMP/b-commits")
    if [[ "$B_UNC" -le "$EXPECT_UNCOMMITTED_MAX" && "$B_DIF" -le "$EXPECT_DIFF_STAT_MAX" \
       && "$B_COM" -le "$EXPECT_RECENT_COMMITS_MAX" ]]; then
        ok "all three sections are within their caps (${B_COM}/${EXPECT_RECENT_COMMITS_MAX}, ${B_DIF}/${EXPECT_DIFF_STAT_MAX}, ${B_UNC}/${EXPECT_UNCOMMITTED_MAX} B)"
    else
        no "a section breached its cap (commits ${B_COM}/${EXPECT_RECENT_COMMITS_MAX}, diffstat ${B_DIF}/${EXPECT_DIFF_STAT_MAX}, uncommitted ${B_UNC}/${EXPECT_UNCOMMITTED_MAX} B)"
    fi

    # 2b. THE SIGPIPE CONJUNCT: heading present, body non-empty, real content (not just a notice).
    if grep -qax '## Uncommitted changes' "$BOUNDED_FILE" \
       && [[ "$B_UNC" -gt 0 ]] \
       && [[ "$(grep -c '^ M ' "$TMP/b-uncommitted")" -gt 0 ]]; then
        ok "'## Uncommitted changes' heading is present and its body carries real status entries"
    else
        no "'## Uncommitted changes' heading or body was lost -- the payload now reads as a clean tree"
    fi

    # 2c. the truncation notice is present in each bounded section, and names local recovery only.
    NOTICES=0
    for f in "$TMP/b-uncommitted" "$TMP/b-diffstat" "$TMP/b-commits"; do
        grep -q '^\[\.\.\. truncated at [0-9]* B of [0-9]* B; [0-9]* more line(s) omitted -- ' "$f" \
            && NOTICES=$((NOTICES+1))
    done
    if [[ "$NOTICES" -eq 3 ]]; then
        ok "all three bounded sections carry a truncation notice"
    else
        no "only $NOTICES/3 bounded sections carry a truncation notice"
    fi
    if grep -qi 're-dispatch\|redispatch\|ask the dispatcher\|ask your dispatcher' "$BOUNDED_FILE"; then
        no "a truncation notice suggests re-dispatching; the remedies must be local ones"
    else
        ok "no notice suggests re-dispatch or asking the dispatcher"
    fi

    # 2d. the notice's omitted-line count matches fixture truth.
    KEPT_UNC_LINES=$(grep -cv '^\[\.\.\. truncated at ' "$TMP/b-uncommitted")
    CLAIMED=$(sed -n 's/^\[\.\.\. truncated at [0-9]* B of [0-9]* B; \([0-9]*\) more line(s) omitted.*/\1/p' "$TMP/b-uncommitted" | head -1)
    EXPECTED_OMITTED=$((TRUTH_UNCOMMITTED_LINES - KEPT_UNC_LINES))
    if [[ -n "$CLAIMED" && "$CLAIMED" -eq "$EXPECTED_OMITTED" ]]; then
        ok "uncommitted notice claims $CLAIMED omitted lines; fixture truth is $TRUTH_UNCOMMITTED_LINES - $KEPT_UNC_LINES = $EXPECTED_OMITTED"
    else
        no "uncommitted notice claims '$CLAIMED' omitted lines but fixture truth is $EXPECTED_OMITTED"
    fi

    # 2e. line-boundary: every kept line is a WHOLE line of the true git output.
    grep -v '^\[\.\.\. truncated at ' "$TMP/b-uncommitted" > "$TMP/b-uncommitted-body"
    STRAY="$(grep -Fxv -f "$TMP/truth-uncommitted" "$TMP/b-uncommitted-body" 2>/dev/null)"
    if [[ -z "$STRAY" ]]; then
        ok "every kept uncommitted line is a whole line of the real git status output (no mid-line cut)"
    else
        no "a kept line is not a whole line of the real git status output (mid-line cut):"
        printf '%s\n' "$STRAY" | head -3 | sed 's/^/      /'
    fi

    # 2f. the whole payload is valid UTF-8. BACKSTOP ONLY -- see the header: 2e is the catcher,
    # and this fires only when the cut happens to land inside a multibyte sequence.
    if utf8_ok "$BOUNDED_FILE"; then
        ok "the bounded payload is valid UTF-8 end to end"
    else
        no "the bounded payload contains invalid UTF-8 -- a truncation split a multibyte sequence"
    fi

    # 2g. the backstop has something to back up: the recent-commits boundary sits in non-ASCII
    # text. Without this, 2f is structurally unable to fire in the one section whose content is
    # commit subjects, and a green 2f would be reporting on the path sections alone.
    KEPT_COM_N=$(grep -cv '^\[\.\.\. truncated at ' "$TMP/b-commits")
    KEPT_COM_LAST="$(grep -v '^\[\.\.\. truncated at ' "$TMP/b-commits" | tail -1)"
    FIRST_OMITTED_COM="$(sed -n "$((KEPT_COM_N+1))p" "$TMP/truth-commits")"
    if [[ "$KEPT_COM_N" -gt 0 && -n "$FIRST_OMITTED_COM" ]] \
       && printf '%s' "$KEPT_COM_LAST"     | LC_ALL=C grep -q '[^ -~]' \
       && printf '%s' "$FIRST_OMITTED_COM" | LC_ALL=C grep -q '[^ -~]'; then
        ok "the recent-commits cut falls between two non-ASCII commit subjects (kept ${KEPT_COM_N} lines)"
    else
        no "the recent-commits cut does not sit in non-ASCII text -- the UTF-8 backstop is vacuous there"
    fi
else
    no "no bounded envelope to inspect; assertions 2a-2g skipped"
fi

# ---- 3. soft-resolution of an unrecognized value ---------------------------------------------
do_render soft-resolve "no-such-mode" "$SMALL_TASK"
if [[ "$R_RC" -eq 0 ]]; then
    ok "an unrecognized CODEX_IPC_GIT_CONTEXT value still exits 0 (soft-resolve, never a refusal)"
else
    no "an unrecognized CODEX_IPC_GIT_CONTEXT value changed the exit code to $R_RC"
fi
if grep -q 'CODEX_IPC_GIT_CONTEXT="no-such-mode" is not a recognized value' "$R_STDERR"; then
    ok "the soft-resolve note is emitted on stderr and names the offending value"
else
    no "no soft-resolve note on stderr for an unrecognized value"
fi
if [[ -n "$R_FILE" ]] \
   && section_body "$R_FILE" "## Uncommitted changes" | grep -q '^\[\.\.\. truncated at ' ; then
    ok "an unrecognized value resolves to BOUNDED semantics (sections are truncated)"
else
    no "an unrecognized value did not resolve to bounded semantics"
fi
if [[ -s "$R_STDOUT" ]] && ! grep -qi 'not a recognized value' "$R_STDOUT"; then
    ok "the soft-resolve note did not contaminate stdout"
else
    no "stdout is empty or carries the soft-resolve note"
fi

# ---- 4. full mode reproduces the pre-bounding payload ------------------------------------------
do_render full full "$SMALL_TASK"
FULL_FILE="$R_FILE"
if [[ "$R_RC" -eq 0 && -n "$FULL_FILE" ]]; then
    ok "CODEX_IPC_GIT_CONTEXT=full render exited 0 and published one envelope"
else
    no "full render exited $R_RC / published '$FULL_FILE'"
fi
# 4a. structural identity: each section IS the raw command output, byte for byte, uncapped.
if [[ -n "$FULL_FILE" ]]; then
    section_body "$FULL_FILE" "## Uncommitted changes"                       > "$TMP/f-uncommitted"
    section_body "$FULL_FILE" "## Files changed vs main"                     > "$TMP/f-diffstat"
    section_body "$FULL_FILE" "## Commits on this branch (not yet on main)"  > "$TMP/f-commits"
    RAWDIFF=0
    cmp -s "$TMP/f-uncommitted" "$TMP/truth-uncommitted" || RAWDIFF=1
    cmp -s "$TMP/f-diffstat"    "$TMP/truth-diffstat"    || RAWDIFF=1
    cmp -s "$TMP/f-commits"     "$TMP/truth-commits"     || RAWDIFF=1
    if [[ "$RAWDIFF" -eq 0 ]]; then
        ok "full mode reproduces all three sections as the raw, uncapped git output"
    else
        no "full mode altered at least one section relative to the raw git output"
    fi
else
    no "no full-mode envelope to inspect"
fi

# 4b. whole-payload byte identity against the pre-bounding wrapper, normalized only for the
# per-dispatch nonce and the generation timestamp (both are unique per run by construction).
normalize() { # normalize <payload> <out>
    sed -e 's/[0-9]\{10\}-[0-9]\{1,\}-[0-9a-f]\{16\}/DISPATCH_ID/g' \
        -e 's/^Generated: .*/Generated: NORMALIZED/' "$1" > "$2"
}
BASELINE_WRAPPER="$TMP/baseline_handoff.sh"
if git -C "$ROOT" cat-file -e "${BASELINE_REF}:skills/ipc/scripts/handoff_to_codex.sh" 2>/dev/null \
   && git -C "$ROOT" show "${BASELINE_REF}:skills/ipc/scripts/handoff_to_codex.sh" > "$BASELINE_WRAPPER" 2>/dev/null; then
    do_render baseline - "$SMALL_TASK" "$BASELINE_WRAPPER"
    BASE_FILE="$R_FILE"
    if [[ "$R_RC" -eq 0 && -n "$BASE_FILE" && -n "$FULL_FILE" ]]; then
        normalize "$BASE_FILE" "$TMP/n-base"
        normalize "$FULL_FILE" "$TMP/n-full"
        if cmp -s "$TMP/n-base" "$TMP/n-full"; then
            ok "full-mode payload is byte-identical to the pre-bounding wrapper's (${BASELINE_REF:0:7}), modulo dispatch id and timestamp"
        else
            no "full-mode payload diverged from the pre-bounding wrapper's (${BASELINE_REF:0:7}):"
            diff "$TMP/n-base" "$TMP/n-full" | head -12 | sed 's/^/      /'
        fi
    else
        no "could not render the ${BASELINE_REF:0:7} baseline wrapper (rc=$R_RC)"
    fi
else
    echo "  (baseline ${BASELINE_REF:0:7} unreachable in this checkout: byte-identity vs the pre-bounding wrapper not asserted; 4a still ran)"
fi

# ---- 5. oversized-payload advisory ---------------------------------------------------------
mk_big() { local i n="$1"; for ((i=0;i<n;i++)); do
    printf 'log line %05d: the quick brown fox jumps over the lazy dog 0123456789\n' "$i"; done; }
BIG_TASK="$(mk_big 1600)"
do_render big - "$BIG_TASK"
BIG_STDOUT="$R_STDOUT"; BIG_STDERR="$R_STDERR"
BIG_BYTES=0
[[ -n "$R_FILE" ]] && BIG_BYTES=$(wc -c < "$R_FILE" | tr -d ' ')
if [[ "$R_RC" -eq 0 && "$BIG_BYTES" -ge "$EXPECT_WARN_BYTES" ]]; then
    ok "oversized fixture produced a ${BIG_BYTES} B envelope (>= ${EXPECT_WARN_BYTES} B) and still exited 0"
else
    no "oversized fixture produced ${BIG_BYTES} B / rc=$R_RC -- the advisory assertions would be vacuous"
fi
if grep -q "^WARNING: handoff payload is [0-9]* B (advisory threshold ${EXPECT_WARN_BYTES} B)" "$BIG_STDERR"; then
    ok "the oversized-payload advisory fired on stderr and names the byte count"
else
    no "no oversized-payload advisory on stderr for a >= ${EXPECT_WARN_BYTES} B payload"
fi
if grep -q 'Largest git-context section: "' "$BIG_STDERR" \
   && grep -qi 'git commit / git stash' "$BIG_STDERR" \
   && grep -q 'CODEX_IPC_GIT_CONTEXT' "$BIG_STDERR"; then
    ok "the advisory names the dominant git-context section, a local remedy, and the git-context knob"
else
    no "the advisory is missing the dominant section, the local remedy, or the git-context knob"
fi
if grep -qi 're-dispatch\|redispatch\|ask the dispatcher\|ask your dispatcher' "$BIG_STDERR"; then
    no "the advisory suggests re-dispatching or asking the dispatcher; only local remedies are permitted"
else
    ok "the advisory suggests no re-dispatch and no dispatcher round-trip"
fi
# 5b. it does NOT fire on a small payload, and that path writes nothing to stderr at all.
if ! grep -q '^WARNING: handoff payload is' "$TMP/err-bounded-default"; then
    ok "the advisory does not fire on the small-task render"
else
    no "the advisory fired on a payload below the threshold"
fi
if [[ ! -s "$TMP/err-bounded-default" ]]; then
    ok "the default small-task render writes nothing to stderr"
else
    no "the default small-task render wrote unexpected stderr:"
    sed 's/^/      /' "$TMP/err-bounded-default" | head -5
fi
# 5c. stdout is byte-identical between the warning and non-warning paths (modulo the nonce).
normalize "$BOUNDED_STDOUT" "$TMP/n-out-small"
normalize "$BIG_STDOUT"     "$TMP/n-out-big"
if cmp -s "$TMP/n-out-small" "$TMP/n-out-big"; then
    ok "stdout is byte-identical with and without the advisory (advisories are stderr-only)"
else
    no "stdout differs between the advisory and non-advisory paths:"
    diff "$TMP/n-out-small" "$TMP/n-out-big" | head -8 | sed 's/^/      /'
fi

# ---- 6. nested-handoff advisory --------------------------------------------------------------
NEST_TASK="$(printf '%s\n' \
    '# Handoff from Claude Code -> Codex' \
    '' \
    'Generated: 2026-01-01 00:00:00 UTC on branch `x` (dispatch 0000000000-0-0000000000000000)' \
    '' \
    '## How to use this file' \
    'You (Codex) have been handed follow-up work from a Claude Code session.' \
    '' \
    '## Task' \
    'do the thing')"
do_render nested - "$NEST_TASK"
if [[ "$R_RC" -eq 0 ]] && grep -q '^WARNING: the task text appears to embed a full prior handoff payload' "$R_STDERR"; then
    ok "the nesting advisory fires when the task carries BOTH markers (exit code still 0)"
else
    no "the nesting advisory did not fire on a task embedding a full prior handoff (rc=$R_RC)"
fi
do_render nested-mention - "Please review the handoff process and the '## How to use this file' section of our docs."
if [[ "$R_RC" -eq 0 ]] && ! grep -q 'embed a full prior handoff' "$R_STDERR"; then
    ok "the nesting advisory does NOT fire on a task quoting only ONE marker"
else
    no "the nesting advisory fired on a task carrying only one marker (false positive)"
fi
do_render nested-word - "Summarize what a handoff is and when to use one."
if [[ "$R_RC" -eq 0 ]] && ! grep -q 'embed a full prior handoff' "$R_STDERR"; then
    ok "the nesting advisory does NOT fire on a task merely mentioning 'handoff'"
else
    no "the nesting advisory fired on a task merely mentioning 'handoff' (false positive)"
fi

# ---- 7. the same bound under git's DEFAULT core.quotepath ------------------------------------
# Every leg above pins core.quotepath=false so RAW multibyte path bytes reach the truncation
# boundary -- deliberately the harder input for the cut, but NOT what a real operator runs. At
# git's default, `git status --short` C-escapes each non-ASCII path byte (\303\251), which
# LENGTHENS those lines and moves the boundary. The bound, the heading, and the whole-line
# retreat must hold there too, so the suite exercises both configurations rather than only the
# one it constructed. Ordered last: it mutates the fixture's git config.
git -C "$FIX" config --unset core.quotepath >/dev/null 2>&1
( cd "$FIX" && git status --short ) > "$TMP/truth-uncommitted-qp"
if LC_ALL=C grep -q '\\3[0-7][0-7]' "$TMP/truth-uncommitted-qp"; then
    ok "at default core.quotepath git escapes the non-ASCII paths (the leg below is not a rerun)"
else
    no "default core.quotepath produced no escaped path; this leg duplicates the quotepath=false one"
fi
do_render quotepath-default - "$SMALL_TASK"
QP_FILE="$R_FILE"
if [[ "$R_RC" -eq 0 && -n "$QP_FILE" ]]; then
    ok "default-core.quotepath render exited 0 and published one envelope"
else
    no "default-core.quotepath render exited $R_RC / published '$QP_FILE'"
fi
if [[ -n "$QP_FILE" ]]; then
    section_body "$QP_FILE" "## Uncommitted changes" > "$TMP/q-uncommitted"
    Q_UNC=$(section_bytes "$TMP/q-uncommitted")
    if [[ "$Q_UNC" -le "$EXPECT_UNCOMMITTED_MAX" ]] \
       && grep -qax '## Uncommitted changes' "$QP_FILE" \
       && [[ "$Q_UNC" -gt 0 ]] \
       && grep -q '^\[\.\.\. truncated at ' "$TMP/q-uncommitted"; then
        ok "at default core.quotepath the uncommitted section is bounded (${Q_UNC}/${EXPECT_UNCOMMITTED_MAX} B), kept, and noticed"
    else
        no "at default core.quotepath the uncommitted section is ${Q_UNC} B / heading or notice missing"
    fi
    grep -v '^\[\.\.\. truncated at ' "$TMP/q-uncommitted" > "$TMP/q-uncommitted-body"
    QSTRAY="$(grep -Fxv -f "$TMP/truth-uncommitted-qp" "$TMP/q-uncommitted-body" 2>/dev/null)"
    if [[ -z "$QSTRAY" ]]; then
        ok "at default core.quotepath every kept line is still a whole line of the real git output"
    else
        no "at default core.quotepath a kept line is not a whole line of the real git output:"
        printf '%s\n' "$QSTRAY" | head -3 | sed 's/^/      /'
    fi
    if utf8_ok "$QP_FILE"; then
        ok "the default-core.quotepath payload is valid UTF-8 end to end"
    else
        no "the default-core.quotepath payload contains invalid UTF-8"
    fi
fi

# ---- 8. containment ---------------------------------------------------------------------------
ESCAPED=0
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in "$TMP"/*) ;; *) ESCAPED=1 ;; esac
done < <(find "$IPCROOT" -type f -name '*.task.md' 2>/dev/null)
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
