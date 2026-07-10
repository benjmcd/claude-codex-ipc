#!/usr/bin/env bash
# Hermetic W2 harvester/observer/viewer integration tests. Host state and live IPC are forbidden.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node is unavailable; rollout fallback tests require optional Node."
    exit 0
fi

resolve_script() {
    local name="$1" candidate
    for candidate in "$DIR/../skills/ipc/scripts/$name" "$DIR/../scripts/$name"; do
        [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

HARVESTER="$(resolve_script codex_ipc_reply_harvest.mjs)" || { echo "FAIL: harvester not found" >&2; exit 1; }
OBSERVER="$(resolve_script codex_ipc_rollout_observe.mjs)" || { echo "FAIL: observer not found" >&2; exit 1; }
VIEWER="$(resolve_script codex_ipc_replies.sh)" || { echo "FAIL: viewer not found" >&2; exit 1; }
FIXTURES="$DIR/fixtures/rollout"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if ! HARVESTER="$HARVESTER" OBSERVER="$OBSERVER" FIXTURES="$FIXTURES" TMPDIR_TEST="$TMP" \
  node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const { harvestDispatch } = await import(pathToFileURL(process.env.HARVESTER));
const { observeRollout } = await import(pathToFileURL(process.env.OBSERVER));
let passed = 0;
async function test(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`PASS: ${name}`);
  } catch (error) {
    console.error(`FAIL: ${name}`);
    throw error;
  }
}

const basic = path.join(
  process.env.FIXTURES,
  "rollout-basic-11111111-1111-4111-8111-111111111111.jsonl",
);
const tmp = process.env.TMPDIR_TEST;
const dispatch = "1000000000-1-abcdef0123456789";

await test("regular reply file is primary without rollout access", () => {
  const reply = path.join(tmp, "primary.reply.md");
  fs.writeFileSync(reply, "PRIMARY");
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: reply,
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: path.join(tmp, "does-not-exist"),
    maxBytes: 4,
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.sourceBytes, 7);
  assert.equal(result.returnedBytes, 4);
  assert.equal(result.bodyBase64, null);
});

await test("completed rollout is selected only when primary is unavailable", () => {
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: path.join(tmp, "absent.reply.md"),
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: basic,
    maxBytes: 4096,
  });
  assert.equal(result.source, "rollout-fallback");
  assert.equal(Buffer.from(result.bodyBase64, "base64").toString("utf8"), "latest final");
  assert.equal(result.duplicateCount, 2);
});

await test("directory or symlink-like non-regular primary does not block fallback", () => {
  const notRegular = path.join(tmp, "not-regular.reply.md");
  fs.mkdirSync(notRegular);
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: notRegular,
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: basic,
  });
  assert.equal(result.source, "rollout-fallback");
});

await test("abort, null final, missing candidate, and filedrop are explicit none outcomes", () => {
  const aborted = harvestDispatch({
    dispatchId: "2000000000-2-abcdef0123456789",
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: basic,
  });
  const noFinal = harvestDispatch({
    dispatchId: "3000000000-3-abcdef0123456789",
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: basic,
  });
  const missing = harvestDispatch({
    dispatchId: dispatch,
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: path.join(tmp, "missing-root"),
  });
  const filedrop = harvestDispatch({ dispatchId: dispatch, threadId: "filedrop" });
  assert.deepEqual(
    [aborted.reason, noFinal.reason, missing.reason, filedrop.reason],
    ["unavailable", "unavailable", "unavailable", "unavailable"],
  );
});

await test("pending, ambiguous, and unparseable fallback reasons remain distinct", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const base = [
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/8100000000-8-abcdef0123456789.task.md and proceed" } },
  ];
  const make = (name, lines) => {
    const target = path.join(tmp, `rollout-${name}-${owner}.jsonl`);
    fs.writeFileSync(target, `${lines.join("\n")}\n`);
    return target;
  };
  const prefix = base.map((item) => JSON.stringify(item));
  const pendingPath = make("pending", prefix);
  const ambiguousPath = make("ambiguous", [
    ...prefix,
    JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "intervening" } }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: null } }),
  ]);
  const unparseablePath = make("unparseable", [
    ...prefix,
    "{bad json}",
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: null } }),
  ]);
  const collect = (rolloutPath) => harvestDispatch({
    dispatchId: "8100000000-8-abcdef0123456789",
    threadId: owner,
    rolloutPath,
  }).reason;
  assert.deepEqual(
    [collect(pendingPath), collect(ambiguousPath), collect(unparseablePath)],
    ["pending", "ambiguous", "unparseable"],
  );
});

