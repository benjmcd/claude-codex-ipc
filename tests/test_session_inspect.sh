#!/usr/bin/env bash
# Hermetic session-inspector hardening tests.
# Uses only temp SQLite/JSONL state. Never reads ~/.codex and never connects to IPC.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECT=""
for candidate in \
  "$TDIR/../skills/ipc/scripts/codex_ipc_session_inspect.mjs" \
  "$TDIR/../scripts/codex_ipc_session_inspect.mjs"; do
  [[ -f "$candidate" ]] && INSPECT="$candidate" && break
done
[[ -n "$INSPECT" ]] || { echo "FATAL: codex_ipc_session_inspect.mjs not found" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is unavailable; session-inspector suite not applicable"
  exit 0
fi
NODE_BIN="$(command -v node)"
if ! "$NODE_BIN" -e 'await import("node:sqlite")' >/dev/null 2>&1; then
  echo "SKIP: node:sqlite is unavailable; session-inspector suite not applicable"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
THREAD="11111111-1111-4111-8111-111111111111"
PASS=0
FAIL=0
OUT=""
RC=0
ERR=""

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

DB_BUILDER="$TMP/build-db.mjs"
cat > "$DB_BUILDER" <<'EOF'
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";

const [dbPath, threadId, rolloutPath = ""] = process.argv.slice(2);
fs.rmSync(dbPath, { force: true });
const db = new DatabaseSync(dbPath);
try {
  db.exec(
    "create table threads (" +
      "id text primary key, rollout_path text, updated_at text, " +
      "updated_at_ms integer, archived integer, sandbox_policy text, approval_mode text)",
  );
  db.prepare(
    "insert into threads (id, rollout_path, updated_at, updated_at_ms, archived, sandbox_policy, approval_mode) " +
      "values (?, ?, ?, ?, ?, ?, ?)",
  ).run(
    threadId,
    rolloutPath || null,
    "2026-07-10T00:00:00Z",
    1783641600000,
    0,
    '{"type":"disabled"}',
    "never",
  );
} finally {
  db.close();
}
EOF

ALIAS_BUILDER="$TMP/build-alias.mjs"
cat > "$ALIAS_BUILDER" <<'EOF'
import fs from "node:fs";
import path from "node:path";

const target = path.resolve(process.argv[2]);
const aliasPath = path.resolve(process.argv[3]);
if (process.platform === "win32") {
  const longPath = target.startsWith("\\\\")
    ? "\\\\?\\UNC\\" + target.slice(2)
    : "\\\\?\\" + target;
  process.stdout.write(longPath);
} else {
  fs.symlinkSync(target, aliasPath);
  process.stdout.write(aliasPath);
}
EOF

ASSERT_JSON="$TMP/assert-json.mjs"
cat > "$ASSERT_JSON" <<'EOF'
import fs from "node:fs";

let raw = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) raw += chunk;
const value = JSON.parse(raw);
const testCase = process.argv[2];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(value.ok === true, "expected top-level ok=true for an existing DB thread");
assert(value.dbThread?.thread?.exists === true, "expected existing DB thread");
assert("lastTaskCompleteLine" in value.activitySignals, "backward field lastTaskCompleteLine missing");
assert("maybeMidTurn" in value.activitySignals, "backward field maybeMidTurn missing");
assert(Array.isArray(value.rollout?.candidates), "backward rollout.candidates missing");
assert("primary" in value.rollout, "backward rollout.primary missing");

switch (testCase) {
  case "abort-terminal":
    assert(value.activitySignals.lastTaskCompleteLine === null, "task_complete field must remain null");
    assert(value.activitySignals.lastTurnAbortedLine === 2, "turn_aborted line mismatch");
    assert(value.activitySignals.lastTerminalLine === 2, "terminal line mismatch");
    assert(value.activitySignals.lastTerminalType === "turn_aborted", "terminal type mismatch");
    assert(value.activitySignals.terminalState === "aborted", "terminal state mismatch");
    assert(value.activitySignals.hasTurnAbortedInTail === true, "abort presence missing");
    assert(value.activitySignals.hasTerminalInTail === true, "terminal presence missing");
    assert(value.activitySignals.maybeMidTurn === false, "abort must close the inferred turn");
    break;
  case "complete-terminal":
    assert(value.activitySignals.lastTaskCompleteLine === 2, "task_complete backward field changed");
    assert(value.activitySignals.lastTurnAbortedLine === null, "unexpected abort line");
    assert(value.activitySignals.lastTerminalLine === 2, "terminal line mismatch");
    assert(value.activitySignals.lastTerminalType === "task_complete", "terminal type mismatch");
    assert(value.activitySignals.terminalState === "completed", "terminal state mismatch");
    assert(value.activitySignals.hasTaskCompleteInTail === true, "completion presence changed");
    assert(value.activitySignals.hasTerminalInTail === true, "terminal presence missing");
    assert(value.activitySignals.maybeMidTurn === false, "completion must remain terminal");
    break;
  case "user-after-terminal":
    assert(value.activitySignals.lastTurnAbortedLine === 2, "abort line mismatch");
    assert(value.activitySignals.lastTerminalLine === 2, "terminal line mismatch");
    assert(value.activitySignals.lastUserMessageLine === 3, "latest user line mismatch");
    assert(value.activitySignals.maybeMidTurn === true, "newer user must remain potentially active");
    break;
  case "ambiguous-candidates":
    assert(value.rollout.candidates.length === 2, "expected two physical candidates");
    assert(value.rollout.candidates[0].path.includes("rollout-b-"), "candidate ordering is not newest-first");
    assert(value.rollout.candidatesAmbiguous === true, "ambiguity flag missing");
    assert(value.rollout.ambiguousCandidates.length === 2, "ambiguous candidate list missing");
    assert(value.rollout.primary === null, "ambiguous candidates must not select a primary");
    assert(value.rollout.selection?.status === "ambiguous", "selection status mismatch");
    assert(value.rollout.selection?.reason === "multiple-candidates", "selection reason mismatch");
    assert(value.rollout.selection?.authority === "sessions-root-match", "authority mismatch");
    break;
  case "db-authority":
    assert(value.rollout.candidates.length === 2, "expected DB candidate plus distinct discovered candidate");
    assert(value.rollout.candidatesAmbiguous === false, "DB authority must resolve selection");
    assert(value.rollout.ambiguousCandidates.length === 0, "unexpected ambiguous list");
    assert(value.rollout.selection?.status === "found", "selection status mismatch");
    assert(value.rollout.selection?.reason === "db-rollout-path", "selection reason mismatch");
    assert(value.rollout.selection?.authority === "db.rollout_path", "DB authority missing");
    assert(value.rollout.primary?.path === value.dbThread.thread.rolloutPath, "DB rollout was not parsed");
    break;
  case "physical-alias":
    assert(value.rollout.candidates.length === 1, "physical aliases were not deduplicated");
    assert(value.rollout.candidates[0].aliases.length === 2, "alias list must retain both spellings");
    assert(typeof value.rollout.candidates[0].canonicalPath === "string", "canonical path missing");
    assert(value.rollout.candidatesAmbiguous === false, "aliases must not be ambiguous");
    assert(value.rollout.selection?.authority === "db.rollout_path", "DB alias must retain authority");
    assert(value.rollout.selection?.aliasCount === 2, "selection alias count mismatch");
    if (process.platform === "win32") {
      assert(!value.rollout.candidates[0].canonicalPath.startsWith("\\\\?\\"), "long-path prefix was not stripped");
      assert(
        value.rollout.candidates[0].canonicalPath === value.rollout.candidates[0].canonicalPath.toLowerCase(),
        "Windows canonical path was not case-normalized",
      );
    } else {
      assert(
        value.rollout.candidates[0].canonicalPath === fs.realpathSync(value.rollout.candidates[0].path),
        "canonical path does not resolve the physical file",
      );
    }
    break;
  case "single-candidate":
    assert(value.rollout.candidates.length === 1, "single candidate missing");
    assert(value.rollout.candidatesAmbiguous === false, "single candidate cannot be ambiguous");
    assert(value.rollout.selection?.status === "found", "selection status mismatch");
    assert(value.rollout.selection?.reason === "single-candidate", "selection reason mismatch");
    assert(value.rollout.selection?.authority === "sessions-root-match", "authority mismatch");
    assert(value.rollout.primary?.parsedOk === true, "single candidate was not parsed");
    break;
  case "malformed-db-authority":
    assert(value.rollout.candidates.length === 2, "expected DB candidate plus discovered candidate");
    assert(value.rollout.candidatesAmbiguous === false, "DB authority must resolve selection");
    assert(value.rollout.selection?.status === "found", "selection status mismatch");
    assert(value.rollout.selection?.reason === "db-rollout-path", "selection reason mismatch");
    assert(value.rollout.primary?.path === value.dbThread.thread.rolloutPath, "DB rollout was not parsed");
    assert(value.rollout.primary?.parsedOk === false, "malformed DB rollout validity was hidden");
    assert(value.rollout.primary?.parseErrors?.length === 1, "malformed DB parse error missing");
    break;
  case "advisory": {
    // A2: stored approvalMode/sandboxPolicy names+values are preserved byte-for-byte, and the
    // exact additive permissionProfileAdvisory sibling demotes them to non-gating advisory context.
    const thread = value.dbThread.thread;
    assert(thread.approvalMode === "never", "stored approvalMode value changed");
    assert(
      JSON.stringify(thread.sandboxPolicy) === JSON.stringify({ type: "disabled" }),
      "stored sandboxPolicy value changed",
    );
    assert(
      JSON.stringify(thread.permissionProfileAdvisory) ===
        JSON.stringify({
          source: "stored-thread-row",
          mayDifferFromEffectiveTurn: true,
          mustNotGateDispatch: true,
          predictsReplyWritability: false,
        }),
      "permissionProfileAdvisory object is not the exact advisory shape",
    );
    break;
  }
  default:
    throw new Error("unknown assertion case: " + testCase);
}
EOF

