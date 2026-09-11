#!/usr/bin/env bash
# Hermetic session-inspector hardening tests.
# Uses only temp SQLite/JSONL state. Never reads ~/.codex and never connects to IPC.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECT=""
SNAPSHOT=""
for candidate in \
  "$TDIR/../skills/ipc/scripts/codex_ipc_session_inspect.mjs" \
  "$TDIR/../scripts/codex_ipc_session_inspect.mjs"; do
  [[ -f "$candidate" ]] && INSPECT="$candidate" && break
done
[[ -n "$INSPECT" ]] || { echo "FATAL: codex_ipc_session_inspect.mjs not found" >&2; exit 1; }
for candidate in \
  "$TDIR/../skills/ipc/scripts/codex_ipc_snapshot.mjs" \
  "$TDIR/../scripts/codex_ipc_snapshot.mjs"; do
  [[ -f "$candidate" ]] && SNAPSHOT="$candidate" && break
done
[[ -n "$SNAPSHOT" ]] || { echo "FATAL: codex_ipc_snapshot.mjs not found" >&2; exit 1; }

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
PAGE="00000000-0000-4000-8000-00000000c0de"
HISTORY_BASE="33333333-3333-4333-8333-333333333333"
OTHER_THREAD="22222222-2222-4222-8222-222222222222"
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

SNAPSHOT_DB_BUILDER="$TMP/build-snapshot-db.mjs"
cat > "$SNAPSHOT_DB_BUILDER" <<'EOF'
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";

const [dbPath, ...threadIds] = process.argv.slice(2);
const columns = [
  "id", "rollout_path", "created_at", "updated_at", "source", "model_provider", "cwd",
  "title", "sandbox_policy", "approval_mode", "tokens_used", "has_user_event", "archived",
  "git_sha", "git_branch", "cli_version", "first_user_message", "agent_nickname", "agent_role",
  "memory_mode", "model", "reasoning_effort", "agent_path", "created_at_ms", "updated_at_ms",
  "thread_source", "preview",
];
fs.rmSync(dbPath, { force: true });
const db = new DatabaseSync(dbPath);
try {
  db.exec(`create table threads (${columns.map((name) => `${name} text`).join(", ")})`);
  const insert = db.prepare("insert into threads (id, archived) values (?, ?)");
  for (const threadId of threadIds) insert.run(threadId, 0);
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

ROOT_SYMLINK_BUILDER="$TMP/build-root-symlink.mjs"
cat > "$ROOT_SYMLINK_BUILDER" <<'EOF'
import fs from "node:fs";
import path from "node:path";

const target = path.resolve(process.argv[2]);
const aliasPath = path.resolve(process.argv[3]);
try {
  if (process.platform === "win32") {
    fs.symlinkSync(target, aliasPath, "file");
  } else {
    fs.symlinkSync(target, aliasPath);
  }
} catch (error) {
  process.stderr.write(`symlink unavailable: ${error.code || error.message}\n`);
  process.exit(77);
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
    assert(value.activitySignals.lastTurnAbortedLine === 3, "turn_aborted line mismatch");
    assert(value.activitySignals.lastTerminalLine === 3, "terminal line mismatch");
    assert(value.activitySignals.lastTerminalType === "turn_aborted", "terminal type mismatch");
    assert(value.activitySignals.terminalState === "aborted", "terminal state mismatch");
    assert(value.activitySignals.hasTurnAbortedInTail === true, "abort presence missing");
    assert(value.activitySignals.hasTerminalInTail === true, "terminal presence missing");
    assert(value.activitySignals.maybeMidTurn === false, "abort must close the inferred turn");
    break;
  case "complete-terminal":
    assert(value.activitySignals.lastTaskCompleteLine === 3, "task_complete backward field changed");
    assert(value.activitySignals.lastTurnAbortedLine === null, "unexpected abort line");
    assert(value.activitySignals.lastTerminalLine === 3, "terminal line mismatch");
    assert(value.activitySignals.lastTerminalType === "task_complete", "terminal type mismatch");
    assert(value.activitySignals.terminalState === "completed", "terminal state mismatch");
    assert(value.activitySignals.hasTaskCompleteInTail === true, "completion presence changed");
    assert(value.activitySignals.hasTerminalInTail === true, "terminal presence missing");
    assert(value.activitySignals.maybeMidTurn === false, "completion must remain terminal");
    break;
  case "canonical-thread":
    assert(value.threadId === "11111111-1111-4111-8111-111111111111", "top-level thread id was not canonicalized");
    assert(value.dbThread.thread.id === value.threadId, "canonical target did not retain DB authority");
    assert(value.rollout.selection?.authority === "db.rollout_path", "uppercase target lost DB rollout authority");
    break;
  case "user-after-terminal":
    assert(value.activitySignals.lastTurnAbortedLine === 3, "abort line mismatch");
    assert(value.activitySignals.lastTerminalLine === 3, "terminal line mismatch");
    assert(value.activitySignals.lastUserMessageLine === 4, "latest user line mismatch");
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
  case "unresolved-candidate-set":
    assert(value.rollout.candidates.length === 1, "expected one valid discovered candidate");
    assert(value.rollout.primary === null, "an unresolved candidate set must select no primary");
    assert(value.rollout.candidatesAmbiguous === true, "unresolved candidate-set ambiguity flag missing");
    assert(value.rollout.selection?.status === "ambiguous", "selection status mismatch");
    assert(value.rollout.selection?.reason === "candidate-set-unresolved", "selection reason mismatch");
    assert(value.rollout.selection?.authority === "sessions-root-match", "authority mismatch");
    assert(value.rollout.selection?.rejectedCandidateCount === 1, "rejected sibling count missing");
    assert(value.rollout.selection?.scanIssueCount === 0, "unexpected scan issue count");
    assert(value.warnings.some((item) => item.includes("rejected target candidates")), "unresolved warning missing");
    assert(!value.warnings.some((item) => item.includes("Multiple distinct")), "false equal-authority warning retained");
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
  case "paginated-db-authority":
    assert(value.rollout.candidates.length === 1, "expected one DB-designated paginated candidate");
    assert(value.rollout.candidates[0].source === "db.rollout_path", "paginated candidate lost DB source");
    assert(value.rollout.selection?.status === "found", "paginated DB rollout was not selected");
    assert(value.rollout.selection?.reason === "db-rollout-path", "paginated DB selection reason mismatch");
    assert(value.rollout.selection?.authority === "db.rollout_path", "paginated DB authority missing");
    assert(value.rollout.primary?.path === value.dbThread.thread.rolloutPath, "paginated DB rollout path mismatch");
    assert(value.rollout.primary?.parsedOk === true, "paginated DB rollout was not parsed");
    assert(value.activitySignals?.turnActivity === "closed", "paginated DB rollout activity was not reported");
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
  case "root-symlink-distinct":
    assert(value.rollout.candidates.length === 2, "root scan omitted a distinct symlink target");
    assert(value.rollout.primary === null, "distinct symlink target must not select a primary");
    assert(value.rollout.candidatesAmbiguous === true, "distinct symlink target ambiguity missing");
    assert(value.rollout.ambiguousCandidates.length === 2, "distinct symlink ambiguity list missing");
    assert(value.rollout.selection?.status === "ambiguous", "distinct symlink selection status mismatch");
    assert(value.rollout.selection?.reason === "multiple-candidates", "distinct symlink selection reason mismatch");
    assert(value.rollout.selection?.authority === "sessions-root-match", "distinct symlink authority mismatch");
    assert(value.rollout.selection?.aliasCount === 2, "distinct symlink alias count mismatch");
    break;
  case "root-symlink-alias":
    assert(value.rollout.candidates.length === 1, "same-target root symlink was not deduplicated");
    assert(value.rollout.candidates[0].aliases.length === 2, "same-target root alias spellings missing");
    assert(value.rollout.primary?.parsedOk === true, "same-target root alias did not retain a primary");
    assert(value.rollout.candidatesAmbiguous === false, "same-target root aliases cannot be ambiguous");
    assert(value.rollout.selection?.status === "found", "same-target root alias selection status mismatch");
    assert(value.rollout.selection?.reason === "single-candidate", "same-target root alias selection reason mismatch");
    assert(value.rollout.selection?.authority === "sessions-root-match", "same-target root alias authority mismatch");
    assert(value.rollout.selection?.aliasCount === 2, "same-target root alias count mismatch");
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
  case "invalid-db-identity":
    assert(value.rollout.primary === null, "identity-invalid DB rollout must not be parsed");
    assert(value.rollout.selection?.status === "unavailable", "identity-invalid DB rollout must be unavailable");
    assert(value.rollout.selection?.path === null, "identity-invalid DB rollout must select no path");
    assert(
      value.rollout.selection?.authority !== "sessions-root-match",
      "identity-invalid DB authority must not fall back to a sessions-root match",
    );
    break;
  case "suffix-decoy":
    assert(value.rollout.candidates.length === 0, "suffix decoy must not be a rollout candidate");
    assert(value.rollout.primary === null, "suffix decoy must not be parsed");
    assert(value.rollout.candidatesAmbiguous === true, "suffix decoy must keep discovery unresolved");
    assert(value.rollout.selection?.status === "ambiguous", "suffix decoy must be fail-visible");
    assert(value.rollout.selection?.reason === "candidate-set-unresolved", "suffix decoy reason mismatch");
    assert(value.rollout.selection?.rejectedCandidateCount === 1, "suffix decoy diagnostic count missing");
    assert(value.rollout.selection?.scanIssueCount === 0, "unexpected suffix-decoy scan issue count");
    assert(value.rollout.selection?.path === null, "suffix decoy must select no path");
    break;
  case "unusable-db-authority":
    assert(value.rollout.candidates.length === 0, "unusable DB authority must not expose a fallback candidate");
    assert(value.rollout.primary === null, "unusable DB authority must not parse a fallback");
    assert(value.rollout.selection?.status === "unavailable", "unusable DB authority must be unavailable");
    assert(value.rollout.selection?.authority === "db.rollout_path", "DB authority attribution was lost");
    assert(value.rollout.selection?.path === null, "unusable DB authority must select no path");
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
  local db_path="$1" sessions_root="$2" thread_id="${3:-$THREAD}"
  local err_path="$TMP/inspect.stderr"
  OUT="$("$NODE_BIN" "$INSPECT" \
    --db "$db_path" \
    --sessions-root "$sessions_root" \
    --thread "$thread_id" \
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
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"user_message","message":"task"}}
{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}
EOF
}