await test("distinct physical candidates fail visible as ambiguous", () => {
  const root = path.join(tmp, "harvest-ambiguous");
  for (const dir of ["a", "b"]) {
    const target = path.join(root, dir, path.basename(basic));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(basic, target);
  }
  const result = harvestDispatch({
    dispatchId: dispatch,
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: root,
  });
  assert.equal(result.source, "none");
  assert.equal(result.reason, "ambiguous");
});

await test("observer reports admission hit without requiring completion", async () => {
  const target = path.join(tmp, "rollout-observe-11111111-1111-4111-8111-111111111111.jsonl");
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } })}\n`);
  let now = 0;
  let sleeps = 0;
  const result = await observeRollout(
    {
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: "8000000000-8-abcdef0123456789",
      rolloutPath: target,
      budgetMs: 10,
      intervalMs: 2,
    },
    {
      now: () => now,
      sleep: async (ms) => {
        sleeps += 1;
        now += ms;
        if (sleeps === 1) {
          fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "read C:/x/8000000000-8-abcdef0123456789.task.md and proceed" } })}\n`);
        }
      },
    },
  );
  assert.equal(result.token, "rollout-hit");
  assert.equal(sleeps, 1);
});

await test("observer preserves a hit parsed before hard-deadline expiry", async () => {
  const target = path.join(tmp, "rollout-deadline-hit-11111111-1111-4111-8111-111111111111.jsonl");
  const prefix = [
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/8050000000-8-abcdef0123456789.task.md and proceed" } },
  ].map((item) => JSON.stringify(item)).join("\n");
  fs.writeFileSync(target, `${prefix}\n${" ".repeat(300000)}`);
  let ticks = 0;
  const result = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: "8050000000-8-abcdef0123456789",
    rolloutPath: target,
    budgetMs: 4,
    intervalMs: 1,
  }, { now: () => ++ticks, sleep: async () => {} });
  assert.equal(result.token, "rollout-hit");
});

await test("observer distinguishes pending from unavailable with fake time", async () => {
  let now = 0;
  const deps = {
    now: () => now,
    sleep: async (ms) => {
      now += ms;
    },
  };
  const pending = await observeRollout(
    {
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: "8888888888-8-abcdef0123456789",
      rolloutPath: basic,
      budgetMs: 5,
      intervalMs: 2,
    },
    deps,
  );
  const unavailable = await observeRollout(
    {
      threadId: "22222222-2222-4222-8222-222222222222",
      dispatchId: dispatch,
      sessionsRoot: path.join(tmp, "missing-observer-root"),
      budgetMs: 5,
      intervalMs: 2,
    },
    { ...deps, now: () => 0, sleep: async () => {} },
  );
  assert.equal(pending.token, "rollout-pending");
  assert.equal(unavailable.token, "rollout-unavailable");
});

await test("observer rejects agent-only, substring, ambiguous, and malformed evidence", async () => {
  let now = 0;
  const deps = { now: () => now, sleep: async (ms) => { now += ms; } };
  const agentOnly = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: "9999999999-9-ffffffffffffffff",
    rolloutPath: basic,
    budgetMs: 2,
    intervalMs: 1,
  }, deps);
  now = 0;
  const substring = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: "1000000000-1-abcdef012345678",
    rolloutPath: basic,
    budgetMs: 2,
    intervalMs: 1,
  }, deps);

  const ambiguousRoot = path.join(tmp, "observer-ambiguous");
  for (const dir of ["a", "b"]) {
    const target = path.join(ambiguousRoot, dir, path.basename(basic));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(basic, target);
  }
  const ambiguous = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: dispatch,
    sessionsRoot: ambiguousRoot,
    budgetMs: 2,
    intervalMs: 1,
  }, deps);

  const malformedPath = path.join(tmp, "rollout-observer-bad-22222222-2222-4222-8222-222222222222.jsonl");
  fs.writeFileSync(malformedPath, `${JSON.stringify({ type: "session_meta", payload: { id: "22222222-2222-4222-8222-222222222222" } })}\n{bad json}\n`);
  now = 0;
  const malformed = await observeRollout({
    threadId: "22222222-2222-4222-8222-222222222222",
    dispatchId: dispatch,
    rolloutPath: malformedPath,
    budgetMs: 2,
    intervalMs: 1,
  }, deps);
  assert.deepEqual(
    [agentOnly.token, substring.token, ambiguous.token, malformed.token],
    ["rollout-pending", "rollout-pending", "rollout-unavailable", "rollout-unavailable"],
  );
});

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
then
  echo "FAIL: Node harvester/observer suite failed" >&2
  exit 1