make_db(){
  local db_path="$1" rollout_path="${2:-}"
  "$NODE_BIN" "$DB_BUILDER" "$db_path" "$THREAD" "$rollout_path" >/dev/null 2>&1
}

run_inspect(){
  local db_path="$1" sessions_root="$2"
  local err_path="$TMP/inspect.stderr"
  OUT="$("$NODE_BIN" "$INSPECT" \
    --db "$db_path" \
    --sessions-root "$sessions_root" \
    --thread "$THREAD" \
    --tail-events 20 2>"$err_path")"
  RC=$?
  ERR="$(cat "$err_path")"
}

assert_case(){
  local test_case="$1" label="$2"
  if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | "$NODE_BIN" "$ASSERT_JSON" "$test_case" >/dev/null 2>&1; then
    ok "$label"
  else
    no "$label (rc=$RC)"
    [[ -n "$ERR" ]] && printf '%s\n' "$ERR"
    printf '%s\n' "$OUT" | sed -n '1,40p'
  fi
}

write_user_abort(){
  local file_path="$1"
  cat > "$file_path" <<EOF
{"type":"event_msg","payload":{"type":"user_message","message":"task"}}
{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}
EOF
}

write_user_complete(){
  local file_path="$1"
  cat > "$file_path" <<EOF
{"type":"event_msg","payload":{"type":"user_message","message":"task"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}
EOF
}

write_user_after_abort(){
  local file_path="$1"
  cat > "$file_path" <<EOF
{"type":"event_msg","payload":{"type":"user_message","message":"task one"}}
{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","message":"task two"}}
EOF
}

echo "== 1. turn_aborted has terminal parity with task_complete =="
CASE="$TMP/abort"; mkdir -p "$CASE/sessions"
ROLLOUT="$CASE/sessions/rollout-abort-$THREAD.jsonl"
write_user_abort "$ROLLOUT"
make_db "$CASE/state.sqlite" "$ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case abort-terminal "turn_aborted closes the inferred active turn and adds terminal fields"

echo "== 2. task_complete backward fields remain intact =="
CASE="$TMP/complete"; mkdir -p "$CASE/sessions"
ROLLOUT="$CASE/sessions/rollout-complete-$THREAD.jsonl"
write_user_complete "$ROLLOUT"
make_db "$CASE/state.sqlite" "$ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case complete-terminal "task_complete retains existing fields and gains terminal parity fields"

echo "== 3. a user message after the last terminal remains potentially active =="
CASE="$TMP/new-user"; mkdir -p "$CASE/sessions"
ROLLOUT="$CASE/sessions/rollout-new-user-$THREAD.jsonl"
write_user_after_abort "$ROLLOUT"
make_db "$CASE/state.sqlite" "$ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case user-after-terminal "newer user activity is not hidden by an older abort"

echo "== 4. distinct equal-authority candidates fail visible =="
CASE="$TMP/ambiguous"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
write_user_complete "$CASE/sessions/a/rollout-a-$THREAD.jsonl"
write_user_complete "$CASE/sessions/b/rollout-b-$THREAD.jsonl"
"$NODE_BIN" -e 'const fs=require("node:fs"); fs.utimesSync(process.argv[1], new Date("2020-01-01"), new Date("2020-01-01")); fs.utimesSync(process.argv[2], new Date("2021-01-01"), new Date("2021-01-01"));' \
  "$CASE/sessions/a/rollout-a-$THREAD.jsonl" "$CASE/sessions/b/rollout-b-$THREAD.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case ambiguous-candidates "multiple physical sessions-root candidates select no primary"

echo "== 5. a valid DB-designated rollout remains higher authority =="
CASE="$TMP/db-authority"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
DB_ROLLOUT="$CASE/sessions/a/rollout-db-$THREAD.jsonl"
write_user_complete "$DB_ROLLOUT"
write_user_abort "$CASE/sessions/b/rollout-other-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$DB_ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case db-authority "DB-designated rollout remains primary over discovered candidates"

echo "== 6. physical aliases deduplicate before ambiguity =="
CASE="$TMP/alias"; mkdir -p "$CASE/sessions" "$CASE/aliases"
TARGET="$CASE/sessions/rollout-alias-$THREAD.jsonl"
write_user_complete "$TARGET"
ALIAS="$("$NODE_BIN" "$ALIAS_BUILDER" "$TARGET" "$CASE/aliases/rollout-link-$THREAD.jsonl")"
make_db "$CASE/state.sqlite" "$ALIAS"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case physical-alias "long-path/symlink aliases collapse to one physical candidate"

echo "== 7. one discovered candidate remains readable =="
CASE="$TMP/single"; mkdir -p "$CASE/sessions"
write_user_complete "$CASE/sessions/rollout-single-$THREAD.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case single-candidate "single sessions-root candidate remains primary"

echo "== 8. DB authority does not silently fall back after a parse error =="
CASE="$TMP/malformed-db"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
DB_ROLLOUT="$CASE/sessions/a/rollout-db-bad-$THREAD.jsonl"
printf '%s\n' '{malformed' > "$DB_ROLLOUT"
write_user_complete "$CASE/sessions/b/rollout-other-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$DB_ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case malformed-db-authority "DB path remains authoritative while parse invalidity stays explicit"

echo "== 9. A2: stored policy is preserved byte-for-byte and demoted to advisory =="
CASE="$TMP/advisory"; mkdir -p "$CASE/sessions"
write_user_complete "$CASE/sessions/rollout-advisory-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$CASE/sessions/rollout-advisory-$THREAD.jsonl"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case advisory "approvalMode/sandboxPolicy unchanged plus the exact permissionProfileAdvisory sibling"

echo "== 10. A2: predictive stored-policy claims are gone from active guidance =="
SKILL_ROOT="$(cd "$(dirname "$(dirname "$INSPECT")")" && pwd)"
GUIDANCE=("$INSPECT" "$SKILL_ROOT/SKILL.md" "$SKILL_ROOT/references/troubleshooting.md")
NEG_OK=1
for surface in "${GUIDANCE[@]}"; do
  [[ -f "$surface" ]] || continue
  if grep -q "injected turns run under these" "$surface" \
    || grep -q "injected follower turns run" "$surface" \
    || grep -q "will be able to write its reply file" "$surface"; then
    NEG_OK=0
    echo "    predictive claim still present in: $surface"
  fi
done
[[ $NEG_OK -eq 1 ]] && ok "no predictive stored-policy claim remains in active guidance" \
  || no "a predictive stored-policy claim remains in active guidance"
if grep -q "permissionProfileAdvisory" "$SKILL_ROOT/references/troubleshooting.md" 2>/dev/null \
  && grep -q -- "--accept-rollout-fallback" "$SKILL_ROOT/references/troubleshooting.md" 2>/dev/null; then
  ok "bundled troubleshooting carries the advisory denied-write row"
else
  no "bundled troubleshooting missing the advisory denied-write row"
fi

# ---- A4 turnActivity (open/closed/ambiguous) over the FULL parse stream -------------------
assert_turn_activity(){
  local expected="$1" label="$2"
  local got=""
  if [[ $RC -eq 0 ]]; then
    got="$(printf '%s' "$OUT" | "$NODE_BIN" -e 'const v=JSON.parse(require("node:fs").readFileSync(0,"utf8"));process.stdout.write(String(v.activitySignals.turnActivity));' 2>/dev/null)"
  fi
  if [[ "$got" == "$expected" ]]; then
    ok "$label"
  else
    no "$label (rc=$RC, turnActivity=$got want=$expected)"
  fi
}

run_turn_activity_case(){
  local rollout="$1"
  local case_dir; case_dir="$(dirname "$rollout")"
  make_db "$case_dir/../state.sqlite" "$rollout"
  run_inspect "$case_dir/../state.sqlite" "$case_dir"
}

write_open_no_terminal(){   # start(A) -> user(A) -> agent(A), no terminal
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-a","message":"do the task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"working on it","phase":"commentary"}}
EOF
}