write_user_complete(){
  local file_path="$1"
  cat > "$file_path" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"user_message","message":"task"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}
EOF
}

write_user_after_abort(){
  local file_path="$1"
  cat > "$file_path" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
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

echo "== 2b. inspector canonicalizes case-insensitive UUID input before authority lookup =="
run_inspect "$CASE/state.sqlite" "$CASE/sessions" "${THREAD^^}"
assert_case canonical-thread "uppercase target retains the exact lowercase DB row and rollout authority"

echo "== 2c. snapshot canonicalizes target/other/allowlist UUIDs and binds compare identity =="
SNAP_CASE="$TMP/snapshot-case"; mkdir -p "$SNAP_CASE"
"$NODE_BIN" "$SNAPSHOT_DB_BUILDER" "$SNAP_CASE/state.sqlite" "$THREAD" "$OTHER_THREAD" >/dev/null 2>&1
printf '%s\n' 'model = "synthetic"' > "$SNAP_CASE/config.toml"
SNAP_OUT="$("$NODE_BIN" "$SNAPSHOT" --db "$SNAP_CASE/state.sqlite" --config "$SNAP_CASE/config.toml" \
  --thread "${THREAD^^}" --other-thread "${OTHER_THREAD^^}" 2>/dev/null)"; SNAP_RC=$?
if [[ $SNAP_RC -eq 0 ]] && printf '%s' "$SNAP_OUT" | "$NODE_BIN" -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
const thread = process.argv[1];
const other = process.argv[2];
process.exit(value.ok === true && value.targetThreadId === thread &&
  value.otherThreadIds?.[0] === other && value.db?.threads?.target?.id === thread &&
  value.db?.threads?.otherThreads?.[other]?.id === other ? 0 : 1);
' "$THREAD" "$OTHER_THREAD" >/dev/null 2>&1; then
  ok "snapshot resolves uppercase target and other-thread inputs to canonical DB identities"
else
  no "snapshot UUID canonicalization failed (rc=$SNAP_RC)"
fi

SNAP_BEFORE="$SNAP_CASE/before.json"
SNAP_AFTER="$SNAP_CASE/after.json"
SNAP_MISMATCH="$SNAP_CASE/mismatch.json"
SNAP_BEFORE="$SNAP_BEFORE" SNAP_AFTER="$SNAP_AFTER" SNAP_MISMATCH="$SNAP_MISMATCH" \
  SNAP_THREAD="$THREAD" SNAP_OTHER="$OTHER_THREAD" "$NODE_BIN" --input-type=module <<'NODE'
import fs from "node:fs";
const thread = process.env.SNAP_THREAD;
const other = process.env.SNAP_OTHER;
function snapshot(targetThreadId, targetRowId, otherHash, uppercaseHashIds = false) {
  const threadKey = uppercaseHashIds ? thread.toUpperCase() : thread;
  const otherKey = uppercaseHashIds ? other.toUpperCase() : other;
  return {
    targetThreadId,
    config: { sha256: "a", keys: {}, stableDuringRead: true },
    db: {
      stableDuringRead: true,
      marker: null,
      threads: {
        target: { exists: true, id: targetRowId },
        threadRowHashById: { [threadKey]: "target", [otherKey]: otherHash },
      },
    },
  };
}
fs.writeFileSync(process.env.SNAP_BEFORE, JSON.stringify(snapshot(thread.toUpperCase(), thread.toUpperCase(), "before", true)));
fs.writeFileSync(process.env.SNAP_AFTER, JSON.stringify(snapshot(thread, thread, "after")));
fs.writeFileSync(process.env.SNAP_MISMATCH, JSON.stringify(snapshot(other, other, "before")));
NODE
COMPARE_OUT="$("$NODE_BIN" "$SNAPSHOT" --compare "$SNAP_BEFORE" "$SNAP_AFTER" \
  --allow-thread-change "${OTHER_THREAD^^}" 2>/dev/null)"; COMPARE_RC=$?
if [[ $COMPARE_RC -eq 0 ]] && printf '%s' "$COMPARE_OUT" | "$NODE_BIN" -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
process.exit(value.ok === true && value.db?.targetIdentityBound === true &&
  value.allowThreadChangeIds?.[0] === process.argv[1] &&
  value.db?.allowedNonTargetChangedIds?.[0] === process.argv[1] ? 0 : 1);
' "$OTHER_THREAD" >/dev/null 2>&1; then
  ok "snapshot compare accepts mixed-case same identity and canonicalizes its change allowlist"
else
  no "snapshot compare same-identity canonicalization failed (rc=$COMPARE_RC)"
fi
MISMATCH_OUT="$("$NODE_BIN" "$SNAPSHOT" --compare "$SNAP_BEFORE" "$SNAP_MISMATCH" 2>/dev/null)"; MISMATCH_RC=$?
if [[ $MISMATCH_RC -ne 0 ]] && printf '%s' "$MISMATCH_OUT" | "$NODE_BIN" -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
process.exit(value.ok === false && value.db?.targetIdentityBound === false ? 0 : 1);
' >/dev/null 2>&1; then
  ok "snapshot compare rejects different before/after target identities"
else
  no "snapshot compare did not fail closed on target mismatch (rc=$MISMATCH_RC)"
fi

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

echo "== 6a. root-only discovery sees a symlink to a distinct physical rollout =="
CASE="$TMP/root-symlink-distinct"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b" "$CASE/sources"
write_user_complete "$CASE/sessions/a/rollout-regular-$THREAD.jsonl"
write_user_complete "$CASE/sources/distinct.jsonl"
SYMLINK_RC=0
"$NODE_BIN" "$ROOT_SYMLINK_BUILDER" \
  "$CASE/sources/distinct.jsonl" \
  "$CASE/sessions/b/rollout-symlink-$THREAD.jsonl" || SYMLINK_RC=$?
if [[ $SYMLINK_RC -eq 0 ]]; then
  make_db "$CASE/state.sqlite"
  run_inspect "$CASE/state.sqlite" "$CASE/sessions"
  assert_case root-symlink-distinct "root scan keeps a distinct symlink target ambiguous"
elif [[ $SYMLINK_RC -eq 77 ]]; then
  echo "  NOTE: file symlinks unavailable; skipping distinct root-symlink regression"
else
  no "distinct root-symlink fixture failed (rc=$SYMLINK_RC)"
fi

echo "== 6b. root-only discovery deduplicates a symlink to the same physical rollout =="
CASE="$TMP/root-symlink-alias"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
TARGET="$CASE/sessions/a/rollout-regular-$THREAD.jsonl"
write_user_complete "$TARGET"
SYMLINK_RC=0
"$NODE_BIN" "$ROOT_SYMLINK_BUILDER" \
  "$TARGET" \
  "$CASE/sessions/b/rollout-symlink-$THREAD.jsonl" || SYMLINK_RC=$?
if [[ $SYMLINK_RC -eq 0 ]]; then
  make_db "$CASE/state.sqlite"
  run_inspect "$CASE/state.sqlite" "$CASE/sessions"
  assert_case root-symlink-alias "root scan deduplicates a same-target symlink with aliasCount 2"
elif [[ $SYMLINK_RC -eq 77 ]]; then
  echo "  NOTE: file symlinks unavailable; skipping same-target root-symlink regression"
else
  no "same-target root-symlink fixture failed (rc=$SYMLINK_RC)"
fi

echo "== 7. one discovered candidate remains readable =="
CASE="$TMP/single"; mkdir -p "$CASE/sessions"
write_user_complete "$CASE/sessions/rollout-single-$THREAD.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case single-candidate "single sessions-root candidate remains primary"

echo "== 8. DB authority does not silently fall back after a parse error =="
CASE="$TMP/malformed-db"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
DB_ROLLOUT="$CASE/sessions/a/rollout-db-bad-$THREAD.jsonl"
cat > "$DB_ROLLOUT" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{malformed
EOF
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

write_paginated_closed(){  # $1=path  $2=session_id (optional)
  local file_path="$1" session_id="${2:-$THREAD}"
  cat > "$file_path" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD","session_id":"$session_id","history_mode":"paginated","history_base":{"thread_id":"$HISTORY_BASE"}}}
{"type":"event_msg","payload":{"type":"task_started","thread_id":"$THREAD","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","thread_id":"$THREAD","turn_id":"turn-a","message":"do the task"}}
{"type":"event_msg","payload":{"type":"agent_message","thread_id":"$THREAD","turn_id":"turn-a","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","thread_id":"$THREAD","turn_id":"turn-a","last_agent_message":"done"}}
EOF
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

write_wrong_thread_wrapper(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-a","thread_id":"22222222-2222-4222-8222-222222222222","item":{"type":"AgentMessage","id":"item-a","phase":"final_answer","content":[{"type":"output_text","text":"wrong owner body"}]}}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"wrong owner body"}}
EOF
}

write_rebound_owner(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"done"}}
EOF
}

write_lineaged_owner(){
  cat > "$1" <<EOF
{"ordinal":0,"type":"session_meta","payload":{"id":"$THREAD","parent_thread_id":"22222222-2222-4222-8222-222222222222","forked_from_id":"22222222-2222-4222-8222-222222222222","subagent_history_start_ordinal":6}}
{"ordinal":1,"type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","forked_from_id":"33333333-3333-4333-8333-333333333333"}}
{"ordinal":2,"type":"event_msg","payload":{"type":"task_started","turn_id":"ancestor-turn"}}
{"ordinal":3,"type":"event_msg","payload":{"type":"user_message","turn_id":"ancestor-turn","message":"inherited task"}}
{"ordinal":4,"type":"event_msg","payload":{"type":"agent_message","turn_id":"ancestor-turn","message":"inherited body","phase":"final_answer"}}
{"ordinal":5,"type":"event_msg","payload":{"type":"task_complete","turn_id":"ancestor-turn","last_agent_message":"inherited body"}}
{"ordinal":6,"type":"event_msg","payload":{"type":"thread_settings_applied"}}
{"ordinal":7,"type":"event_msg","payload":{"type":"task_started","thread_id":"$THREAD","turn_id":"turn-a"}}
{"ordinal":8,"type":"event_msg","payload":{"type":"user_message","thread_id":"$THREAD","turn_id":"turn-a","message":"sanitized task"}}
{"ordinal":9,"type":"event_msg","payload":{"type":"agent_message","thread_id":"$THREAD","turn_id":"turn-a","message":"done","phase":"final_answer"}}
{"ordinal":10,"type":"event_msg","payload":{"type":"task_complete","thread_id":"$THREAD","turn_id":"turn-a","last_agent_message":"done"}}
EOF
}

