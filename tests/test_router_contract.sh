#!/usr/bin/env bash
# R3 ROUTER-CONTRACT SENTINEL (hermetic; no live IPC)
#
# SENTINELED:
# - Real-client dry-run emits initialize then thread-follower-start-turn with the exact
#   observable request keys, method names, the protocol version DERIVED FROM
#   tests/fixtures/codex_desktop_method_versions.json, the absence of a frame-level hostId,
#   target, text input, and UUID ids.
# - The checked-in method table fails closed on drift: editing it to the pre-repair value makes
#   the follower assertion fail, so this file asserts the app's contract instead of pinning a
#   constant the app no longer accepts.
# - Dry-run byte totals equal UTF-8 JSON bytes plus the four-byte frame overhead.
# - The real client's pure live-response projection preserves the follower request on a
#   non-success router response without opening a pipe.
# - Wrapper process-result classification covers acceptance, no-client-found, and
#   malformed/unknown failures using stubbed client, observer, and inspector processes.
#
# EXCLUDED:
# - Raw four-byte frame header contents/endianness (dry-run exposes only total bytes).
# - Named-pipe I/O, live owner state, GUI delivery/focus, rollout mutation, reply-file
#   completion, sandbox behavior, and any end-to-end Desktop claim.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout
# (tests/ inside the skill root, scripts/ as sibling).
CLIENT=""
WRAPPER=""
for _scripts in "$ROOT/skills/ipc/scripts" "$ROOT/scripts"; do
    if [[ -f "$_scripts/codex_ipc_client.mjs" && -f "$_scripts/handoff_to_codex.sh" ]]; then
        CLIENT="$_scripts/codex_ipc_client.mjs"
        WRAPPER="$_scripts/handoff_to_codex.sh"
        break
    fi
done
NODE_BIN="$(command -v node 2>/dev/null || true)"

if [[ -z "$NODE_BIN" ]]; then
  echo "SKIP: node is unavailable; router-contract sentinel not applicable"
  exit 0
fi
if [[ -z "$CLIENT" || -z "$WRAPPER" ]]; then
  echo "SKIP: client or wrapper is absent; router-contract sentinel not applicable"
  exit 0
fi
# The wire contract is asserted against a checked-in copy of the app's own method-version table,
# derived read-only from the installed Codex Desktop bundle at a recorded build. Without it there
# is nothing to assert against, and pinning a literal version is exactly the failure this file
# now exists to prevent.
METHOD_TABLE="$SCRIPT_DIR/fixtures/codex_desktop_method_versions.json"
if [[ ! -f "$METHOD_TABLE" ]]; then
  echo "SKIP: checked-in method table is absent; router-contract sentinel not applicable"
  exit 0
fi
export CODEX_IPC_METHOD_TABLE="$METHOD_TABLE"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
THREAD="22222222-2222-4222-8222-222222222222"
TASK_TEXT="router contract sentinel"
CLIENT_TYPE="router-contract-sentinel"
PASS=0
FAIL=0

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

ASSERT_JSON="$TMP/assert-json.mjs"
cat > "$ASSERT_JSON" <<'EOF'
import fs from "node:fs";
let raw = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) raw += chunk;
const value = JSON.parse(raw);
const mode = process.argv[2];
const expectedThread = process.argv[3];
const expectedTask = process.argv[4];
const expectedClientType = process.argv[5];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function keys(value) {
  return Object.keys(value).sort().join(",");
}
function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

assert(value.ok === true && value.dryRun === true, "expected successful dry-run");
assert(value.targetThreadId === expectedThread, "dry-run target mismatch");
assert(value.authorizedTestThreadId === null, "unexpected test authorization");
assert(value.liveWriteWouldBeAllowedWithSend === false, "dry-run unexpectedly authorizes send");
assert(Array.isArray(value.requests) && value.requests.length === 2, "expected exactly two requests");