write_closed_same_turn(){   # start(A) -> user(A) -> agent(A) -> task_complete(A)
  write_open_no_terminal "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\",\"last_agent_message\":\"done\"}}" >> "$1"
}

write_mismatched_terminal(){  # start(A) -> user(A) -> agent(A) -> task_complete(B)
  write_open_no_terminal "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-b\",\"last_agent_message\":\"done\"}}" >> "$1"
}

write_completed_then_open(){  # closed turn-a, then a fresh open turn-b (terminalState=completed, activity=open)
  write_closed_same_turn "$1"
  cat >> "$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-b"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-b","message":"a fresh follow-up"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"picking it up","phase":"commentary"}}
EOF
}

write_clipped_closed(){  # a long tail whose latest same-turn boundary is complete
  {
    printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$THREAD\"}}"
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-a\"}}"
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"turn_id\":\"turn-a\",\"message\":\"do the long task\"}}"
    for i in $(seq 1 30); do
      printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"progress $i\",\"phase\":\"commentary\"}}"
    done
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\",\"last_agent_message\":\"done\"}}"
  } > "$1"
}

write_no_boundary(){  # a found, parseable rollout with no turn boundary at all
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total":1}}}
EOF
}

write_drifted_closed(){  # start(A) -> IN-WINDOW unknown-pair drift -> user(A) -> agent(A) -> task_complete(A)
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"future_lifecycle_event","turn_id":"turn-a","message":"unknown in-window record"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-a","message":"do the task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"done body","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"done body"}}
EOF
}

echo "== 11. A4 turnActivity: start->user->agent (no terminal) is open =="
CASE="$TMP/ta-open"; mkdir -p "$CASE/sessions"
write_open_no_terminal "$CASE/sessions/rollout-open-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-open-$THREAD.jsonl"
assert_turn_activity open "start->user->agent with no terminal is open"

echo "== 12. A4 turnActivity: A-08 fixture (start->user->agent) is open =="
CASE="$TMP/ta-a08"; mkdir -p "$CASE/sessions"
cp "$TDIR/fixtures/rollout/rollout-a08-midturn-$THREAD.jsonl" "$CASE/sessions/rollout-a08-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-a08-$THREAD.jsonl"
assert_turn_activity open "committed A-08 mid-turn fixture is open"

