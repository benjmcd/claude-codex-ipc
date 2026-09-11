#!/usr/bin/env bash
# codex_ipc_wait black-box conformance suite (hermetic; no live IPC)
#
# FIXED CLI CONTRACT UNDER TEST (quoted from the lane handoff):
# node skills/ipc/scripts/codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> [options]
# Options: --reply-path <path> (explicit, wins) | --transport-root <path>
# (default env CODEX_IPC_ROOT else ~/.claude/ipc) | --session <sid> (reply
# derivation <transport-root>/<sid>/<thread>/<dispatch>.reply.md; with NEITHER
# --reply-path NOR --session: scan <transport-root>/*/<thread>/<dispatch>.reply.md,
# multiple distinct hits = ambiguity, never guess) | --rollout-path <path>
# (explicit, wins) | --sessions-root <path> (locator root override) |
# --budget-ms <n> (0 default = single-shot; >0 bounded in-process re-evaluation) |
# --interval-ms <n> (strictly positive; zero/malformed -> documented default +
# visible stderr warning). Env CODEX_IPC_WAIT_BUDGET_MS /
# CODEX_IPC_WAIT_INTERVAL_MS; flags override env.
# stdout EXACTLY one line, one token: done | aborted | superseded |
# reply-missing | pending | unavailable.
# Semantics: done = a readable regular non-symlink reply file (including a
# zero-byte one) AND the dispatch's OWN turn (user_message carrying
# <dispatchId>.task.md basename; turn_id-primary correlation) reached
# task_complete un-superseded. aborted = own turn turn_aborted (regardless of
# reply presence). superseded = own turn superseded (newer task_started before
# its terminal); a later unrelated turn's terminal must NEVER certify.
# reply-missing = own turn task_complete un-superseded but reply
# absent/unreadable/present-invalid. pending = no determination yet at
# single-shot or budget expiry. unavailable = no authoritative rollout candidate
# / ambiguity (rollout or reply scan) / schema failure.
# D2 opt-in (--accept-rollout-fallback): ONLY when the reply file is genuinely
# ABSENT does a completed own turn whose verified rollout body matches its
# terminal certify done from the rollout store (replySource=rollout-fallback,
# surfaced as one stderr WAIT_DIAGNOSTIC reply-source; stdout stays one token;
# the recovered body is NEVER emitted). A present-but-invalid reply (symlink,
# non-regular, unreadable) never falls through. An absent/empty/mismatched body
# stays reply-missing. Flagless v0.1.6 stays file-primary and byte-identical.
# Diagnostics stderr only. FLAGLESS: exit 0 for every determination, nonzero
# only usage errors (byte-identical to prior releases). A6 opt-in
# --status-exit-codes maps the determination to a frozen exit code
# (done=0, pending=2, aborted=3, superseded=4, reply-missing=5, unavailable=6);
# usage errors stay exit 1 with no determination token in either mode; the token
# stays the sole stdout line. No daemon; import side-effect-free; Node builtins
# only, node:sqlite forbidden.

set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TDIR/.." && pwd)"
# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout
# (tests/ inside the skill root, scripts/ as sibling). Without this the suite self-skips in
# installed roots, where the tool exists but under a different relative path.
WAIT_TOOL="${CODEX_IPC_WAIT_TEST_TARGET:-}"
if [[ -z "$WAIT_TOOL" ]]; then
    for _cand in "$ROOT/skills/ipc/scripts/codex_ipc_wait.mjs" "$ROOT/scripts/codex_ipc_wait.mjs"; do
        [[ -f "$_cand" ]] && WAIT_TOOL="$_cand" && break
    done
fi

if [[ ! -f "$WAIT_TOOL" ]]; then
  echo "SKIP: codex_ipc_wait.mjs absent"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node absent"
  exit 0
fi

NODE_BIN="$(command -v node)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

THREAD="11111111-1111-4111-8111-111111111111"
OWN_TURN="22222222-2222-4222-8222-222222222222"
LATER_TURN="33333333-3333-4333-8333-333333333333"
DISPATCH="6100000000-1-abcdef0123456789"
PASS=0
FAIL=0
RUN_ID=0
RC=0
OUT_FILE=""
ERR_FILE=""
ELAPSED_MS=0
RUN_ENV=()
NODE_ARGS=()

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