fi

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== Observer CLI contract =="
BASIC="$FIXTURES/rollout-basic-11111111-1111-4111-8111-111111111111.jsonl"
ERR="$TMP/observer.err"
OUT="$(CODEX_IPC_OBSERVE_INTERVAL_MS=0 node "$OBSERVER" \
  --thread 11111111-1111-4111-8111-111111111111 \
  --dispatch 1000000000-1-abcdef0123456789 --rollout-path "$BASIC" 2>"$ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == "rollout-hit" && "$(wc -l < <(printf '%s\n' "$OUT"))" -eq 1 ]] \
  && grep -qi 'warning.*interval' "$ERR" && ok "exact one-line hit token; invalid env warns on stderr" \
  || no "observer hit/stdout/warning contract (rc=$RC out=$OUT)"
OUT="$(node "$OBSERVER" --thread bad --dispatch x 2>"$ERR")"; RC=$?
[[ $RC -ne 0 && -z "$OUT" ]] && ok "usage error is nonzero with no outcome token" || no "usage error contract (rc=$RC out=$OUT)"
OUT="$(CODEX_IPC_ROLLOUT_MAX_RECORD_BYTES=1 node "$OBSERVER" \
  --thread 11111111-1111-4111-8111-111111111111 --dispatch 8888888888-8-abcdef0123456789 \
  --rollout-path "$BASIC" --budget-ms 50 --interval-ms 10 2>"$ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == "rollout-unavailable" ]] \
  && ok "schema/record-cap failure maps to unavailable with exit 0" || no "observer cap mapping (rc=$RC out=$OUT)"

echo "== Viewer dual-source integration =="
IPCROOT="$TMP/ipc"; SESSIONS="$TMP/sessions"; SID=s1; THREAD=11111111-1111-4111-8111-111111111111
mkdir -p "$IPCROOT/$SID/$THREAD" "$SESSIONS/2026/07/09"
cp "$BASIC" "$SESSIONS/2026/07/09/$(basename "$BASIC")"
printf 'task' > "$IPCROOT/$SID/$THREAD/1000000000-1-abcdef0123456789.task.md"
manifest(){ find "$IPCROOT" -printf '%p|%s|%T@\n' | sort; }
before="$(manifest)"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" 2>&1)"; RC=$?
after="$(manifest)"
[[ $RC -eq 0 && "$before" == "$after" && "$OUT" == *"source=rollout-fallback"* \
  && "$OUT" == *"latest final"* && ! -e "$IPCROOT/$SID/$THREAD/1000000000-1-abcdef0123456789.reply.md" ]] \
  && ok "rollout fallback is labeled, rendered, stdout-only, and read-only" \
  || no "viewer rollout fallback (rc=$RC)"
printf 'PRIMARY-CONFLICT' > "$IPCROOT/$SID/$THREAD/1000000000-1-abcdef0123456789.reply.md"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-CONFLICT"* \
  && "$OUT" != *"latest final"* ]] && ok "reply file wins without body comparison" \
  || no "viewer source precedence (rc=$RC)"
BIN_UNREADABLE="$TMP/bin-unreadable"; mkdir -p "$BIN_UNREADABLE"; REAL_HEAD="$(command -v head)"
cat > "$BIN_UNREADABLE/head" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-c" && "\${2:-}" == "0" ]]; then exit 1; fi
exec "$REAL_HEAD" "\$@"
EOF
chmod +x "$BIN_UNREADABLE/head"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" PATH="$BIN_UNREADABLE:$PATH" bash "$VIEWER" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=rollout-fallback"* && "$OUT" == *"latest final"* \
  && "$OUT" != *"PRIMARY-CONFLICT"* ]] && ok "unreadable primary is fallback-eligible" \
  || no "viewer unreadable-primary fallback (rc=$RC)"