echo "== 13. A4 turnActivity: +task_complete(A) is closed =="
CASE="$TMP/ta-closed"; mkdir -p "$CASE/sessions"
write_closed_same_turn "$CASE/sessions/rollout-closed-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-closed-$THREAD.jsonl"
assert_turn_activity closed "start->user->agent->task_complete(A) is closed"

echo "== 14. A4 turnActivity: +only task_complete(B) is ambiguous =="
CASE="$TMP/ta-ambiguous"; mkdir -p "$CASE/sessions"
write_mismatched_terminal "$CASE/sessions/rollout-ambig-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-ambig-$THREAD.jsonl"
assert_turn_activity ambiguous "a mismatched-id terminal is ambiguous"

echo "== 15. A4 turnActivity: task_complete(A)->start(B)->agent(B) is open while terminalState stays completed =="
CASE="$TMP/ta-reopen"; mkdir -p "$CASE/sessions"
write_completed_then_open "$CASE/sessions/rollout-reopen-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-reopen-$THREAD.jsonl"
assert_turn_activity open "a fresh open turn after a completed one is open"
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | "$NODE_BIN" -e 'const v=JSON.parse(require("node:fs").readFileSync(0,"utf8"));process.exit(v.activitySignals.terminalState==="completed"?0:1);' >/dev/null 2>&1; then
  ok "historical terminalState remains completed independent of turnActivity"
else
  no "terminalState should remain completed"
fi

echo "== 16. A4 turnActivity: a long clipped display tail with a complete latest boundary is closed =="
CASE="$TMP/ta-clipped"; mkdir -p "$CASE/sessions"
write_clipped_closed "$CASE/sessions/rollout-clipped-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-clipped-$THREAD.jsonl"
assert_turn_activity closed "display-tail truncation is not ambiguity when the full stream retained the boundary"

echo "== 17. A4 turnActivity: a found rollout with no boundary snapshot is ambiguous (no throw) =="
CASE="$TMP/ta-noboundary"; mkdir -p "$CASE/sessions"
write_no_boundary "$CASE/sessions/rollout-noboundary-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-noboundary-$THREAD.jsonl"
assert_turn_activity ambiguous "a found rollout with no emitted boundary is ambiguous"

# ---- A4 write-proof pre-send gate: require closed; --allow-mid-turn overrides open only ----
WRITE_PROOF=""
for candidate in \
  "$TDIR/../skills/ipc/scripts/codex_ipc_write_proof.mjs" \
  "$TDIR/../scripts/codex_ipc_write_proof.mjs"; do
  [[ -f "$candidate" ]] && WRITE_PROOF="$candidate" && break
done

wp_home_setup(){  # $1=home  $2=rollout writer function
  local home="$1" writer="$2"
  rm -rf "$home"; mkdir -p "$home/.codex/sessions"
  local rollout="$home/.codex/sessions/rollout-wp-$THREAD.jsonl"
  "$writer" "$rollout"
  "$NODE_BIN" "$DB_BUILDER" "$home/.codex/state_5.sqlite" "$THREAD" "$rollout" >/dev/null 2>&1
}

WPOUT=""; WPRC=0
wp_dryrun(){  # $1=home  ...extra write-proof args
  local home="$1"; shift
  WPOUT="$(USERPROFILE="$home" HOME="$home" "$NODE_BIN" "$WRITE_PROOF" --thread "$THREAD" "$@" 2>/dev/null)"; WPRC=$?
}
wp_field(){  # $1=js predicate over parsed dry-run object `v`
  printf '%s' "$WPOUT" | "$NODE_BIN" -e "const v=JSON.parse(require('node:fs').readFileSync(0,'utf8'));process.exit(($1)?0:1);" >/dev/null 2>&1
}

if [[ -n "$WRITE_PROOF" ]]; then
  echo "== 18. A4 write-proof dry-run: an open turn is rejected without --allow-mid-turn =="
  wp_home_setup "$TMP/wp-open" write_open_no_terminal
  wp_dryrun "$TMP/wp-open"
  wp_field 'v.dryRun===true && v.ok===false && v.failures.some(f=>f.includes("open (mid-turn)"))' \
    && ok "open turn rejected as mid-turn (dry-run ok:false)" || no "open turn not rejected (rc=$WPRC)"

  echo "== 19. A4 write-proof dry-run: --allow-mid-turn overrides an open turn =="
  wp_dryrun "$TMP/wp-open" --allow-mid-turn
  wp_field 'v.dryRun===true && v.ok===true' \
    && ok "--allow-mid-turn permits an open turn" || no "--allow-mid-turn did not permit open (rc=$WPRC)"

  echo "== 20. A4 write-proof dry-run: an ambiguous turn is never overridable =="
  wp_home_setup "$TMP/wp-ambiguous" write_mismatched_terminal
  wp_dryrun "$TMP/wp-ambiguous" --allow-mid-turn
  wp_field 'v.ok===false && v.failures.some(f=>f.includes("ambiguous"))' \
    && ok "ambiguous turn rejected even with --allow-mid-turn" || no "ambiguous override behavior wrong (rc=$WPRC)"

  echo "== 21. A4 write-proof dry-run: a closed turn passes the pre-send gate =="
  wp_home_setup "$TMP/wp-closed" write_closed_same_turn
  wp_dryrun "$TMP/wp-closed"
  wp_field 'v.ok===true && v.targetInspection.turnActivity==="closed"' \
    && ok "a closed turn is send-ready" || no "closed turn not send-ready (rc=$WPRC)"
else
  echo "  NOTE: codex_ipc_write_proof.mjs not found; skipping write-proof gate checks"
fi

# ---- A1/F1 fail-closed drift consistency (RED at 9434721, GREEN after the fix) --------------
echo "== 22. A1/F1 turnActivity: in-window schema drift on a COMPLETED turn is ambiguous =="
CASE="$TMP/ta-drift-closed"; mkdir -p "$CASE/sessions"
write_drifted_closed "$CASE/sessions/rollout-driftclosed-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-driftclosed-$THREAD.jsonl"
assert_turn_activity ambiguous "in-window drift inside a completed turn fails closed as ambiguous"

if [[ -n "$WRITE_PROOF" ]]; then
  echo "== 23. A1/F1 write-proof dry-run: a drift-poisoned completed turn is rejected, not overridable =="
  wp_home_setup "$TMP/wp-drift" write_drifted_closed
  wp_dryrun "$TMP/wp-drift" --allow-mid-turn
  wp_field 'v.dryRun===true && v.ok===false && v.targetInspection.turnActivity==="ambiguous" && v.failures.some(f=>f.includes("ambiguous"))' \
    && ok "drift-poisoned completed turn is not send-ready even with --allow-mid-turn" \
    || no "drift-poisoned completed turn was accepted (rc=$WPRC)"
