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
# Semantics: done = reply file exists+readable (regular, non-symlink) AND the
# dispatch's OWN turn (user_message carrying <dispatchId>.task.md basename;
# turn_id-primary correlation) reached task_complete un-superseded. aborted =
# own turn turn_aborted (regardless of reply presence). superseded = own turn
# superseded (newer task_started before its terminal); a later unrelated turn's
# terminal must NEVER certify. reply-missing = own turn task_complete
# un-superseded but reply absent/unreadable. pending = no determination yet at
# single-shot or budget expiry. unavailable = no authoritative rollout candidate
# / ambiguity (rollout or reply scan) / schema failure.
# Diagnostics stderr only; exit 0 for every determination, nonzero only usage
# errors; no daemon; import side-effect-free; Node builtins only, node:sqlite
# forbidden.

set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TDIR/.." && pwd)"
WAIT_TOOL="${CODEX_IPC_WAIT_TEST_TARGET:-$ROOT/skills/ipc/scripts/codex_ipc_wait.mjs}"

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

now_ms(){ "$NODE_BIN" -e 'process.stdout.write(String(Date.now()))'; }

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

echo "== 0. turn-id-primary correlation outranks the fallback's ambiguity rule =="
# A later user message inside the SAME turn_id'd turn (the operator typing while the lane works)
# is not ambiguity: turn_id already delimits the turn. Observed live 2026-07-10.
CASE="$TMP/intervening-user"; mkdir -p "$CASE"
write_prefix "$CASE/rollout-$THREAD.jsonl"
printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"turn_id\":\"$OWN_TURN\",\"message\":\"operator note typed mid-turn\"}}" >>"$CASE/rollout-$THREAD.jsonl"
printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
make_reply "$CASE/reply.md"
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
assert_token done "a mid-turn operator message does not defeat turn-id correlation"

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
(
  sleep 2
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"$OWN_TURN\",\"last_agent_message\":\"complete\"}}" >>"$CASE/rollout-$THREAD.jsonl"
) &
WRITER_PID=$!
RUN_ENV=("CODEX_IPC_WAIT_BUDGET_MS=5000" "CODEX_IPC_WAIT_INTERVAL_MS=5000")
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
if (( ELAPSED_MS < 1000 )); then
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
RUN_ENV=("CODEX_IPC_WAIT_BUDGET_MS=1500" "CODEX_IPC_WAIT_INTERVAL_MS=25")
run_case "$CASE" --rollout-path "$CASE/rollout-$THREAD.jsonl" --reply-path "$CASE/reply.md"
wait "$WRITER_PID"
assert_token done "budget and interval environment values drive in-process re-evaluation"
if (( ELAPSED_MS >= 60 && ELAPSED_MS < 1500 )); then
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
if (( ELAPSED_MS >= 60 && ELAPSED_MS < 3000 )); then
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
if (( ELAPSED_MS < 3000 )); then
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
if (( ELAPSED_MS < 3000 )); then
  ok "malformed interval fallback does not hang (${ELAPSED_MS}ms)"
else
  no "malformed interval fallback exceeded the wall-time bound (${ELAPSED_MS}ms)"
fi

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

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
echo "ALL GREEN"