dump_output(){
  printf '%s\n' '    --- stdout verbatim ---'
  cat "$OUT_FILE"
  printf '%s\n' '    --- end stdout ---'
  if [[ -s "$ERR_FILE" ]]; then
    printf '%s\n' '    --- stderr (first 20 lines) ---'
    sed -n '1,20p' "$ERR_FILE"
  fi
}

# Milliseconds now. Prefer bash-native EPOCHREALTIME (bash>=5): the node fallback spawns a
# process whose cold-start (2-3s under battery load) lands INSIDE the measured window and
# skews ELAPSED_MS by up to a cold-start in either direction (net error band ~±1 cold-start).
now_ms(){
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME/,/.}"
    printf '%s' "$(( ${t%%.*} * 1000 + 10#${t#*.} / 1000 ))"
  else
    "$NODE_BIN" -e 'process.stdout.write(String(Date.now()))'
  fi
}

run_wait(){
  RUN_ID=$((RUN_ID+1))
  OUT_FILE="$TMP/run-$RUN_ID.stdout"
  ERR_FILE="$TMP/run-$RUN_ID.stderr"
  local started ended
  started="$(now_ms)"
  env -u CODEX_IPC_WAIT_BUDGET_MS -u CODEX_IPC_WAIT_INTERVAL_MS \
    HOME="$TMP/home" USERPROFILE="$TMP/home" CODEX_IPC_ROOT="$TMP/default-transport" \
    NODE_NO_WARNINGS=1 "${RUN_ENV[@]}" "$NODE_BIN" "${NODE_ARGS[@]}" "$WAIT_TOOL" "$@" \
    >"$OUT_FILE" 2>"$ERR_FILE"
  RC=$?
  ended="$(now_ms)"
  ELAPSED_MS=$((ended-started))
  RUN_ENV=()
}

run_case(){
  local case_root="$1"
  shift
  mkdir -p "$case_root/sessions" "$case_root/transport" "$TMP/home"
  run_wait --thread "$THREAD" --dispatch "$DISPATCH" \
    --sessions-root "$case_root/sessions" --transport-root "$case_root/transport" "$@"
}

assert_token(){
  local expected="$1" label="$2"
  if [[ $RC -eq 0 ]] && printf '%s\n' "$expected" | cmp -s - "$OUT_FILE"; then
    ok "$label"
  else
    no "$label (expected=$expected rc=$RC elapsed=${ELAPSED_MS}ms)"
    dump_output
  fi
}

write_prefix(){
  local target="$1"
  cat >"$target" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$OWN_TURN"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"$OWN_TURN","message":"read /fixture/$DISPATCH.task.md and proceed"}}
EOF
}

write_done(){
  write_prefix "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$1"
}

write_done_without_user_turn(){
  cat >"$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$OWN_TURN"}}
{"type":"event_msg","payload":{"type":"user_message","message":"read /fixture/$DISPATCH.task.md and proceed"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"$OWN_TURN","last_agent_message":"complete"}}
EOF
}

write_pending(){ write_prefix "$1"; }

write_aborted(){
  write_prefix "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"$OWN_TURN\"}}" >>"$1"
}

write_superseded(){
  write_prefix "$1"
  cat >>"$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$LATER_TURN"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"$LATER_TURN","message":"ordinary unrelated turn"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"$LATER_TURN","last_agent_message":"unrelated complete"}}
EOF
}

write_compacted_supersession(){
  write_prefix "$1"
  cat >>"$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$LATER_TURN"}}
{"type":"event_msg","payload":{"type":"context_compacted","turn_id":"$LATER_TURN"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"$LATER_TURN","last_agent_message":null}}
EOF
}

write_completed_then_later(){
  write_done "$1"
  cat >>"$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$LATER_TURN"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"$LATER_TURN","message":"later after terminal"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"$LATER_TURN","last_agent_message":null}}
EOF
}

write_false_marker(){
  cat >"$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$LATER_TURN"}}
{"type":"response_item","payload":{"type":"function_call_output","output":"read /fixture/$DISPATCH.task.md and proceed; task_complete"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"$LATER_TURN","last_agent_message":null}}
EOF
}

make_reply(){
  mkdir -p "$(dirname "$1")"
  printf '%s\n' 'synthetic reply' >"$1"
}