fi

# ============================================================================================
# O3: the `--summary` preflight projection (AC1-AC7).
#
# INVARIANT UNDER TEST (S1) -- SUMMARY IS A PARAMETER-IDENTICAL FIELD-SUBSET. For any argv A,
# `A --summary` projects the SAME computed object A produces: every JSON path in the summary
# exists at the identical path in the default output, and every scalar leaf at a shared path
# carries the identical value, with exactly three declared bounded carve-outs (recentItems
# length+keys, candidates length+keys, and the mini-tail's 120-char re-truncation). The flag
# sets ONE boolean and the projection never receives `opts`, so no parsing parameter can shift.
# ============================================================================================

REPO_ROOT="$(cd "$TDIR/.." && pwd)"

# The commit immediately BEFORE --summary landed. AC1 diffs the SHIPPED DEFAULT output against
# this ref's inspector, byte for byte. That comparison is load-bearing, not ceremonial:
# handoff_to_codex.sh greps the literal pretty-printed `"ok": false` / `"ok": true` /
# `"archived": 1` out of a `--tail-events 1` inspector run, and any whitespace or field drift in
# the default emit turns the unowned-thread auto-load into a fail-closed refusal.
PRE_O3_REF="6cd565331d96f3f769e07d4b821f9435d48ab8ab"

# A DB builder carrying the inspector's FULL column list, so the AC4 ratio is measured against a
# realistic full object. The suite's original DB_BUILDER declares 7 columns, which would leave
# preview / first_user_message / title / cwd / model out of the denominator and flatter the ratio.
O3_DB_BUILDER="$TMP/build-db-full.mjs"
cat > "$O3_DB_BUILDER" <<'EOF'
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";

const [dbPath, threadId, rolloutPath = ""] = process.argv.slice(2);
const long = (seed, n) => (seed + " ").repeat(Math.ceil(n / (seed.length + 1))).slice(0, n);
fs.rmSync(dbPath, { force: true });
const db = new DatabaseSync(dbPath);
try {
  db.exec(
    "create table threads (id text primary key, rollout_path text, created_at text, " +
      "updated_at text, cwd text, title text, model text, reasoning_effort text, " +
      "sandbox_policy text, approval_mode text, tokens_used integer, archived integer, " +
      "thread_source text, preview text, first_user_message text, created_at_ms integer, " +
      "updated_at_ms integer)",
  );
  db.prepare(
    "insert into threads values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
  ).run(
    threadId,
    rolloutPath || null,
    "2026-08-01T00:00:00Z",
    "2026-08-05T00:00:00Z",
    "C:\\dev\\some-project-with-a-realistic-path\\worktrees\\feature-branch",
    "Refactor the rollout reader boundary machine and re-prove the wait contract",
    "gpt-5-codex",
    "high",
    '{"type":"disabled"}',
    "never",
    182344,
    0,
    "desktop",
    long("the operator asked for a bounded projection of the preflight object", 400),
    long("please refactor the boundary accumulator so the display tail cannot", 400),
    1785283200000,
    1785628800000,
  );
} finally {
  db.close();
}
EOF

make_db_full(){
  local db_path="$1" rollout_path="${2:-}"
  "$NODE_BIN" "$O3_DB_BUILDER" "$db_path" "$THREAD" "$rollout_path" >/dev/null 2>&1
}

# A production-shaped rollout: mixed text sizes so the measurement is not gamed by an all-maximal
# fixture. 40 chars truncates on neither side, 180/420 on the summary side only, 900 on both.
write_o3_stream(){  # write_o3_stream <path> <n-progress-items>
  local file_path="$1" n="${2:-30}" i len
  {
    printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"type\":\"session_meta\",\"id\":\"$THREAD\",\"cwd\":\"C:/dev/some-project\",\"instructions\":\"$(printf 'a%.0s' $(seq 1 400))\"}}"
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-a\"}}"
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"turn_id\":\"turn-a\",\"message\":\"$(printf 'u%.0s' $(seq 1 300))\"}}"
    for ((i=0; i<n; i++)); do
      case $((i % 4)) in
        0) len=40 ;;
        1) len=180 ;;
        2) len=420 ;;
        *) len=900 ;;
      esac
      printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"phase\":\"commentary\",\"message\":\"item $i $(printf 'x%.0s' $(seq 1 $len))\"}}"
    done
    printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\",\"last_agent_message\":\"done\"}}"
  } > "$file_path"
}

# AC3 (Strategy B, normative): the LATEST turn is closed over the full stream, but the display
# tail at --tail-events 1 holds only the trailing out-of-turn commentary, so the tail-derived
# terminalState reads "none". terminalState and turnActivity must therefore DISAGREE, and the
# summary must carry the authoritative one. --tail-events 1 is the real production narrow-tail
# call site (handoff_to_codex.sh's unowned-thread guard).
write_o3_out_of_tail(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"type":"session_meta","id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-a","message":"do the task"}}
{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"here is the answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"here is the answer"}}
{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"a trailing out-of-turn note"}}
EOF
}

run_o3(){  # run_o3 <out-file> <script> <db> <sessions-root> [args...]
  local out="$1" script="$2" db_path="$3" root="$4"; shift 4
  "$NODE_BIN" "$script" --db "$db_path" --sessions-root "$root" --thread "$THREAD" "$@" \
    > "$out" 2>/dev/null
}

# ---- fixtures ------------------------------------------------------------------------------
O3="$TMP/o3"; mkdir -p "$O3/basic/sessions" "$O3/outoftail/sessions" "$O3/ambig12" "$O3/malformed/sessions/a" "$O3/malformed/sessions/b"
write_o3_stream "$O3/basic/sessions/rollout-o3-$THREAD.jsonl" 30
make_db_full "$O3/basic/state.sqlite" "$O3/basic/sessions/rollout-o3-$THREAD.jsonl"
write_o3_out_of_tail "$O3/outoftail/sessions/rollout-oot-$THREAD.jsonl"
make_db_full "$O3/outoftail/state.sqlite" "$O3/outoftail/sessions/rollout-oot-$THREAD.jsonl"
# AC4b: ambiguity needs NO db.rollout_path and >=2 distinct physical files. Twelve of them, so the
# cap is exercised and selection.candidateCount can be proven to survive it.
for i in $(seq -w 1 12); do
  mkdir -p "$O3/ambig12/sessions/d$i"
  write_o3_stream "$O3/ambig12/sessions/d$i/rollout-c$i-$THREAD.jsonl" 4
done
make_db_full "$O3/ambig12/state.sqlite"
printf '%s\n' '{malformed' > "$O3/malformed/sessions/a/rollout-bad-$THREAD.jsonl"
write_user_complete "$O3/malformed/sessions/b/rollout-other-$THREAD.jsonl"
make_db_full "$O3/malformed/state.sqlite" "$O3/malformed/sessions/a/rollout-bad-$THREAD.jsonl"