write_lineaged_owner_without_boundary(){
  cat > "$1" <<EOF
{"ordinal":0,"type":"session_meta","payload":{"id":"$THREAD","forked_from_id":"22222222-2222-4222-8222-222222222222"}}
{"ordinal":1,"type":"event_msg","payload":{"type":"task_started","thread_id":"$THREAD","turn_id":"turn-a"}}
{"ordinal":2,"type":"event_msg","payload":{"type":"user_message","thread_id":"$THREAD","turn_id":"turn-a","message":"sanitized task"}}
{"ordinal":3,"type":"event_msg","payload":{"type":"agent_message","thread_id":"$THREAD","turn_id":"turn-a","message":"done","phase":"final_answer"}}
{"ordinal":4,"type":"event_msg","payload":{"type":"task_complete","thread_id":"$THREAD","turn_id":"turn-a","last_agent_message":"done"}}
EOF
}

write_lineaged_owner_boundary_only(){
  cat > "$1" <<EOF
{"ordinal":0,"type":"session_meta","payload":{"id":"$THREAD","parent_thread_id":"22222222-2222-4222-8222-222222222222","forked_from_id":"22222222-2222-4222-8222-222222222222","subagent_history_start_ordinal":6}}
{"ordinal":1,"type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","forked_from_id":"33333333-3333-4333-8333-333333333333"}}
{"ordinal":2,"type":"event_msg","payload":{"type":"task_started","turn_id":"ancestor-turn"}}
{"ordinal":3,"type":"event_msg","payload":{"type":"user_message","turn_id":"ancestor-turn","message":"inherited task"}}
{"ordinal":4,"type":"event_msg","payload":{"type":"agent_message","turn_id":"ancestor-turn","message":"inherited body","phase":"final_answer"}}
{"ordinal":5,"type":"event_msg","payload":{"type":"task_complete","turn_id":"ancestor-turn","last_agent_message":"inherited body"}}
{"ordinal":6,"type":"event_msg","payload":{"type":"thread_settings_applied"}}
EOF
}

write_rebound_owner_before_turn(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-later"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-later","message":"sanitized task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-later","last_agent_message":"done"}}
EOF
}

write_invalid_owner_before_turn(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"session_meta","payload":{"id":"not-a-uuid"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-later"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-later","message":"sanitized task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-later","last_agent_message":"done"}}
EOF
}

write_ownerless_closed(){
  cat > "$1" <<EOF
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-a","message":"sanitized task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"done"}}
EOF
}

write_wrong_thread_direct(){
  cat > "$1" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","thread_id":"22222222-2222-4222-8222-222222222222","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","thread_id":"22222222-2222-4222-8222-222222222222","turn_id":"turn-a","message":"sanitized task"}}
{"type":"event_msg","payload":{"type":"agent_message","thread_id":"22222222-2222-4222-8222-222222222222","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","thread_id":"22222222-2222-4222-8222-222222222222","turn_id":"turn-a","last_agent_message":"done"}}
EOF
}

