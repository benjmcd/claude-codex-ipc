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

# ---- A-08 mid-turn (RED, pending A4/Phase-3) --------------------------------------------
# start -> user -> agent with NO terminal. CURRENT: maybeMidTurn=false, no turnActivity
# field, conclusion "no mid-turn condition inferred". DESIRED (A4): turnActivity=="open".
# Gated OFF by default so the release runner's green battery is unaffected; observe RED with:
#   IPC_RED_PENDING=1 bash tests/test_session_inspect.sh
if [[ "${IPC_RED_PENDING:-0}" == "1" ]]; then
  echo "== A-08 mid-turn: start->user->agent, no terminal is open (RED, pending A4/Phase-3) =="
  CASE="$TMP/a08-midturn"; mkdir -p "$CASE/sessions"
  ROLLOUT="$CASE/sessions/rollout-a08-$THREAD.jsonl"
  cp "$TDIR/fixtures/rollout/rollout-a08-midturn-$THREAD.jsonl" "$ROLLOUT"
  make_db "$CASE/state.sqlite" "$ROLLOUT"
  run_inspect "$CASE/state.sqlite" "$CASE/sessions"
  if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | "$NODE_BIN" -e 'const v=JSON.parse(require("node:fs").readFileSync(0,"utf8"));process.exit(v.activitySignals.turnActivity==="open"?0:1);' >/dev/null 2>&1; then
    ok "A-08 mid-turn start->user->agent is classified open"
  else
    no "A-08 mid-turn start->user->agent is classified open (RED: pending A4/Phase-3)"
  fi
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