echo "== 24. O3/AC1: the DEFAULT emit is byte-identical to ${PRE_O3_REF:0:7} at every in-bundle window =="
# THE ONE DECLARED NORMALIZATION is generatedAt, which is `new Date().toISOString()` and differs
# per run by construction. Nothing else is normalized: same fixture, same files, same run, so
# paths, sizes and mtimes are identical between the two invocations. An undeclared normalization
# list makes a byte-identity claim vacuous, so this list is exactly one entry long.
o3_norm(){ sed -E 's/"generatedAt": "[^"]*"/"generatedAt": "NORMALIZED"/' "$1" > "$2"; }
PRE_O3_DIR="$TMP/pre-o3"; mkdir -p "$PRE_O3_DIR"
PRE_O3=""
if git -C "$REPO_ROOT" cat-file -e "${PRE_O3_REF}:skills/ipc/scripts/codex_ipc_session_inspect.mjs" 2>/dev/null \
   && git -C "$REPO_ROOT" show "${PRE_O3_REF}:skills/ipc/scripts/codex_ipc_session_inspect.mjs" > "$PRE_O3_DIR/codex_ipc_session_inspect.mjs" 2>/dev/null \
   && git -C "$REPO_ROOT" show "${PRE_O3_REF}:skills/ipc/scripts/codex_ipc_rollout_reader.mjs" > "$PRE_O3_DIR/codex_ipc_rollout_reader.mjs" 2>/dev/null; then
  PRE_O3="$PRE_O3_DIR/codex_ipc_session_inspect.mjs"
fi
if [[ -n "$PRE_O3" ]]; then
  AC1_DIFFS=0; AC1_PAIRS=0
  for fixture in basic outoftail ambig12 malformed; do
    for window in 1 5 20; do
      run_o3 "$TMP/ac1-old" "$PRE_O3" "$O3/$fixture/state.sqlite" "$O3/$fixture/sessions" --tail-events "$window"
      run_o3 "$TMP/ac1-new" "$INSPECT"  "$O3/$fixture/state.sqlite" "$O3/$fixture/sessions" --tail-events "$window"
      o3_norm "$TMP/ac1-old" "$TMP/ac1-old.n"; o3_norm "$TMP/ac1-new" "$TMP/ac1-new.n"
      AC1_PAIRS=$((AC1_PAIRS+1))
      if ! cmp -s "$TMP/ac1-old.n" "$TMP/ac1-new.n"; then
        AC1_DIFFS=$((AC1_DIFFS+1))
        echo "    default output drifted: fixture=$fixture --tail-events $window"
        diff "$TMP/ac1-old.n" "$TMP/ac1-new.n" | head -6 | sed 's/^/      /'
      fi
    done
  done
  if [[ "$AC1_DIFFS" -eq 0 ]]; then
    ok "default output is byte-identical across $AC1_PAIRS (fixture x window) pairs, modulo generatedAt only"
  else
    no "$AC1_DIFFS of $AC1_PAIRS default-output pairs drifted from ${PRE_O3_REF:0:7}"
  fi
  # Non-vacuity: the flag must genuinely be new, or "identical default" proves nothing.
  if "$NODE_BIN" "$PRE_O3" --db "$O3/basic/state.sqlite" --sessions-root "$O3/basic/sessions" \
       --thread "$THREAD" --summary >/dev/null 2>"$TMP/ac1-oldflag"; then
    no "${PRE_O3_REF:0:7} accepted --summary; the AC1 comparison is not against a pre-flag inspector"
  elif grep -q "Unknown argument: --summary" "$TMP/ac1-oldflag"; then
    ok "${PRE_O3_REF:0:7} rejects --summary with 'Unknown argument' (the flag is genuinely new)"
  else
    no "${PRE_O3_REF:0:7} rejected --summary for the wrong reason"
  fi
else
  echo "  (${PRE_O3_REF:0:7} unreachable in this checkout: AC1 byte-identity not asserted here)"
fi

echo "== 25. O3/AC2: every SKILL.md-mandated field is present, and the mandating prose still says so =="
# TWO HALVES, both required. The array alone cannot detect SKILL.md drift -- if the prose is
# rewritten, a hardcoded list stays green while the projection silently stops matching its only
# authority. The prose anchors below are substrings, never line numbers, so they survive
# renumbering and fail on a rewrite, forcing re-derivation of the list.
SKILL_MANDATED_SUMMARY_FIELDS=(
  # field path                                  # mandating SKILL.md clause
  "dbThread.thread.title"                       # "the target title"
  "dbThread.thread.cwd"                         # "cwd/project"
  "dbThread.thread.model"                       # "model"
  "dbThread.thread.reasoningEffort"             # "reasoning effort"
  "dbThread.thread.archived"                    # "archived flag"
  "dbThread.thread.rolloutPath"                 # "and rollout path"
  "dbThread.thread.approvalMode"                # "the thread's stored approvalMode/sandboxPolicy"
  "dbThread.thread.sandboxPolicy"               # (same clause)
  "dbThread.thread.permissionProfileAdvisory"   # "(carried alongside permissionProfileAdvisory)"
  "dbThread.thread.exists"                      # "missing ... targets" is only decidable from exists
  "dbThread.thread.id"                          # identity-mismatch check
  "threadId"                                    # the one-UUID rule
  "activitySignals.lastUserMessageLine"         # "the latest user/agent/task-complete signals"
  "activitySignals.lastAgentMessageLine"        # (same clause)
  "activitySignals.lastTaskCompleteLine"        # (same clause)
  "activitySignals.turnActivity"                # "the authoritative open/closed/ambiguous read"
  "activitySignals.maybeMidTurn"                # named, therefore present to be de-preferred
  "activitySignals.terminalState"               # named as a past-turn signal
  "activitySignals.conclusion"                  # the rendered open/closed/ambiguous sentence
)
FIELD_WALKER="$TMP/o3-fields.mjs"
cat > "$FIELD_WALKER" <<'EOF'
let raw = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) raw += chunk;
const value = JSON.parse(raw);
const missing = [];
for (const dotted of process.argv.slice(2)) {
  let node = value;
  let present = true;
  for (const key of dotted.split(".")) {
    // `in`, never truthiness: archived===0, lastTaskCompleteLine===null and maybeMidTurn===false
    // are all legitimate values whose ABSENCE is the defect this walks for.
    if (node === null || typeof node !== "object" || !(key in node)) { present = false; break; }
    node = node[key];
  }
  if (!present) missing.push(dotted);
}
if (missing.length) { console.error("missing: " + missing.join(", ")); process.exit(1); }
EOF
run_o3 "$TMP/ac2-summary" "$INSPECT" "$O3/basic/state.sqlite" "$O3/basic/sessions" --tail-events 20 --summary
if "$NODE_BIN" "$FIELD_WALKER" "${SKILL_MANDATED_SUMMARY_FIELDS[@]}" < "$TMP/ac2-summary" 2>"$TMP/ac2-err"; then
  ok "--summary carries all ${#SKILL_MANDATED_SUMMARY_FIELDS[@]} SKILL.md-mandated fields"