const initialize = value.requests[0];
const follower = value.requests[1];
switch (mode) {
  case "top":
    assert(initialize.name === "initialize", "initialize must be first");
    assert(follower.name === "thread-follower-start-turn", "follower request must be second");
    break;
  case "initialize":
    assert(keys(initialize) === "bytes,json,name", "initialize envelope keys drifted");
    assert(keys(initialize.json) === "method,params,requestId,type", "initialize request keys drifted");
    assert(initialize.json.type === "request", "initialize type mismatch");
    assert(initialize.json.method === "initialize", "initialize method mismatch");
    assert(isUuid(initialize.json.requestId), "initialize requestId is not a UUID");
    assert(keys(initialize.json.params) === "clientType", "initialize params keys drifted");
    assert(initialize.json.params.clientType === expectedClientType, "client type mismatch");
    break;
  case "follower": {
    // The expectation is read from the checked-in table, never written here: a literal version in
    // this file is what let the client keep sending a shape the app had stopped accepting.
    const tablePath = process.env.CODEX_IPC_METHOD_TABLE;
    assert(Boolean(tablePath), "CODEX_IPC_METHOD_TABLE must point at the checked-in method table");
    const table = JSON.parse(fs.readFileSync(tablePath, "utf8"));
    const expectedVersion = table.methodVersions["thread-follower-start-turn"];
    assert(Number.isInteger(expectedVersion), "method table has no thread-follower-start-turn entry");
    assert(table.frame.payloadKey === "turnStart", "method table payload key drifted");
    assert(table.frame.hostIdMustBeAbsent === true, "method table hostId rule drifted");

    assert(keys(follower) === "bytes,json,name", "follower envelope keys drifted");
    assert(
      keys(follower.json) === "method,params,requestId,sourceClientId,type,version",
      "follower request keys drifted",
    );
    // A frame-level hostId raises the app's required version for every thread-follower-* method,
    // so the key must be absent - not null.
    assert(!("hostId" in follower.json), "follower frame must not carry hostId");
    assert(follower.json.type === "request", "follower type mismatch");
    assert(follower.json.method === "thread-follower-start-turn", "follower method mismatch");
    assert(
      follower.json.version === expectedVersion,
      "follower version does not match the checked-in table",
    );
    assert(isUuid(follower.json.requestId), "follower requestId is not a UUID");
    assert(follower.json.requestId !== initialize.json.requestId, "requestIds must be distinct");
    assert(follower.json.sourceClientId === "<client-id-from-initialize>", "source client placeholder drifted");
    assert(
      keys(follower.json.params) === `conversationId,${table.frame.payloadKey}`,
      "follower params keys drifted",
    );
    assert(follower.json.params.conversationId === expectedThread, "conversationId mismatch");
    const turnStart = follower.json.params[table.frame.payloadKey];
    assert(keys(turnStart) === "request", "turnStart keys drifted (context must be omitted)");
    const request = turnStart.request;
    assert(keys(request) === "input,threadId,turnTrigger", "turnStart.request keys drifted");
    assert(
      request.threadId === follower.json.params.conversationId,
      "request.threadId must equal conversationId",
    );
    assert(
      typeof request.turnTrigger === "string" && request.turnTrigger.length > 0,
      "turnTrigger missing",
    );
    assert(Array.isArray(request.input) && request.input.length === 1, "input count mismatch");
    const input = request.input[0];
    assert(keys(input) === "text,text_elements,type", "text input keys drifted");
    assert(input.type === "text" && input.text === expectedTask, "text input mismatch");
    assert(Array.isArray(input.text_elements) && input.text_elements.length === 0, "text_elements mismatch");
    break;
  }
  case "framing":
    for (const request of value.requests) {
      assert(request.bytes === 4 + Buffer.byteLength(JSON.stringify(request.json)), `${request.name} byte total drifted`);
    }
    break;
  default:
    throw new Error(`unknown assertion mode: ${mode}`);
}
EOF

echo "== 1. real-client dry-run request contract =="
DRY_ERR="$TMP/dry.stderr"
DRY_OUT="$("$NODE_BIN" "$CLIENT" --thread "$THREAD" --task "$TASK_TEXT" --client-type "$CLIENT_TYPE" 2>"$DRY_ERR")"
DRY_RC=$?
assert_dry(){
  local mode="$1" label="$2"
  if [[ $DRY_RC -eq 0 ]] && printf '%s' "$DRY_OUT" | "$NODE_BIN" "$ASSERT_JSON" "$mode" "$THREAD" "$TASK_TEXT" "$CLIENT_TYPE" >/dev/null 2>&1; then
    ok "$label"
  else
    no "$label (rc=$DRY_RC)"
    sed -n '1,20p' "$DRY_ERR"
  fi
}
assert_dry top "dry-run is inert and emits the ordered request pair"
assert_dry initialize "initialize request shape is exact"
assert_dry follower "thread-follower-start-turn request shape is exact"
assert_dry framing "observable frame totals include exactly four overhead bytes"

