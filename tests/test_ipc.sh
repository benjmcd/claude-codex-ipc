#!/usr/bin/env bash
# Isolated verification harness for the rebuilt handoff_to_codex.sh.
# Tests the transport FILE-PLANE (root resolution, per-(session,thread,dispatch) keying,
# atomic non-truncating write, flag-guard/mis-invocation absorption, repo/CWD-independence,
# missing-session-id safety). The live Codex delivery path (router/autoload) is stubbed:
# `node`/`powershell.exe` are faked so no real thread is touched; `codex` is an inert
# tripwire proving that no wrapper path invokes the Codex CLI.
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
IPCROOT="$TMP/ipcroot"; mkdir -p "$IPCROOT"
BIN="$TMP/bin"; mkdir -p "$BIN"
REPO="$TMP/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
UUID="00000000-0000-4000-8000-000000000000"

# --- stubs on PATH (node records argv; codex/powershell are no-ops) ---
cat > "$BIN/node" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/nodeargs.log"
echo '{"ok":true}'
exit 0
EOF
cat > "$BIN/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/codexargs.log"
exit 0
EOF
cat > "$BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN"/*

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
run(){ # run(cwd, sid, args...) -> stdout in $OUT, exit in $RC
  local cwd="$1" sid="$2"; shift 2
  OUT="$( cd "$cwd" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="$sid" PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>&1 )"; RC=$?
}
taskfiles(){ find "$IPCROOT" -name '*.task.md' 2>/dev/null; }
count_task(){ taskfiles | wc -l | tr -d ' '; }

echo "== 1. file-drop basic keying =="
run "$REPO" "sessA" "do the thing"
f=$(find "$IPCROOT/sessA/filedrop" -name '*.task.md' 2>/dev/null | head -1)
[[ $RC -eq 0 ]] && ok "exit 0" || no "exit 0 (rc=$RC)"
[[ -n "$f" ]] && ok "keyed task file under sessA/filedrop" || no "no keyed task file"
[[ -n "$f" ]] && grep -qx "do the thing" "$f" && ok "task body written verbatim" || no "task body missing"
[[ -n "$f" ]] && grep -q "\.reply\.md" "$f" && ok "payload points reply at per-dispatch .reply.md" || no "reply path missing"
printf '%s' "$OUT" | grep -q "$(cygpath -m "$f" 2>/dev/null || echo "$f")" && ok "prints absolute task path" || no "task path not printed"

echo "== 2. isolation: two sessions never share a file =="
run "$REPO" "sessB" "task b"
[[ -d "$IPCROOT/sessA" && -d "$IPCROOT/sessB" ]] && ok "separate per-session dirs" || no "sessions not isolated"

echo "== 3. no truncation: two dispatches, same session =="
before=$(find "$IPCROOT/sessA" -name '*.task.md' | wc -l | tr -d ' ')
run "$REPO" "sessA" "second dispatch"
after=$(find "$IPCROOT/sessA" -name '*.task.md' | wc -l | tr -d ' ')
[[ "$after" -gt "$before" ]] && ok "second dispatch is a NEW file (first not overwritten): $before -> $after" || no "dispatch overwrote prior (count $before -> $after)"

echo "== 4a. flag absorb: --ipc <uuid> --allow-any-thread \"real task\" =="
: > "$TMP/nodeargs.log"
run "$REPO" "sessC" --ipc "$UUID" --allow-any-thread "the real task"
tf=$(find "$IPCROOT/sessC/$UUID" -name '*.task.md' 2>/dev/null | head -1)
[[ -n "$tf" ]] && grep -qx "the real task" "$tf" && ok "real task used (flag absorbed, not captured as task)" || no "task body wrong: $(grep -A0 -m1 . "$tf" 2>/dev/null)"
[[ -n "$tf" ]] && ! grep -qx -- "--allow-any-thread" "$tf" && ok "no '--allow-any-thread' as task body" || no "flag leaked into task body"
grep -q -- "--allow-any-thread" "$TMP/nodeargs.log" && ok "client still receives --allow-any-thread (send-gate)" || no "client lost --allow-any-thread"
grep -q -- '--task read "' "$TMP/nodeargs.log" && ok "client told to read the keyed task path (double-quoted)" || no "client task pointer wrong"

echo "== 4b. flag-guard: a stray flag as task fails closed =="
run "$REPO" "sessD" "--bogus-flag"
[[ $RC -ne 0 ]] && ok "exit nonzero on flag-as-task" || no "did not fail closed (rc=$RC)"
[[ -z "$(find "$IPCROOT/sessD" -name '*.task.md' 2>/dev/null)" ]] && ok "no task file written on guarded failure" || no "wrote a file despite guard"

echo "== 5. repo/CWD-independence: works outside any git repo =="
run "$NOREPO" "sessE" "task with no repo"
nf=$(find "$IPCROOT/sessE/filedrop" -name '*.task.md' 2>/dev/null | head -1)
[[ $RC -eq 0 && -n "$nf" ]] && ok "file-drop works with no git repo" || no "failed outside a repo (rc=$RC)"
[[ -n "$nf" ]] && grep -q "not in a git repository" "$nf" && ok "payload notes no-repo context" || no "no-repo note missing"

echo "== 6. missing session id: isolated token, no transcript guess =="
OUT6="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" PATH="$BIN:$PATH" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$SCRIPT" "task no sid" 2>&1 )"; RC6=$?
nosiddir=$(find "$IPCROOT" -maxdepth 1 -type d -name 'nosid-*' 2>/dev/null | head -1)
[[ $RC6 -eq 0 && -n "$nosiddir" ]] && ok "runs with an isolated nosid-* token" || no "missing-sid handling failed (rc=$RC6)"
sf=$(find "$nosiddir" -name '*.task.md' 2>/dev/null | head -1)
[[ -n "$sf" ]] && grep -q "transcript path omitted by default" "$sf" && ok "transcript pointer omitted without opt-in" || no "transcript not omitted by default"

echo "== 6b. transcript disclosure is OPT-IN and never guessed =="
# default (sid present, no opt-in): omitted
run "$REPO" "sessT" "task with sid, no opt-in"
tf6=$(find "$IPCROOT/sessT/filedrop" -name '*.task.md' 2>/dev/null | head -1)
[[ -n "$tf6" ]] && grep -q "transcript path omitted by default" "$tf6" && ok "sid present, no opt-in -> transcript omitted" || no "transcript leaked without opt-in"
# opt-in but no sid: fail-closed "unavailable", never guessed. Select the dispatch
# deterministically by its unique task body (mtime -newer is same-second flaky).
OUT6B="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_INCLUDE_TRANSCRIPT=1 PATH="$BIN:$PATH" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$SCRIPT" "task opt-in no sid" 2>&1 )"; RC6B=$?
tf6b=""
while IFS= read -r f; do
    grep -qx "task opt-in no sid" "$f" && { tf6b="$f"; break; }
done < <(find "$IPCROOT" -path '*nosid-*' -name '*.task.md' 2>/dev/null)
[[ $RC6B -eq 0 && -n "$tf6b" ]] && grep -q "transcript path unavailable" "$tf6b" && ok "opt-in without sid -> unavailable (not guessed)" || no "opt-in/no-sid transcript handling wrong (rc=$RC6B)"
# explicit override honored only under opt-in
OUT6D="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_TRANSCRIPT="$TMP/fake-transcript.jsonl" CLAUDE_CODE_SESSION_ID="sessT2" PATH="$BIN:$PATH" bash "$SCRIPT" "no opt-in with explicit override" 2>&1 )"
tf6c=$(find "$IPCROOT/sessT2/filedrop" -name '*.task.md' 2>/dev/null | head -1)
OUT6C="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_INCLUDE_TRANSCRIPT=1 CLAUDE_TRANSCRIPT="$TMP/fake-transcript.jsonl" CLAUDE_CODE_SESSION_ID="sessT3" PATH="$BIN:$PATH" bash "$SCRIPT" "opt-in with explicit override" 2>&1 )"; RC6C=$?
tf6d=$(find "$IPCROOT/sessT3/filedrop" -name '*.task.md' 2>/dev/null | head -1)
[[ -n "$tf6d" ]] && grep -q "fake-transcript.jsonl" "$tf6d" && ok "opt-in honors explicit CLAUDE_TRANSCRIPT override" || no "opt-in override not honored"
[[ -n "$tf6c" ]] && ! grep -q "fake-transcript.jsonl" "$tf6c" && ok "override ignored without opt-in" || no "override leaked without opt-in"

echo "== 7. atomic write leaves no temp files =="
[[ -z "$(find "$IPCROOT" -name '*.task.md.*' 2>/dev/null)" ]] && ok "no leftover mktemp temp files" || no "temp files left behind"

echo "== 8. multi-thread grace: one session -> N threads, each its own dir =="
U1="11111111-1111-4111-8111-111111111111"; U2="22222222-2222-4222-8222-222222222222"
: > "$TMP/nodeargs.log"
run "$REPO" "sessM" --ipc "$U1" "task for thread one"
run "$REPO" "sessM" --ipc "$U2" "task for thread two"
[[ -d "$IPCROOT/sessM/$U1" && -d "$IPCROOT/sessM/$U2" ]] && ok "two conversationIds -> two sibling thread dirs" || no "threads not isolated under the session"
t1=$(find "$IPCROOT/sessM/$U1" -name '*.task.md' | head -1); t2=$(find "$IPCROOT/sessM/$U2" -name '*.task.md' | head -1)
[[ -n "$t1" && -n "$t2" ]] && grep -qx "task for thread one" "$t1" && grep -qx "task for thread two" "$t2" && ok "each thread's task is in its own channel (no mixing)" || no "thread task bodies mixed/missing"

echo "== 9. --ipc happy path: gui-delivered, exit 0 =="
run "$REPO" "sessH" --ipc "$UUID" "deliver me"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-delivered" && ok "reports gui-delivered and exits 0" || no "ipc happy path wrong (rc=$RC)"
printf '%s' "$OUT" | grep -q "reply will be written to" && ok "advertises the keyed reply path" || no "reply-path notice missing"

echo "== 10. TRUE concurrency: 20 parallel dispatches across 2 sessions, no collision =="
pids=()
for i in $(seq 1 20); do
  ( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="conc$((i % 2))" PATH="$BIN:$PATH" bash "$SCRIPT" "parallel $i" >/dev/null 2>&1 ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
cnt=$(find "$IPCROOT/conc0" "$IPCROOT/conc1" -name '*.task.md' 2>/dev/null | wc -l | tr -d ' ')
[[ "$cnt" -eq 20 ]] && ok "20 concurrent dispatches -> 20 distinct files (no clobber)" || no "concurrency collision: got $cnt/20"

echo "== 11. rapid-fire same-session uniqueness (15 in a tight loop) =="
for i in $(seq 1 15); do run "$REPO" "rapid" "burst $i"; done
rc=$(find "$IPCROOT/rapid/filedrop" -name '*.task.md' 2>/dev/null | wc -l | tr -d ' ')
[[ "$rc" -eq 15 ]] && ok "15 rapid dispatches -> 15 unique files" || no "rapid-fire collision: $rc/15"

echo "== 11b. create-once: a same-name destination is a HARD ERROR, never a silent overwrite =="
# Source the wrapper's own atomic_write so the test exercises the SHIPPING primitive,
# not a reimplementation. `_TEST_SOURCE_ONLY` makes the script define functions and
# return before doing any dispatch work.
CO="$TMP/create-once"; mkdir -p "$CO"
( set -e
  _TEST_SOURCE_ONLY=1 . "$SCRIPT" 2>/dev/null || true
  # Case 1: fresh destination publishes and the staging link is cleaned up.
  printf 'first\n'  | atomic_write "$CO/env.task.md"
  [[ "$(cat "$CO/env.task.md")" == "first" ]] || { echo "CO-FAIL: first write wrong content"; exit 3; }
  [[ -z "$(find "$CO" -name 'env.task.md.*' 2>/dev/null)" ]] || { echo "CO-FAIL: staging residue left"; exit 3; }
  # Case 2: a colliding write FAILS (nonzero) and does NOT alter the existing bytes.
  if printf 'second\n' | atomic_write "$CO/env.task.md" 2>/dev/null; then echo "CO-FAIL: overwrite succeeded"; exit 3; fi
  [[ "$(cat "$CO/env.task.md")" == "first" ]] || { echo "CO-FAIL: existing bytes clobbered"; exit 3; }
  # Case 3: a directory sitting at the destination is refused, not linked into.
  mkdir -p "$CO/dir.task.md"
  if printf 'x\n' | atomic_write "$CO/dir.task.md" 2>/dev/null; then echo "CO-FAIL: linked into a directory dest"; exit 3; fi
  [[ -z "$(find "$CO/dir.task.md" -type f 2>/dev/null)" ]] || { echo "CO-FAIL: created a link inside the dir dest"; exit 3; }
  # Case 4: no staging residue remains after the failing cases either.
  [[ "$(find "$CO" -name '*.task.md.*' 2>/dev/null | wc -l)" -eq 0 ]] || { echo "CO-FAIL: staging residue after failures"; exit 3; }
)
[[ $? -eq 0 ]] && ok "create-once: fresh publishes, collision + directory-dest fail closed, no residue" \
              || no "create-once publication defect (see CO-FAIL above)"

echo "== 11c. an EXECUTED wrapper ignores an inherited _TEST_SOURCE_ONLY (no silent suppression) =="
# The test seam must be honored only when SOURCED. An inherited value in the environment
# of an executed dispatch must NOT silently exit 0 without publishing.
SS="$TMP/sourceseam/filedrop"; mkdir -p "$(dirname "$SS")"
_TEST_SOURCE_ONLY=1 CODEX_IPC_ROOT="$TMP/sourceseam" CLAUDE_CODE_SESSION_ID="seam" \
    bash "$SCRIPT" "seam-executed task" >/dev/null 2>&1
seam_rc=$?
seam_made=$(find "$TMP/sourceseam" -name '*.task.md' 2>/dev/null | wc -l)
[[ "$seam_rc" -eq 0 && "$seam_made" -eq 1 ]] \
    && ok "executed wrapper dispatched despite inherited _TEST_SOURCE_ONLY=1 (rc=$seam_rc, 1 envelope)" \
    || no "inherited _TEST_SOURCE_ONLY suppressed a real executed dispatch (rc=$seam_rc, envelopes=$seam_made)"

echo "== 12. removed Codex-CLI modes fail before transport access or child launch =="
REMOVED_ENV="$TMP/removed-mode-probe.sh"
REMOVED_EMPTY_PATH="$TMP/removed-empty-path"; mkdir -p "$REMOVED_EMPTY_PATH"
cat > "$REMOVED_ENV" <<'EOF'
cd() {
  builtin printf 'builtin:cd\n' >> "$REMOVED_PROBE_LOG"
  return 97
}
command_not_found_handle() {
  builtin printf 'external:%s\n' "$1" >> "$REMOVED_PROBE_LOG"
  return 127
}
EOF
for flag in --app --open --exec; do
  removed_root="$TMP/removed-root-${flag#--}"
  removed_log="$TMP/removed-${flag#--}.log"
  : > "$removed_log"
  expected="ERROR: $flag was removed in v0.1.8 (No Codex CLI); use positional file-drop (\"task\") or --ipc <conversationId> \"task\"."
  OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$removed_root" CLAUDE_CODE_SESSION_ID="removed" \
      REMOVED_PROBE_LOG="$removed_log" BASH_ENV="$REMOVED_ENV" PATH="$REMOVED_EMPTY_PATH" \
      "$BASH" "$SCRIPT" "$flag" "ignored" 2>&1 )"; RC=$?
  [[ $RC -eq 64 ]] && ok "$flag exits with stable status 64" || no "$flag exit changed (rc=$RC)"
  [[ "$OUT" == "$expected" ]] && ok "$flag emits the exact replacement error" || no "$flag error changed: $OUT"
  [[ ! -e "$removed_root" ]] && ok "$flag creates no transport root or envelope" || no "$flag wrote transport state"
  [[ ! -s "$removed_log" ]] && ok "$flag performs no root read or child-command attempt" \
    || no "$flag touched the root or attempted a child: $(cat "$removed_log")"
done

echo "== 13. apostrophe in transport root: pickup string stays quote-safe =="
QROOT="$TMP/ob'rien/ipc"; mkdir -p "$QROOT"
OUTQ="$( cd "$REPO" && CODEX_IPC_ROOT="$QROOT" CLAUDE_CODE_SESSION_ID="sessQ" PATH="$BIN:$PATH" bash "$SCRIPT" "task in apostrophe root" 2>&1 )"; RCQ=$?
[[ $RCQ -eq 0 ]] && ok "runs with an apostrophe in the root" || no "failed with apostrophe root (rc=$RCQ)"
printf '%s' "$OUTQ" | grep -q 'read "' && ok "pickup line double-quotes the path (apostrophe cannot break it)" || no "pickup line not double-quoted"

# ============================================================================
# Foreground-policy suite (14+). Uses stateful stubs: node dispatches by script
# name with a first-send-fail mode; powershell.exe records args and exits with a
# configured code. Timing knobs keep negative poll cases under ~3s.
# ============================================================================
FGDIR="$TMP/fg"; BIN2="$TMP/bin2"; mkdir -p "$FGDIR" "$BIN2"
UUIDF="33333333-3333-4333-8333-333333333333"

cat > "$BIN2/node" <<EOF
#!/usr/bin/env bash
FG="$FGDIR"
case "\$*" in
  *codex_ipc_client.mjs*)
    printf '%s\n' "\$*" >> "\$FG/nodeargs.log"
    n=\$(cat "\$FG/send_count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$FG/send_count"
    mode=\$(cat "\$FG/client_mode" 2>/dev/null || echo always-ok)
    case "\$mode" in
      always-ok) echo '{"ok": true}'; exit 0;;
      always-fail) echo '{ "error": "no-client-found" }'; exit 1;;
      fail-then-ok)
        if [[ "\$n" -le 1 ]]; then echo '{ "error": "no-client-found" }'; exit 1
        else echo '{"ok": true}'; exit 0; fi;;
    esac;;
  *codex_ipc_session_inspect.mjs*)
    mode=\$(cat "\$FG/inspect_mode" 2>/dev/null || echo ok)
    case "\$mode" in
      ok)        printf '{\n  "ok": true,\n  "thread": { "archived": 0 }\n}\n'; exit 0;;
      okarchived) printf '{\n  "ok": true,\n  "thread": { "archived": 1 }\n}\n'; exit 1;;
      notfound)  printf '{\n  "ok": false\n}\n'; exit 1;;
      malformed) echo '{{{ not json'; exit 0;;
      empty)     exit 0;;
      stderr)    echo "boom: inspector crashed" >&2; exit 1;;
    esac;;
  *codex_ipc_rollout_observe.mjs*)
    printf '%s\n' "\$*" >> "\$FG/observe_args.log"
    n=\$(cat "\$FG/observe_count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$FG/observe_count"
    mode=\$(cat "\$FG/observe_mode" 2>/dev/null || echo rollout-hit)
    case "\$mode" in
      rollout-hit|rollout-pending|rollout-unavailable) echo "\$mode"; exit 0;;
      crash)      echo "boom: observer crashed" >&2; exit 1;;
      empty)      exit 0;;
      garbage)    echo "not-an-observation-token"; exit 0;;
      timeout)    echo "observer timed out" >&2; exit 124;;
      spawn-fail) echo "observer could not start" >&2; exit 127;;
    esac;;
  *) echo '{"ok": true}'; exit 0;;
esac
EOF
cat > "$BIN2/powershell.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FGDIR/pslog"
exit "\$(cat "$FGDIR/pscode" 2>/dev/null || echo 0)"
EOF
cat > "$BIN2/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FGDIR/codexargs.log"
exit 0
EOF
chmod +x "$BIN2"/*

fgreset(){ # fgreset <client_mode> [inspect_mode] [pscode]
  rm -f "$FGDIR"/send_count "$FGDIR"/nodeargs.log "$FGDIR"/pslog \
        "$FGDIR"/observe_count "$FGDIR"/observe_args.log
  echo "${1}" > "$FGDIR/client_mode"
  echo "${2:-ok}" > "$FGDIR/inspect_mode"
  echo "${3:-0}" > "$FGDIR/pscode"
  echo "${4:-rollout-hit}" > "$FGDIR/observe_mode"
}
fgrun(){ # fgrun <wrapper args...> -> OUT/RC (fast poll knobs; hermetic PATH)
  OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="fgsess" \
      CODEX_IPC_POLL_DEADLINE_S=2 CODEX_IPC_POLL_INTERVAL_S=1 \
      PATH="$BIN2:$PATH" bash "$SCRIPT" "$@" 2>&1 )"; RC=$?
}
TAX_RE='^RESULT: (gui-delivered|gui-unowned|failed-closed) -- reason=[a-z0-9-]+ -- confirmation=[a-z0-9-]+$'
assert_tax(){ # every RESULT line in $OUT must match the parser-compatible taxonomy
  local bad
  bad="$(printf '%s\n' "$OUT" | grep '^RESULT:' | grep -vE "$TAX_RE" || true)"
  [[ -z "$bad" ]] && ok "$1: all RESULT lines parser-compatible" || { no "$1: non-conforming RESULT line"; printf '%s\n' "$bad"; }
}
assert_no_codex_cli(){
  local bad
  bad="$(
    { [[ -f "$TMP/codexargs.log" ]] && cat "$TMP/codexargs.log"; [[ -f "$FGDIR/codexargs.log" ]] && cat "$FGDIR/codexargs.log"; } || true
  )"
  [[ -z "$bad" ]] && ok "no wrapper path invoked the Codex CLI" \
    || { no "a wrapper path invoked the Codex CLI"; printf '%s\n' "$bad"; }
}

echo "== 14. default policy defer: foreground-Codex deferral is explicit =="
fgreset always-fail ok 2
fgrun --ipc "$UUIDF" "t14 defer"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-unowned -- reason=codex-foreground-deferred -- confirmation=not-attempted" && ok "defer -> gui-unowned/codex-foreground-deferred" || no "defer subreason wrong (rc=$RC)"
printf '%s' "$OUT" | grep -q "POLICY: foreground=defer (source: default) ack=none" && ok "active policy printed" || no "policy line missing"
[[ -n "$(find "$IPCROOT/fgsess/$UUIDF" -name '*.task.md' 2>/dev/null)" ]] && ok "envelope written before deferral" || no "envelope missing on deferral"
assert_tax "t14"

echo "== 15. switch without ack: fails closed BEFORE any live IPC =="
fgreset always-fail ok 0
fgrun --ipc "$UUIDF" --foreground-policy switch -- "t15 switch no ack"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "reason=foreground-switch-unacknowledged" && ok "switch-no-ack fails closed" || no "switch-no-ack (rc=$RC)"
[[ ! -f "$FGDIR/nodeargs.log" ]] && ok "no live send attempted" || no "live send attempted despite missing ack"
[[ ! -f "$FGDIR/pslog" ]] && ok "no autoload attempted" || no "autoload attempted despite missing ack"
printf '%s' "$OUT" | grep -qx 'FALLBACK -- file-drop is ready. In your Codex session, paste:' && ok "fallback preserved" || no "fallback line missing"
assert_tax "t15"

echo "== 16. switch with ack: autoload gets policy args; delivery reports foreground-switched =="
fgreset fail-then-ok ok 0
fgrun --ipc "$UUIDF" --foreground-policy switch --ack-foreground-switch -- "t16 switch ack"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-delivered -- reason=foreground-switched -- confirmation=rollout-hit" && ok "switch+ack delivers with observed confirmation" || no "switch+ack (rc=$RC)"
grep -q -- "-ForegroundPolicy switch" "$FGDIR/pslog" 2>/dev/null && grep -q -- "-AckForegroundSwitch" "$FGDIR/pslog" && ok "helper received policy + ack" || no "helper args wrong: $(cat "$FGDIR/pslog" 2>/dev/null)"
assert_tax "t16"

echo "== 17. restore-if-known: fail-closed subreason =="
fgreset always-fail ok 4
fgrun --ipc "$UUIDF" --foreground-policy restore-if-known -- "t17 restore"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-unowned -- reason=foreground-restore-unproven -- confirmation=not-attempted" && ok "restore fails closed with restore-unproven" || no "restore subreason (rc=$RC)"
assert_tax "t17"

echo "== 18. unknown helper status: fails closed, never retries =="
fgreset always-fail ok 7
fgrun --ipc "$UUIDF" "t18 unknown status"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "reason=autoload-unexpected-status" && ok "unknown helper code -> failed-closed" || no "unknown code fell through (rc=$RC)"
[[ "$(cat "$FGDIR/send_count")" == "1" ]] && ok "no live retry after unknown status" || no "retried despite unknown status ($(cat "$FGDIR/send_count") sends)"
assert_tax "t18"

echo "== 19. invalid policy value: envelope written, fails closed before live IPC =="
fgreset always-ok ok 0
fgrun --ipc "$UUIDF" --foreground-policy bogus -- "t19 invalid policy"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "reason=invalid-foreground-policy" && ok "invalid policy fails closed" || no "invalid policy (rc=$RC)"
[[ ! -f "$FGDIR/nodeargs.log" ]] && ok "no live send on invalid policy" || no "live send despite invalid policy"
tf19=""; while IFS= read -r f; do grep -qx "t19 invalid policy" "$f" && { tf19="$f"; break; }; done < <(find "$IPCROOT/fgsess" -name '*.task.md' 2>/dev/null)
[[ -n "$tf19" ]] && ok "envelope written before policy failure" || no "envelope missing on policy failure"
assert_tax "t19"

echo "== 20. inspection ambiguity: five refusals, all before autoload =="
for m in notfound:target-not-found okarchived:target-archived malformed:target-inspection-ambiguous empty:target-inspection-ambiguous stderr:target-inspection-ambiguous; do
    imode="${m%%:*}"; want="${m##*:}"
    fgreset always-fail "$imode" 0
    fgrun --ipc "$UUIDF" "t20 $imode"
    [[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "reason=${want}" && [[ ! -f "$FGDIR/pslog" ]] \
        && ok "inspect=$imode -> $want, no deep-link" || no "inspect=$imode (rc=$RC, want $want)"
done
assert_tax "t20"

echo "== 21. autoload ok but retry never succeeds: gui-unowned, not gui-delivered =="
fgreset always-fail ok 0
fgrun --ipc "$UUIDF" "t21 retry exhausted"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-unowned -- reason=autoload-incomplete -- confirmation=not-attempted" && ok "poll exhaustion -> autoload-incomplete" || no "poll exhaustion (rc=$RC)"
! printf '%s' "$OUT" | grep -q "gui-delivered" && ok "never overclaims delivery" || no "overclaimed delivery"
assert_tax "t21"

echo "== 22. default-policy auto-load delivery still works (reason=auto-loaded) =="
fgreset fail-then-ok ok 0
fgrun --ipc "$UUIDF" "t22 autoload delivery"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "RESULT: gui-delivered -- reason=auto-loaded -- confirmation=rollout-hit" && ok "auto-loaded delivery observed" || no "auto-loaded delivery (rc=$RC)"
assert_tax "t22"

echo "== 23. '--' delimiter: dash-leading task accepted; trailing junk rejected =="
fgreset always-ok ok 0
fgrun --ipc "$UUIDF" -- "--task-that-looks-like-a-flag"
tf23=""; while IFS= read -r f; do grep -qx -- "--task-that-looks-like-a-flag" "$f" && { tf23="$f"; break; }; done < <(find "$IPCROOT/fgsess" -name '*.task.md' 2>/dev/null)
[[ $RC -eq 0 && -n "$tf23" ]] && ok "dash task delivered verbatim after --" || no "dash task (rc=$RC)"
fgreset always-ok ok 0
fgrun --ipc "$UUIDF" -- "task" "trailing-junk"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "unexpected trailing argument" && ok "trailing junk rejected" || no "trailing junk accepted (rc=$RC)"
fgreset always-ok ok 0
fgrun --ipc "$UUIDF" --bogus-flag -- "task"
[[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "unknown --ipc flag" && ok "unknown flag rejected" || no "unknown flag accepted (rc=$RC)"

echo "== 24. standing approval env: acts as ack and is printed =="
fgreset fail-then-ok ok 0
OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="fgsess" \
    CODEX_IPC_POLL_DEADLINE_S=2 CODEX_IPC_POLL_INTERVAL_S=1 \
    CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL=1 \
    PATH="$BIN2:$PATH" bash "$SCRIPT" --ipc "$UUIDF" --foreground-policy switch -- "t24 standing" 2>&1 )"; RC=$?
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "ack=standing-approval-env" && printf '%s' "$OUT" | grep -q "reason=foreground-switched" && ok "standing approval honored and disclosed" || no "standing approval (rc=$RC)"
assert_tax "t24"

echo "== 25. renderer-owned success maps each observer token without changing delivery =="
for token in rollout-hit rollout-pending rollout-unavailable; do
    fgreset always-ok ok 0 "$token"
    fgrun --ipc "$UUIDF" "t25 $token"
    [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -qx "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=${token}" \
        && ok "$token preserves renderer-owned delivery" || no "$token mapping (rc=$RC)"
    [[ "$(cat "$FGDIR/observe_count" 2>/dev/null || echo 0)" == "1" ]] \
        && grep -q -- "--thread $UUIDF --dispatch " "$FGDIR/observe_args.log" 2>/dev/null \
        && ok "$token observes once with thread + dispatch" || no "$token observer contract"
    assert_tax "t25-$token"
done

echo "== 26. observer failures normalize to unavailable after accepted send =="
for mode in crash empty garbage timeout spawn-fail; do
    fgreset always-ok ok 0 "$mode"
    fgrun --ipc "$UUIDF" "t26 $mode"
    [[ $RC -eq 0 ]] \
        && printf '%s' "$OUT" | grep -qx "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=rollout-unavailable" \
        && [[ "$(printf '%s\n' "$OUT" | grep -c '^RESULT:')" == "1" ]] \
        && [[ "$(cat "$FGDIR/send_count" 2>/dev/null || echo 0)" == "1" ]] \
        && ok "$mode preserves one accepted-send RESULT without resend" || no "$mode normalization (rc=$RC)"
    assert_tax "t26-$mode"
done

echo "== 27. pending observation after auto-load never resends =="
fgreset fail-then-ok ok 0 rollout-pending
fgrun --ipc "$UUIDF" "t27 pending no resend"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -qx "RESULT: gui-delivered -- reason=auto-loaded -- confirmation=rollout-pending" \
    && ok "auto-loaded pending preserves delivery" || no "auto-loaded pending (rc=$RC)"
[[ "$(cat "$FGDIR/send_count" 2>/dev/null || echo 0)" == "2" ]] \
    && [[ "$(cat "$FGDIR/observe_count" 2>/dev/null || echo 0)" == "1" ]] \
    && ok "pending adds one observation and no resend" || no "pending send/observe count"
assert_tax "t27"

echo "== 28. auto-load poll knobs reject zero/malformed values with visible fallback =="
fgknobrun(){ # fgknobrun <deadline> <interval> <client_mode> <task>
  local deadline="$1" interval="$2" client_mode="$3" task="$4"
  fgreset "$client_mode" ok 0 rollout-hit
  OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="fgsess" \
      CODEX_IPC_POLL_DEADLINE_S="$deadline" CODEX_IPC_POLL_INTERVAL_S="$interval" \
      PATH="$BIN2:$PATH" bash "$SCRIPT" --ipc "$UUIDF" "$task" 2>&1 )"; RC=$?
}

for knobcase in deadline-zero deadline-malformed interval-zero interval-malformed; do
    case "$knobcase" in
      deadline-zero)      fgknobrun 0 1 fail-then-ok "t28 $knobcase"; want="CODEX_IPC_POLL_DEADLINE_S=0";;
      deadline-malformed) fgknobrun nope 1 fail-then-ok "t28 $knobcase"; want="CODEX_IPC_POLL_DEADLINE_S=nope";;
      interval-zero)      fgknobrun 1 0 always-fail "t28 $knobcase"; want="CODEX_IPC_POLL_INTERVAL_S=0";;
      interval-malformed) fgknobrun 1 nope fail-then-ok "t28 $knobcase"; want="CODEX_IPC_POLL_INTERVAL_S=nope";;
    esac
    if [[ "$knobcase" == "interval-zero" ]]; then
        [[ $RC -ne 0 ]] && printf '%s' "$OUT" | grep -q "WARNING: ${want} must be a positive integer" \
            && [[ "$(cat "$FGDIR/send_count" 2>/dev/null || echo 0)" == "2" ]] \
            && ok "$knobcase falls back without a tight loop" || no "$knobcase fallback (rc=$RC)"
    else
        [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "WARNING: ${want} must be a positive integer" \
            && printf '%s' "$OUT" | grep -q "confirmation=rollout-hit" \
            && ok "$knobcase warns and falls back" || no "$knobcase fallback (rc=$RC)"
    fi
    assert_tax "t28-$knobcase"
done

echo "== 29. non-accepted outcomes never invoke rollout observation =="
fgreset always-fail ok 7 rollout-hit
fgrun --ipc "$UUIDF" "t29 no observation"
[[ $RC -ne 0 ]] && [[ ! -f "$FGDIR/observe_count" ]] \
    && printf '%s' "$OUT" | grep -q "RESULT: failed-closed -- reason=autoload-unexpected-status -- confirmation=not-attempted" \
    && ok "failed send remains not-attempted with no observer" || no "observer ran before acceptance (rc=$RC)"
assert_tax "t29"

echo "== 30. injected session id is contained to one segment under the transport root =="
# Regression: CLAUDE_SESSION_ID becomes a path segment, so a dot segment or separator wrote the
# envelope OUTSIDE CODEX_IPC_ROOT (audit A-02). Fail closed; never sanitize silently.
SIDROOT="$TMP/sidroot"; mkdir -p "$SIDROOT/root"
sid_run(){ ( cd "$NOREPO" && CODEX_IPC_ROOT="$SIDROOT/root" CLAUDE_SESSION_ID="$1" bash "$SCRIPT" "sid containment" >/dev/null 2>&1 ); }
esc=0
for bad in '../escape' '..' 'a/b' 'a\b' '/abs'; do
    sid_run "$bad" && esc=1
done
[[ $esc -eq 0 ]] && ok "unsafe session ids fail closed" || no "an unsafe session id was accepted"
[[ -z "$(find "$SIDROOT" -name '*.task.md' -not -path "$SIDROOT/root/*" 2>/dev/null)" ]] \
    && ok "no envelope escaped the transport root" || no "envelope written outside CODEX_IPC_ROOT"
sid_run "00000000-0000-4000-8000-000000000000" \
    && [[ -n "$(find "$SIDROOT/root" -name '*.task.md' 2>/dev/null)" ]] \
    && ok "a normal session id still writes under the root" || no "valid session id rejected"

echo "== 31. A5 producer denied-reply protocol lands in the generated payload (E1 fixture) =="
# E1 (sanitized): a managed-sandbox reply write is denied. The generated payload must instruct the
# follower to attempt the printed reply path exactly once, not retry, and put the FULL substantive
# result in its final agent message. Assert the branch is present in BOTH a filedrop and an --ipc
# envelope (both share the one PAYLOAD scaffold).
run "$REPO" "sessE1" "review the sandboxed change and reply"
E1_FD=$(find "$IPCROOT/sessE1/filedrop" -name '*.task.md' 2>/dev/null | head -1)
if [[ -n "$E1_FD" ]] \
  && grep -q "attempt to write the printed reply path exactly once" "$E1_FD" \
  && grep -q "do NOT retry" "$E1_FD" \
  && grep -q "the full substantive result" "$E1_FD" \
  && grep -q "A one-line denial with no result is a contract violation" "$E1_FD"; then
  ok "filedrop payload carries the one-attempt / no-retry / full-final-result branch"
else
  no "filedrop payload missing the denied-reply protocol"
fi

: > "$TMP/nodeargs.log"
run "$REPO" "sessE1ipc" --ipc "$UUID" --allow-any-thread "review the sandboxed change and reply"
E1_IPC=$(find "$IPCROOT/sessE1ipc/$UUID" -name '*.task.md' 2>/dev/null | head -1)
if [[ -n "$E1_IPC" ]] \
  && grep -q "attempt to write the printed reply path exactly once" "$E1_IPC" \
  && grep -q "do NOT retry" "$E1_IPC" \
  && grep -q "the full substantive result" "$E1_IPC"; then
  ok "--ipc envelope carries the denied-reply protocol"
else
  no "--ipc payload missing the denied-reply protocol"
fi

assert_no_codex_cli

# --- A3 wrapper wait-hint (D3) + easy-path OQ-4 gate --------------------------------------
fgrun_stdout(){ # like fgrun but captures stdout ONLY (stderr discarded) to test WAIT/RESULT ordering
  OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="fgsess" \
      CODEX_IPC_POLL_DEADLINE_S=2 CODEX_IPC_POLL_INTERVAL_S=1 \
      PATH="$BIN2:$PATH" bash "$SCRIPT" "$@" 2>/dev/null )"; RC=$?
}

assert_wait_hint_then_result(){ # $1 label
  local label="$1"
  local wcount rcount wln rln last
  wcount="$(printf '%s\n' "$OUT" | grep -c '^WAIT: node ')"
  rcount="$(printf '%s\n' "$OUT" | grep -c '^RESULT:')"
  last="$(printf '%s\n' "$OUT" | tail -n1)"
  wln="$(printf '%s\n' "$OUT" | grep -n '^WAIT:' | head -1 | cut -d: -f1)"
  rln="$(printf '%s\n' "$OUT" | grep -n '^RESULT:' | head -1 | cut -d: -f1)"
  [[ "$wcount" == "1" ]] && ok "$label: exactly one runnable WAIT: hint" || no "$label: WAIT hint count=$wcount"
  printf '%s\n' "$OUT" | grep -q 'codex_ipc_wait.mjs' \
    && printf '%s\n' "$OUT" | grep -q -- '--accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000' \
    && printf '%s\n' "$OUT" | grep -q -- '--reply-path ' \
    && ok "$label: WAIT hint is runnable (wait tool + D2 flag + budget + reply-path)" || no "$label: WAIT hint content wrong"
  [[ "$rcount" == "1" ]] && ok "$label: exactly one RESULT line on stdout" || no "$label: RESULT count=$rcount"
  [[ "$last" == RESULT:* ]] && ok "$label: RESULT is the final stdout line" || no "$label: RESULT not final ($last)"
  [[ -n "$wln" && -n "$rln" && "$wln" -lt "$rln" ]] && ok "$label: WAIT precedes RESULT" || no "$label: WAIT/RESULT order (w=$wln r=$rln)"
}

echo "== 32. A3 wait hint: renderer-owned success prints WAIT: before the final RESULT =="
fgreset always-ok ok 0 rollout-hit
fgrun_stdout --ipc "$UUIDF" "t32 renderer wait hint"
assert_wait_hint_then_result "renderer-owned"

echo "== 33. A3 wait hint: auto-loaded success prints WAIT: before the final RESULT =="
fgreset fail-then-ok ok 0 rollout-hit
fgrun_stdout --ipc "$UUIDF" "t33 autoloaded wait hint"
assert_wait_hint_then_result "auto-loaded"

echo "== 34. A3 wait hint: file-drop and failed sends print NO WAIT: hint =="
FD_OUT="$( cd "$REPO" && CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID="sessNoHint" \
    PATH="$BIN:$PATH" bash "$SCRIPT" "plain filedrop task" 2>/dev/null )"
! printf '%s\n' "$FD_OUT" | grep -q '^WAIT:' && ok "file-drop prints no WAIT hint" || no "file-drop leaked a WAIT hint"
fgreset always-fail ok 2 rollout-hit
fgrun_stdout --ipc "$UUIDF" "t34 deferred failed"
! printf '%s\n' "$OUT" | grep -q '^WAIT:' && ok "a deferred (gui-unowned) send prints no WAIT hint" || no "failed send leaked a WAIT hint"
fgreset always-fail ok 0 rollout-hit
fgrun_stdout --ipc "$UUIDF" --foreground-policy switch -- "t34 switch no ack"
! printf '%s\n' "$OUT" | grep -q '^WAIT:' && ok "a switch-no-ack failed-closed send prints no WAIT hint" || no "failed-closed leaked a WAIT hint"

echo "== 35. A3 easy path: codex_ipc_wait + the verbatim OQ-4 caveat on every recovery surface =="
OQ4='resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.'
SURFACES=(
  "$TDIR/../README.md"
  "$TDIR/../docs/TROUBLESHOOTING.md"
  "$TDIR/../skills/ipc/references/troubleshooting.md"
  "$TDIR/../skills/ipc/examples/quickstart.md"
  "$TDIR/../skills/ipc/SKILL.md"
)
gate_ok=1
for s in "${SURFACES[@]}"; do
  [[ -f "$s" ]] || continue
  grep -q "codex_ipc_wait" "$s" || { gate_ok=0; echo "    missing codex_ipc_wait: $s"; }
  grep -Fq "$OQ4" "$s" || { gate_ok=0; echo "    missing verbatim OQ-4 caveat: $s"; }
done
[[ $gate_ok -eq 1 ]] && ok "every recovery surface references codex_ipc_wait and carries the verbatim OQ-4 caveat" \
  || no "a recovery surface is missing codex_ipc_wait or the OQ-4 caveat"
for s in "$TDIR/../docs/TROUBLESHOOTING.md" "$TDIR/../skills/ipc/references/troubleshooting.md"; do
  [[ -f "$s" ]] || continue
  [[ "$(grep -Fc "$OQ4" "$s")" -ge 2 ]] \
    && ok "$(basename "$s") carries OQ-4 in both the reply-missing and aborted rows" \
    || no "$(basename "$s") missing an OQ-4 row"
done
existing_surfaces=(); for s in "${SURFACES[@]}"; do [[ -f "$s" ]] && existing_surfaces+=("$s"); done
resume_bad="$(grep -Fl "resume the same goal" "${existing_surfaces[@]}" 2>/dev/null || true)"
[[ -z "$resume_bad" ]] && ok "no recovery surface says 'resume the same goal' without the caveat" \
  || no "a recovery surface says 'resume the same goal': $resume_bad"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit $FAIL