write_malformed_thread_direct_after_terminal(){
  write_closed_same_turn "$1"
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","thread_id":"","info":{"total":1}}}' >> "$1"
}

write_malformed_thread_nested_after_terminal(){
  write_closed_same_turn "$1"
  printf '%s\n' "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"turn-a\",\"thread_id\":\"$THREAD\",\"item\":{\"id\":\"bad-owner\",\"type\":\"Reasoning\",\"thread_id\":0}}}" >> "$1"
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

# Exercise the write-proof live branch without a pipe: the real harness and rollout reader are
# copied beside four process-boundary stubs. The client stub preserves the maintained response
# envelope and, for resolvable shapes, appends a same-thread/same-turn completion to the rollout.
WP_TURN="00000000-0000-4000-8000-000000000000"
WP_OTHER_TURN="22222222-2222-4222-8222-222222222222"

wp_live_setup(){  # $1=case dir  $2=rollout variant (optional)
  local case_dir="$1" variant="${2:-valid}" scripts="$1/scripts" home="$1/home"
  mkdir -p "$scripts" "$home/.codex/sessions"
  case "$variant" in
    valid)
      WP_LIVE_ROLLOUT="$home/.codex/sessions/rollout-wp-live-${THREAD}_${PAGE}.jsonl"
      write_paginated_closed "$WP_LIVE_ROLLOUT"
      ;;
    wrong-root)
      WP_LIVE_ROLLOUT="$home/.codex/sessions/rollout-wp-live-${OTHER_THREAD}_${PAGE}.jsonl"
      write_paginated_closed "$WP_LIVE_ROLLOUT"
      ;;
    bad-page)
      WP_LIVE_ROLLOUT="$home/.codex/sessions/rollout-wp-live-${THREAD}_not-a-page.jsonl"
      write_paginated_closed "$WP_LIVE_ROLLOUT"
      ;;
    bad-metadata)
      WP_LIVE_ROLLOUT="$home/.codex/sessions/rollout-wp-live-${THREAD}_${PAGE}.jsonl"
      write_paginated_closed "$WP_LIVE_ROLLOUT" "$OTHER_THREAD"
      ;;
    *)
      echo "unknown write-proof rollout variant: $variant" >&2
      return 1
      ;;
  esac
  WP_LIVE_SEND_COUNT="$case_dir/send-count.txt"
  WP_LIVE_SNAPSHOT_COUNT="$case_dir/snapshot-count.txt"
  WP_LIVE_STDERR="$case_dir/write-proof.stderr"
  cp "$WRITE_PROOF" "$scripts/codex_ipc_write_proof.mjs"
  cp "$(dirname "$WRITE_PROOF")/codex_ipc_rollout_reader.mjs" \
    "$scripts/codex_ipc_rollout_reader.mjs"

  cat > "$scripts/codex_ipc_session_inspect.mjs" <<'EOF'
const threadId = process.env.WP_THREAD;
const rolloutPath = process.env.WP_ROLLOUT;
const mode = process.env.WP_RESPONSE_MODE;
const structuredNegative = mode === "structured-negative-inspection";
const dbTrusted = mode !== "untrusted-inspection" && !structuredNegative;
console.log(JSON.stringify({
  ok: !structuredNegative,
  dbThread: {
    exists: dbTrusted,
    readOnlyOpenOk: dbTrusted,
    thread: structuredNegative
      ? { exists: false }
      : { exists: true, id: threadId, archived: 0, rolloutPath },
  },
  rollout: { primary: { path: rolloutPath, lineCount: 5 } },
  activitySignals: {
    turnActivity: structuredNegative ? "ambiguous" : "closed",
    maybeMidTurn: false,
  },
}));
if (structuredNegative) process.exitCode = 1;
EOF

  cat > "$scripts/codex_ipc_revalidate.mjs" <<'EOF'
console.log(JSON.stringify({
  ok: true,
  revalidationLevel: "initialize-only",
  summary: { failed: [], skipped: [] },
}));
EOF

  cat > "$scripts/codex_ipc_snapshot.mjs" <<'EOF'
import fs from "node:fs";
const countPath = process.env.WP_SNAPSHOT_COUNT;
const count = (fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, "utf8")) : 0) + 1;
fs.writeFileSync(countPath, String(count));
const mode = process.env.WP_RESPONSE_MODE;
const rolloutPath = process.env.WP_ROLLOUT;
if (mode === "rollout-growth-before-send" && count === 1) {
  fs.appendFileSync(rolloutPath, `${JSON.stringify({ type: "world_state", payload: {} })}\n`);
}
if (mode === "rollout-same-size-before-send" && count === 1) {
  const original = fs.readFileSync(rolloutPath, "utf8");
  const replacement = original.replaceAll(process.env.WP_THREAD, process.env.WP_OTHER_TURN);
  if (Buffer.byteLength(replacement) !== Buffer.byteLength(original)) {
    throw new Error("same-size test fixture changed byte length");
  }
  fs.writeFileSync(rolloutPath, replacement);
}
if (mode === "after-snapshot-error" && count > 1) {
  console.error("offline stub: post-send snapshot failed");
  process.exit(1);
}
const threadId = process.env.WP_THREAD;
const otherTurnId = process.env.WP_OTHER_TURN;
console.log(JSON.stringify({
  ok: true,
  generatedAt: "2026-08-30T00:00:00.000Z",
  targetThreadId:
    mode === "after-target-id-mismatch" && count > 1 ? otherTurnId : threadId,
  config: {
    exists: true,
    sha256: "a".repeat(64),
    keys: {},
    stableDuringRead: mode !== "unstable-before" || count > 1,
  },
  db: {
    exists: true,
    readOnlyOpenOk: true,
    sha256: "b".repeat(64),
    stableDuringRead: true,
    quickCheck: "ok",
    threads: {
      target: {
        exists: true,
        id: threadId,
        archived:
          (mode === "archived-before" && count === 1) ||
          (mode === "after-archived" && count > 1)
            ? 1
            : 0,
        rolloutPath:
          mode === "missing-path-before" && count === 1
            ? null
            : mode === "after-rollover" && count > 1
              ? `${rolloutPath}.next`
              : rolloutPath,
      },
      threadRowHashById: {
        [threadId]: count === 1 ? "before" : "after",
        ...(mode === "uppercase-allowlist"
          ? { [otherTurnId]: count === 1 ? "other-before" : "other-after" }
          : {}),
      },
    },
    marker: { dbBinaryCount: 0, textSha256: "c".repeat(64) },
  },
}));
EOF

  cat > "$scripts/codex_ipc_client.mjs" <<'EOF'
import fs from "node:fs";
const countPath = process.env.WP_SEND_COUNT;
const count = (fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, "utf8")) : 0) + 1;
fs.writeFileSync(countPath, String(count));
const mode = process.env.WP_RESPONSE_MODE;
const threadId = process.env.WP_THREAD;
const turnId = process.env.WP_TURN;
const otherTurnId = process.env.WP_OTHER_TURN;
const marker = process.env.WP_MARKER;
const rolloutPath = process.env.WP_ROLLOUT;
let result;
if ([
  "nested",
  "duplicate-follower",
  "extra-target-follower",
  "after-snapshot-error",
  "after-archived",
  "after-rollover",
  "after-target-id-mismatch",
  "uppercase-allowlist",
  "uppercase-test-authorization",
  "wrong-top-level-target",
  "error-response-result",
].includes(mode)) {
  result = { result: { turn: { id: turnId } } };
}
else if (mode === "one-level") result = { turn: { id: turnId } };
else if (mode === "turn-id") result = { turnId };
else if (mode === "duplicate") {
  result = { result: { turn: { id: turnId.toUpperCase() } }, turn: { id: turnId } };
} else if (mode === "conflict") {
  result = { result: { turn: { id: turnId } }, turn: { id: otherTurnId } };
} else if (mode === "invalid-carrier") {
  result = { result: { turn: { id: turnId } }, turnId: "not-a-uuid" };
} else result = {};