tree_digest(){
  "$NODE_BIN" --input-type=module - "$1" <<'EOF'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const root = path.resolve(process.argv[2]);
const rows = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const target = path.join(dir, entry.name);
    const rel = path.relative(root, target).replaceAll(path.sep, "/");
    if (entry.isDirectory()) walk(target);
    else if (entry.isSymbolicLink()) rows.push(`L ${rel} ${fs.readlinkSync(target)}`);
    else rows.push(`F ${rel} ${crypto.createHash("sha256").update(fs.readFileSync(target)).digest("hex")}`);
  }
}
walk(root);
process.stdout.write(crypto.createHash("sha256").update(rows.join("\n")).digest("hex"));
EOF
}

echo "== 0. a turn id cannot hide a distinct later task-changing user message =="
# A turn id delimits lifecycle, but a distinct later user event can change which task the final
# body answers. Named-dispatch certification therefore fails closed.
CASE="$TMP/intervening-user"; mkdir -p "$CASE"
write_prefix "$CASE/rollout-$THREAD.jsonl"
printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"turn_id\":\"$OWN_TURN\",\"message\":\"operator note typed mid-turn\"}}" >>"$CASE/rollout-$THREAD.jsonl"
printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token unavailable "a distinct mid-turn operator message invalidates named-dispatch certification"

echo "== 1. six determination tokens and own-turn semantics =="
CASE="$TMP/done"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
BEFORE="$(tree_digest "$CASE")"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token done "done requires the own task_complete plus a regular reply"
AFTER="$(tree_digest "$CASE")"
[[ "$BEFORE" == "$AFTER" ]] && ok "determination is read-only over injected fixtures" || no "determination mutated fixture state"

CASE="$TMP/done-sequence"; mkdir -p "$CASE"; write_done_without_user_turn "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token done "user_message without turn_id correlates to its surrounding own turn"

CASE="$TMP/reply-missing"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/missing.reply.md"
assert_token reply-missing "completed own turn without a reply is reply-missing"

CASE="$TMP/pending"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token pending "reply presence cannot complete an open own turn"

CASE="$TMP/aborted"; mkdir -p "$CASE"; write_aborted "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token aborted "turn_aborted beats a present reply"

CASE="$TMP/superseded"; mkdir -p "$CASE"; write_superseded "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token superseded "later unrelated task_complete never certifies a superseded dispatch"

CASE="$TMP/compacted"; mkdir -p "$CASE"; write_compacted_supersession "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token superseded "compaction turn without a user message cannot inherit the dispatch marker"

CASE="$TMP/post-terminal"; mkdir -p "$CASE"; write_completed_then_later "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token done "a later start after the own terminal does not retroactively supersede"

CASE="$TMP/false-marker"; mkdir -p "$CASE"; write_false_marker "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token pending "marker text outside user_message cannot bind a dispatch turn"

echo "== 2. reply authority, derivation, regular-file checks, and ambiguity =="
CASE="$TMP/reply-explicit"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/transport/sid/$THREAD/$DISPATCH.reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --session sid --reply-path "$CASE/explicit-missing.md"
assert_token reply-missing "explicit reply path wins over a valid session-derived reply"

CASE="$TMP/reply-session"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/transport/sid/$THREAD/$DISPATCH.reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --session sid
assert_token done "session derives the exact transport-root reply path"

CASE="$TMP/reply-scan"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/transport/only/$THREAD/$DISPATCH.reply.md"
RUN_ENV=("CODEX_IPC_ROOT=$TMP/wrong-env-root")
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl"
assert_token done "unique reply scan works and transport-root flag overrides CODEX_IPC_ROOT"

CASE="$TMP/reply-env"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/env-root/sid/$THREAD/$DISPATCH.reply.md"
RUN_ENV=("CODEX_IPC_ROOT=$CASE/env-root")
mkdir -p "$CASE/sessions"
run_wait --thread "$THREAD" --dispatch "$DISPATCH" --sessions-root "$CASE/sessions" \
  --rollout-path "$CASE/rollout-$THREAD.jsonl" --session sid
assert_token done "CODEX_IPC_ROOT supplies the default transport root"

CASE="$TMP/reply-ambiguous"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/transport/a/$THREAD/$DISPATCH.reply.md"
make_reply "$CASE/transport/b/$THREAD/$DISPATCH.reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl"
assert_token unavailable "two distinct reply-scan hits are unavailable"