CANONICAL_CASE_THREAD="00000000-0000-4000-8000-00000000c0de"
UPPER_THREAD="${CANONICAL_CASE_THREAD^^}"
UPPER_OUT="$("$NODE_BIN" "$CLIENT" --thread "$UPPER_THREAD" --task "$TASK_TEXT" --client-type "$CLIENT_TYPE" 2>/dev/null)"
if printf '%s' "$UPPER_OUT" | "$NODE_BIN" "$ASSERT_JSON" follower "$CANONICAL_CASE_THREAD" "$TASK_TEXT" "$CLIENT_TYPE" >/dev/null 2>&1; then
  ok "case-insensitive UUID input is emitted as one canonical lowercase target"
else
  no "uppercase UUID input was not canonicalized before request construction"
fi

AUTHORIZED_OUT="$(CODEX_IPC_AUTHORIZED_TEST_THREAD="$UPPER_THREAD" \
  "$NODE_BIN" "$CLIENT" --thread "$CANONICAL_CASE_THREAD" --task "$TASK_TEXT" 2>/dev/null)"
if printf '%s' "$AUTHORIZED_OUT" | "$NODE_BIN" -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
process.exit(value.dryRun === true && value.authorizedTestThreadId === process.argv[1] &&
  value.targetThreadId === process.argv[1] && value.liveWriteWouldBeAllowedWithSend === true ? 0 : 1);
' "$CANONICAL_CASE_THREAD" >/dev/null 2>&1; then
  ok "uppercase authorized-test UUID is canonicalized to the same dry-run target identity"
else
  no "uppercase authorized-test UUID did not preserve thread-scoped authorization equivalence"
fi

if CLIENT="$CLIENT" THREAD="$THREAD" "$NODE_BIN" --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { projectLiveResponse } = await import(pathToFileURL(process.env.CLIENT));
const threadId = process.env.THREAD;
const initializeRequest = { type: "request", method: "initialize", requestId: "init" };
const initialize = { resultType: "success", result: { clientId: "offline-client" } };
const followerRequest = {
  type: "request",
  method: "thread-follower-start-turn",
  requestId: "follow",
  params: { conversationId: threadId },
};
const response = { resultType: "error", error: "offline rejection" };
const result = projectLiveResponse(
  { pipePath: "offline", threadId },
  initializeRequest,
  initialize,
  followerRequest,
  response,
);
assert.equal(result.ok, false);
assert.equal(result.targetThreadId, threadId);
assert.equal(result.sentRequests.length, 2);
assert.equal(result.sentRequests[1].name, "thread-follower-start-turn");
assert.equal(result.sentRequests[1].json.method, "thread-follower-start-turn");
assert.equal(result.sentRequests[1].json.params.conversationId, threadId);
assert.equal(result.response, response);
NODE
then
  ok "real-client non-success projection retains exact follower-send occurrence"
else
  no "real-client non-success projection lost follower-send occurrence"
fi

echo "== 2. the checked-in method table is provenanced and fails closed on drift =="
if "$NODE_BIN" -e '
const fs = require("node:fs");
const table = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const ok =
  typeof table.build === "string" && table.build.length > 0 &&
  typeof table.package === "string" && table.package.includes(table.build) &&
  /^[0-9a-f]{64}$/.test(table.asar?.sha256 ?? "") &&
  Number.isInteger(table.asar?.size) &&
  Array.isArray(table.members) && table.members.length >= 2 &&
  table.members.every((m) => /^[0-9a-f]{64}$/.test(m.sha256 ?? "") && typeof m.path === "string");
process.exit(ok ? 0 : 1);
' "$METHOD_TABLE" >/dev/null 2>&1; then
  ok "method table names the build it was derived from with archive and member digests"
else
  no "method table lacks the build/digest provenance that makes it re-derivable"
fi