if ([
  "nested",
  "one-level",
  "turn-id",
  "duplicate",
  "after-snapshot-error",
  "after-archived",
  "after-rollover",
  "after-target-id-mismatch",
  "uppercase-allowlist",
  "uppercase-test-authorization",
  "wrong-top-level-target",
  "error-response-result",
].includes(mode)) {
  const finalBody = `${marker} ACK`;
  const records = [
    { type: "event_msg", payload: { type: "task_started", thread_id: threadId, turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", thread_id: threadId, turn_id: turnId, message: `CONTROLLED IPC WRITE PROOF ${marker}` } },
    { type: "event_msg", payload: { type: "agent_message", thread_id: threadId, turn_id: turnId, phase: "final_answer", message: finalBody } },
    { type: "event_msg", payload: { type: "task_complete", thread_id: threadId, turn_id: turnId, last_agent_message: finalBody } },
  ];
  fs.appendFileSync(rolloutPath, records.map((item) => JSON.stringify(item)).join("\n") + "\n");
}

if (mode === "transport-unknown") {
  console.error("offline stub: follower response transport failed after invocation");
  process.exit(1);
}

const clientOk = mode !== "nonzero-structured";
const sentRequests = [
  { name: "initialize", bytes: 1, json: { method: "initialize" } },
  { name: "thread-follower-start-turn", bytes: 1, json: { method: "thread-follower-start-turn", params: { conversationId: threadId } } },
];
if (mode === "duplicate-follower") {
  sentRequests.push({
    name: "thread-follower-start-turn",
    bytes: 1,
    json: { method: "thread-follower-start-turn", params: { conversationId: threadId } },
  });
}
if (mode === "extra-target-follower") {
  sentRequests.push({
    name: "thread-follower-start-turn",
    bytes: 1,
    json: { method: "thread-follower-start-turn", params: { conversationId: process.env.WP_OTHER_TURN } },
  });
}

console.log(JSON.stringify({
  ok: clientOk,
  pipePath: "offline-stub",
  targetThreadId: mode === "wrong-top-level-target" ? otherTurnId : threadId,
  sentRequests,
  initialize: { resultType: "success", result: { clientId: "stub-client" } },
  response: {
    resultType: mode === "error-response-result" ? "error" : clientOk ? "success" : "error",
    ...(mode === "error-response-result" ? { error: "no-client-found" } : {}),
    handledByClientId: "stub-client",
    result,
  },
}));
if (!clientOk) process.exitCode = 1;
EOF
}

wp_live_run(){  # $1=case dir  $2=response mode  $3=rollout variant (optional)
  local case_dir="$1" mode="$2" variant="${3:-valid}" home="$1/home" marker="CODEX_IPC_TEST_${2}_MARKER"
  local authorized_thread=""
  local -a authorization_args=(--allow-any-thread)
  local -a extra_args=()
  if [[ "$mode" == "uppercase-test-authorization" ]]; then
    authorized_thread="${THREAD^^}"
    authorization_args=()
  fi
  if [[ "$mode" == "uppercase-allowlist" ]]; then
    extra_args=(--allow-thread-change "${OTHER_THREAD^^}")
  fi
  wp_live_setup "$case_dir" "$variant"
  WPOUT="$(
    WP_THREAD="$THREAD" WP_TURN="$WP_TURN" WP_OTHER_TURN="$WP_OTHER_TURN" \
    WP_MARKER="$marker" WP_ROLLOUT="$WP_LIVE_ROLLOUT" \
    WP_SEND_COUNT="$WP_LIVE_SEND_COUNT" WP_SNAPSHOT_COUNT="$WP_LIVE_SNAPSHOT_COUNT" \
    WP_RESPONSE_MODE="$mode" CODEX_IPC_AUTHORIZED_TEST_THREAD="$authorized_thread" \
    USERPROFILE="$home" HOME="$home" \
      "$NODE_BIN" "$case_dir/scripts/codex_ipc_write_proof.mjs" \
        --thread "$THREAD" --marker "$marker" \
        --task "CONTROLLED IPC WRITE PROOF $marker" \
        --send --ack-live-write "${authorization_args[@]}" "${extra_args[@]}" \
        --timeout-ms 100 --poll-ms 100 --poll-attempts 5 2>"$WP_LIVE_STDERR"
  )"
  WPRC=$?
}