CASE="$TMP/reply-symlink"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/target.md"
if ! "$NODE_BIN" -e 'require("node:fs").symlinkSync(process.argv[1], process.argv[2])' "$CASE/target.md" "$CASE/link.md" >/dev/null 2>&1; then
  mkdir -p "$CASE/target-dir"
  "$NODE_BIN" -e 'require("node:fs").symlinkSync(process.argv[1], process.argv[2], "junction")' \
    "$CASE/target-dir" "$CASE/link.md" >/dev/null 2>&1 || true
fi
if "$NODE_BIN" -e 'process.exit(require("node:fs").lstatSync(process.argv[1]).isSymbolicLink() ? 0 : 1)' "$CASE/link.md"; then
  run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/link.md"
  assert_token reply-missing "a symlinked reply is not an eligible completion artifact"
else
  no "could not create an actual symlink for the required reply test"
fi

echo "== 3. rollout authority and schema failures =="
CASE="$TMP/no-rollout"; mkdir -p "$CASE/sessions"; make_reply "$CASE/reply.md"
run_case "$CASE" --reply-path "$CASE/reply.md"
assert_token unavailable "no authoritative rollout candidate is unavailable"

CASE="$TMP/rollout-explicit"; mkdir -p "$CASE"; make_reply "$CASE/reply.md"; write_done "$CASE/explicit-$THREAD.jsonl"
printf '%s\n' 'not a sessions directory' >"$CASE/not-a-directory"
run_wait --thread "$THREAD" --dispatch "$DISPATCH" --sessions-root "$CASE/not-a-directory" \
  --transport-root "$CASE/transport" --rollout-path "$CASE/explicit-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token done "explicit rollout path wins without consulting the locator root"

CASE="$TMP/malformed"; mkdir -p "$CASE"; write_prefix "$CASE/rollout-$THREAD.jsonl"
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"bad:\001\200"}}\n' >>"$CASE/rollout-$THREAD.jsonl"
printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\"}}" >>"$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token unavailable "malformed rollout schema is unavailable"
# Permit only HT/LF/CR used for diagnostic line framing; reject all other C0/C1 bytes.
if "$NODE_BIN" -e 'const b=require("node:fs").readFileSync(process.argv[1]); process.exit([...b].some(x => (x<=8)||(x>=11&&x<=12)||(x>=14&&x<=31)||(x>=127&&x<=159)) ? 1 : 0)' "$ERR_FILE"; then
  ok "malformed-record diagnostics do not echo raw C0/C1 bytes"
else
  no "stderr contains raw C0/C1 bytes"
fi

echo "== 4. bounded re-evaluation and option precedence =="
CASE="$TMP/single-shot"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
# Fuse must outlast run_case's spawn/assert overhead under full-battery load (a 2s fuse
# raced it; 15s raced it again once load pushed cold-starts past 4s with node-based timing),
# yet stay BELOW the 20s conflicting env budget so an env-honoring waiter is exposed three
# ways: mutation flips its token to done, the liveness probe finds the writer dead, and the
# ELAPSED_MS bound trips.
(
  sleep 18
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
) &
WRITER_PID=$!
# Conflicting env deliberately far above the pass bound: the wrong regime (honoring either
# env knob over the flags) then costs >=18s (fuse-capped), leaving a wide gap over any
# loaded correct-path cost instead of the old 5000ms floor the bound had to hug.
RUN_ENV=("CODEX_IPC_WAIT_BUDGET_MS=20000" "CODEX_IPC_WAIT_INTERVAL_MS=20000")
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" \
  --budget-ms 0 --interval-ms 25
assert_token pending "budget flag zero overrides env and performs one evaluation"
if kill -0 "$WRITER_PID" >/dev/null 2>&1; then
  ok "budget=0 returns before a scheduled fixture mutation"
  kill "$WRITER_PID" >/dev/null 2>&1 || true
  wait "$WRITER_PID" 2>/dev/null || true
else
  no "budget=0 remained alive until the fixture mutation"
  wait "$WRITER_PID" 2>/dev/null || true
fi
# correct = one spawn + one read (observed worst 7.4s under synthetic battery load; modeled <=4s); wrong =
# env-honoring sleep (floor >=18000, fuse-capped). 10000 is >=2.5x loaded-correct and >=44%
# below the wrong floor, so load cannot fail it and polling cannot pass it.
if (( ELAPSED_MS < 10000 )); then
  ok "budget=0 has no polling-sized wall-time delay (${ELAPSED_MS}ms)"
