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
# - Runtime CLI entry guards preserve direct execution through owned path aliases,
#   reject usage/resolution failures, and keep ordinary/eval/stdin imports inert.
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
#
# A missing table is a repository defect, NOT an inapplicable environment, so it must fail hard.
# The two skips above are platform-conditional: node or the scripts are genuinely absent and no
# assertion is possible anywhere. The table is different. It is checked in, it is covered by no
# release manifest and by no other test, and nothing else in the repository would notice its
# absence - so skipping on it would silently convert this whole suite into a green no-op the one
# time someone deletes or mistypes the path.
METHOD_TABLE="$SCRIPT_DIR/fixtures/codex_desktop_method_versions.json"
if [[ ! -f "$METHOD_TABLE" ]]; then
  echo "FAIL: the checked-in method table is missing at tests/fixtures/codex_desktop_method_versions.json" >&2
  echo "  This sentinel derives its expectation from that file. Without it the suite would exit" >&2
  echo "  green while asserting nothing about the wire contract. Restore or re-derive the table." >&2
  exit 1
fi
export CODEX_IPC_METHOD_TABLE="$METHOD_TABLE"

TMP="$(mktemp -d)" && [[ -n "$TMP" && -d "$TMP" ]] \
    || { echo "FATAL: could not create router-contract temporary directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
THREAD="22222222-2222-4222-8222-222222222222"
TASK_TEXT="router contract sentinel"
CLIENT_TYPE="router-contract-sentinel"
PASS=0
FAIL=0

ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
fatal(){ echo "FATAL: $*" >&2; exit 1; }

# Wrapper-side Git probes must not inherit tracing, redirecting, or repository-selection
# variables from the caller. In particular, GIT_TRACE* can write outside this fixture.
while IFS= read -r _git_var; do
  [[ "${_git_var^^}" == GIT_* ]] && unset "$_git_var"
done < <(compgen -e)
for _git_var in $(compgen -e); do
  [[ "${_git_var^^}" != GIT_* ]] || fatal "could not clear inherited Git variable $_git_var"
done
unset _git_var
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_ATTR_NOSYSTEM=1 GIT_PAGER=cat GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0

# CLI_GUARD_BEGIN: real processes and owned aliases only; no host state or IPC.
if CLI_GUARD_SCRIPTS="$(dirname "$CLIENT")" \
  "$NODE_BIN" --input-type=module <<'CLI_GUARD_NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
const source = fs.realpathSync(process.env.CLI_GUARD_SCRIPTS);
const tempParent = fs.realpathSync(os.tmpdir());
const owned = fs.mkdtempSync(path.join(tempParent, "ipc-guard-"));
const scripts = path.join(owned, "owned scripts");
const alias = path.join(owned, "alias scripts");
let aliasCreated = false;
let failed = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: CLI guard ${name}`); }
  catch (error) { failed++; console.error(`FAIL: CLI guard ${name}: ${error.message}`); }
}
try {
  fs.mkdirSync(scripts);
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".mjs")) {
      fs.copyFileSync(path.join(source, entry.name), path.join(scripts, entry.name));
    }
  }
  fs.symlinkSync(scripts, alias, process.platform === "win32" ? "junction" : "dir");
  aliasCreated = true;
  assert.equal(fs.realpathSync(alias), fs.realpathSync(scripts));
  const home = path.join(owned, "home");
  fs.mkdirSync(home);
  const env = { ...process.env, NODE_OPTIONS: "", NODE_NO_WARNINGS: "1",
    HOME: home, USERPROFILE: home, CODEX_HOME: path.join(home, ".codex"),
    CODEX_IPC_ROOT: path.join(home, "transport"),
    CODEX_IPC_SESSIONS_ROOT: path.join(home, "sessions") };
  const importer = path.join(owned, "ordinary import.mjs");
  const importBody = 'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.env.CLI_GUARD_TARGET).href + (process.env.CLI_GUARD_SUFFIX || ""));';
  fs.writeFileSync(importer, importBody);
  const preload = path.join(owned, "realpath failure.cjs");
  fs.writeFileSync(preload, `
const fs = require("node:fs");
const { fileURLToPath } = require("node:url");
const { syncBuiltinESMExports } = require("node:module");
const original = fs.realpathSync.native;
fs.realpathSync.native = function (value, ...rest) {
  if (value instanceof URL && fileURLToPath(value) === process.env.CLI_GUARD_TARGET) {
    fs.appendFileSync(process.env.CLI_GUARD_FAULT_HIT, "hit\\n");
    throw Object.assign(new Error("synthetic entry resolution failure"), { code: "EACCES" });
  }
  return original(value, ...rest);
};
syncBuiltinESMExports();
`);
  for (const name of [
    "codex_ipc_client.mjs", "codex_ipc_queue.mjs", "codex_ipc_reply_harvest.mjs",
    "codex_ipc_rollout_observe.mjs", "codex_ipc_wait.mjs", "codex_ipc_write_proof.mjs",
  ]) {
    const target = path.join(scripts, name);
    const aliased = path.join(alias, name);
    assert.ok(fs.existsSync(target), `copied module missing: ${name}`);
    const run = (args, input, extra = {}) => {
      const result = spawnSync(process.execPath, args, { cwd: owned,
        env: { ...env, CLI_GUARD_TARGET: target, ...extra }, input,
        encoding: "utf8", timeout: 10000, windowsHide: true });
      assert.ifError(result.error);
      assert.equal(result.signal, null, "child was terminated");
      return result;
    };
    const quiet = (result) => {
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, "", "import ran the CLI");
      assert.equal(result.stderr, "", "import emitted a diagnostic");
    };
    const usageError = (result) => {
      assert.notEqual(result.status, 0, "invalid option exited successfully");
      assert.equal(result.stdout, "", "usage error emitted a success result");
      assert.match(result.stderr, /--guard-invalid-option/, "CLI did not diagnose the option");
    };
    for (const [label, entry, prefix] of [
      ["physical", target, []], ["alias with spaces", aliased, []],
      ["title=-e", aliased, ["--title=-e"]], ["title=--eval", aliased, ["--title=--eval"]],
      ["V8 -expose-gc", aliased, ["-expose-gc"]],
      ["print without expression", aliased, ["-p", "--"]],
      ["print followed by option", aliased, ["--print", "--title=x"]],
    ]) {
      check(`${name}: ${label} rejects invalid option`, () =>
        usageError(run([...prefix, entry, "--guard-invalid-option"])));
    }
    if (["codex_ipc_client.mjs", "codex_ipc_queue.mjs", "codex_ipc_write_proof.mjs"].includes(name)) {
      check(`${name}: alias help executes`, () => {
        const result = run([aliased, "--help"]);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /usage:/i);
      });
    }
    for (const arg of [undefined, path.join(owned, "nonexistent.mjs"), target]) {
      const trailing = arg === undefined ? [] : [arg];
      const label = arg === undefined ? "absent" : arg === target ? "module path" : "nonexistent";
      check(`${name}: ordinary import with ${label} argument is silent`, () =>
        quiet(run([importer, ...trailing])));
      check(`${name}: eval import with ${label} argv is silent`, () =>
        quiet(run(["--input-type=module", "-e", importBody, ...trailing])));
      check(`${name}: stdin import with ${label} trailing argument is silent`, () =>
        quiet(run(["--input-type=module", "-", ...trailing], importBody)));
    }
    check(`${name}: implicit stdin import without entry argv is silent`, () =>
      quiet(run(["--input-type=module"], importBody)));
    for (const suffix of ["?import-only", "#import-only"]) {
      check(`${name}: ordinary import ${suffix} is silent`, () =>
        quiet(run([importer], undefined, { CLI_GUARD_SUFFIX: suffix })));
    }
    check(`${name}: realpath failure cannot report successful empty CLI`, () => {
      const hit = path.join(owned, name + ".fault");
      const result = run(["--require", preload, target, "--guard-invalid-option"], undefined,
        { CLI_GUARD_FAULT_HIT: hit });
      assert.ok(fs.existsSync(hit), "resolution failure was not injected");
      assert.notEqual(result.status, 0, "resolution failure exited successfully");
      assert.equal(result.stdout, "", "resolution failure emitted a success result");
      assert.equal(result.stderr, name === "codex_ipc_wait.mjs" ?
        'ERROR {"code":"entrypoint-resolution-failed"}\n' :
        "ERROR: entrypoint-resolution-failed\n", "resolution failure had the wrong diagnostic");
    });
  }
  assert.deepEqual(fs.readdirSync(home), [], "guard checks wrote into isolated host state");
} catch (error) {
  failed++;
  console.error(`FAIL: CLI guard fixture: ${error.stack}`);
} finally {
  // Only this mkdtemp tree is owned. Unlink its verified alias before recursive cleanup.
  assert.equal(path.dirname(fs.realpathSync(owned)), tempParent);
  assert.match(path.basename(owned), /^ipc-guard-/);
  if (aliasCreated) {
    assert.equal(fs.realpathSync(alias), fs.realpathSync(scripts));
    fs.unlinkSync(alias);
  }
  fs.rmSync(owned, { recursive: true, force: true });
}
process.exitCode = failed ? 1 : 0;
CLI_GUARD_NODE
then
  ok "CLI entry guards preserve direct execution and inert imports"
else
  no "CLI entry-guard regressions"
fi
# CLI_GUARD_END

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

settings_reject(){ # settings_reject <label> <expected-fragment> [client args...]
  local label="$1" expected="$2" out err rc
  shift 2
  err="$TMP/settings-reject-$RANDOM.err"
  out="$("$NODE_BIN" "$CLIENT" --thread "$THREAD" --task "$TASK_TEXT" "$@" 2>"$err")"
  rc=$?
  if [[ $rc -ne 0 && -z "$out" ]] && grep -qF -- "$expected" "$err"; then
    ok "$label"
  else
    no "$label (rc=$rc, stdout=${out:-<empty>})"
    sed -n '1,8p' "$err"
  fi
}

settings_accept(){ # settings_accept <label> <model|null> <effort|null> [client args...]
  local label="$1" expected_model="$2" expected_effort="$3" out err rc
  shift 3
  err="$TMP/settings-accept-$RANDOM.err"
  out="$("$NODE_BIN" "$CLIENT" --thread "$THREAD" --task "$TASK_TEXT" "$@" 2>"$err")"
  rc=$?
  if [[ $rc -eq 0 ]] && printf '%s' "$out" | "$NODE_BIN" -e '
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(0, "utf8"));
const request = value?.requests?.[1]?.json?.params?.turnStart?.request;
const wantModel = process.argv[1] === "null" ? undefined : process.argv[1];
const wantEffort = process.argv[2] === "null" ? undefined : process.argv[2];
const ok = request && request.model === wantModel && request.effort === wantEffort;
process.exit(ok ? 0 : 1);
' "$expected_model" "$expected_effort" >/dev/null 2>&1; then
    ok "$label"
  else
    no "$label (rc=$rc)"
    sed -n '1,8p' "$err"
  fi
}

echo "== 1b. stored thread-setting rewrites require their own explicit acknowledgement =="
settings_reject "model override without settings acknowledgement is rejected" \
  "--ack-thread-settings-change" --model synthetic-model
settings_reject "effort override without settings acknowledgement is rejected" \
  "--ack-thread-settings-change" --effort high
settings_reject "combined overrides without settings acknowledgement are rejected" \
  "--ack-thread-settings-change" --model synthetic-model --effort high
settings_reject "live-write acknowledgement does not acknowledge stored setting rewrites" \
  "--ack-thread-settings-change" --model synthetic-model --ack-live-write
settings_reject "acknowledged whitespace-only model is rejected" \
  "--model must provide non-empty text" --model $' \t' --ack-thread-settings-change
settings_reject "acknowledged whitespace-only effort is rejected" \
  "--effort must provide non-empty text" --effort $' \t' --ack-thread-settings-change
settings_accept "acknowledged model override is retained exactly" synthetic-model null \
  --model '  synthetic-model  ' --ack-thread-settings-change
settings_accept "acknowledged effort override is retained exactly" null high \
  --effort '  high  ' --ack-thread-settings-change
settings_accept "acknowledged combined overrides are retained exactly" synthetic-model high \
  --model synthetic-model --effort high --ack-thread-settings-change
settings_accept "settings acknowledgement alone preserves omission of both fields" null null \
  --ack-thread-settings-change

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

# A demonstration that scores any non-zero exit as a caught drift cannot tell a catch from a
# crash: pointing the table at a nonexistent path also exits non-zero, from ENOENT inside
# readFileSync, and would be reported as "drift caught" while proving nothing. So each case
# asserts that the mutated table was actually written, and that the failure carries the specific
# assertion message this sentinel exists to produce. The vacuity_case below is the control that
# keeps those two checks honest.
drift_case(){
  # $1 = label, $2 = node expression mutating the parsed table object `o`, $3 = expected message
  local label="$1" mutation="$2" expected="$3"
  local drift="$TMP/method-table-drift-$RANDOM.json"
  local errlog="$TMP/method-table-drift-$RANDOM.err"
  "$NODE_BIN" -e '
const fs = require("node:fs");
const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
(new Function("o", process.argv[3]))(o);
fs.writeFileSync(process.argv[2], JSON.stringify(o, null, 2));
' "$METHOD_TABLE" "$drift" "$mutation"
  if [[ ! -s "$drift" ]]; then
    no "$label (the mutated table was never written, so nothing was demonstrated)"
    return
  fi
  if printf '%s' "$DRY_OUT" \
    | CODEX_IPC_METHOD_TABLE="$drift" "$NODE_BIN" "$ASSERT_JSON" follower "$THREAD" "$TASK_TEXT" "$CLIENT_TYPE" \
      >/dev/null 2>"$errlog"; then
    no "$label (the sentinel pins the client instead of asserting the app's table)"
  elif ! grep -qF "$expected" "$errlog"; then
    no "$label (failed for the wrong reason: $(grep -m1 -oE 'Error: .*' "$errlog" | cut -c1-120))"
  else
    ok "$label"
  fi
}
drift_case "a table pinned to the pre-repair version 1 makes the follower assertion fail" \
  'o.methodVersions["thread-follower-start-turn"] = 1;' \
  "follower version does not match the checked-in table"
drift_case "a table pinned to the pre-repair payload key turnStartParams makes it fail" \
  'o.frame.payloadKey = "turnStartParams";' \
  "method table payload key drifted"

# Control for the two cases above: an unreadable table must NOT look like a caught drift.
vacuity_case(){
  local missing="$TMP/method-table-absent-$RANDOM.json"
  local errlog="$TMP/method-table-absent-$RANDOM.err"
  rm -f "$missing"
  if printf '%s' "$DRY_OUT" \
    | CODEX_IPC_METHOD_TABLE="$missing" "$NODE_BIN" "$ASSERT_JSON" follower "$THREAD" "$TASK_TEXT" "$CLIENT_TYPE" \
      >/dev/null 2>"$errlog"; then
    no "an unreadable method table is not silently treated as a passing contract"
  elif grep -qF "follower version does not match the checked-in table" "$errlog"; then
    no "an unreadable method table is misreported as a caught version drift"
  else
    ok "an unreadable method table fails distinguishably from a caught drift"
  fi
}
vacuity_case

echo "== 3. wrapper process-result classification =="
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN" || fatal "could not create router-contract stub directory"
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
      routerless-host|routerless-unversioned|router-malformed-expectation|router-expected-host)
        printf 'client invoked: %s\n' "$ROUTER_CASE" >> "$TOOL_LOG.client"
        printf '{"ok":true,"targetThreadId":"%s","sentRequests":[{"name":"thread-follower-start-turn","json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}}],"response":{"resultType":"success"}}\n' "$target" "$target"
        exit 0
        ;;
      no-client|no-client-orphan|no-client-archived|no-client-invalid-archive|no-client-db-unavailable|no-client-warning)
        printf '{"ok":false,"targetThreadId":"%s","sentRequests":[{"name":"thread-follower-start-turn","json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}}],"response":{"resultType":"error","error":"no-client-found"}}\n' "$target" "$target"
        exit 1
        ;;
      nested-poison)
        printf '{"ok":false,"targetThreadId":"%s","sentRequests":[{"json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}},{"json":{"method":"other","error":"no-client-found"}}],"response":{"resultType":"error","error":"router-contract-changed","nested":{"error":"no-client-found"}}}\n' "$target" "$target"
        exit 1
        ;;
      router-absent)
        printf '{"ok":false,"phase":"connect","targetThreadId":"%s","sentRequests":[],"connectError":{"code":"ENOENT","message":"the router pipe is not present"}}\n' "$target"
        exit 1
        ;;
      router-unreachable)
        printf '{"ok":false,"phase":"connect","targetThreadId":"%s","sentRequests":[],"connectError":{"code":"EACCES","message":"access denied"}}\n' "$target"
        exit 1
        ;;
      connect-claim-with-request)
        printf '{"ok":false,"phase":"connect","targetThreadId":"%s","sentRequests":[{"name":"thread-follower-start-turn","json":{"method":"thread-follower-start-turn","params":{"conversationId":"%s"}}}],"connectError":{"code":"ENOENT","message":"x"}}\n' "$target" "$target"
        exit 1
        ;;
      connect-claim-other-target)
        printf '{"ok":false,"phase":"connect","targetThreadId":"%s","sentRequests":[],"connectError":{"code":"ENOENT","message":"x"}}\n' "00000000-0000-4000-8000-000000000000"
        exit 1
        ;;
      unknown) printf '%s\n' '{"ok":false,"error":"router-contract-changed"}'; exit 1 ;;
      malformed) printf '%s\n' '{malformed'; exit 1 ;;
      queue-*)
        # --deliver queue never runs the router client; this records it if it ever does.
        printf 'client invoked: %s\n' "$ROUTER_CASE" >> "$TOOL_LOG.client"
        printf '%s\n' '{"ok":false,"error":"queue-case-client"}'; exit 1 ;;
      *) printf '%s\n' '{"ok":false,"error":"missing-router-case"}'; exit 1 ;;
    esac
    ;;
  codex_ipc_queue.mjs)
    if [[ "${ROUTER_CASE:-}" == "queue-helper-garbage" ]]; then
      printf '%s\n' 'not a helper document'; exit 1
    fi
    exec "$REAL_NODE" "$@"
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
        printf '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":true,"id":"%s","archived":1,"model":"synthetic-model","threadSource":"user"}},"targetClassification":{"kind":"root","parentThreadId":null,"reasons":["thread-source-root"],"warnings":[]}}\n' "$target"
        ;;
      no-client-invalid-archive)
        printf '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":true,"id":"%s","archived":null,"model":"synthetic-model","threadSource":"user"}},"targetClassification":{"kind":"root","parentThreadId":null,"reasons":["thread-source-root"],"warnings":[]}}\n' "$target"
        ;;
      no-client-db-unavailable)
        printf '%s\n' '{"ok":true,"dbThread":{"exists":false,"readOnlyOpenOk":false,"thread":{"exists":false}},"rollout":{"primary":{"parsedOk":true}}}'
        ;;
      no-client-warning)
        printf '%s\n' 'ExperimentalWarning: synthetic node:sqlite warning' >&2
        printf '%s\n' '{"ok":false,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":false}}}'
        exit 1
        ;;
      *)
        printf '{"ok":true,"dbThread":{"exists":true,"readOnlyOpenOk":true,"thread":{"exists":true,"id":"%s","archived":0,"model":"synthetic-model","threadSource":"user"}},"targetClassification":{"kind":"root","parentThreadId":null,"reasons":["thread-source-root"],"warnings":[]}}\n' "$target"
        ;;
    esac
    exit 0
    ;;
  *) exec "$REAL_NODE" "$@" ;;
esac
EOF
[[ $? -eq 0 ]] || fatal "could not materialize router-contract node stub"
POLICY_LOG="$TMP/router-policy.log"
: > "$POLICY_LOG"
cat > "$STUB_BIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
script=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-File" ]]; then script="${argument//\\//}"; break; fi
  previous="$argument"
done
if [[ "${script##*/}" == "codex_ipc_host_policy.ps1" ]]; then
  printf '%s\n' "$*" >> "$POLICY_LOG"
  case "${ROUTER_CASE:-}" in
    routerless-host) echo '{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"codex-uri","source":"environment"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":["not-checked"],"intendedHostVersion":"26.1117.4957.0","routerExpected":false}' ;;
    routerless-unversioned) echo '{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"codex-uri","source":"environment"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":["not-checked"],"intendedHostVersion":null,"routerExpected":false}' ;;
    router-malformed-expectation) echo '{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"codex-uri","source":"environment"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":["not-checked"],"intendedHostVersion":"26.1117.4957.0","routerExpected":"no"}' ;;
    router-expected-host) echo '{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"codex-uri","source":"environment"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":["not-checked"],"intendedHostVersion":"26.1111.9664.0","routerExpected":true}' ;;
    queue-*) printf '%s\n' "${QUEUE_POLICY_JSON:-}" ;;
    *)
      echo '{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"codex-uri","source":"environment"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":["not-checked"]}'
      ;;
  esac
  exit 0
fi
printf 'powershell.exe invoked: %s\n' "$*" >> "$TOOL_LOG"
exit 99
EOF
[[ $? -eq 0 ]] || fatal "could not materialize router-contract PowerShell tripwire"
cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex invoked\n' >> "$TOOL_LOG"
exit 99
EOF
[[ $? -eq 0 ]] || fatal "could not materialize router-contract Codex tripwire"
chmod +x "$NODE_STUB" "$STUB_BIN/powershell.exe" "$STUB_BIN/codex" \
  || fatal "could not make router-contract stubs executable"
for _stub in node powershell.exe codex; do
  _resolved="$(PATH="$STUB_BIN:$PATH" command -v "$_stub" 2>/dev/null)" \
    || fatal "$_stub router-contract stub does not resolve"
  [[ "$_resolved" == "$STUB_BIN/$_stub" ]] \
    || fatal "$_stub resolved outside the harness: $_resolved"
done
unset _stub _resolved

run_wrapper_case(){
  # $5 (optional): text that MUST NOT appear in the wrapper's combined output.
  local scenario="$1" expected_rc="$2" expected_result="$3" label="$4" forbidden="${5:-}" target="${6:-$THREAD}"
  local case_root="$TMP/$scenario" output rc
  mkdir -p "$case_root/ipc" "$case_root/home" \
    || fatal "could not create router-contract fixture for $scenario"
  output="$(env \
    PATH="$STUB_BIN:$PATH" \
    REAL_NODE="$NODE_BIN" \
    ROUTER_CASE="$scenario" \
    TOOL_LOG="$TOOL_LOG" \
    POLICY_LOG="$POLICY_LOG" \
    HOME="$case_root/home" \
    CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" \
    CODEX_IPC_ROOT="$case_root/ipc" \
    CODEX_IPC_AUTOLOAD=codex-uri \
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
# A connect-phase failure precedes every frame write: the client reports it with no sent
# requests, so non-admission is proven and the pickup line is safe. Codex Desktop 26.1117
# builds serve no router pipe at all (ENOENT). Only the exact structure qualifies; a
# connect claim that carries a request, or names another thread, stays ambiguous.
run_wrapper_case router-absent 1 \
  "RESULT: gui-unowned -- reason=router-absent -- confirmation=not-attempted" \
  "an absent router pipe is pre-write non-admission"
run_wrapper_case router-unreachable 1 \
  "RESULT: gui-unowned -- reason=router-unreachable -- confirmation=not-attempted" \
  "any other connect-phase failure is pre-write non-admission"
run_wrapper_case connect-claim-with-request 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "a connect claim that carries a sent request stays ambiguous" \
  "FALLBACK -- file-drop is ready"
run_wrapper_case connect-claim-other-target 1 \
  "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" \
  "a connect claim for another thread stays ambiguous" \
  "FALLBACK -- file-drop is ready"
# A host the policy proves to be a 26.1117+ build serves no router: the wrapper refuses before the
# client runs, so nothing contacts any process serving that pipe name. An unknown or older
# version keeps the client path; a malformed expectation fails closed.
run_wrapper_case routerless-host 1 \
  "RESULT: gui-unowned -- reason=router-absent -- confirmation=not-attempted" \
  "a routerless (26.1117+) intended host is refused before the client"
run_wrapper_case routerless-unversioned 1 \
  "RESULT: gui-unowned -- reason=host-policy-invalid -- confirmation=not-attempted" \
  "a routerless claim without a host version fails closed as invalid policy"
run_wrapper_case router-malformed-expectation 1 \
  "RESULT: gui-unowned -- reason=host-policy-invalid -- confirmation=not-attempted" \
  "a non-boolean router expectation fails closed as invalid policy"
if grep -Eq 'client invoked: (routerless-host|routerless-unversioned|router-malformed-expectation)' "$TOOL_LOG.client"; then
  no "the client ran for a refused router expectation"
else
  ok "no client ran for a routerless or malformed router expectation (zero pipe contact)"
fi
run_wrapper_case router-expected-host 0 \
  "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=rollout-hit" \
  "a host that still expects a router keeps the client path"
grep -q 'client invoked: router-expected-host' "$TOOL_LOG.client" \
  && ok "the client runs for a host that expects a router" \
  || no "the client did not run for a router-expecting host"
_routerless_out="$(env PATH="$STUB_BIN:$PATH" REAL_NODE="$NODE_BIN" ROUTER_CASE=routerless-host \
  TOOL_LOG="$TOOL_LOG" POLICY_LOG="$POLICY_LOG" HOME="$TMP/routerless-pickup/home" \
  CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" CODEX_IPC_ROOT="$TMP/routerless-pickup/ipc" \
  CODEX_IPC_AUTOLOAD=codex-uri CODEX_IPC_RETENTION_DAYS=0 \
  bash "$WRAPPER" --ipc "$THREAD" "$TASK_TEXT" 2>&1)"
if printf '%s\n' "$_routerless_out" | grep -Fq "FALLBACK -- file-drop is ready" \
  && printf '%s\n' "$_routerless_out" | grep -Fq "intended host 26.1117.4957.0 is a Codex Desktop 26.1117+ build"; then
  ok "the routerless refusal names the host version and prints the pickup line"
else
  no "routerless refusal output is wrong"
  printf '%s\n' "$_routerless_out" | sed -n '1,20p'
fi
unset _routerless_out
for _pickup_case in router-absent router-unreachable; do
  _pickup_out="$(env PATH="$STUB_BIN:$PATH" REAL_NODE="$NODE_BIN" ROUTER_CASE="$_pickup_case" \
    TOOL_LOG="$TOOL_LOG" POLICY_LOG="$POLICY_LOG" HOME="$TMP/$_pickup_case/home" \
    CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" CODEX_IPC_ROOT="$TMP/$_pickup_case/ipc" \
    CODEX_IPC_AUTOLOAD=codex-uri CODEX_IPC_RETENTION_DAYS=0 \
    bash "$WRAPPER" --ipc "$THREAD" "$TASK_TEXT" 2>&1)"
  if printf '%s\n' "$_pickup_out" | grep -Fq "FALLBACK -- file-drop is ready" \
    && ! printf '%s\n' "$_pickup_out" | grep -Fq "AMBIGUOUS"; then
    ok "$_pickup_case prints the pickup line and no ambiguity notice"
  else
    no "$_pickup_case pickup output is wrong"
    printf '%s\n' "$_pickup_out" | sed -n '1,20p'
  fi
done
unset _pickup_case _pickup_out

echo "== 3c. --deliver queue: runtime queue delivery classification =="
# The runtime is a fake codex.exe that the real helper launches exactly as it would the real one.
# On Windows it is a copy of node.exe that a --require preload turns into the fake, because Windows
# cannot launch a script as an executable without a shell; elsewhere it is a shebang script. Every
# case has its own HOME/USERPROFILE with a fixture queue store, so the real ~/.codex is never read,
# and the router client and the PATH `codex` tripwire must stay untouched throughout.
QUEUE_DIR="$TMP/queue-runtime"
mkdir -p "$QUEUE_DIR" || fatal "could not create the fake runtime directory"
QUEUE_FAKE_JS="$QUEUE_DIR/fake_runtime.cjs"
QUEUE_RUNTIME_LOG="$TMP/queue-runtime.log"
QUEUE_QID="0f0f0001-0000-4000-8000-000000000001"
QUEUE_OTHER_THREAD="00000000-0000-4000-8000-000000000000"
cat > "$QUEUE_FAKE_JS" <<'EOF'
"use strict";
const fs = require("node:fs");
const path = require("node:path");
// Preloaded: node.exe running as codex.exe takes "queue" as its main script path.
const preloaded = path.basename(process.execPath).toLowerCase() === "codex.exe";
const scripted = path.basename(process.argv[1] || "") === "fake_runtime.cjs";
if (preloaded || scripted) {
  const args = preloaded
    ? [path.basename(process.argv[1] || ""), ...process.argv.slice(2)]
    : process.argv.slice(2);
  fs.appendFileSync(process.env.QUEUE_RUNTIME_LOG, JSON.stringify({ args, cwd: process.cwd() }) + "\n");
  const thread = args[args.indexOf("--thread") + 1];
  const qid = process.env.QUEUE_QID;
  const out = (text) => fs.writeSync(1, text);
  switch (process.env.FAKE_RUNTIME_MODE) {
    case "success": out(`Queued message ${qid} for thread ${thread}.\n`); process.exit(0); break;
    case "crlf": out(`Queued message ${qid} for thread ${thread}.\r\n`); process.exit(0); break;
    case "nonzero":
      fs.writeSync(2, "Error: failed to queue session message: synthetic thread not found\n");
      process.exit(1); break;
    case "garbage": out("something unexpected\n"); process.exit(0); break;
    case "extra-line":
      out("note: an extra line\n");
      out(`Queued message ${qid} for thread ${thread}.\n`);
      process.exit(0); break;
    case "mismatch":
      out(`Queued message ${qid} for thread ${process.env.QUEUE_OTHER_THREAD}.\n`); process.exit(0); break;
    case "hang": Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 60000); process.exit(0); break;
    default: fs.writeSync(2, "fake runtime: no mode\n"); process.exit(97);
  }
}
EOF
[[ $? -eq 0 ]] || fatal "could not materialize the fake runtime"
QUEUE_WINDOWS=0
[[ "$("$NODE_BIN" -p process.platform 2>/dev/null)" == "win32" ]] && QUEUE_WINDOWS=1
native_path(){ if [[ $QUEUE_WINDOWS -eq 1 ]]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
QUEUE_RUNTIME="$QUEUE_DIR/codex.exe"
QUEUE_NODE_OPTIONS=""
if [[ $QUEUE_WINDOWS -eq 1 ]]; then
  cp "$NODE_BIN" "$QUEUE_RUNTIME" || fatal "could not create the fake runtime executable"
  QUEUE_NODE_OPTIONS="--require=\"$(cygpath -m "$QUEUE_FAKE_JS")\""
else
  printf '#!/usr/bin/env bash\nexec "$REAL_NODE" "%s" "$@"\n' "$QUEUE_FAKE_JS" > "$QUEUE_RUNTIME" \
    && chmod +x "$QUEUE_RUNTIME" || fatal "could not create the fake runtime script"
fi
QUEUE_RUNTIME_NATIVE="$(native_path "$QUEUE_RUNTIME")"
QUEUE_RUNTIME_LOG_NATIVE="$(native_path "$QUEUE_RUNTIME_LOG")"
mkdir -p "$QUEUE_DIR/not-a-runtime" && printf 'not an executable\n' > "$QUEUE_DIR/not-a-runtime/codex.exe" \
  || fatal "could not create the non-executable runtime fixture"

queue_store_fixture(){
  "$NODE_BIN" -e '
const { DatabaseSync } = require("node:sqlite");
const fs = require("node:fs");
const path = require("node:path");
fs.mkdirSync(path.dirname(process.argv[1]), { recursive: true });
const db = new DatabaseSync(process.argv[1]);
db.exec("create table queued_items (id text primary key not null, thread_id text not null, " +
  "payload_json text not null, queue_order integer not null, created_at_ms integer not null, " +
  "updated_at_ms integer not null)");
db.close();' "$(native_path "$1")" 2>/dev/null || fatal "could not create a fixture queue store"
}
# queue_policy <runtime-status|absent> <executable|-> [sendEligible] [reasons]
queue_policy(){
  "$NODE_BIN" -e '
const [status, executable, eligible = "true", reasons = ""] = process.argv.slice(1);
const doc = { schemaVersion: 1, ok: true, purpose: "send",
  configuration: { valid: true, autoload: { value: "off", source: "default" },
    intendedHost: { kind: "package", executable: null, source: "default" } },
  inventory: { complete: true, guiHosts: [{ matchesIntended: true }], appServers: [] },
  sendEligible: eligible === "true", sendReasons: reasons ? reasons.split(",") : [],
  activationEligible: false, activationReasons: ["activation-not-evaluated"],
  intendedHostVersion: "26.1117.31558.0", routerExpected: false };
if (status !== "absent") {
  doc.intendedRuntime = { status, executable: executable === "-" ? null : executable };
}
process.stdout.write(JSON.stringify(doc));' "$@"
}

QUEUE_N=0
QUEUE_OUT=""
QUEUE_CASE_ROOT=""
QUEUE_FLAGS=()
QUEUE_STORE=1
QUEUE_POLICY=""
# run_queue_case <router-case> <runtime-mode> <rc> <exact RESULT or ERROR line> <label> [NAME=VALUE ...]
run_queue_case(){
  local scenario="$1" mode="$2" expected_rc="$3" expected_line="$4" label="$5" rc
  shift 5
  QUEUE_N=$((QUEUE_N + 1))
  QUEUE_CASE_ROOT="$TMP/queue-case-$QUEUE_N"
  mkdir -p "$QUEUE_CASE_ROOT/ipc" "$QUEUE_CASE_ROOT/home" || fatal "could not create queue case $QUEUE_N"
  [[ "$QUEUE_STORE" -eq 1 ]] && queue_store_fixture "$QUEUE_CASE_ROOT/home/.codex/queue_1.sqlite"
  : > "$QUEUE_RUNTIME_LOG"
  QUEUE_OUT="$(env -u CODEX_HOME -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST -u QUEUE_ID \
    PATH="$STUB_BIN:$PATH" REAL_NODE="$NODE_BIN" ROUTER_CASE="$scenario" \
    TOOL_LOG="$TOOL_LOG" POLICY_LOG="$POLICY_LOG" QUEUE_POLICY_JSON="$QUEUE_POLICY" \
    QUEUE_RUNTIME_LOG="$QUEUE_RUNTIME_LOG_NATIVE" QUEUE_QID="$QUEUE_QID" \
    QUEUE_OTHER_THREAD="$QUEUE_OTHER_THREAD" FAKE_RUNTIME_MODE="$mode" \
    NODE_OPTIONS="$QUEUE_NODE_OPTIONS" \
    HOME="$QUEUE_CASE_ROOT/home" USERPROFILE="$(native_path "$QUEUE_CASE_ROOT/home")" \
    CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" \
    CODEX_IPC_ROOT="$QUEUE_CASE_ROOT/ipc" CODEX_IPC_RETENTION_DAYS=0 \
    "$@" \
    bash "$WRAPPER" --ipc "$THREAD" --deliver queue ${QUEUE_FLAGS[@]+"${QUEUE_FLAGS[@]}"} -- "$TASK_TEXT" 2>&1)"
  rc=$?
  if [[ $rc -eq $expected_rc ]] && printf '%s\n' "$QUEUE_OUT" | grep -Fqx "$expected_line"; then
    ok "$label"
  else
    no "$label (rc=$rc)"
    printf '%s\n' "$QUEUE_OUT" | sed -n '1,40p'
  fi
}
queue_runtime_ran(){ [[ -s "$QUEUE_RUNTIME_LOG" ]]; }
queue_out_has(){ printf '%s\n' "$QUEUE_OUT" | grep -Fq -- "$1"; }
queue_out_has_wait(){ printf '%s\n' "$QUEUE_OUT" | grep -q '^WAIT:'; }
# A refusal before the runtime ran keeps the pickup line; it prints no WAIT and no ambiguity.
assert_queue_not_attempted(){
  if ! queue_runtime_ran && queue_out_has "FALLBACK -- file-drop is ready" \
    && ! queue_out_has "AMBIGUOUS" && ! queue_out_has_wait; then
    ok "$1: the runtime did not run and the pickup line is offered"
  else
    no "$1: not-attempted shape is wrong"
    printf '%s\n' "$QUEUE_OUT" | sed -n '1,30p'
  fi
}
# After the runtime ran, anything but its exact success line is unknown: no pickup, no WAIT.
assert_queue_unknown(){
  if queue_runtime_ran && ! queue_out_has "FALLBACK -- file-drop is ready" \
    && queue_out_has "AMBIGUOUS" && queue_out_has "do not resend" && ! queue_out_has_wait; then
    ok "$1: the runtime ran, so pickup is suppressed and the outcome stays unknown"
  else
    no "$1: unknown shape is wrong"
    printf '%s\n' "$QUEUE_OUT" | sed -n '1,30p'
  fi
}

QUEUE_POLICY="$(queue_policy resolved "$QUEUE_RUNTIME_NATIVE")"
run_queue_case queue-success success 0 \
  "RESULT: queued -- reason=runtime-accepted -- confirmation=pending -- queueId=$QUEUE_QID" \
  "a routerless (26.1117+) host queues the pickup line and reports the queue id"
_queue_envelope="$(find "$QUEUE_CASE_ROOT/ipc" -name '*.task.md' -type f)"
_queue_dispatch="$(basename "$_queue_envelope" .task.md)"
if [[ $QUEUE_WINDOWS -eq 1 ]]; then _queue_envelope="$(cygpath -m "$_queue_envelope")"; fi
if "$NODE_BIN" -e '
const fs = require("node:fs");
const [log, thread, envelope] = process.argv.slice(1);
const lines = fs.readFileSync(log, "utf8").split("\n").filter(Boolean);
if (lines.length !== 1) process.exit(1);
const { args, cwd } = JSON.parse(lines[0]);
const expected = ["queue", "--thread", thread, "--message", `read "${envelope}" and proceed`];
process.exit(JSON.stringify(args) === JSON.stringify(expected) && cwd.includes(thread) ? 0 : 1);
' "$QUEUE_RUNTIME_LOG_NATIVE" "$THREAD" "$_queue_envelope"; then
  ok "the runtime ran once with exactly queue --thread <id> --message <pickup line> (no --resume, --remote or -c)"
else
  no "the runtime argv is not exactly the queue command"
  cat "$QUEUE_RUNTIME_LOG"
fi
if printf '%s\n' "$QUEUE_OUT" | grep '^WAIT:' | grep -Fq -- "--queue-id $QUEUE_QID" \
  && printf '%s\n' "$QUEUE_OUT" | grep '^WAIT:' | grep -Fq -- "--dispatch $_queue_dispatch" \
  && printf '%s\n' "$QUEUE_OUT" | grep '^WAIT:' | grep -Fq -- "--materialize-reply"; then
  ok "the WAIT line carries the dispatch, --materialize-reply and --queue-id"
else
  no "the queue WAIT line is wrong"
  printf '%s\n' "$QUEUE_OUT" | grep '^WAIT:'
fi
if queue_out_has "POLICY: delivery=queue intended-host=package (source: default) runtime=resolved" \
  && ! queue_out_has "$QUEUE_RUNTIME_NATIVE" && ! queue_out_has "FALLBACK -- file-drop is ready"; then
  ok "the queue POLICY line names the runtime status, never its path, and no pickup is printed"
else
  no "queue success output leaks the runtime path or offers pickup"
  printf '%s\n' "$QUEUE_OUT" | sed -n '1,30p'
fi
unset _queue_envelope _queue_dispatch

run_queue_case queue-crlf crlf 0 \
  "RESULT: queued -- reason=runtime-accepted -- confirmation=pending -- queueId=$QUEUE_QID" \
  "a CRLF-terminated success line is the same success"
_policy_lines_before="$(wc -l < "$POLICY_LOG")"
QUEUE_FLAGS=(--intended-host package --reply-mode final-message)
run_queue_case queue-intended-host success 0 \
  "RESULT: queued -- reason=runtime-accepted -- confirmation=pending -- queueId=$QUEUE_QID" \
  "--intended-host and --reply-mode combine with --deliver queue"
QUEUE_FLAGS=()
if tail -n +"$((_policy_lines_before + 1))" "$POLICY_LOG" | grep -q -- '-Purpose send .*-IntendedHost package' \
  && queue_out_has "reply mode final-message"; then
  ok "the queue route asks the shared send policy for the named intended host"
else
  no "the queue route did not pass --intended-host to the host policy"
fi
unset _policy_lines_before

run_queue_case queue-nonzero nonzero 1 \
  "RESULT: failed-closed -- reason=queue-runtime-failed -- confirmation=unknown" \
  "a nonzero runtime exit is post-attempt unknown, never not-attempted"
assert_queue_unknown "nonzero exit"
queue_out_has "synthetic thread not found" && ok "bounded runtime diagnostics are shown" \
  || no "runtime diagnostics were not shown"
run_queue_case queue-garbage garbage 1 \
  "RESULT: failed-closed -- reason=queue-output-unrecognized -- confirmation=unknown" \
  "unrecognized runtime output is unknown"
assert_queue_unknown "garbage output"
run_queue_case queue-extra-line extra-line 1 \
  "RESULT: failed-closed -- reason=queue-output-unrecognized -- confirmation=unknown" \
  "a success line with extra output is not exact, so it is unknown"
assert_queue_unknown "extra output"
run_queue_case queue-mismatch mismatch 1 \
  "RESULT: failed-closed -- reason=queue-thread-mismatch -- confirmation=unknown" \
  "a success line for another thread is unknown, never success"
assert_queue_unknown "thread mismatch"
queue_out_has "queue item $QUEUE_QID for thread $QUEUE_OTHER_THREAD" \
  && ok "a thread mismatch names the reported item and thread" || no "thread mismatch was not named"
run_queue_case queue-timeout hang 1 \
  "RESULT: failed-closed -- reason=queue-timeout -- confirmation=unknown" \
  "a runtime that outlives the timeout is unknown" CODEX_IPC_QUEUE_TIMEOUT_MS=1500
assert_queue_unknown "timeout"
run_queue_case queue-helper-garbage success 1 \
  "RESULT: failed-closed -- reason=queue-helper-failure -- confirmation=unknown" \
  "an unreadable helper document is unknown, because the runtime may have run"
if ! queue_out_has "FALLBACK -- file-drop is ready" && queue_out_has "AMBIGUOUS" && ! queue_out_has_wait; then
  ok "helper failure suppresses pickup and WAIT"
else
  no "helper failure shape is wrong"
fi

QUEUE_POLICY="$(queue_policy ambiguous -)"
run_queue_case queue-runtime-ambiguous success 1 \
  "RESULT: queue-unavailable -- reason=runtime-ambiguous -- confirmation=not-attempted" \
  "two runtime executables under the intended host refuse before any run"
assert_queue_not_attempted "ambiguous runtime"
QUEUE_POLICY="$(queue_policy missing -)"
run_queue_case queue-runtime-missing success 1 \
  "RESULT: queue-unavailable -- reason=runtime-missing -- confirmation=not-attempted" \
  "no proven runtime refuses before any run"
assert_queue_not_attempted "missing runtime"
QUEUE_POLICY="$(queue_policy absent -)"
run_queue_case queue-runtime-unreported success 1 \
  "RESULT: queue-unavailable -- reason=host-policy-invalid -- confirmation=not-attempted" \
  "policy output without the intended runtime refuses"
assert_queue_not_attempted "unreported runtime"
QUEUE_POLICY='{"schemaVersion":1,"ok":true,"purpose":"send","configuration":{"valid":true,"autoload":{"value":"off","source":"default"},"intendedHost":{"kind":"package","executable":null,"source":"default"}},"inventory":{"complete":true,"guiHosts":[{"matchesIntended":true}],"appServers":[]},"sendEligible":true,"sendReasons":[],"activationEligible":false,"activationReasons":[],"intendedHostVersion":"26.1117.31558.0","routerExpected":false,"intendedRuntime":{"status":"resolved","executable":"codex.exe"}}'
run_queue_case queue-runtime-relative success 1 \
  "RESULT: queue-unavailable -- reason=host-policy-invalid -- confirmation=not-attempted" \
  "a relative runtime path is malformed policy, never a PATH lookup"
assert_queue_not_attempted "relative runtime"
QUEUE_POLICY="$(queue_policy resolved "$(native_path "$QUEUE_DIR/absent/codex.exe")")"
run_queue_case queue-runtime-file-absent success 1 \
  "RESULT: queue-unavailable -- reason=runtime-missing -- confirmation=not-attempted" \
  "a runtime path with no file behind it refuses before any run"
assert_queue_not_attempted "absent runtime file"
QUEUE_POLICY="$(queue_policy resolved "$(native_path "$QUEUE_DIR/not-a-runtime/codex.exe")")"
run_queue_case queue-runtime-unlaunchable success 1 \
  "RESULT: queue-unavailable -- reason=runtime-launch-failed -- confirmation=not-attempted" \
  "a runtime that cannot be started never ran, so pickup stays safe"
assert_queue_not_attempted "unlaunchable runtime"
QUEUE_POLICY="$(queue_policy resolved "$QUEUE_RUNTIME_NATIVE" false intended-host-not-running)"
run_queue_case queue-host-not-running success 1 \
  "RESULT: queue-unavailable -- reason=intended-host-not-running -- confirmation=not-attempted" \
  "the queue route keeps the shared send gate (intended host must run alone)"
assert_queue_not_attempted "host not running"
QUEUE_POLICY="$(queue_policy resolved "$QUEUE_RUNTIME_NATIVE" false other-desktop-host-running)"
run_queue_case queue-other-host success 1 \
  "RESULT: queue-unavailable -- reason=other-desktop-host-running -- confirmation=not-attempted" \
  "another Desktop host refuses the queue route"
assert_queue_not_attempted "other host"
QUEUE_POLICY="$(queue_policy resolved "$QUEUE_RUNTIME_NATIVE")"
QUEUE_STORE=0
run_queue_case queue-store-absent success 1 \
  "RESULT: queue-unavailable -- reason=queue-store-absent -- confirmation=not-attempted" \
  "a Codex home without a queue store refuses (the runtime would create one)"
assert_queue_not_attempted "absent queue store"
QUEUE_STORE=1
mkdir -p "$TMP/elsewhere/.codex" || fatal "could not create the other Codex home"
run_queue_case queue-codex-home success 1 \
  "RESULT: queue-unavailable -- reason=codex-home-mismatch -- confirmation=not-attempted" \
  "a CODEX_HOME other than the inspected home refuses" CODEX_HOME="$(native_path "$TMP/elsewhere/.codex")"
assert_queue_not_attempted "CODEX_HOME mismatch"

_policy_lines_before="$(wc -l < "$POLICY_LOG")"
run_queue_case no-client-archived success 1 \
  "RESULT: failed-closed -- reason=target-archived -- confirmation=not-attempted" \
  "an archived target refuses before the host policy or the runtime"
if ! queue_runtime_ran && ! queue_out_has "FALLBACK -- file-drop is ready" \
  && [[ "$(wc -l < "$POLICY_LOG")" -eq "$_policy_lines_before" ]]; then
  ok "a target refusal offers no pickup and consults no host policy"
else
  no "target refusal shape is wrong"
fi
run_queue_case no-client-orphan success 1 \
  "RESULT: failed-closed -- reason=target-inspection-ambiguous -- confirmation=not-attempted" \
  "an untrusted target row refuses the queue route"
unset _policy_lines_before

QUEUE_FLAGS=(--autoload codex-uri)
run_queue_case queue-flag-autoload success 1 \
  "ERROR: --deliver queue cannot be combined with --autoload, --foreground-policy or --ack-foreground-switch." \
  "--deliver queue refuses activation flags"
QUEUE_FLAGS=(--foreground-policy switch --ack-foreground-switch)
run_queue_case queue-flag-foreground success 1 \
  "ERROR: --deliver queue cannot be combined with --autoload, --foreground-policy or --ack-foreground-switch." \
  "--deliver queue refuses foreground flags"
QUEUE_FLAGS=()
if [[ -z "$(find "$TMP/queue-case-$((QUEUE_N - 1))" "$TMP/queue-case-$QUEUE_N" -name '*.task.md' 2>/dev/null)" ]] \
  && ! queue_runtime_ran; then
  ok "flag refusals happen before any envelope or runtime"
else
  no "a flag refusal wrote an envelope or ran the runtime"
fi
_bad_deliver="$(env PATH="$STUB_BIN:$PATH" REAL_NODE="$NODE_BIN" HOME="$TMP/bad-deliver" \
  CODEX_IPC_ROOT="$TMP/bad-deliver/ipc" bash "$WRAPPER" --ipc "$THREAD" --deliver bogus -- x 2>&1)"
printf '%s\n' "$_bad_deliver" | grep -Fqx "ERROR: --deliver requires live, manual or queue (got 'bogus')." \
  && ok "an unknown --deliver value names all three modes" || no "unknown --deliver message is wrong"
unset _bad_deliver

if [[ ! -s "$TOOL_LOG.client" ]] || ! grep -q 'client invoked: queue-' "$TOOL_LOG.client"; then
  ok "no --deliver queue case ran the router client"
else
  no "a --deliver queue case ran the router client"
fi
if [[ ! -f "$TOOL_LOG" ]] || ! grep -q 'codex invoked' "$TOOL_LOG"; then
  ok "no --deliver queue case ran a codex found on PATH"
else
  no "a codex found on PATH was invoked"
fi

# The manual route never adds --queue-id, even with an inherited QUEUE_ID in the environment.
_manual_out="$(env PATH="$STUB_BIN:$PATH" REAL_NODE="$NODE_BIN" ROUTER_CASE=acceptance QUEUE_ID="$QUEUE_QID" \
  TOOL_LOG="$TOOL_LOG" POLICY_LOG="$POLICY_LOG" HOME="$TMP/manual-queue-id/home" \
  CLAUDE_SESSION_ID="33333333-3333-4333-8333-333333333333" CODEX_IPC_ROOT="$TMP/manual-queue-id/ipc" \
  CODEX_IPC_RETENTION_DAYS=0 bash "$WRAPPER" --ipc "$THREAD" --deliver manual -- "$TASK_TEXT" 2>&1)"
if printf '%s\n' "$_manual_out" | grep -q '^WAIT:' && ! printf '%s\n' "$_manual_out" | grep -Fq -- "--queue-id"; then
  ok "manual WAIT lines never carry --queue-id, even with QUEUE_ID inherited"
else
  no "manual WAIT line picked up a queue id"
  printf '%s\n' "$_manual_out" | grep '^WAIT:'
fi
unset _manual_out

echo "== 3d. queue helper: exact success-line parsing and bounded diagnostics =="
if QUEUE_HELPER="$(dirname "$WRAPPER")/codex_ipc_queue.mjs" "$NODE_BIN" --input-type=module -e '
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { parseQueuedOutput, excerpt, sendToQueue } = await import(pathToFileURL(process.env.QUEUE_HELPER).href);
const q = "0f0f0001-0000-4000-8000-000000000001";
const t = "22222222-2222-4222-8222-222222222222";
assert.deepEqual(parseQueuedOutput(`Queued message ${q} for thread ${t}.\n`), { queueId: q, threadId: t });
assert.deepEqual(parseQueuedOutput(`Queued message ${q.toUpperCase()} for thread ${t}.`), { queueId: q, threadId: t });
for (const bad of ["", "\n", `Queued message ${q} for thread ${t}`, `Queued message ${q} for thread ${t}.\n\n`,
  `x\nQueued message ${q} for thread ${t}.\n`, ` Queued message ${q} for thread ${t}.`,
  `Queued message not-a-uuid for thread ${t}.`, `Queued message ${q} for thread ${t}. extra`]) {
  assert.equal(parseQueuedOutput(bad), null, JSON.stringify(bad));
}
assert.deepEqual(excerpt("\u001b[31mError:\u001b[0m bad\r\nline\u0007 two\n\n"), ["Error: bad", "line two"]);
assert.equal(excerpt("x\n".repeat(20)).length, 6);
assert.ok(Buffer.byteLength(excerpt("y".repeat(5000)).join("")) <= 600);
const cut = excerpt("a" + "é".repeat(400))[0];
assert.equal(Buffer.byteLength(cut), 599, "a cut never keeps half a character");
assert.ok(!cut.endsWith(String.fromCharCode(0xfffd)));
let spawned = false;
const refused = sendToQueue({ runtime: "codex.exe", threadId: t, message: "m" },
  { env: {}, spawnSync: () => { spawned = true; } });
assert.equal(refused.outcome, "not-attempted");
assert.equal(refused.reason, "runtime-missing");
assert.equal(spawned, false, "a relative runtime is never launched or looked up");
' >/dev/null 2>"$TMP/queue-helper.err"; then
  ok "the helper accepts only the exact success sentence and bounds runtime diagnostics"
else
  no "queue helper unit checks"
  sed -n '1,30p' "$TMP/queue-helper.err"
fi

echo "== 3b. real client: a connect-phase failure is structured and sends nothing =="
# A random pipe name that no process serves. On Windows the client finds it absent in the pipe
# namespace and never connects; elsewhere the connect itself fails with ENOENT. Either way the
# result is the same structure, and nothing reaches the Desktop router.
ABSENT_PIPE='\\.\pipe\codex-ipc-absent-'"$RANDOM$RANDOM"
ABSENT_ERR="$TMP/absent-pipe.err"
ABSENT_OUT="$("$NODE_BIN" "$CLIENT" --thread "$THREAD" --task "$TASK_TEXT" --pipe "$ABSENT_PIPE" \
  --allow-any-thread --send --ack-live-write --timeout-ms 2000 2>"$ABSENT_ERR")"
ABSENT_RC=$?
if [[ $ABSENT_RC -eq 1 ]] && ABSENT_OUT="$ABSENT_OUT" THREAD="$THREAD" "$NODE_BIN" -e '
const value = JSON.parse(process.env.ABSENT_OUT);
const ok = value.ok === false && value.phase === "connect" &&
  value.targetThreadId === process.env.THREAD &&
  Array.isArray(value.sentRequests) && value.sentRequests.length === 0 &&
  !("response" in value) && value.connectError?.code === "ENOENT";
process.exit(ok ? 0 : 1);
'; then
  ok "an absent pipe yields phase=connect, ENOENT, no sent requests, exit 1"
else
  no "absent-pipe client result is not the structured connect failure (rc=$ABSENT_RC)"
  printf '%s\n' "$ABSENT_OUT" | sed -n '1,12p'; sed -n '1,8p' "$ABSENT_ERR"
fi

echo "== revalidator host-policy authority =="
REVALIDATOR="$(dirname "$CLIENT")/codex_ipc_revalidate.mjs"
[[ -f "$REVALIDATOR" ]] || fatal "revalidator is missing"
REVALIDATE_HOME="$TMP/revalidate-home"
REVALIDATE_ROOT="$REVALIDATE_HOME/transport"
REVALIDATE_LOG="$TMP/revalidate-spawns.log"
REVALIDATE_LIVE="$TMP/revalidate-live.log"
REVALIDATE_PRELOAD="$TMP/revalidate-preload.cjs"
mkdir -p "$REVALIDATE_HOME/.codex/sessions" "$REVALIDATE_ROOT" \
  || fatal "could not create revalidator fixture state"
: > "$REVALIDATE_HOME/.codex/config.toml"
: > "$REVALIDATE_HOME/.codex/state_5.sqlite"
cat > "$REVALIDATE_PRELOAD" <<'REVALIDATOR_PRELOAD'
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { syncBuiltinESMExports } = require("node:module");

const originalExistsSync = fs.existsSync;
const originalReaddirSync = fs.readdirSync;
fs.existsSync = function (value) {
  const text = String(value);
  if (/^C:\\Program Files\\Git\\(?:bin|usr\\bin)\\bash\.exe$/i.test(text)) return true;
  return originalExistsSync(value);
};
fs.readdirSync = function (value, ...rest) {
  if (String(value) === "\\\\.\\pipe\\") return ["codex-ipc"];
  return originalReaddirSync(value, ...rest);
};

function result(status, stdout = "", stderr = "", error = null) {
  return { status, signal: null, stdout, stderr, error };
}
function policyDocument(mode) {
  const eligible = {
    schemaVersion: 1,
    ok: true,
    purpose: "send",
    configuration: {
      valid: true,
      autoload: { value: "off", source: "default" },
      intendedHost: { kind: "package", executable: null, source: "default" },
      descriptor: { path: "x".repeat(3000), status: "absent" },
    },
    inventory: {
      complete: true,
      coverage: "synthetic",
      errors: [],
      packageRootsComplete: true,
      packageRoots: [],
      guiHosts: [{
        pid: 10,
        parentPid: 1,
        name: "ChatGPT.exe",
        executable: "C:\\Program Files\\WindowsApps\\OpenAI.Codex_fixture\\app\\ChatGPT.exe",
        matchesIntended: true,
        classification: "package",
      }],
      appServers: [{
        pid: 11,
        parentPid: 10,
        name: "codex.exe",
        executable: "C:\\Program Files\\WindowsApps\\OpenAI.Codex_fixture\\app\\resources\\codex.exe",
        matchesIntended: true,
        classification: "package",
      }],
    },
    sendEligible: true,
    sendReasons: [],
    activationEligible: false,
    activationReasons: ["autoload-disabled"],
  };
  if (mode === "refuse-other") {
    eligible.inventory.guiHosts = [{
      pid: 10,
      parentPid: 1,
      name: "ChatGPT.exe",
      executable: "C:\\Alt\\Host\\ChatGPT.exe",
      matchesIntended: false,
      classification: "other",
    }];
    eligible.sendEligible = false;
    eligible.sendReasons = ["other-desktop-host-running"];
  } else if (mode === "incomplete") {
    eligible.inventory.complete = false;
    eligible.inventory.guiHosts = [];
    eligible.sendEligible = false;
    eligible.sendReasons = ["host-inventory-incomplete", "intended-host-not-running"];
  }
  return JSON.stringify(eligible);
}

childProcess.spawnSync = function (command, args = []) {
  const commandText = String(command);
  const argv = Array.from(args, String);
  fs.appendFileSync(process.env.REVALIDATE_LOG, `${commandText}\t${argv.join("\t")}\n`);

  if (/bash(?:\.exe)?$/i.test(commandText)) {
    if (process.env.REVALIDATE_BASH_MODE === "path-bad" && commandText.toLowerCase() === "bash") {
      return result(1, "", "synthetic WSL shim failure");
    }
    return result(0);
  }
  if (/powershell\.exe$/i.test(commandText)) {
    const fileIndex = argv.findIndex((item) => item === "-File");
    const script = fileIndex >= 0 ? argv[fileIndex + 1] : "";
    if (path.basename(script).toLowerCase() === "codex_ipc_host_policy.ps1") {
      const purposeIndex = argv.indexOf("-Purpose");
      const rootIndex = argv.indexOf("-IpcRoot");
      const policyArgsOk =
        purposeIndex >= 0 && argv[purposeIndex + 1] === "send" &&
        rootIndex >= 0 && argv[rootIndex + 1] === process.env.CODEX_IPC_ROOT;
      fs.appendFileSync(process.env.REVALIDATE_LOG, "host-policy-args-ok=" + policyArgsOk + "\n");
      const mode = process.env.REVALIDATE_POLICY_MODE || "eligible-long";
      if (mode === "malformed") return result(0, "{bad");
      if (mode === "empty") return result(0, "");
      if (mode === "nonzero-ok") return result(7, policyDocument("eligible-long"));
      return result(0, policyDocument(mode));
    }
    const commandBody = argv.join(" ");
    if (commandBody.includes("PSParser")) return result(0, "PARSE-OK\n");
    if (commandBody.includes("Get-AppxPackage")) {
      return result(0, '{"packageInstalled":true,"guiIdentified":true}\n');
    }
    return result(97, "", "unexpected PowerShell command");
  }
  if (commandText === process.execPath) {
    if (argv[0] === "--check") return result(0);
    if (argv[0] === "-e" && argv.join(" ").includes("node:sqlite")) {
      return result(0, "node:sqlite ok\n");
    }
    if (path.basename(argv[0] || "") === "codex_ipc_probe.mjs") {
      fs.appendFileSync(process.env.REVALIDATE_LIVE, "live-probe\n");
      return result(0, '{"ok":true}\n');
    }
  }
  return result(null, "", "", Object.assign(new Error(`unexpected spawn: ${commandText}`), { code: "ENOENT" }));
};

syncBuiltinESMExports();
REVALIDATOR_PRELOAD

revalidate_case(){ # mode expected-rc predicate [extra args...]
  local mode="$1" expected_rc="$2" predicate="$3"; shift 3
  local output rc
  : > "$REVALIDATE_LOG"
  : > "$REVALIDATE_LIVE"
  output="$(env \
    HOME="$REVALIDATE_HOME" USERPROFILE="$REVALIDATE_HOME" \
    CODEX_HOME="$REVALIDATE_HOME/.codex" CODEX_IPC_ROOT="$REVALIDATE_ROOT" \
    REVALIDATE_POLICY_MODE="$mode" REVALIDATE_BASH_MODE="${REVALIDATE_BASH_MODE:-normal}" \
    REVALIDATE_LOG="$REVALIDATE_LOG" REVALIDATE_LIVE="$REVALIDATE_LIVE" \
    NODE_OPTIONS="--require=$REVALIDATE_PRELOAD" \
    "$NODE_BIN" "$REVALIDATOR" "$@" 2>&1)"
  rc=$?
  if [[ "$rc" -eq "$expected_rc" ]] && REVALIDATE_PREDICATE="$predicate" \
    printf '%s' "$output" | REVALIDATE_PREDICATE="$predicate" "$NODE_BIN" -e '
let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { text += chunk; });
process.stdin.on("end", () => {
  try {
    const value = JSON.parse(text);
    const predicate = new Function("value", `return Boolean(${process.env.REVALIDATE_PREDICATE});`);
    process.exit(predicate(value) ? 0 : 1);
  } catch { process.exit(1); }
});
'; then
    ok "revalidator mode=$mode"
  else
    no "revalidator mode=$mode (rc=$rc, expected=$expected_rc)"
    printf '%s\n' "$output" | sed -n '1,24p'
  fi
}

revalidate_platform="$("$NODE_BIN" -p 'process.platform')"
eligible_bash_mode=normal
if [[ "$revalidate_platform" == "win32" ]]; then
  eligible_bash_mode=path-bad
fi
REVALIDATE_BASH_MODE="$eligible_bash_mode" revalidate_case eligible-long 0 '
  value.ok === true && value.checks.hostPolicy.ok === true &&
  value.checks.hostPolicy.sendEligible === true &&
  value.checks.hostPolicy.inventory.guiHosts.length === 1 &&
  value.checks.hostPolicy.inventory.guiHosts[0].executable.endsWith("ChatGPT.exe") &&
  value.checks.hostPolicy.inventory.guiHosts[0].classification === "package" &&
  value.checks.hostPolicy.inventory.appServers.length === 1 &&
  !("commandLine" in value.checks.hostPolicy.inventory.appServers[0]) &&
  value.summary.failed.length === 0'
first_bash="$(awk -F '\t' 'tolower($1) ~ /bash(\.exe)?$/ { print $1; exit }' "$REVALIDATE_LOG")"
if [[ "$revalidate_platform" == "win32" ]]; then
  [[ "$first_bash" == 'C:\Program Files\Git\bin\bash.exe' ]] \
    && ok "Windows revalidator prefers pinned Git Bash before a failing PATH shim" \
    || no "revalidator selected the wrong Bash first: $first_bash"
else
  ok "pinned Git Bash ordering is Windows-only"
fi
grep -Fqx 'host-policy-args-ok=true' "$REVALIDATE_LOG" \
  && ok "revalidator passes send purpose and the resolved IPC root to host policy" \
  || no "revalidator omitted host-policy purpose/root"

REVALIDATE_BASH_MODE=normal revalidate_case refuse-other 1 '
  value.ok === false && value.checks.hostPolicy.ok === false &&
  value.checks.hostPolicy.sendEligible === false &&
  value.checks.hostPolicy.inventory.guiHosts.length === 1 &&
  value.checks.hostPolicy.inventory.guiHosts[0].executable === "C:\\Alt\\Host\\ChatGPT.exe" &&
  value.checks.hostPolicy.inventory.guiHosts[0].classification === "other" &&
  value.summary.failed.includes("hostPolicy")'
for mode in malformed empty nonzero-ok incomplete; do
  revalidate_case "$mode" 1 '
    value.ok === false && value.checks.hostPolicy.ok === false &&
    value.summary.failed.includes("hostPolicy")'
done

revalidate_case refuse-other 1 '
  value.ok === false && value.checks.hostPolicy.ok === false &&
  value.checks.liveIpcReadProbe.skipped === true' \
  --allow-live-ipc-read
[[ ! -s "$REVALIDATE_LIVE" ]] \
  && ok "host-policy refusal suppresses the optional live probe" \
  || no "live probe ran after host-policy refusal"

if [[ ! -s "$TOOL_LOG" && -s "$POLICY_LOG" ]]; then
  ok "sentinel invoked only the read-only host policy, no Desktop, activation, or Codex helper"
else
  no "unexpected external helper invocation"
  cat "$TOOL_LOG"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