else
  no "--summary is missing a SKILL.md-mandated field: $(cat "$TMP/ac2-err")"
fi
SKILL_MD="$SKILL_ROOT/SKILL.md"
ANCHORS_OK=1
while IFS= read -r anchor; do
  [[ -n "$anchor" ]] || continue
  grep -qF -- "$anchor" "$SKILL_MD" || { ANCHORS_OK=0; echo "    mandating prose gone: $anchor"; }
done <<'ANCHORS'
Use the inspector output to identify: the target title, cwd/project, model, reasoning effort,
archived flag, and rollout path; the thread's stored `approvalMode`/`sandboxPolicy` (carried
user/agent/task-complete signals; and `activitySignals.turnActivity`
`turnActivity` over the historical `maybeMidTurn` tail heuristic
ANCHORS
[[ $ANCHORS_OK -eq 1 ]] \
  && ok "the four load-bearing SKILL.md mandate fragments are still present verbatim" \
  || no "SKILL.md's field mandate was rewritten; re-derive SKILL_MANDATED_SUMMARY_FIELDS"

echo "== 26. O3/AC3: an out-of-tail terminal keeps turnActivity authoritative in BOTH emits =="
# The highest-stakes S1 pair: at --tail-events 1 the tail-derived terminalState says "none" while
# the full-stream boundary machine says "closed". Both emits must agree with each other AND the
# summary must carry the authoritative field, or the projection would have silently swapped a
# fail-closed signal for a display artefact.
AC3_OK=1
for emit in default summary; do
  if [[ "$emit" == summary ]]; then
    run_o3 "$TMP/ac3-$emit" "$INSPECT" "$O3/outoftail/state.sqlite" "$O3/outoftail/sessions" --tail-events 1 --summary
  else
    run_o3 "$TMP/ac3-$emit" "$INSPECT" "$O3/outoftail/state.sqlite" "$O3/outoftail/sessions" --tail-events 1
  fi
  "$NODE_BIN" -e '
    const v = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const s = v.activitySignals;
    if (s.turnActivity !== "closed") throw new Error("turnActivity=" + s.turnActivity + " want closed");
    if (s.terminalState !== "none") throw new Error("terminalState=" + s.terminalState + " want none");
    if (s.lastTaskCompleteLine !== null) throw new Error("lastTaskCompleteLine should be null out of tail");
  ' "$TMP/ac3-$emit" 2>"$TMP/ac3-err" || { AC3_OK=0; echo "    $emit: $(cat "$TMP/ac3-err")"; }
done
[[ $AC3_OK -eq 1 ]] \
  && ok "at --tail-events 1 both emits report turnActivity=closed with terminalState=none" \
  || no "the out-of-tail terminal was misreported by at least one emit"

echo "== 27. O3/AC4: --summary is a bounded fraction of the same run's default output =="
# RATIO, not an absolute byte bar. The bar is tied to the savings claim itself, is immune to
# fixture-size drift, and is tokenizer-independent (numerator and denominator are the same
# content class). Both numbers are captured from the SAME fixture in the SAME run; an inherited
# estimate is not an acceptable baseline.
AC4_RATIO_MAX=40      # non-ambiguous, percent of default output bytes
AC4B_RATIO_MAX=50     # ambiguous (the doubled candidate array is the open upper tail)
o3_ratio(){  # o3_ratio <fixture> <window> -> sets O3_FULL_B / O3_SUM_B / O3_PCT
  run_o3 "$TMP/ratio-full" "$INSPECT" "$O3/$1/state.sqlite" "$O3/$1/sessions" --tail-events "$2"
  run_o3 "$TMP/ratio-sum"  "$INSPECT" "$O3/$1/state.sqlite" "$O3/$1/sessions" --tail-events "$2" --summary
  O3_FULL_B=$(wc -c < "$TMP/ratio-full" | tr -d ' ')
  O3_SUM_B=$(wc -c < "$TMP/ratio-sum" | tr -d ' ')
  O3_PCT=$(( O3_SUM_B * 100 / O3_FULL_B ))
}
o3_ratio basic 20
if [[ "$O3_PCT" -le "$AC4_RATIO_MAX" ]]; then
  ok "non-ambiguous: ${O3_SUM_B} B of ${O3_FULL_B} B = ${O3_PCT}% (bar ${AC4_RATIO_MAX}%)"
else
  no "non-ambiguous: ${O3_SUM_B} B of ${O3_FULL_B} B = ${O3_PCT}% exceeds the ${AC4_RATIO_MAX}% bar"
fi

echo "== 28. O3/AC4b: 12 ambiguous candidates cap at 5 while the TRUE total survives =="
o3_ratio ambig12 20
if [[ "$O3_PCT" -le "$AC4B_RATIO_MAX" ]]; then
  ok "ambiguous: ${O3_SUM_B} B of ${O3_FULL_B} B = ${O3_PCT}% (bar ${AC4B_RATIO_MAX}%)"
else
  no "ambiguous: ${O3_SUM_B} B of ${O3_FULL_B} B = ${O3_PCT}% exceeds the ${AC4B_RATIO_MAX}% bar"
fi
if "$NODE_BIN" -e '
  const v = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const r = v.rollout;
  if (r.selection.status !== "ambiguous") throw new Error("status=" + r.selection.status);
  if (r.selection.reason !== "multiple-candidates") throw new Error("reason=" + r.selection.reason);
  if (r.selection.authority !== "sessions-root-match") throw new Error("authority=" + r.selection.authority);
  if (r.primary !== null) throw new Error("ambiguity must select no primary");
  if (r.candidatesAmbiguous !== true) throw new Error("candidatesAmbiguous must be true");
  // The cap is only safe because the true total is never lost.
  if (r.selection.candidateCount !== 12) throw new Error("candidateCount=" + r.selection.candidateCount + " want 12");
  if (r.candidates.length !== 5) throw new Error("candidates.length=" + r.candidates.length);
  if (r.ambiguousCandidates.length !== 5) throw new Error("ambiguousCandidates.length=" + r.ambiguousCandidates.length);
  for (const c of [...r.candidates, ...r.ambiguousCandidates]) {
    const keys = Object.keys(c).sort().join(",");
    if (keys !== "path,size,source") throw new Error("candidate key set is " + keys);
  }