else
  no "budget=0 incurred a polling-sized delay (${ELAPSED_MS}ms)"
fi

CASE="$TMP/env-poll"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
(
  sleep 0.12
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
) &
WRITER_PID=$!
# Budget raised 1500 -> 20000 so exit-at-budget-expiry (the wrong regime) sits far above
# the bound instead of inside the loaded correct-path band.
RUN_ENV=("CODEX_IPC_WAIT_BUDGET_MS=20000" "CODEX_IPC_WAIT_INTERVAL_MS=25")
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
wait "$WRITER_PID"
assert_token done "budget and interval environment values drive in-process re-evaluation"
# correct = transition-triggered early exit (~150ms in-tool + loaded spawn overhead, observed worst ~7.4s total);
# wrong = sleeping to the 20000ms env-budget expiry. 10000 is >=2.5x loaded-correct and 50%
# below the expiry floor. Lower bound stays: it asserts the waiter really polled.
if (( ELAPSED_MS >= 60 && ELAPSED_MS < 10000 )); then
  ok "env-budget polling observed the transition within its bound (${ELAPSED_MS}ms)"
else
  no "env-budget polling timing escaped its bound (${ELAPSED_MS}ms)"
fi

CASE="$TMP/flag-poll"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
(
  sleep 0.12
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
) &
WRITER_PID=$!
RUN_ENV=("CODEX_IPC_WAIT_BUDGET_MS=0" "CODEX_IPC_WAIT_INTERVAL_MS=5000")
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" \
  --budget-ms 1000 --interval-ms 25
wait "$WRITER_PID"
assert_token done "budget and interval flags override conflicting environment values"

CASE="$TMP/budget-expiry"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" \
  --budget-ms 120 --interval-ms 20
assert_token pending "unchanged state is pending at positive-budget expiry"
# correct = 120ms budget expiry + loaded spawn overhead (observed worst ~7.4s total); wrong = an unbounded wait
# (no finite floor -- this is a hang fuse at >=2.5x the loaded correct path). Lower bound
# stays: it asserts a positive budget actually waited.
if (( ELAPSED_MS >= 60 && ELAPSED_MS < 10000 )); then
  ok "positive budget waits and exits within a bounded window (${ELAPSED_MS}ms)"
else
  no "positive budget timing escaped its bounded window (${ELAPSED_MS}ms)"
fi

CASE="$TMP/interval-zero"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" \
  --budget-ms 120 --interval-ms 0
assert_token pending "zero interval falls back and preserves determination output"
if grep -qi 'interval' "$ERR_FILE"; then
  ok "zero interval emits a visible stderr warning"
else
  no "zero interval did not emit a visible stderr warning"
fi
# correct = 120ms budget + <=250ms fallback interval + loaded spawn overhead (observed worst ~7.4s total); wrong =
# a hang or an interval misparse that never expires (no finite floor). 10000 >= 2.5x loaded-correct.
if (( ELAPSED_MS < 10000 )); then
  ok "zero interval fallback does not hang (${ELAPSED_MS}ms)"
else
  no "zero interval fallback exceeded the wall-time bound (${ELAPSED_MS}ms)"
fi

CASE="$TMP/interval-malformed"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" \
  --budget-ms 120 --interval-ms malformed
assert_token pending "malformed interval falls back and preserves determination output"
if grep -qi 'interval' "$ERR_FILE"; then
  ok "malformed interval emits a visible stderr warning"
else
  no "malformed interval did not emit a visible stderr warning"
fi
# Same regimes and margins as the zero-interval fallback bound above.
if (( ELAPSED_MS < 10000 )); then
  ok "malformed interval fallback does not hang (${ELAPSED_MS}ms)"
else
  no "malformed interval fallback exceeded the wall-time bound (${ELAPSED_MS}ms)"
fi

echo "== 4b. D2 opt-in rollout fallback (--accept-rollout-fallback) =="
# New fallback fixtures per the A1 test-correctness constraint: an agent_message.phase=final_answer
# followed by a MATCHING task_complete.last_agent_message. A genuinely-absent reply is
# fallback-eligible under the flag; the flagless path and a present-invalid reply are not.
write_done_body(){
  write_prefix "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"recovered body\",\"phase\":\"final_answer\"}}" >>"$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"recovered body\"}}" >>"$1"
}

