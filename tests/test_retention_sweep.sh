#!/usr/bin/env bash
# Retention-sweep survival harness for handoff_to_codex.sh (WS-7).
#
# The opportunistic bounded-retention sweep must never age-delete an UNREPLIED
# *.task.md envelope: a task with no same-dispatch *.reply.md sibling is an
# outstanding (never-answered) dispatch, and deleting it is silent data loss.
# Contract under test:
#   * an aged unreplied *.task.md SURVIVES the sweep, regardless of age;
#   * an aged task+reply PAIR is swept exactly as before;
#   * an aged orphaned *.reply.md (terminal artifact) is swept as before;
#   * fresh files are untouched;
#   * the aged empty-dir sweep is unchanged;
#   * CODEX_IPC_RETENTION_DAYS=0 disables the sweep entirely;
#   * the script's retention doc text states the unreplied exemption.
#
# Hermetic: everything runs against a mktemp transport root; file-drop mode only,
# so no node/codex/powershell stubs and no real transport root are involved.
set -uo pipefail

# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout
# (tests/ inside the skill root, scripts/ as sibling) are both supported byte-identically.
TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT=""
for _cand in "$TDIR/../skills/ipc/scripts/handoff_to_codex.sh" "$TDIR/../scripts/handoff_to_codex.sh"; do
    [[ -f "$_cand" ]] && SCRIPT="$_cand" && break
