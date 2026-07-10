#!/usr/bin/env bash
# R3 ROUTER-CONTRACT SENTINEL (hermetic; no live IPC)
#
# SENTINELED:
# - Real-client dry-run emits initialize then thread-follower-start-turn with the exact
#   observable request keys, method names, version, target, text input, and UUID ids.
# - Dry-run byte totals equal UTF-8 JSON bytes plus the four-byte frame overhead.
# - Wrapper process-result classification covers acceptance, no-client-found, and
#   malformed/unknown failures using stubbed client, observer, and inspector processes.
#
# EXCLUDED:
# - Raw four-byte frame header contents/endianness (dry-run exposes only total bytes).
# - The client's live response-body resultType/clientId classifier (not injectable via
#   dry-run without modifying the read-only client).
# - Named-pipe I/O, live owner state, GUI delivery/focus, rollout mutation, reply-file
#   completion, sandbox behavior, and any end-to-end Desktop claim.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT="$ROOT/skills/ipc/scripts/codex_ipc_client.mjs"
WRAPPER="$ROOT/skills/ipc/scripts/handoff_to_codex.sh"
NODE_BIN="$(command -v node 2>/dev/null || true)"

if [[ -z "$NODE_BIN" ]]; then
  echo "SKIP: node is unavailable; router-contract sentinel not applicable"
  exit 0
fi
if [[ ! -f "$CLIENT" || ! -f "$WRAPPER" ]]; then
  echo "SKIP: client or wrapper is absent; router-contract sentinel not applicable"
  exit 0
fi

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
  case "follower":
    assert(keys(follower) === "bytes,json,name", "follower envelope keys drifted");
    assert(
      keys(follower.json) === "method,params,requestId,sourceClientId,type,version",
      "follower request keys drifted",
    );
    assert(follower.json.type === "request", "follower type mismatch");
    assert(follower.json.method === "thread-follower-start-turn", "follower method mismatch");
    assert(follower.json.version === 1, "follower version mismatch");
    assert(isUuid(follower.json.requestId), "follower requestId is not a UUID");
    assert(follower.json.requestId !== initialize.json.requestId, "requestIds must be distinct");
    assert(follower.json.sourceClientId === "<client-id-from-initialize>", "source client placeholder drifted");
    assert(keys(follower.json.params) === "conversationId,turnStartParams", "follower params keys drifted");
    assert(follower.json.params.conversationId === expectedThread, "conversationId mismatch");
    assert(keys(follower.json.params.turnStartParams) === "input", "turnStartParams keys drifted");
    assert(follower.json.params.turnStartParams.input.length === 1, "input count mismatch");
    const input = follower.json.params.turnStartParams.input[0];
    assert(keys(input) === "text,text_elements,type", "text input keys drifted");
    assert(input.type === "text" && input.text === expectedTask, "text input mismatch");
    assert(Array.isArray(input.text_elements) && input.text_elements.length === 0, "text_elements mismatch");
    break;
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

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
TOOL_LOG="$TMP/tool.log"
NODE_STUB="$STUB_BIN/node"
cat > "$NODE_STUB" <<'EOF'
#!/usr/bin/env bash
name="${1##*/}"
case "$name" in
  codex_ipc_client.mjs)
    case "${ROUTER_CASE:-}" in
      acceptance) printf '%s\n' '{"ok":true,"resultType":"success"}'; exit 0 ;;
      no-client) printf '%s\n' '{"ok":false,"error":"no-client-found"}'; exit 1 ;;
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
    printf '%s\n' '{"ok": false, "dbThread":{"thread":{"exists":false}}}'
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
  local scenario="$1" expected_rc="$2" expected_result="$3" label="$4"
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
    bash "$WRAPPER" --ipc "$THREAD" "$TASK_TEXT" 2>&1)"
  rc=$?
  if [[ $rc -eq $expected_rc ]] && printf '%s\n' "$output" | grep -Fqx "$expected_result"; then
    ok "$label"
  else
    no "$label (rc=$rc)"
    printf '%s\n' "$output" | sed -n '1,30p'
  fi
}

echo "== 2. wrapper process-result classification =="
run_wrapper_case acceptance 0 \
  "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=rollout-hit" \
  "successful client process is classified as renderer-owned acceptance"
run_wrapper_case no-client 1 \
  "RESULT: failed-closed -- reason=target-not-found -- confirmation=not-attempted" \
  "no-client-found reaches guarded ownership handling"
run_wrapper_case unknown 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=not-attempted" \
  "unknown client failure is not misclassified as no-client-found"
run_wrapper_case malformed 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=not-attempted" \
  "malformed client failure fails closed as router-pipe-failure"

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