write_terminal_selected_body(){
  write_prefix "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"SAFE\",\"phase\":\"final_answer\"}}" >>"$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"OTHER\",\"phase\":\"final_answer\"}}" >>"$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"SAFE\"}}" >>"$1"
}

write_conflicting_body(){
  write_prefix "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"SAFE\",\"phase\":\"final_answer\"}}" >>"$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"OTHER\",\"phase\":\"final_answer\"}}" >>"$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"NEITHER\"}}" >>"$1"
}

append_opaque_tail(){
  printf '%s\n' '{"type":"event_msg","payload":{"type":"future_lifecycle_event"}}' >>"$1"
}

append_exact_unsettled_duplicate(){
  cat >>"$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"$LATER_TURN"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"$LATER_TURN","message":"read /fixture/$DISPATCH.task.md and proceed"}}
EOF
}

CASE="$TMP/fallback-flagless"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md"
assert_token reply-missing "flagless: a verified rollout body does not certify a genuinely-absent reply"

run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md" \
  --accept-rollout-fallback
assert_token done "opt-in: a verified rollout body certifies done when the reply is absent"
if grep -Fxq 'WAIT_DIAGNOSTIC {"code":"reply-source","source":"rollout-fallback"}' "$ERR_FILE"; then
  ok "opt-in fallback emits exactly one rollout-fallback source diagnostic"
else
  no "opt-in fallback source diagnostic missing"; dump_output
fi
if ! grep -q "recovered body" "$OUT_FILE" "$ERR_FILE"; then
  ok "the recovered body is never emitted on stdout or stderr"
else
  no "the recovered body leaked into output"; dump_output
fi

CASE="$TMP/fallback-primary-opaque"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
append_opaque_tail "$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token unavailable "an opaque post-boundary tail keeps a historical primary unverified"
if grep -Fq '"code":"dispatch-freshness-unsettled"' "$ERR_FILE" \
  && grep -Fq '"code":"reply-unverified"' "$ERR_FILE"; then
  ok "an opaque tail keeps the historical primary visible but machine-unverified"
else
  no "opaque-tail primary diagnostics were incomplete"; dump_output
fi

CASE="$TMP/fallback-opaque"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
append_opaque_tail "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md" \
  --accept-rollout-fallback
assert_token unavailable "an opaque post-boundary tail blocks rollout-only completion"
if grep -Fq '"code":"dispatch-freshness-unsettled"' "$ERR_FILE" \
  && ! grep -Fq '"code":"reply-source","source":"rollout-fallback"' "$ERR_FILE"; then
  ok "opaque-tail fallback failure is diagnosed without granting fallback authority"
else
  no "opaque-tail fallback diagnostics or authority were wrong"; dump_output
fi

CASE="$TMP/fallback-exact-unsettled"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
append_exact_unsettled_duplicate "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md" \
  --accept-rollout-fallback
assert_token unavailable "a reused dispatch id blocks older rollout-only completion"
if grep -Fq '"code":"dispatch-id-reused"' "$ERR_FILE" \
  && ! grep -Fq '"code":"reply-source","source":"rollout-fallback"' "$ERR_FILE"; then
  ok "dispatch-id reuse remains untrusted and carries no fallback authority"
else
  no "dispatch-id reuse diagnostics or authority were wrong"; dump_output
fi

CASE="$TMP/fallback-terminal-selected"; mkdir -p "$CASE"; write_terminal_selected_body "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md" \
  --accept-rollout-fallback
assert_token done "one exact terminal copy selects a rollout fallback from distinct final bodies"
if grep -Fxq 'WAIT_DIAGNOSTIC {"code":"reply-source","source":"rollout-fallback"}' "$ERR_FILE" \
  && ! grep -q 'SAFE\|OTHER' "$OUT_FILE" "$ERR_FILE"; then
  ok "terminal-selected fallback reports rollout authority without emitting its body"
else
  no "terminal-selected rollout fallback authority was wrong"; dump_output