done
[[ -n "$SCRIPT" ]] || { echo "FATAL: handoff_to_codex.sh not found in repo or installed layout" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

age(){ touch -d '10 days ago' "$@"; }  # well past the default 7-day horizon

# seed_root <root>: builds the retention matrix in a foreign channel (a session
# other than the one whose dispatch triggers the sweep).
seed_root(){
  local ch="$1/sweepsess/filedrop"
  mkdir -p "$ch"
  printf 'aged unreplied\n'    > "$ch/1000-1-aaaaaaaaaaaaaaaa.task.md"   # survival subject
  printf 'aged pair task\n'    > "$ch/1000-2-bbbbbbbbbbbbbbbb.task.md"   # replied: sweepable
  printf 'aged pair reply\n'   > "$ch/1000-2-bbbbbbbbbbbbbbbb.reply.md"
  printf 'aged orphan reply\n' > "$ch/1000-3-cccccccccccccccc.reply.md"  # terminal: sweepable
  age "$ch/1000-1-aaaaaaaaaaaaaaaa.task.md" \
      "$ch/1000-2-bbbbbbbbbbbbbbbb.task.md" \
      "$ch/1000-2-bbbbbbbbbbbbbbbb.reply.md" \
      "$ch/1000-3-cccccccccccccccc.reply.md"
  printf 'fresh unreplied\n'   > "$ch/2000-4-dddddddddddddddd.task.md"   # fresh: untouched
  printf 'fresh pair task\n'   > "$ch/2000-5-eeeeeeeeeeeeeeee.task.md"
  printf 'fresh pair reply\n'  > "$ch/2000-5-eeeeeeeeeeeeeeee.reply.md"
  mkdir -p "$1/aged-empty"                                               # empty-dir sweep subject
  age "$1/aged-empty"
}

run_dispatch(){ # run_dispatch <root> [env VAR=VAL ...] -> OUT/RC; a plain file-drop dispatch triggers the sweep
  local root="$1"; shift
  # Hermetic: unset any INHERITED CODEX_IPC_RETENTION_DAYS so a section that means to
  # exercise the DEFAULT actually gets the default, not the runner's ambient value.
  # A caller that wants a specific retention passes it explicitly in "$@" and `env`
  # applies it after this -u, so the explicit value still wins.
  OUT="$( cd "$NOREPO" && env -u CODEX_IPC_RETENTION_DAYS "$@" CODEX_IPC_ROOT="$root" CLAUDE_CODE_SESSION_ID="sweeper" bash "$SCRIPT" "sweep trigger task" 2>&1 )"; RC=$?
}

echo "== 1. survival matrix under an explicit 7-day sweep =="
R1="$TMP/root1"; seed_root "$R1"
CH1="$R1/sweepsess/filedrop"
run_dispatch "$R1" CODEX_IPC_RETENTION_DAYS=7
[[ $RC -eq 0 ]] && ok "dispatch exits 0" || no "dispatch failed (rc=$RC): $OUT"
[[ -f "$CH1/1000-1-aaaaaaaaaaaaaaaa.task.md" ]] \
    && ok "aged UNREPLIED task survives the sweep" \
    || no "aged unreplied task was age-deleted (silent data loss for a never-answered dispatch)"
[[ ! -f "$CH1/1000-2-bbbbbbbbbbbbbbbb.task.md" ]] \
    && ok "aged replied task swept (pair remains sweepable)" \
    || no "aged replied task not swept"
[[ ! -f "$CH1/1000-2-bbbbbbbbbbbbbbbb.reply.md" ]] \
    && ok "aged pair reply swept" \
    || no "aged pair reply not swept"
[[ ! -f "$CH1/1000-3-cccccccccccccccc.reply.md" ]] \
    && ok "aged orphaned reply swept (terminal artifact)" \
    || no "aged orphaned reply not swept"
[[ -f "$CH1/2000-4-dddddddddddddddd.task.md" ]] \
    && ok "fresh unreplied task untouched" \
    || no "fresh unreplied task deleted"
[[ -f "$CH1/2000-5-eeeeeeeeeeeeeeee.task.md" && -f "$CH1/2000-5-eeeeeeeeeeeeeeee.reply.md" ]] \
    && ok "fresh pair untouched" \
    || no "fresh pair deleted"
[[ ! -d "$R1/aged-empty" ]] \
    && ok "aged empty dir pruned (empty-dir sweep unchanged)" \
    || no "aged empty dir not pruned"
[[ -n "$(find "$R1/sweeper/filedrop" -name '*.task.md' 2>/dev/null)" ]] \
    && ok "triggering dispatch still writes its own envelope" \
    || no "triggering dispatch envelope missing"

echo "== 2. CODEX_IPC_RETENTION_DAYS=0 disables the sweep entirely =="
R2="$TMP/root2"; seed_root "$R2"
CH2="$R2/sweepsess/filedrop"
run_dispatch "$R2" CODEX_IPC_RETENTION_DAYS=0
[[ $RC -eq 0 ]] && ok "dispatch exits 0 with retention disabled" || no "dispatch failed (rc=$RC): $OUT"
n2="$(find "$CH2" -type f \( -name '*.task.md' -o -name '*.reply.md' \) 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n2" == "7" ]] && ok "all 7 seeded envelopes retained (7/7)" || no "retention-disabled sweep deleted files ($n2/7 remain)"
[[ -d "$R2/aged-empty" ]] && ok "aged empty dir retained when disabled" || no "aged empty dir deleted despite 0"

echo "== 3. exemption survives repeat sweeps (idempotent retention, not a one-run grace) =="
run_dispatch "$R1" CODEX_IPC_RETENTION_DAYS=7
[[ -f "$CH1/1000-1-aaaaaaaaaaaaaaaa.task.md" ]] \
    && ok "aged unreplied task still present after a second sweep" \
    || no "second sweep deleted the unreplied task"

echo "== 4. once the reply ARRIVES and ages, the pair becomes sweepable =="
printf 'late reply\n' > "$CH1/1000-1-aaaaaaaaaaaaaaaa.reply.md"
age "$CH1/1000-1-aaaaaaaaaaaaaaaa.task.md" "$CH1/1000-1-aaaaaaaaaaaaaaaa.reply.md"
run_dispatch "$R1" CODEX_IPC_RETENTION_DAYS=7
[[ ! -f "$CH1/1000-1-aaaaaaaaaaaaaaaa.task.md" && ! -f "$CH1/1000-1-aaaaaaaaaaaaaaaa.reply.md" ]] \
    && ok "answered-then-aged pair is swept (exemption is pairing-based, not permanent)" \
    || no "answered aged pair not swept"