BIN_RACE="$TMP/bin-race"; mkdir -p "$BIN_RACE"
cat > "$BIN_RACE/head" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-c" && "\${2:-}" == "0" ]]; then exit 0; fi
exit 1
EOF
chmod +x "$BIN_RACE/head"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" PATH="$BIN_RACE:$PATH" bash "$VIEWER" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"became unreadable during render"* ]] \
  && ok "mid-render primary race stays visible with exit 0" || no "primary render race (rc=$RC)"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" --paths-only 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" != *"PRIMARY-CONFLICT"* && "$OUT" != *"latest final"* ]] \
  && ok "paths-only remains body-free" || no "paths-only fallback gate (rc=$RC)"

echo "== Fallback renderer, retention boundary, and deterministic output =="
THREAD2=22222222-2222-4222-8222-222222222222; DISPATCH2=8200000000-8-abcdef0123456789
mkdir -p "$IPCROOT/$SID/$THREAD2"
printf 'task' > "$IPCROOT/$SID/$THREAD2/$DISPATCH2.task.md"
ROLLOUT2="$SESSIONS/2026/07/09/rollout-safe-$THREAD2.jsonl"
node - "$ROLLOUT2" <<'NODE'
const fs = require("node:fs");
const target = process.argv[2];
const owner = "22222222-2222-4222-8222-222222222222";
const turn = "00000000-0000-4000-8000-00000000c0de";
const dispatch = "8200000000-8-abcdef0123456789";
const body = "AB\u001b[31mCD\u0000EFGHIJKLMNOP";
const records = [
  { type: "session_meta", payload: { id: owner } },
  { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
  { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${dispatch}.task.md and proceed` } },
  { type: "event_msg", payload: { type: "agent_message", message: body, phase: "final_answer" } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: body } },
];
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$THREAD2" --max-bytes 12 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=rollout-fallback"* && "$OUT" == *'\x1B'* \
  && "$OUT" == *'\x00'* && "$OUT" == *"truncated at 12 B"* ]] \
  && ok "fallback controls are inert and truncation uses source bytes" \
  || no "fallback safe renderer/truncation (rc=$RC)"
BIN_DECODE="$TMP/bin-decode"; mkdir -p "$BIN_DECODE"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN_DECODE/base64"; chmod +x "$BIN_DECODE/base64"
OUT_DECODE="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" PATH="$BIN_DECODE:$PATH" bash "$VIEWER" -c "$THREAD2" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT_DECODE" == *"could not be decoded safely"* ]] \
  && ok "fallback decode failure stays visible with exit 0" || no "fallback decode guard (rc=$RC)"
OUT2="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$THREAD2" --max-bytes 12 2>&1)"; RC=$?
NORM1="$(printf '%s\n' "$OUT" | grep -v '^# captured:')"
NORM2="$(printf '%s\n' "$OUT2" | grep -v '^# captured:')"
[[ $RC -eq 0 && "$NORM1" == "$NORM2" ]] && ok "unchanged fallback reruns are deterministic" \
  || no "fallback determinism (rc=$RC)"

THREAD3=33333333-3333-4333-8333-333333333333
mkdir -p "$IPCROOT/$SID/$THREAD3"
cp "$FIXTURES/rollout-superseded-$THREAD3.jsonl" "$SESSIONS/2026/07/09/rollout-pruned-$THREAD3.jsonl"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" != *"5000000000-5-abcdef0123456789"* && "$OUT" != *"must not escape"* ]] \
  && ok "persistent rollout cannot resurrect a pruned task envelope" \
  || no "retention boundary (rc=$RC)"

mkdir -p "$IPCROOT/snode/filedrop"; printf 'task' > "$IPCROOT/snode/filedrop/no-node.task.md"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID=snode PATH="/usr/bin:/bin" \
  bash "$VIEWER" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=none | reason=unavailable"* ]] \
  && ok "Node absence degrades only fallback eligibility" || no "no-Node fallback note (rc=$RC)"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit $FAIL