fi
# Owner ruling D-34 / OD-11 (2026-09-03): the waiter must disclose that the terminal copy chose
# among distinct final bodies, and the disclosure must carry no body text. Both conditions are
# read off the SAME line: matching "count":2 anywhere in the file would let an unrelated
# diagnostic satisfy the count, and the no-body condition is only meaningful about this line.
T_DISCLOSE="$(grep -F 'WAIT_DIAGNOSTIC {"code":"terminal-copy-disambiguated"' "$ERR_FILE" || true)"
if [[ -n "$T_DISCLOSE" ]] \
  && printf '%s\n' "$T_DISCLOSE" | grep -Fq '"count":2' \
  && ! printf '%s\n' "$T_DISCLOSE" | grep -q 'SAFE\|OTHER'; then
  ok "terminal-selected fallback discloses that a choice among distinct finals was made"
else
  no "terminal-selected rollout fallback did not disclose the disambiguation"; dump_output
fi

CASE="$TMP/fallback-conflict"; mkdir -p "$CASE"; write_conflicting_body "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.reply.md" \
  --accept-rollout-fallback
assert_token unavailable "distinct final bodies without an exact terminal match cannot certify fallback"
if ! grep -q 'reply-source.*rollout-fallback\|SAFE\|OTHER' "$OUT_FILE" "$ERR_FILE"; then
  ok "conflicting rollout bodies emit neither fallback authority nor body text"
else
  no "conflicting rollout body or authority leaked"; dump_output
fi

CASE="$TMP/fallback-zerobyte"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
: >"$CASE/zero.reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/zero.reply.md" \
  --accept-rollout-fallback
assert_token done "a readable zero-byte primary reply certifies done"
if grep -Fxq 'WAIT_DIAGNOSTIC {"code":"reply-source","source":"reply-file"}' "$ERR_FILE"; then
  ok "a zero-byte primary reports reply-file (not rollout-fallback) as the source"
else
  no "zero-byte primary source diagnostic wrong"; dump_output
fi

CASE="$TMP/fallback-present-invalid"; mkdir -p "$CASE"; write_done_body "$CASE/rollout-$THREAD.jsonl"
mkdir -p "$CASE/dir.reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/dir.reply.md" \
  --accept-rollout-fallback
assert_token reply-missing "a present-invalid reply never falls through to the rollout fallback"

echo "== 5. process, import, and dependency boundaries =="
OUT_FILE="$TMP/import.stdout"; ERR_FILE="$TMP/import.stderr"
mkdir -p "$TMP/import-home" "$TMP/import-transport" "$TMP/import-sessions"
env -u CODEX_IPC_WAIT_BUDGET_MS -u CODEX_IPC_WAIT_INTERVAL_MS \
  HOME="$TMP/import-home" USERPROFILE="$TMP/import-home" CODEX_IPC_ROOT="$TMP/import-transport" \
  WAIT_IMPORT_TARGET="$WAIT_TOOL" \
  "$NODE_BIN" --input-type=module -e \
  'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.env.WAIT_IMPORT_TARGET).href);' \
  >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
if [[ $RC -eq 0 && ! -s "$OUT_FILE" && ! -s "$ERR_FILE" ]] \
  && [[ -z "$(find "$TMP/import-home" "$TMP/import-transport" "$TMP/import-sessions" -type f -print -quit)" ]]; then
  ok "module import is silent and side-effect-free"
else
  no "module import produced output, state, or a nonzero exit (rc=$RC)"
  dump_output
fi

LOADER="$TMP/builtins-only-loader.mjs"
cat >"$LOADER" <<'EOF'
import { builtinModules } from "node:module";
const builtins = new Set([...builtinModules, ...builtinModules.map((name) => `node:${name}`)]);
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "node:sqlite" || specifier === "sqlite") {
    throw new Error("node:sqlite is forbidden by the wait contract");
  }
  if (builtins.has(specifier)) return nextResolve(specifier, context);
  const local = specifier.startsWith(".") || specifier.startsWith("/") || specifier.startsWith("file:");
  if (!local) throw new Error(`external dependency is forbidden: ${specifier}`);
  const resolved = await nextResolve(specifier, context);
  if (resolved.url.includes("/node_modules/") || resolved.url.includes("\\node_modules\\")) {
    throw new Error(`external dependency is forbidden: ${resolved.url}`);
  }
  return resolved;
}
EOF
LOADER_URL="$("$NODE_BIN" -e 'process.stdout.write(require("node:url").pathToFileURL(process.argv[1]).href)' "$LOADER")"
NODE_ARGS=(--experimental-loader "$LOADER_URL")