drift_case(){
  # $1 = label, $2 = node expression mutating the parsed table object `o`
  local label="$1" mutation="$2"
  local drift="$TMP/method-table-drift-$RANDOM.json"
  "$NODE_BIN" -e '
const fs = require("node:fs");
const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
(new Function("o", process.argv[3]))(o);
fs.writeFileSync(process.argv[2], JSON.stringify(o, null, 2));
' "$METHOD_TABLE" "$drift" "$mutation"
  if printf '%s' "$DRY_OUT" \
    | CODEX_IPC_METHOD_TABLE="$drift" "$NODE_BIN" "$ASSERT_JSON" follower "$THREAD" "$TASK_TEXT" "$CLIENT_TYPE" \
      >/dev/null 2>&1; then
    no "$label (the sentinel pins the client instead of asserting the app's table)"
  else
    ok "$label"
  fi
}
drift_case "a table pinned to the pre-repair version 1 makes the follower assertion fail" \
  'o.methodVersions["thread-follower-start-turn"] = 1;'
drift_case "a table pinned to the pre-repair payload key turnStartParams makes it fail" \
  'o.frame.payloadKey = "turnStartParams";'

echo "== 3. wrapper process-result classification =="
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
TOOL_LOG="$TMP/tool.log"
NODE_STUB="$STUB_BIN/node"
cat > "$NODE_STUB" <<'EOF'
#!/usr/bin/env bash
name="${1##*/}"
case "$name" in
  codex_ipc_client.mjs)
    target=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--thread" ]]; then target="$argument"; break; fi
      previous="$argument"
    done
    case "${ROUTER_CASE:-}" in
      acceptance|acceptance-uppercase)
        printf '{"ok":true,"targetThreadId":"%s","sentRequests":[{"name":"thread-follower-start-turn","json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}}],"response":{"resultType":"success"}}\n' "$target" "$target"
        exit 0
        ;;
      malformed-success) printf '%s\n' '{"ok":true,"resultType":"success"}'; exit 0 ;;
      no-client|no-client-orphan|no-client-archived|no-client-invalid-archive|no-client-db-unavailable|no-client-warning)
        printf '{"ok":false,"targetThreadId":"%s","sentRequests":[{"name":"thread-follower-start-turn","json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}}],"response":{"resultType":"error","error":"no-client-found"}}\n' "$target" "$target"
        exit 1
        ;;
      nested-poison)
        printf '{"ok":false,"targetThreadId":"%s","sentRequests":[{"json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}},{"json":{"method":"other","error":"no-client-found"}}],"response":{"resultType":"error","error":"router-contract-changed","nested":{"error":"no-client-found"}}}\n' "$target" "$target"
        exit 1
        ;;
      unknown) printf '%s\n' '{"ok":false,"error":"router-contract-changed"}'; exit 1 ;;
      malformed) printf '%s\n' '{malformed'; exit 1 ;;
      *) printf '%s\n' '{"ok":false,"error":"missing-router-case"}'; exit 1 ;;
    esac
    ;;
  codex_ipc_rollout_observe.mjs)
    printf '%s\n' 'rollout-hit'
    exit 0
    ;;
  codex_ipc_session_inspect.mjs)
    target=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--thread" ]]; then target="$argument"; break; fi
      previous="$argument"
    done
    case "${ROUTER_CASE:-}" in
      no-client)
        printf '%s\n' '{"ok":false,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":false}}}'
        exit 1
        ;;
      no-client-orphan)
        printf '%s\n' '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":false}},"rollout":{"primary":{"parsedOk":true}}}'
        exit 0
        ;;
      no-client-archived)
        printf '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":true,"id":"%s","archived":1}}}\n' "$target"
        ;;
      no-client-invalid-archive)
        printf '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":true,"id":"%s","archived":null}}}\n' "$target"
        ;;
      no-client-db-unavailable)
        printf '%s\n' '{"ok":true,"dbThread":{"exists":false,"readOnlyOpenOk":false,"thread":{"exists":false}},"rollout":{"primary":{"parsedOk":true}}}'
        ;;
      no-client-warning)
        printf '%s\n' 'ExperimentalWarning: synthetic node:sqlite warning' >&2
        printf '%s\n' '{"ok":false,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":false}}}'
        exit 1
        ;;
      *) printf '%s\n' '{"ok":false,"dbThread":{"thread":{"exists":false}}}' ;;
    esac
    exit 0
    ;;
  *) exec "$REAL_NODE" "$@" ;;
esac
EOF
cat > "$STUB_BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf 'powershell.exe invoked\n' >> "$TOOL_LOG"
exit 99
EOF
cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex invoked\n' >> "$TOOL_LOG"
exit 99
EOF
chmod +x "$NODE_STUB" "$STUB_BIN/powershell.exe" "$STUB_BIN/codex"