' "$TMP/ratio-sum" 2>"$TMP/ac4b-err"; then
  ok "both candidate arrays cap at 5, keys are exactly path/source/size, candidateCount stays 12"
else
  no "ambiguous projection is wrong: $(cat "$TMP/ac4b-err")"
fi

echo "== 29. O3/AC5: the mini-tail is bounded, re-truncated in place, and parameter-free =="
# The 120-char re-truncation is the ONLY value deviation in the whole projection, so it carries
# the whole burden of proof: truncate() normalizes whitespace and then slices the ORIGINAL
# characters, so truncate(truncate(s,600),120) === truncate(s,120) -- the outer slice can never
# read the inner marker. Proven here against BOTH the derivation and a separate real run at
# --max-text-chars 120, which is the parameter shift the projection deliberately does NOT make.
run_o3 "$TMP/ac5-full"  "$INSPECT" "$O3/basic/state.sqlite" "$O3/basic/sessions" --tail-events 20
run_o3 "$TMP/ac5-sum"   "$INSPECT" "$O3/basic/state.sqlite" "$O3/basic/sessions" --tail-events 20 --summary
run_o3 "$TMP/ac5-mtc"   "$INSPECT" "$O3/basic/state.sqlite" "$O3/basic/sessions" --tail-events 20 --max-text-chars 120
if "$NODE_BIN" -e '
  const fs = require("node:fs");
  const [full, sum, mtc] = process.argv.slice(1).map((p) => JSON.parse(fs.readFileSync(p, "utf8")));
  const truncate = (text, maxChars) => {
    if (!text) return "";
    const n = String(text).replace(/\s+/g, " ").trim();
    return n.length <= maxChars ? n : n.slice(0, Math.max(0, maxChars - 14)) + "...[truncated]";
  };
  const tail = sum.rollout.primary.recentItems;
  const fullTail = full.rollout.primary.recentItems;
  const mtcTail = mtc.rollout.primary.recentItems;
  if (tail.length !== 3) throw new Error("mini-tail length " + tail.length + " want 3");
  if (fullTail.length !== 20) throw new Error("default tail length " + fullTail.length + " want 20 (fixture too small)");
  if (JSON.stringify(tail).length > 1500) throw new Error("serialized mini-tail " + JSON.stringify(tail).length + " B > 1500");
  const want = ["line", "payloadType", "role", "text", "timestamp"].join(",");
  let truncatedSeen = 0;
  for (let i = 0; i < 3; i++) {
    const item = tail[i];
    const source = fullTail[fullTail.length - 3 + i];
    const viaMtc = mtcTail[mtcTail.length - 3 + i];
    if (Object.keys(item).sort().join(",") !== want) throw new Error("key set " + Object.keys(item).sort().join(","));
    // C-a/C-c aside, every retained leaf is value-identical to the default emit.
    for (const k of ["line", "timestamp", "payloadType", "role"]) {
      if (JSON.stringify(item[k]) !== JSON.stringify(source[k])) throw new Error("leaf " + k + " diverged at tail " + i);
    }
    if (item.text.length > 120) throw new Error("text " + item.text.length + " chars > 120");
    if (item.text !== truncate(source.text, 120)) throw new Error("text is not truncate(default,120) at tail " + i);
    if (item.text !== viaMtc.text) throw new Error("text differs from a real --max-text-chars 120 run at tail " + i);
    if (item.text.endsWith("...[truncated]")) truncatedSeen += 1;
  }
  if (truncatedSeen === 0) throw new Error("no tail item was actually re-truncated; the proof is vacuous");
  // Amendment-3 fields, by `in` (status/reason/authority are strings but path is legitimately null).
  for (const k of ["status", "reason", "authority", "path", "candidateCount", "aliasCount"]) {
    if (!(k in sum.rollout.selection)) throw new Error("selection." + k + " missing");
  }
  if (!("parsedOk" in sum.rollout.primary)) throw new Error("primary.parsedOk missing");
  if (!("candidatesAmbiguous" in sum.rollout)) throw new Error("candidatesAmbiguous missing");
' "$TMP/ac5-full" "$TMP/ac5-sum" "$TMP/ac5-mtc" 2>"$TMP/ac5-err"; then
  ok "mini-tail is <=3 items / 5 keys / <=120 chars, value-identical elsewhere, and equals a real --max-text-chars 120 run"
else
  no "mini-tail projection is wrong: $(cat "$TMP/ac5-err")"
fi
# A DB-authoritative rollout may legitimately be parsedOk:false; the summary must not hide it.
run_o3 "$TMP/ac5-bad" "$INSPECT" "$O3/malformed/state.sqlite" "$O3/malformed/sessions" --tail-events 20 --summary
if "$NODE_BIN" -e '
  const v = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (v.rollout.selection.authority !== "db.rollout_path") throw new Error("authority lost");
  if (v.rollout.primary === null) throw new Error("DB-designated primary was dropped");
  if (v.rollout.primary.parsedOk !== false) throw new Error("parse invalidity was hidden");
  if (v.rollout.primary.parseErrorCount !== 1) throw new Error("parseErrorCount=" + v.rollout.primary.parseErrorCount);
' "$TMP/ac5-bad" 2>"$TMP/ac5b-err"; then
  ok "a malformed DB-authoritative rollout keeps parsedOk:false and its parseErrorCount in the summary"
else
  no "malformed-rollout projection is wrong: $(cat "$TMP/ac5b-err")"
fi

echo "== 30. O3/AC7: the projection is complete JSON, is documented, and is actually adopted =="
# Four conjuncts. The fourth is the flag-without-adoption guard: a commit that adds --summary but
# leaves the SKILL.md preflight fence pointing at the unprojected invocation is not O3.
AC7_OK=1
"$NODE_BIN" -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"))' "$TMP/ratio-sum" 2>/dev/null \
  || { AC7_OK=0; echo "    the ambiguous-fixture summary is not parseable JSON"; }
[[ "$O3_PCT" -le "$AC4B_RATIO_MAX" ]] || { AC7_OK=0; echo "    the ambiguous-fixture summary breached its ratio bar"; }
grep -qF 'never pipe the preflight through `head`/`tail`' "$SKILL_MD" \
  || { AC7_OK=0; echo "    SKILL.md lost the read-it-whole instruction"; }
# The fenced preflight invocation itself, extracted by content rather than by line number.
if ! grep -q 'codex_ipc_session_inspect\.mjs.*--thread <conversationId>.*--summary' "$SKILL_MD"; then
  AC7_OK=0; echo "    SKILL.md's preflight invocation does not pass --summary (flag without adoption)"
fi
[[ $AC7_OK -eq 1 ]] \
  && ok "summary output parses whole, stays within its bar, is documented, and the preflight fence adopts it" \
  || no "an AC7 conjunct failed"
echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