wp_sent_once(){ [[ "$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null)" == "1" ]]; }
wp_sent_zero(){ [[ ! -e "$WP_LIVE_SEND_COUNT" ]] || [[ "$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null)" == "0" ]]; }
wp_live_debug(){ printf '%s\n' "$WPOUT" | sed -n '1,80p'; }

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

  WPOUT="$(USERPROFILE="$TMP/wp-closed" HOME="$TMP/wp-closed" "$NODE_BIN" "$WRITE_PROOF" \
    --thread "${THREAD^^}" 2>/dev/null)"; WPRC=$?
  if [[ $WPRC -eq 0 ]] && wp_field 'v.ok===true && v.threadId==="11111111-1111-4111-8111-111111111111"'; then
    ok "write-proof canonicalizes uppercase target UUID before every pre-send authority check"
  else
    no "write-proof uppercase target lost canonical authority (rc=$WPRC)"
  fi

  echo "== 21a. write-proof rejects an inspector result without trusted DB authority before send =="
  wp_live_run "$TMP/wp-live-untrusted-inspection" untrusted-inspection
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_zero \
    && wp_field 'v.ok===false && v.failures.some(f=>f.includes("state DB authority"))'; then
    ok "untrusted inspector DB metadata fails closed with zero send attempts"
  else
    no "untrusted inspector DB metadata reached or obscured the send boundary (rc=$WPRC)"
    wp_live_debug
  fi

  echo "== 21a2. write-proof consumes the inspector's structured negative exit contract =="
  wp_live_run "$TMP/wp-live-structured-negative" structured-negative-inspection
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_zero \
    && [[ ! -s "$WP_LIVE_STDERR" ]] \
    && wp_field 'v.ok===false && !("send" in v) && v.failures.includes("inspector result was not ok") && v.failures.some(f=>f.includes("state DB authority")) && v.failures.some(f=>f.includes("not found"))'; then
    ok "valid inspector ok:false plus exit 1 remains a structured pre-send failure without a stack"
  else
    no "structured inspector negative escaped the write-proof contract (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
    sed -n '1,40p' "$WP_LIVE_STDERR" 2>/dev/null || true
  fi

  echo "== 21a3. write-proof canonicalizes an uppercase non-target-change allowlist =="
  wp_live_run "$TMP/wp-live-uppercase-allowlist" uppercase-allowlist
  if [[ $WPRC -eq 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===true && v.compare.db.allowedNonTargetChangedIds.length===1 && v.compare.db.allowedNonTargetChangedIds[0]==="22222222-2222-4222-8222-222222222222" && v.compare.db.unexpectedNonTargetChangedIds.length===0'; then
    ok "uppercase --allow-thread-change authorizes only its canonical thread identity"
  else
    no "uppercase write-proof allowlist lost canonical identity (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21a4. write-proof canonicalizes the configured test-thread authorization =="
  wp_live_run "$TMP/wp-live-uppercase-test-auth" uppercase-test-authorization
  if [[ $WPRC -eq 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===true && v.threadId==="11111111-1111-4111-8111-111111111111" && v.send.occurrence==="confirmed"'; then
    ok "uppercase CODEX_IPC_AUTHORIZED_TEST_THREAD authorizes its canonical target without --allow-any-thread"
  else
    no "uppercase configured test-thread authorization was not canonicalized (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21a5. write-proof rejects a successful shell whose top-level target is inconsistent =="
  wp_live_run "$TMP/wp-live-wrong-top-level-target" wrong-top-level-target
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===false && v.send.occurrence==="confirmed" && v.send.responseType==="success" && v.send.followerRequestCount===1 && v.send.matchingFollowerRequestCount===1 && v.send.error.includes("targetThreadId") && v.send.turnIdResolution.status==="resolved" && v.send.verificationStatus==="sent-but-unverified" && v.send.retrySafe===false && v.rolloutProbe.attempts===0'; then
    ok "a mismatched top-level target preserves the send but blocks polling and certification"
  else
    no "a mismatched top-level target was certified or lost send evidence (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21a6. write-proof rejects top-level ok when the response resultType is error =="
  wp_live_run "$TMP/wp-live-error-response-result" error-response-result
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===false && v.send.occurrence==="confirmed" && v.send.responseType==="error" && v.send.responseError==="no-client-found" && v.send.error.includes("resultType") && v.send.turnIdResolution.status==="resolved" && v.send.verificationStatus==="sent-but-unverified" && v.send.retrySafe===false && v.rolloutProbe.attempts===0'; then
    ok "an error response with a plausible turn carrier preserves the send, surfaces the router error token, and cannot trigger polling"
  else
    no "an error response was certified or lost send evidence (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21b. write-proof live branch: maintained nested response binds the strict poll =="
  wp_live_run "$TMP/wp-live-nested" nested
  if [[ $WPRC -eq 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===true && v.before.targetThread.rolloutPath.endsWith("_00000000-0000-4000-8000-00000000c0de.jsonl") && v.send.turnId==="00000000-0000-4000-8000-000000000000" && v.send.turnIdResolution.status==="resolved" && v.send.verificationStatus==="turn-bound" && v.rolloutProbe.ok===true && v.rolloutProbe.lastObservation.expectedTurnId===v.send.turnId && v.rolloutProbe.lastObservation.proofTurnId===v.send.turnId'; then
    ok "paginated DB path plus nested result.result.turn.id drive one strict same-turn proof"
  else
    no "nested send response was not strictly turn-bound (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  for shape in one-level turn-id duplicate; do
    echo "== 21c. write-proof live branch: $shape compatibility remains turn-bound =="
    wp_live_run "$TMP/wp-live-$shape" "$shape"
    if [[ $WPRC -eq 0 ]] \
      && wp_sent_once \
      && wp_field 'v.ok===true && v.send.turnId==="00000000-0000-4000-8000-000000000000" && v.rolloutProbe.ok===true && v.rolloutProbe.lastObservation.proofTurnId===v.send.turnId'; then
      ok "$shape response compatibility still drives the strict poll"
    else
      no "$shape response compatibility failed (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
      wp_live_debug
    fi
  done

  echo "== 21d. write-proof live branch: missing turn id is sent-but-unverified after one send =="
  wp_live_run "$TMP/wp-live-missing" missing
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===true && v.send.turnId===null && v.send.turnIdResolution.status==="missing" && v.send.turnIdResolution.candidateCount===0 && v.send.verificationStatus==="sent-but-unverified" && v.rolloutProbe.attempts===0 && v.rolloutProbe.diagnostics.some(d=>d.includes("sent-but-unverified"))'; then
    ok "missing response turn id fails closed while explicitly preserving send occurrence"
  else
    no "missing turn id did not fail as sent-but-unverified (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21e. write-proof live branch: conflicting turn ids are sent-but-unverified after one send =="
  wp_live_run "$TMP/wp-live-conflict" conflict
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===true && v.send.turnId===null && v.send.turnIdResolution.status==="conflict" && v.send.turnIdResolution.candidateCount===2 && v.send.verificationStatus==="sent-but-unverified" && v.rolloutProbe.attempts===0 && v.rolloutProbe.diagnostics.some(d=>d.includes("sent-but-unverified"))'; then
    ok "conflicting valid response turn ids fail closed without hiding the send"
  else
    no "conflicting turn ids did not fail as sent-but-unverified (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21e2. write-proof rejects a valid turn id paired with a malformed recognized carrier =="
  wp_live_run "$TMP/wp-live-invalid-carrier" invalid-carrier
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===true && v.send.turnId===null && v.send.turnIdResolution.status==="invalid" && v.send.turnIdResolution.candidateCount===1 && v.send.turnIdResolution.invalidCandidateCount===1 && v.send.verificationStatus==="sent-but-unverified" && v.rolloutProbe.attempts===0'; then
    ok "malformed recognized turn-id carrier blocks polling and preserves the one-send outcome"
  else
    no "mixed valid/malformed turn-id carriers did not fail closed (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21f. write-proof preserves a confirmed send when the client exits nonzero =="
  wp_live_run "$TMP/wp-live-nonzero" nonzero-structured
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===false && v.send.occurrence==="confirmed" && v.send.commandStatus===1 && v.send.verificationStatus==="sent-but-unverified" && v.rolloutProbe.attempts===0 && v.rolloutProbe.diagnostics.some(d=>d.includes("sent-but-unverified")) && v.warnings.some(w=>w.includes("cannot be safely retried"))'; then
    ok "nonzero structured client result retains confirmed-send evidence and blocks polling/retry"
  else
    no "nonzero structured client result hid or misclassified send occurrence (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21g. write-proof exposes an unknown send outcome when the client emits no JSON =="
  wp_live_run "$TMP/wp-live-unknown" transport-unknown
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.ok===false && v.send.occurrence==="unknown" && v.send.commandStatus===1 && v.send.verificationStatus==="send-outcome-unknown" && v.rolloutProbe.attempts===0 && v.rolloutProbe.diagnostics.some(d=>d.includes("send-outcome-unknown")) && v.warnings.some(w=>w.includes("cannot be safely retried"))'; then
    ok "unparseable client failure remains explicit as send-outcome-unknown with zero polling"
  else
    no "unparseable client failure did not preserve uncertainty (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  for cardinality_mode in duplicate-follower extra-target-follower; do
    echo "== 21h. write-proof rejects $cardinality_mode evidence after one client invocation =="
    wp_live_run "$TMP/wp-live-$cardinality_mode" "$cardinality_mode"
    if [[ $WPRC -ne 0 ]] \
      && wp_sent_once \
      && wp_field 'v.ok===false && v.send.ok===false && v.send.occurrence==="confirmed" && v.send.followerRequestCount===2 && v.send.verificationStatus==="sent-but-unverified" && v.send.retrySafe===false && v.rolloutProbe.attempts===0 && v.warnings.some(w=>w.includes("cannot be safely retried"))'; then
      ok "$cardinality_mode cannot certify an exact-one target send"
    else
      no "$cardinality_mode was not rejected conservatively (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
      wp_live_debug
    fi
  done

  for fresh_mode in archived-before unstable-before missing-path-before; do
    echo "== 21i. write-proof fresh target gate: $fresh_mode sends zero times =="
    wp_live_run "$TMP/wp-live-$fresh_mode" "$fresh_mode"
    if [[ $WPRC -ne 0 ]] \
      && wp_sent_zero \
      && wp_field 'v.ok===false && !("send" in v) && v.preSendState.ok===false && v.failures.some(f=>f.includes("fresh pre-send snapshot"))'; then
      ok "$fresh_mode fails at the latest trustworthy pre-send state"
    else
      no "$fresh_mode did not stop before send (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
      wp_live_debug
    fi
  done

  echo "== 21j. write-proof preserves send occurrence when the after snapshot throws =="
  wp_live_run "$TMP/wp-live-after-snapshot-error" after-snapshot-error
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_once \
    && wp_field 'v.ok===false && v.send.occurrence==="confirmed" && v.send.verificationStatus==="sent-but-unverified" && v.send.retrySafe===false && v.rolloutProbe.ok===true && v.after===null && v.compare.ok===false && v.postSendFailures.some(f=>f.stage==="after-snapshot") && v.warnings.some(w=>w.includes("cannot be safely retried"))'; then
    ok "post-send snapshot failure remains structured and explicitly non-retryable"
  else
    no "post-send snapshot failure escaped structured evidence (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  for after_state in after-archived after-rollover after-target-id-mismatch; do
    echo "== 21k. write-proof refuses $after_state as completed isolation proof =="
    wp_live_run "$TMP/wp-live-$after_state" "$after_state"
    if [[ $WPRC -ne 0 ]] \
      && wp_sent_once \
      && wp_field 'v.ok===false && v.send.occurrence==="confirmed" && v.send.verificationStatus==="sent-but-unverified" && v.send.retrySafe===false && v.rolloutProbe.ok===true && v.after!==null && v.compare.ok===false && v.postSendFailures.length===0 && v.warnings.some(w=>w.includes("cannot be safely retried"))'; then
      ok "$after_state cannot be mistaken for a stable proof"
    else
      no "$after_state was not rejected by the isolation compare (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
      wp_live_debug
    fi
  done

  echo "== 21l. write-proof final pre-send check rejects rollout growth with zero sends =="
  wp_live_run "$TMP/wp-live-rollout-growth" rollout-growth-before-send
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_zero \
    && wp_field 'v.ok===false && !("send" in v) && v.finalRolloutCheck.unchanged===false && v.failures.some(f=>f.includes("rollout baseline changed"))'; then
    ok "rollout growth during the fresh snapshot is detected before the client"
  else
    no "rollout growth crossed the final pre-send gate (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  echo "== 21l2. write-proof final pre-send check rejects same-size prefix rewrites with zero sends =="
  wp_live_run "$TMP/wp-live-rollout-same-size" rollout-same-size-before-send
  if [[ $WPRC -ne 0 ]] \
    && wp_sent_zero \
    && wp_field 'v.ok===false && !("send" in v) && v.authorizationStage==="baseline-revalidation" && v.finalRolloutCheck.unchanged===false && v.failures.some(f=>f.includes("fully revalidated"))'; then
    ok "same-size rollout rewrite is detected by full prefix revalidation before the client"
  else
    no "same-size rollout rewrite crossed the final pre-send gate (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
    wp_live_debug
  fi

  for invalid_rollout in wrong-root bad-page bad-metadata; do
    echo "== 21m. write-proof pre-send: $invalid_rollout paginated authority sends zero times =="
    wp_live_run "$TMP/wp-live-$invalid_rollout" nested "$invalid_rollout"
    if [[ $WPRC -ne 0 ]] \
      && wp_sent_zero \
      && wp_field 'v.ok===false && !("send" in v) && v.rolloutBinding.status==="unavailable" && v.rolloutBinding.reason==="identity-mismatch" && v.failures.some(f=>f.includes("before send"))'; then
      ok "$invalid_rollout paginated authority fails before the injected client"
    else
      no "$invalid_rollout paginated authority did not stop before send (rc=$WPRC, sends=$(cat "$WP_LIVE_SEND_COUNT" 2>/dev/null))"
      wp_live_debug
    fi
  done
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

echo "== 23b. wrapper thread identity must match the pinned rollout owner =="
CASE="$TMP/ta-wrapper-owner"; mkdir -p "$CASE/sessions"
write_wrong_thread_wrapper "$CASE/sessions/rollout-wrapper-owner-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-wrapper-owner-$THREAD.jsonl"
assert_turn_activity ambiguous "wrong-thread completed wrapper fails closed in the pre-send inspector"

echo "== 23c. repeated session metadata cannot rebind an open turn =="
CASE="$TMP/ta-owner-rebound"; mkdir -p "$CASE/sessions"
write_rebound_owner "$CASE/sessions/rollout-owner-rebound-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-rebound-$THREAD.jsonl"
assert_turn_activity ambiguous "conflicting in-turn session metadata fails closed in the pre-send inspector"

echo "== 23c2. provenance-linked ancestor metadata is inert and cannot rebind the owner =="
CASE="$TMP/ta-owner-lineage"; mkdir -p "$CASE/sessions"
write_lineaged_owner "$CASE/sessions/rollout-owner-lineage-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-lineage-$THREAD.jsonl"
assert_turn_activity closed "linked inherited session metadata preserves current-owner activity"

echo "== 23c3. a fork without a producer history boundary cannot authorize child activity =="
CASE="$TMP/ta-owner-lineage-missing"; mkdir -p "$CASE/sessions"
write_lineaged_owner_without_boundary "$CASE/sessions/rollout-owner-lineage-missing-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-lineage-missing-$THREAD.jsonl"
assert_turn_activity ambiguous "boundary-less fork history fails closed instead of guessing ownership"

echo "== 23c4. copied fork tail cannot project ancestor activity or replace child metadata =="
CASE="$TMP/ta-owner-lineage-boundary"; mkdir -p "$CASE/sessions"
write_lineaged_owner_boundary_only "$CASE/sessions/rollout-owner-lineage-boundary-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-lineage-boundary-$THREAD.jsonl"
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | "$NODE_BIN" -e '
  const v=JSON.parse(require("node:fs").readFileSync(0,"utf8"));
  const s=v.activitySignals;
  const expectNull=[
    "lastTaskCompleteLine", "lastTurnAbortedLine", "lastTerminalLine",
    "lastTerminalType", "lastUserMessageLine", "lastAgentMessageLine",
  ];
  for (const key of expectNull) {
    if (s[key] !== null) throw new Error(`${key}=${s[key]} inherited from copied history`);
  }
  if (s.newestRolloutLine !== 7 || s.newestRolloutType !== "thread_settings_applied") {
    throw new Error(`newest admitted item=${s.newestRolloutLine}/${s.newestRolloutType}`);
  }
  if (s.terminalState !== "none") throw new Error(`terminalState=${s.terminalState}`);
  if (s.hasTaskCompleteInTail || s.hasTurnAbortedInTail || s.hasTerminalInTail || s.maybeMidTurn) {
    throw new Error("copied history leaked into boolean activity projections");
  }
  if (s.turnActivity !== "ambiguous") throw new Error(`turnActivity=${s.turnActivity}`);
  if (v.rollout.primary.sessionMeta?.line !== 1) {
    throw new Error(`sessionMeta line=${v.rollout.primary.sessionMeta?.line}; child root metadata was replaced`);
  }
  if (!v.rollout.primary.recentItems.some((item) => item.line === 6 && item.payloadType === "task_complete")) {
    throw new Error("fixture no longer proves display-tail separation from admitted projections");
  }
' >/dev/null 2>&1; then
  ok "copied ancestor tail remains display-only while every activity projection and owner metadata stay child-local"
else
  no "copied ancestor tail leaked into activity projections or replaced child metadata (rc=$RC)"
fi
SUMMARY_OUT="$("$NODE_BIN" "$INSPECT" \
  --db "$CASE/state.sqlite" \
  --sessions-root "$CASE/sessions" \
  --thread "$THREAD" \
  --tail-events 20 \
  --summary 2>/dev/null)"
SUMMARY_RC=$?
if [[ $SUMMARY_RC -eq 0 ]] && printf '%s' "$SUMMARY_OUT" | "$NODE_BIN" -e '
  const v=JSON.parse(require("node:fs").readFileSync(0,"utf8"));
  const s=v.activitySignals;
  if (s.lastTaskCompleteLine !== null || s.terminalState !== "none") {
    throw new Error("summary inherited ancestor completion");
  }
  if (s.lastUserMessageLine !== null || s.lastAgentMessageLine !== null || s.maybeMidTurn) {
    throw new Error("summary inherited ancestor activity");
  }
  if (s.turnActivity !== "ambiguous") throw new Error(`turnActivity=${s.turnActivity}`);
' >/dev/null 2>&1; then
  ok "the bounded --summary projection also excludes every copied ancestor activity signal"
else
  no "the bounded --summary projection retained copied ancestor activity (rc=$SUMMARY_RC)"
fi

echo "== 23d. a pre-turn owner conflict poisons later completed activity =="
CASE="$TMP/ta-owner-global"; mkdir -p "$CASE/sessions"
write_rebound_owner_before_turn "$CASE/sessions/rollout-owner-global-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-global-$THREAD.jsonl"
assert_turn_activity ambiguous "file-global owner conflict fails closed before a later turn"

echo "== 23e. invalid session metadata poisons later completed activity =="
CASE="$TMP/ta-owner-invalid"; mkdir -p "$CASE/sessions"
write_invalid_owner_before_turn "$CASE/sessions/rollout-owner-invalid-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-invalid-$THREAD.jsonl"
assert_turn_activity ambiguous "invalid file-global owner metadata fails closed before a later turn"

echo "== 23f. missing session ownership cannot certify completed activity =="
CASE="$TMP/ta-owner-missing"; mkdir -p "$CASE/sessions"
write_ownerless_closed "$CASE/sessions/rollout-owner-missing-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-owner-missing-$THREAD.jsonl"
assert_turn_activity ambiguous "missing file-global owner metadata fails closed"

echo "== 23g. direct event thread identity must match the inspected target =="
CASE="$TMP/ta-direct-owner"; mkdir -p "$CASE/sessions"
write_wrong_thread_direct "$CASE/sessions/rollout-direct-owner-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-direct-owner-$THREAD.jsonl"
assert_turn_activity ambiguous "wrong-thread direct records fail closed in the pre-send inspector"

echo "== 23h. malformed direct thread identity after a terminal is file-global =="
CASE="$TMP/ta-direct-owner-invalid"; mkdir -p "$CASE/sessions"
write_malformed_thread_direct_after_terminal "$CASE/sessions/rollout-direct-owner-invalid-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-direct-owner-invalid-$THREAD.jsonl"
assert_turn_activity ambiguous "malformed post-terminal direct thread identity fails closed"

echo "== 23i. malformed nested thread identity after a terminal is file-global =="
CASE="$TMP/ta-nested-owner-invalid"; mkdir -p "$CASE/sessions"
write_malformed_thread_nested_after_terminal "$CASE/sessions/rollout-nested-owner-invalid-$THREAD.jsonl"
run_turn_activity_case "$CASE/sessions/rollout-nested-owner-invalid-$THREAD.jsonl"
assert_turn_activity ambiguous "malformed post-terminal nested thread identity fails closed"

echo "== 23j. DB-authoritative exact-suffix rollout requires session_meta as its first record =="
CASE="$TMP/db-first-record"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
DB_ROLLOUT="$CASE/sessions/a/rollout-db-first-record-$THREAD.jsonl"
cat > "$DB_ROLLOUT" <<EOF
{"type":"event_msg","payload":{"type":"token_count","info":{"total":1}}}
{"type":"session_meta","payload":{"id":"$THREAD"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-a","message":"sanitized task"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","last_agent_message":"done"}}
EOF
write_closed_same_turn "$CASE/sessions/b/rollout-valid-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$DB_ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case invalid-db-identity "later matching metadata cannot rescue a DB rollout with a non-session_meta first record"

echo "== 23k. sessions-root matching rejects UUID-containing filename decoys =="
CASE="$TMP/suffix-decoy"; mkdir -p "$CASE/sessions"
write_closed_same_turn "$CASE/sessions/rollout-$THREAD-decoy.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case suffix-decoy "a target-named filename outside the certified grammar keeps root discovery unresolved"

echo "== 23l. a DB rollout path with the wrong filename is rejected without fallback =="
CASE="$TMP/db-wrong-filename"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
DB_ROLLOUT="$CASE/sessions/a/arbitrary-db-path.jsonl"
write_closed_same_turn "$DB_ROLLOUT"
write_closed_same_turn "$CASE/sessions/b/rollout-valid-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$DB_ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case invalid-db-identity "matching first metadata cannot authorize an arbitrary DB rollout filename or fallback"

echo "== 23m. a nonempty DB rollout_path naming a directory is unavailable without fallback =="
CASE="$TMP/db-directory"; mkdir -p "$CASE/sessions" "$CASE/db-rollout-dir"
write_closed_same_turn "$CASE/sessions/rollout-valid-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$CASE/db-rollout-dir"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case unusable-db-authority "an existing directory in DB rollout_path blocks sessions-root fallback"

echo "== 23n. a nonempty missing DB rollout_path is unavailable without fallback =="
CASE="$TMP/db-missing"; mkdir -p "$CASE/sessions"
write_closed_same_turn "$CASE/sessions/rollout-valid-$THREAD.jsonl"
make_db "$CASE/state.sqlite" "$CASE/missing/rollout-missing-$THREAD.jsonl"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case unusable-db-authority "a missing DB rollout_path blocks sessions-root fallback"

echo "== 23o. a valid DB-designated paginated rollout remains owner-bound and readable =="
CASE="$TMP/db-paginated"; mkdir -p "$CASE/sessions"
DB_ROLLOUT="$CASE/sessions/rollout-db-page-${THREAD}_${PAGE}.jsonl"
write_paginated_closed "$DB_ROLLOUT"
make_db "$CASE/state.sqlite" "$DB_ROLLOUT"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case paginated-db-authority "DB-designated root_page rollout is selected and reports closed activity"

echo "== 23p. sessions-root discovery recognizes one valid paginated rollout =="
CASE="$TMP/discovered-paginated"; mkdir -p "$CASE/sessions"
write_paginated_closed "$CASE/sessions/rollout-page-${THREAD}_${PAGE}.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case single-candidate "one discovered root_page rollout is selected and parsed"

echo "== 23q. multiple discovered paginated pages remain ambiguous =="
CASE="$TMP/ambiguous-paginated"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
write_paginated_closed "$CASE/sessions/a/rollout-a-${THREAD}_${PAGE}.jsonl"
write_paginated_closed "$CASE/sessions/b/rollout-b-${THREAD}_${HISTORY_BASE}.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case ambiguous-candidates "multiple physical root_page rollouts fail closed without mtime selection"

echo "== 23r. a valid root candidate plus an identity-invalid sibling remains unresolved =="
CASE="$TMP/unresolved-candidate-set"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
write_closed_same_turn "$CASE/sessions/a/rollout-old-${THREAD}.jsonl"
write_paginated_closed "$CASE/sessions/b/rollout-new-${THREAD}_${PAGE}.jsonl" "$OTHER_THREAD"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case unresolved-candidate-set "root discovery cannot certify an older valid rollout while a target-named sibling is identity-invalid"

echo "== 23s. a trailing UUID cannot hide target-named filename schema drift =="
CASE="$TMP/unresolved-trailing-uuid"; mkdir -p "$CASE/sessions/a" "$CASE/sessions/b"
write_closed_same_turn "$CASE/sessions/a/rollout-old-${THREAD}.jsonl"
write_closed_same_turn "$CASE/sessions/b/rollout-new-${THREAD}-v2-${OTHER_THREAD}.jsonl"
make_db "$CASE/state.sqlite"
run_inspect "$CASE/state.sqlite" "$CASE/sessions"
assert_case unresolved-candidate-set "inspector root discovery cannot silently reinterpret target-named drift as another legacy root"

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
# this ref's inspector byte for byte as an explicit compatibility guard for downstream consumers
# and stored fixtures. The maintained handoff wrapper now parses structural JSON and is not
# coupled to pretty-print whitespace, so this guard must not be read as a transport prerequisite.
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
    printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$THREAD\",\"cwd\":\"C:/dev/some-project\",\"instructions\":\"$(printf 'a%.0s' $(seq 1 400))\"}}"
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
{"type":"session_meta","payload":{"id":"$THREAD"}}
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
cat > "$O3/malformed/sessions/a/rollout-bad-$THREAD.jsonl" <<EOF
{"type":"session_meta","payload":{"id":"$THREAD"}}
{malformed
EOF
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
  # The malformed fixture is intentionally outside this historical byte-identity comparison:
  # the current owner-integrity repair corrects parsedOk from true to false when a valid first
  # session_meta is followed by malformed JSON. AC5 below proves that corrected projection.
  for fixture in basic outoftail ambig12; do
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