echo "== 5. aged task with a FRESH reply is a replied pair: task swept, fresh reply kept =="
R3="$TMP/root3"; CH3="$R3/sweepsess/filedrop"; mkdir -p "$CH3"
printf 'aged answered task\n' > "$CH3/3000-6-ffffffffffffffff.task.md"
printf 'fresh late reply\n'   > "$CH3/3000-6-ffffffffffffffff.reply.md"
age "$CH3/3000-6-ffffffffffffffff.task.md"
run_dispatch "$R3" CODEX_IPC_RETENTION_DAYS=7
[[ ! -f "$CH3/3000-6-ffffffffffffffff.task.md" ]] \
    && ok "aged answered task swept even when its reply is fresh" \
    || no "aged answered task not swept"
[[ -f "$CH3/3000-6-ffffffffffffffff.reply.md" ]] \
    && ok "fresh reply untouched" \
    || no "fresh reply deleted"

echo "== 6. the DEFAULT is keep-only: pruning requires an explicit positive opt-in =="
# Regression guard for the v0.1.8 default flip. Previously the default was 7, so a
# caller that never mentioned retention silently age-deleted transport evidence --
# including replies nobody had harvested. Deletion is now strictly opt-in.
R4="$TMP/root4"; seed_root "$R4"
CH4="$R4/sweepsess/filedrop"
run_dispatch "$R4"                      # no CODEX_IPC_RETENTION_DAYS in the environment
[[ $RC -eq 0 ]] && ok "default dispatch exits 0" || no "default dispatch failed (rc=$RC): $OUT"
SURV4=$(find "$CH4" -type f \( -name '*.task.md' -o -name '*.reply.md' \) | wc -l)
[[ "$SURV4" -eq 7 ]] \
    && ok "all 7 seeded envelopes retained under the default (7/7)" \
    || no "default sweep deleted transport evidence ($SURV4/7 survived; default must be keep-only)"
[[ -d "$R4/aged-empty" ]] \
    && ok "aged empty dir retained under the default" \
    || no "default sweep pruned an aged directory"

echo "== 7. retention doc text states the unreplied exemption =="
grep -qi 'unreplied' "$SCRIPT" \
    && ok "script documentation mentions the unreplied-task exemption" \
    || no "script documentation does not mention the unreplied-task exemption"

echo "== 8. non-canonical retention values are rejected LOUDLY before any envelope write =="
# Regression guard for the octal hole: 08/09 pass a bare ^[0-9]+$ but throw
# "value too great for base" in Bash octal arithmetic, which previously skipped the
# sweep while still publishing. Every non-canonical value must exit nonzero with zero
# envelopes written.
R8="$TMP/root8"; mkdir -p "$R8"
for badval in 08 09 -1 3.5 " " 1x; do
    ch="$R8/sweepsess/filedrop"; rm -rf "$ch"
    run_dispatch "$R8" CODEX_IPC_RETENTION_DAYS="$badval"
    made=$(find "$R8" -name '*.task.md' 2>/dev/null | wc -l)
    [[ "$RC" -ne 0 && "$made" -eq 0 ]] \
        && ok "value '$badval' rejected (rc=$RC, 0 envelopes)" \
        || no "value '$badval' NOT rejected safely (rc=$RC, envelopes=$made)"
done
# And a valid value still dispatches.
R8b="$TMP/root8b"; run_dispatch "$R8b" CODEX_IPC_RETENTION_DAYS=7
[[ "$RC" -eq 0 && "$(find "$R8b" -name '*.task.md'|wc -l)" -eq 1 ]] \
    && ok "canonical value '7' still dispatches" \
    || no "canonical value '7' failed to dispatch (rc=$RC)"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit $FAIL