run_wrapper_case(){
  # $5 (optional): text that MUST NOT appear in the wrapper's combined output.
  local scenario="$1" expected_rc="$2" expected_result="$3" label="$4" forbidden="${5:-}" target="${6:-$THREAD}"
  local case_root="$TMP/$scenario" output rc
  mkdir -p "$case_root/ipc" "$case_root/home"
  output="$(env \
    PATH="$STUB_BIN:$PATH" \
    REAL_NODE="$NODE_BIN" \
    ROUTER_CASE="$scenario" \
    TOOL_LOG="$TOOL_LOG" \
    HOME="$case_root/home" \
    CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" \
    CODEX_IPC_ROOT="$case_root/ipc" \
    CODEX_IPC_RETENTION_DAYS=0 \
    bash "$WRAPPER" --ipc "$target" "$TASK_TEXT" 2>&1)"
  rc=$?
  if [[ $rc -eq $expected_rc ]] && printf '%s\n' "$output" | grep -Fqx "$expected_result"; then
    if [[ -n "$forbidden" ]] && printf '%s\n' "$output" | grep -Fq "$forbidden"; then
      no "$label (forbidden text present: $forbidden)"
      printf '%s\n' "$output" | sed -n '1,30p'
    else
      ok "$label"
    fi
  else
    no "$label (rc=$rc)"
    printf '%s\n' "$output" | sed -n '1,30p'
  fi
}

run_wrapper_case acceptance 0 \
  "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=rollout-hit" \
  "successful client process is classified as renderer-owned acceptance"
run_wrapper_case acceptance-uppercase 0 \
  "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=rollout-hit" \
  "wrapper accepts uppercase UUID spelling and canonicalizes it before transport" \
  "$UPPER_THREAD" "$UPPER_THREAD"
run_wrapper_case malformed-success 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "exit-zero client output without exact follower proof is not called delivered" \
  "FALLBACK -- file-drop is ready"
run_wrapper_case no-client 1 \
  "RESULT: failed-closed -- reason=target-not-found -- confirmation=not-attempted" \
  "no-client-found reaches guarded ownership handling"
run_wrapper_case no-client-orphan 1 \
  "RESULT: failed-closed -- reason=target-inspection-ambiguous -- confirmation=not-attempted" \
  "parseable orphan without a trusted DB row fails ambiguous without autoload"
run_wrapper_case no-client-archived 1 \
  "RESULT: failed-closed -- reason=target-archived -- confirmation=not-attempted" \
  "exact archived DB state blocks autoload"
run_wrapper_case no-client-invalid-archive 1 \
  "RESULT: failed-closed -- reason=target-inspection-ambiguous -- confirmation=not-attempted" \
  "noncanonical archive state fails closed as ambiguous"
run_wrapper_case no-client-db-unavailable 1 \
  "RESULT: failed-closed -- reason=target-inspection-ambiguous -- confirmation=not-attempted" \
  "DB read failure cannot be misreported as authoritative target absence"
run_wrapper_case no-client-warning 1 \
  "RESULT: failed-closed -- reason=target-not-found -- confirmation=not-attempted" \
  "inspector stderr warnings cannot corrupt valid structural stdout"
# router-pipe-failure is POST-ATTEMPT: the client writes the follower frame before it
# awaits the response, so a timeout, closed pipe or protocol drift can each leave the
# task already admitted. The wrapper cannot distinguish "failed before the write" from
# "failed after it", so the honest classification is `unknown`, never `not-attempted`.
# Reporting not-attempted here is what invited a duplicate dispatch.
run_wrapper_case unknown 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "unknown client failure is not misclassified as no-client-found" \
  "FALLBACK -- file-drop is ready"
run_wrapper_case nested-poison 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "nested no-client text cannot authorize autoload or retry" \
  "FALLBACK -- file-drop is ready"
run_wrapper_case malformed 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "malformed client failure fails closed as router-pipe-failure" \
  "FALLBACK -- file-drop is ready"

if [[ ! -s "$TOOL_LOG" ]]; then
  ok "sentinel invoked no Desktop, PowerShell, or Codex transport helper"
else
  no "unexpected external helper invocation"
  cat "$TOOL_LOG"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