run_case "$TMP/done" --rollout-path "$TMP/done/rollout-$THREAD.jsonl" --reply-path "$TMP/done/reply.md"
assert_token done "dependency guard permits the done path"

run_case "$TMP/aborted" --rollout-path "$TMP/aborted/rollout-$THREAD.jsonl" --reply-path "$TMP/aborted/reply.md"
assert_token aborted "dependency guard permits the aborted path"

run_case "$TMP/superseded" --rollout-path "$TMP/superseded/rollout-$THREAD.jsonl" --reply-path "$TMP/superseded/reply.md"
assert_token superseded "dependency guard permits the superseded path"

run_case "$TMP/reply-missing" --rollout-path "$TMP/reply-missing/rollout-$THREAD.jsonl" \
  --reply-path "$TMP/reply-missing/missing.reply.md"
assert_token reply-missing "dependency guard permits the reply-missing path"

run_case "$TMP/pending" --rollout-path "$TMP/pending/rollout-$THREAD.jsonl" --reply-path "$TMP/pending/reply.md" \
  --budget-ms 60 --interval-ms 10
assert_token pending "dependency guard permits the bounded pending path"

run_case "$TMP/reply-ambiguous" --rollout-path "$TMP/reply-ambiguous/rollout-$THREAD.jsonl"
assert_token unavailable "dependency guard permits the unavailable path"

NODE_ARGS=()

run_wait
if [[ $RC -ne 0 ]]; then
  ok "missing required arguments are usage errors"
else
  no "missing required arguments exited zero"
  dump_output
fi

run_wait --thread "$THREAD"
if [[ $RC -ne 0 ]]; then
  ok "missing --dispatch is a usage error"
else
  no "missing --dispatch exited zero"
  dump_output
fi

echo "== 6. A6 opt-in --status-exit-codes: frozen token/exit matrix (flag AND flagless) =="
assert_token_exit(){ # expected_token expected_exit label
  local expected="$1" code="$2" label="$3"
  if [[ $RC -eq "$code" ]] && printf '%s\n' "$expected" | cmp -s - "$OUT_FILE"; then
    ok "$label"
  else
    no "$label (want token=$expected exit=$code; got exit=$RC)"
    dump_output
  fi
}

CASE="$TMP/a6-done"; mkdir -p "$CASE"; write_done "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token_exit done 0 "flagless done exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" --status-exit-codes
assert_token_exit done 0 "flag done exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.md"
assert_token_exit reply-missing 0 "flagless reply-missing exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.md" --status-exit-codes
assert_token_exit reply-missing 5 "flag reply-missing exits 5"

CASE="$TMP/a6-pending"; mkdir -p "$CASE"; write_pending "$CASE/rollout-$THREAD.jsonl"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.md"
assert_token_exit pending 0 "flagless pending exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/absent.md" --status-exit-codes
assert_token_exit pending 2 "flag pending exits 2"

CASE="$TMP/a6-aborted"; mkdir -p "$CASE"; write_aborted "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token_exit aborted 0 "flagless aborted exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" --status-exit-codes
assert_token_exit aborted 3 "flag aborted exits 3"

CASE="$TMP/a6-superseded"; mkdir -p "$CASE"; write_superseded "$CASE/rollout-$THREAD.jsonl"; make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token_exit superseded 0 "flagless superseded exits 0"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md" --status-exit-codes
assert_token_exit superseded 4 "flag superseded exits 4"

CASE="$TMP/a6-unavailable"; mkdir -p "$CASE/sessions"; make_reply "$CASE/reply.md"
run_case "$CASE" --reply-path "$CASE/reply.md"
assert_token_exit unavailable 0 "flagless unavailable exits 0"
run_case "$CASE" --reply-path "$CASE/reply.md" --status-exit-codes
assert_token_exit unavailable 6 "flag unavailable exits 6"

run_wait --thread "$THREAD" --status-exit-codes
if [[ $RC -eq 1 && ! -s "$OUT_FILE" ]]; then ok "usage error under the flag exits 1 with no token"; else no "usage error under flag (rc=$RC)"; dump_output; fi
run_wait --thread "$THREAD"
if [[ $RC -eq 1 && ! -s "$OUT_FILE" ]]; then ok "usage error flagless exits 1 with no token"; else no "usage error flagless (rc=$RC)"; dump_output; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
echo "ALL GREEN"
