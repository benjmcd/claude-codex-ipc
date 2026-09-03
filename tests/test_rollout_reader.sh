#!/usr/bin/env bash
# Hermetic W1 parser/locator verification. No host sessions, IPC, network, or writes outside TMP.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node is unavailable; rollout reader tests require optional Node."
    exit 0
fi

MODULE=""
for candidate in \
    "$DIR/../skills/ipc/scripts/codex_ipc_rollout_reader.mjs" \
    "$DIR/../scripts/codex_ipc_rollout_reader.mjs"; do
    [[ -f "$candidate" ]] && MODULE="$candidate" && break
done
[[ -n "$MODULE" ]] || { echo "FAIL: codex_ipc_rollout_reader.mjs not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODULE="$MODULE" FIXTURES="$DIR/fixtures/rollout" TMPDIR_TEST="$TMP" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const api = await import(pathToFileURL(process.env.MODULE));
const proofApi = await import(
  pathToFileURL(path.join(path.dirname(process.env.MODULE), "codex_ipc_write_proof.mjs")),
);
const {
  DEFAULT_MAX_RECORD_BYTES,
  correlateDispatch,
  createTurnBoundaryAccumulator,
  inspectRolloutMarker,
  inspectRolloutNoGrowth,
  isCompleteReaderCursor,
  locateRollout,
  normalizeRolloutRecord,
  parseRolloutBasename,
  pollRolloutForMarker,
  readRolloutActivity,
  readRolloutFile,
  recordThreadIdentity,
  summarizeThreadActivity,
} = api;
const {
  authorizeBaselineAndSend,
  collectPostSendEvidence,
  validatePreSendSnapshot,
} = proofApi;

let passed = 0;
function test(name, fn) {
  try {
    const result = fn();
    if (result && typeof result.then === "function") {
      return result.then(() => {
        passed += 1;
        console.log(`PASS: ${name}`);
      });
    }
    passed += 1;
    console.log(`PASS: ${name}`);
  } catch (error) {
    console.error(`FAIL: ${name}`);
    throw error;
  }
}

const fixtures = process.env.FIXTURES;
const tmp = process.env.TMPDIR_TEST;
function trustedPreSendSnapshot(threadId, rolloutPath) {
  return {
    ok: true,
    targetThreadId: threadId,
    config: { exists: true, stableDuringRead: true },
    db: {
      exists: true,
      readOnlyOpenOk: true,
      stableDuringRead: true,
      quickCheck: "ok",
      threads: {
        target: {
          exists: true,
          id: threadId,
          archived: 0,
          rolloutPath,
        },
        threadRowHashById: { [threadId]: "synthetic-row-hash" },
      },
    },
  };
}
const basicPath = path.join(
  fixtures,
  "rollout-basic-11111111-1111-4111-8111-111111111111.jsonl",
);
const nestedPath = path.join(
  fixtures,
  "rollout-nested-22222222-2222-4222-8222-222222222222.jsonl",
);
const supersededPath = path.join(
  fixtures,
  "rollout-superseded-33333333-3333-4333-8333-333333333333.jsonl",
);

test("module exports bounded built-in-only reader API", () => {
  assert.equal(typeof readRolloutFile, "function");
  assert.equal(typeof isCompleteReaderCursor, "function");
  assert.equal(typeof inspectRolloutNoGrowth, "function");
  assert.equal(typeof locateRollout, "function");
  assert.equal(typeof parseRolloutBasename, "function");
  assert.equal(typeof correlateDispatch, "function");
  assert.equal(typeof recordThreadIdentity, "function");
  assert.ok(DEFAULT_MAX_RECORD_BYTES > 20 * 1024 * 1024);
});

test("record ownership ignores nested business data outside event item carriers", () => {
  assert.deepEqual(recordThreadIdentity({
    type: "response_item",
    payload: {
      type: "message",
      item: { thread_id: "not-an-owner-field" },
    },
  }), { status: "absent", threadId: null });
  assert.deepEqual(recordThreadIdentity({
    type: "event_msg",
    payload: {
      type: "task_complete",
      item: { thread_id: "not-an-owner-field" },
    },
  }), { status: "absent", threadId: null });
});

test("irrelevant response bodies and raw JSON are not retained", () => {
  const target = path.join(tmp, "rollout-noise-00000000-0000-4000-8000-000000000000.jsonl");
  const records = [
    { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } },
    { type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "x".repeat(1024 * 1024) }] } },
    { type: "event_msg", payload: { type: "token_count", info: { total: 1 } } },
  ];
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  assert.equal(parsed.ok, true);
  assert.equal(
    parsed.records.some(
      (item) => item.envelopeType === "response_item" && item.payloadType === "message",
    ),
    false,
  );
  assert.equal(parsed.records.some((item) => Object.hasOwn(item, "raw")), false);
});

test("repair RED: current response compaction normalizes as known and inert", () => {
  const normalized = normalizeRolloutRecord({
    type: "response_item",
    payload: {
      type: "compaction",
      id: "sanitized-compaction",
      encrypted_content: "sanitized",
      internal_chat_message_metadata_passthrough: null,
    },
  });
  assert.equal(normalized.knownPair, true);
  assert.equal(normalized.payloadType, "compaction");
  assert.equal(normalized.text, "");
});

test("reader can stream normalized records without retaining them", () => {
  const streamed = [];
  const parsed = readRolloutFile(basicPath, {
    retainRecords: false,
    onRecord: (item) => streamed.push(item),
  });
  assert.equal(parsed.ok, true);
  assert.equal(parsed.records.length, 0);
  assert.ok(streamed.some((item) => item.payloadType === "user_message"));
  assert.ok(streamed.every((item) => !Object.hasOwn(item, "raw")));
});

const basic = readRolloutFile(basicPath);
test("direct records normalize with drift diagnostics", () => {
  assert.equal(basic.ok, true);
  assert.equal(basic.partialTail, false);
  assert.ok(basic.diagnostics.some((item) => item.code === "schema-drift"));
  assert.ok(
    basic.records.some(
      (item) => item.envelopeType === "response_item" && item.payloadType === "agent_message",
    ),
  );
});

test("latest completed duplicate wins and response duplicates are ignored", () => {
  const result = correlateDispatch(basic, "1000000000-1-abcdef0123456789");
  assert.equal(result.status, "complete");
  assert.equal(result.text, "latest final");
  assert.equal(result.turnId, "33333333-3333-4333-8333-333333333333");
  assert.equal(result.duplicateCount, 2);
  assert.equal(result.finalMessageCount, 1);
  assert.deepEqual(result.latestOccurrence, {
    status: "complete",
    harvestStatus: "complete",
    reason: null,
    certifiable: true,
    settled: true,
    markerLine: 11,
    terminalLine: 14,
    turnId: "33333333-3333-4333-8333-333333333333",
  });
});

test("completed precedence remains monotone while a later duplicate is disclosed as unsettled", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const firstTurn = "11111111-1111-4111-8111-111111111111";
  const secondTurn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "1100000000-1-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const target = path.join(tmp, `rollout-mixed-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: firstTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: firstTurn, phase: "final_answer", message: "older certified body" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: firstTurn, last_agent_message: "older certified body" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: secondTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = correlateDispatch(readRolloutFile(target), dispatchId);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "older certified body");
  assert.equal(result.lifecycle.status, "complete");
  assert.equal(result.lifecycle.certifiable, true);
  assert.equal(result.duplicateCount, 2);
  assert.deepEqual(result.latestOccurrence, {
    status: "pending",
    harvestStatus: "none",
    reason: "pending",
    certifiable: false,
    settled: false,
    markerLine: 7,
    terminalLine: null,
    turnId: secondTurn,
  });
  assert.equal(result.freshness.status, "pending");
  assert.equal(result.freshness.settled, false);
});

test("a later unavailable duplicate or orphan exact marker cannot look settled", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const firstTurn = "11111111-1111-4111-8111-111111111111";
  const secondTurn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "1200000000-1-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const completedPrefix = [
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: firstTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: firstTurn, phase: "final_answer", message: "older certified body" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: firstTurn, last_agent_message: "older certified body" } },
  ];
  const cases = [
    [
      "later-conflict",
      [
        { type: "event_msg", payload: { type: "task_started", turn_id: secondTurn } },
        { type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } },
        { type: "event_msg", payload: { type: "agent_message", turn_id: secondTurn, phase: "final_answer", message: "candidate A" } },
        { type: "event_msg", payload: { type: "agent_message", turn_id: secondTurn, phase: "final_answer", message: "candidate B" } },
        { type: "event_msg", payload: { type: "task_complete", turn_id: secondTurn, last_agent_message: "candidate C" } },
      ],
      "unavailable",
      null,
    ],
    [
      "orphan-marker",
      [{ type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } }],
      "unparseable",
      null,
    ],
  ];
  for (const [name, suffix, reason, uncertaintyReason] of cases) {
    const target = path.join(tmp, `rollout-mixed-${name}-${owner}.jsonl`);
    fs.writeFileSync(target, `${[...completedPrefix, ...suffix].map((item) => JSON.stringify(item)).join("\n")}\n`);
    const result = correlateDispatch(readRolloutFile(target), dispatchId);
    assert.equal(result.status, "complete", name);
    assert.equal(result.lifecycle.status, "complete", name);
    assert.equal(result.latestOccurrence.status, "unavailable", name);
    assert.equal(result.latestOccurrence.reason, reason, name);
    assert.equal(result.latestOccurrence.settled, false, name);
    assert.equal(result.latestOccurrence.uncertaintyReason || null, uncertaintyReason, name);
    assert.equal(result.freshness.status, "unavailable", name);
    assert.equal(result.freshness.settled, false, name);
  }

});

test("unknown or malformed tail makes current activity ambiguous without revoking history", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "11111111-1111-4111-8111-111111111111";
  const dispatchId = "1250000000-1-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const completed = [
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: "certified body" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "certified body" } },
  ];
  for (const [name, tail] of [
    ["schema", `${JSON.stringify({ type: "event_msg", payload: { type: "future_lifecycle_event" } })}\n`],
    ["malformed", "{\"type\":\n"],
    ["orphan-user", `${JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "new unbound work" } })}\n`],
  ]) {
    const target = path.join(tmp, `rollout-tail-${name}-${owner}.jsonl`);
    fs.writeFileSync(target, `${completed.map((item) => JSON.stringify(item)).join("\n")}\n${tail}`);
    const parsed = readRolloutFile(target);
    const historical = correlateDispatch(parsed, dispatchId);
    assert.equal(historical.status, "complete", name);
    assert.equal(historical.latestOccurrence.settled, true, name);
    if (name === "orphan-user") {
      assert.equal(historical.freshness.settled, true, name);
    } else {
      assert.equal(historical.freshness.status, "unavailable", name);
      assert.equal(historical.freshness.settled, false, name);
      assert.equal(historical.freshness.reason, "post-occurrence-schema-unknown", name);
    }
    const activity = readRolloutActivity(target, { rolloutThreadId: owner });
    assert.equal(activity.turnActivity, "ambiguous", name);
    assert.equal(activity.boundarySnapshot.activity, "ambiguous", name);
  }
});

test("a later certifiable same-dispatch occurrence restores freshness after older opaque schema", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const firstTurn = "11111111-1111-4111-8111-111111111111";
  const secondTurn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "1260000000-1-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const target = path.join(tmp, `rollout-freshness-recovered-${owner}.jsonl`);
  const body = "new certified body";
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: firstTurn, message: "unrelated work" } },
    { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "task_started", turn_id: secondTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: secondTurn, phase: "final_answer", message: body } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: secondTurn, last_agent_message: body } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = correlateDispatch(readRolloutFile(target), dispatchId);
  assert.equal(result.status, "complete");
  assert.equal(result.text, body);
  assert.equal(result.freshness.status, "complete");
  assert.equal(result.freshness.settled, true);
});

test("aborted and null-final completed turns are unavailable", () => {
  assert.equal(
    correlateDispatch(basic, "2000000000-2-abcdef0123456789").reason,
    "unavailable",
  );
  assert.equal(
    correlateDispatch(basic, "3000000000-3-abcdef0123456789").reason,
    "unavailable",
  );
});

test("inter-agent marker cannot correlate a dispatch", () => {
  const target = path.join(
    tmp,
    "rollout-inter-agent-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    {
      type: "response_item",
      payload: {
        type: "agent_message",
        content: "read C:/synthetic/9999999999-9-ffffffffffffffff.task.md and proceed",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = correlateDispatch(
    readRolloutFile(target),
    "9999999999-9-ffffffffffffffff",
  );
  assert.equal(result.status, "none");
  assert.equal(result.reason, "pending");
});

test("turn-id-absent nested shape uses ordered completed window", () => {
  const nested = readRolloutFile(nestedPath);
  const result = correlateDispatch(nested, "4000000000-4-abcdef0123456789");
  assert.equal(result.status, "complete");
  assert.equal(result.text, "nested final");
  assert.equal(result.boundaryMode, "ordered-fallback");
});

test("new start supersedes an unterminated prior turn", () => {
  const parsed = readRolloutFile(supersededPath);
  const result = correlateDispatch(parsed, "5000000000-5-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "turn-superseded"));
});

test("partial tail is held and a later complete append is parsed from the cursor", () => {
  const target = path.join(tmp, "rollout-partial-00000000-0000-4000-8000-000000000000.jsonl");
  const first =
    '{"type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000000"}}\n' +
    '{"type":"event_msg","payload":{"type":"task_started","turn_id":"00000000-0000-4000-8000-00000000c0de"}}\n' +
    '{"type":"event_msg","payload":{"type":"user_message","message":"read C:/x/6000000000-6-abcdef0123456789.task.md and proceed"}}\n' +
    '{"type":"event_msg","payload":{"type":"agent_message","message":"later","phase":"final_answer"}}\n' +
    '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"00000000-0000-4000-8000-00000000c0de","last_agent_message":"later"}';
  fs.writeFileSync(target, first);
  const pending = readRolloutFile(target);
  assert.equal(pending.partialTail, true);
  assert.equal(correlateDispatch(pending, "6000000000-6-abcdef0123456789").reason, "pending");
  fs.appendFileSync(target, "}\n");
  const completed = readRolloutFile(target, { cursor: pending.cursor });
  assert.equal(completed.ok, true);
  assert.equal(completed.records.length, 1);
  assert.equal(completed.records[0].payloadType, "task_complete");
});

test("partial first physical record remains resumable until its owner anchor can be installed", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-partial-first-${owner}.jsonl`);
  const firstRecord = JSON.stringify({ type: "session_meta", payload: { id: owner } });
  fs.writeFileSync(target, firstRecord);

  const pending = readRolloutFile(target, { rolloutThreadId: owner });
  assert.equal(pending.ok, true);
  assert.equal(pending.partialTail, true);
  assert.equal(pending.cursor.firstRecordSeen, false);
  assert.equal(pending.cursor.firstRecordAnchorEndOffset, null);
  assert.equal(pending.cursor.firstRecordAnchorSha256, null);

  fs.appendFileSync(target, "\n");
  const completed = readRolloutFile(target, {
    cursor: pending.cursor,
    rolloutThreadId: owner,
  });
  assert.equal(completed.ok, true);
  assert.equal(completed.partialTail, false);
  assert.equal(completed.cursor.firstRecordSeen, true);
  assert.ok(completed.cursor.firstRecordAnchorEndOffset > 0);
  assert.match(completed.cursor.firstRecordAnchorSha256, /^[0-9a-f]{64}$/);
  assert.equal(isCompleteReaderCursor(completed.cursor), true);
});

test("repair RED: cursor partial bytes cannot synthesize a second physical record", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const dispatch = "6001000000-6-abcdef0123456789";
  const target = path.join(tmp, `rollout-partial-forged-second-${owner}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\nSANITIZED_INERT_PARTIAL`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.partialTail, true);
  assert.equal(baseline.cursor.firstRecordSeen, true);

  const forgedPrefix = JSON.stringify({
    type: "event_msg",
    payload: { type: "task_started", turn_id: turn },
  }).slice(0, -2);
  const forged = {
    ...baseline.cursor,
    partialBase64: Buffer.from(forgedPrefix).toString("base64"),
  };
  fs.appendFileSync(target, `${[
    "}}",
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "agent_message",
        turn_id: turn,
        phase: "final_answer",
        message: "must-not-certify",
      },
    }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: turn,
        last_agent_message: "must-not-certify",
      },
    }),
  ].join("\n")}\n`);

  const resumed = readRolloutFile(target, { cursor: forged });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  const mismatch = resumed.diagnostics.find(
    (item) => item.code === "rollout-prefix-cursor-mismatch",
  );
  assert.ok(mismatch);
  assert.deepEqual(Object.keys(mismatch).sort(), ["code", "path", "reason"]);
  assert.equal(JSON.stringify(mismatch).includes("must-not-certify"), false);

  const fresh = readRolloutFile(target);
  assert.equal(correlateDispatch(fresh, dispatch).status, "none");
});

test("repair RED: cursor partial bytes cannot synthesize the first physical record", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const dispatch = "6002000000-6-abcdef0123456789";
  const target = path.join(tmp, `rollout-partial-forged-first-${owner}.jsonl`);
  fs.writeFileSync(target, "SANITIZED_INERT_FIRST");
  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: owner,
  });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.cursor.firstRecordSeen, false);
  const forged = {
    ...baseline.cursor,
    partialBase64: Buffer.from(
      JSON.stringify({ type: "session_meta", payload: { id: owner } }),
    ).toString("base64"),
  };
  fs.appendFileSync(target, `${[
    "",
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: turn } }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "agent_message",
        turn_id: turn,
        phase: "final_answer",
        message: "must-not-certify",
      },
    }),
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: turn,
        last_agent_message: "must-not-certify",
      },
    }),
  ].join("\n")}\n`);

  const resumed = readRolloutFile(target, {
    cursor: forged,
    rolloutThreadId: owner,
  });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  assert.equal(
    resumed.diagnostics.some((item) => item.code === "rollout-prefix-cursor-mismatch"),
    true,
  );
});

test("repair RED: cursor line count and last timestamp are prefix-derived", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-cursor-derived-scalars-${owner}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({
    timestamp: "2026-08-20T00:00:00.000Z",
    type: "session_meta",
    payload: { id: owner },
  })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.cursor.lineNumber, 1);
  assert.equal(baseline.cursor.lastTimestamp, Date.parse("2026-08-20T00:00:00.000Z"));

  for (const [name, cursor] of [
    ["line", { ...baseline.cursor, lineNumber: baseline.cursor.lineNumber + 1 }],
    ["timestamp", { ...baseline.cursor, lastTimestamp: baseline.cursor.lastTimestamp + 1 }],
  ]) {
    const resumed = readRolloutFile(target, { cursor });
    assert.equal(resumed.ok, false, name);
    assert.equal(resumed.reason, "invalid-cursor", name);
    assert.equal(
      resumed.diagnostics.some((item) => item.code === "rollout-prefix-cursor-mismatch"),
      true,
      name,
    );
  }
});

test("repair RED: invalid cursor partial base64 fails closed", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-cursor-invalid-base64-${owner}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.cursor.partialBase64, "");

  const resumed = readRolloutFile(target, {
    cursor: { ...baseline.cursor, partialBase64: "!!!!" },
  });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  assert.equal(
    resumed.diagnostics.some((item) => item.code === "rollout-prefix-cursor-mismatch"),
    true,
  );
});

test("repair RED: oversized cursor partial base64 is rejected before decode", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-cursor-oversized-base64-${owner}.jsonl`);
  const maxRecordBytes = 256;
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false, maxRecordBytes });
  assert.equal(baseline.ok, true);
  const oversized = "A".repeat(Math.ceil(maxRecordBytes / 3) * 4 + 4);
  const originalBufferFrom = Buffer.from;
  let decodedOversizedCursor = false;
  Buffer.from = function instrumentedBufferFrom(value, ...args) {
    if (value === oversized && args[0] === "base64") decodedOversizedCursor = true;
    return originalBufferFrom(value, ...args);
  };
  let resumed;
  try {
    resumed = readRolloutFile(target, {
      cursor: { ...baseline.cursor, partialBase64: oversized },
      maxRecordBytes,
    });
  } finally {
    Buffer.from = originalBufferFrom;
  }
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  assert.equal(decodedOversizedCursor, false);
});

test("unpadded equivalent cursor partial base64 remains resumable", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-cursor-unpadded-base64-${owner}.jsonl`);
  const secondRecord = JSON.stringify({ type: "event_msg", payload: { type: "token_count" } });
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n${secondRecord[0]}`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.match(baseline.cursor.partialBase64, /={1,2}$/);
  const unpaddedCursor = {
    ...baseline.cursor,
    partialBase64: baseline.cursor.partialBase64.replace(/=+$/, ""),
  };
  fs.appendFileSync(target, `${secondRecord.slice(1)}\n`);

  const resumed = readRolloutFile(target, { cursor: unpaddedCursor });
  const fresh = readRolloutFile(target);
  assert.equal(resumed.ok, true);
  assert.deepEqual(resumed.cursor, fresh.cursor);
});

test("valid partial resume is cursor-equivalent to a fresh full read", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const dispatch = "6003000000-6-abcdef0123456789";
  const target = path.join(tmp, `rollout-partial-equivalence-${owner}.jsonl`);
  const started = JSON.stringify({
    timestamp: "2026-08-20T00:00:01.000Z",
    type: "event_msg",
    payload: { type: "task_started", turn_id: turn },
  });
  const split = started.length - 3;
  fs.writeFileSync(
    target,
    `${JSON.stringify({
      timestamp: "2026-08-20T00:00:00.000Z",
      type: "session_meta",
      payload: { id: owner },
    })}\n${started.slice(0, split)}`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.partialTail, true);
  fs.appendFileSync(target, `${[
    started.slice(split),
    JSON.stringify({
      timestamp: "2026-08-20T00:00:02.000Z",
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    }),
    JSON.stringify({
      timestamp: "2026-08-20T00:00:03.000Z",
      type: "event_msg",
      payload: {
        type: "agent_message",
        turn_id: turn,
        phase: "final_answer",
        message: "equivalent-body",
      },
    }),
    JSON.stringify({
      timestamp: "2026-08-20T00:00:04.000Z",
      type: "event_msg",
      payload: {
        type: "task_complete",
        turn_id: turn,
        last_agent_message: "equivalent-body",
      },
    }),
  ].join("\n")}\n`);

  const resumed = readRolloutFile(target, { cursor: baseline.cursor });
  const fresh = readRolloutFile(target);
  assert.equal(resumed.ok, true);
  assert.equal(fresh.ok, true);
  assert.deepEqual(resumed.cursor, fresh.cursor);
  assert.deepEqual(correlateDispatch(resumed, dispatch), correlateDispatch(fresh, dispatch));
});

test("repair RED: empty rollout with an expected owner fails closed without a cursor", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-empty-${owner}.jsonl`);
  fs.writeFileSync(target, "");

  const parsed = readRolloutFile(target, { rolloutThreadId: owner });
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, "rollout-owner-missing");
  assert.equal(parsed.integrityValidated, false);
  assert.equal(parsed.cursor, null);
  assert.ok(
    parsed.diagnostics.some(
      (item) =>
        item.code === "schema-drift" &&
        item.reason === "rollout-thread-id-missing",
    ),
  );
});

test("file shrink under a cursor is fail-visible", () => {
  const target = path.join(tmp, "rollout-shrink-00000000-0000-4000-8000-00000000c0de.jsonl");
  fs.copyFileSync(nestedPath, target);
  const initial = readRolloutFile(target);
  fs.truncateSync(target, 8);
  const result = readRolloutFile(target, { cursor: initial.cursor });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "file-truncated");
});

test("same-identity shrink during an active read is fail-visible", () => {
  const target = path.join(tmp, "rollout-midread-shrink-00000000-0000-4000-8000-000000000000.jsonl");
  fs.copyFileSync(basicPath, target);
  const originalRead = fs.readSync;
  let injected = false;
  fs.readSync = function injectedRead(descriptor, ...args) {
    const bytesRead = originalRead.call(fs, descriptor, ...args);
    if (!injected && bytesRead > 0) {
      injected = true;
      fs.truncateSync(target, 1);
    }
    return bytesRead;
  };
  let result;
  try {
    result = readRolloutFile(target);
  } finally {
    fs.readSync = originalRead;
  }
  assert.equal(result.ok, false);
  assert.equal(result.reason, "file-truncated");
  assert.ok(result.diagnostics.some((item) => item.code === "file-truncated"));
});

test("same-identity rewrite at the cursor boundary is fail-visible", () => {
  const target = path.join(tmp, "rollout-midread-regrow-00000000-0000-4000-8000-000000000000.jsonl");
  fs.copyFileSync(basicPath, target);
  const originalSize = fs.statSync(target).size;
  const originalRead = fs.readSync;
  let injected = false;
  fs.readSync = function injectedRead(descriptor, ...args) {
    const bytesRead = originalRead.call(fs, descriptor, ...args);
    if (!injected && bytesRead > 0 && args[2] > 4096) {
      injected = true;
      fs.writeFileSync(target, Buffer.alloc(originalSize, 0x20));
    }
    return bytesRead;
  };
  let result;
  try {
    result = readRolloutFile(target);
  } finally {
    fs.readSync = originalRead;
  }
  assert.equal(result.ok, false);
  assert.equal(result.reason, "file-replaced");
  assert.ok(result.diagnostics.some((item) => item.code === "content-anchor-changed"));
});

test("over-cap complete record reports path line and byte offset", () => {
  const target = path.join(tmp, "rollout-cap-00000000-0000-4000-8000-000000000000.jsonl");
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } })}\n`);
  fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "agent_message", message: "x".repeat(2048) } })}\n`);
  const result = readRolloutFile(target, { maxRecordBytes: 1024 });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "record-too-large");
  assert.equal(result.diagnostics.at(-1).line, 2);
  assert.equal(typeof result.diagnostics.at(-1).byteOffset, "number");
  assert.equal(result.diagnostics.at(-1).path, target);
});

test("reader deadline fails closed before integrity certification", () => {
  let ticks = 0;
  const result = readRolloutFile(basicPath, {
    deadlineAt: 2,
    now: () => ++ticks,
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "deadline-exceeded");
  assert.equal(result.integrityValidated, false);
});

test("repair RED: resumed consumed-prefix hashing obeys the hard deadline", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-prefix-deadline-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "world_state", payload: { padding: "x".repeat(256 * 1024) } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);

  let prefixChecks = 0;
  const resumed = readRolloutFile(target, {
    cursor: baseline.cursor,
    deadlineAt: 3,
    now: () => {
      if (!(new Error().stack || "").includes("updatePrefixHash")) return 0;
      prefixChecks += 1;
      return prefixChecks >= 2 ? 3 : 0;
    },
    retainRecords: false,
  });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "deadline-exceeded");
  assert.equal(resumed.integrityValidated, false);
  assert.equal(resumed.cursor, null);
  assert.equal(prefixChecks, 2);
});

test("repair RED: final consumed-prefix revalidation obeys the hard deadline", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-final-prefix-deadline-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "world_state", payload: { padding: "x".repeat(256 * 1024) } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  let prefixChecks = 0;
  const parsed = readRolloutFile(target, {
    deadlineAt: 3,
    now: () => {
      if (!(new Error().stack || "").includes("updatePrefixHash")) return 0;
      prefixChecks += 1;
      return prefixChecks >= 2 ? 3 : 0;
    },
    retainRecords: false,
  });
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, "deadline-exceeded");
  assert.equal(parsed.integrityValidated, false);
  assert.equal(parsed.cursor, null);
  assert.equal(prefixChecks, 2);
});

test("malformed complete line inside a target turn is unparseable", () => {
  const target = path.join(tmp, "rollout-malformed-00000000-0000-4000-8000-000000000000.jsonl");
  const lines = [
    { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7000000000-7-abcdef0123456789.task.md and proceed" } },
  ].map((item) => JSON.stringify(item));
  fs.writeFileSync(target, `${lines.join("\n")}\n{bad json}\n${JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: null } })}\n`);
  const result = correlateDispatch(readRolloutFile(target), "7000000000-7-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
});

test("BOM CRLF and UTF-8 are tolerated with visible drift", () => {
  const target = path.join(tmp, "rollout-crlf-00000000-0000-4000-8000-000000000000.jsonl");
  const records = [
    { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7100000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "agent_message", message: "caf\u00e9", phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: "caf\u00e9" } },
  ];
  const encoded = records.map((item) => JSON.stringify(item));
  fs.writeFileSync(target, Buffer.concat([
    Buffer.from([0xef, 0xbb, 0xbf]),
    Buffer.from(`${encoded[0]}\r\n\r\n${encoded.slice(1).join("\r\n")}\r\n`, "utf8"),
  ]));
  const parsed = readRolloutFile(target);
  assert.equal(correlateDispatch(parsed, "7100000000-7-abcdef0123456789").text, "caf\u00e9");
  assert.ok(parsed.diagnostics.some((item) => item.code === "utf8-bom"));
  assert.ok(parsed.diagnostics.some((item) => item.code === "crlf"));
  assert.ok(parsed.diagnostics.some((item) => item.code === "blank-line"));
});

test("invalid UTF-8 is a structured hard error", () => {
  const target = path.join(tmp, "rollout-utf8-00000000-0000-4000-8000-000000000000.jsonl");
  const first = Buffer.from(`${JSON.stringify({ type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } })}\n`);
  fs.writeFileSync(target, Buffer.concat([first, Buffer.from([0xff, 0x0a])]));
  const result = readRolloutFile(target);
  assert.equal(result.ok, false);
  assert.equal(result.reason, "invalid-utf8");
  assert.equal(result.diagnostics.at(-1).line, 2);
  assert.equal(typeof result.diagnostics.at(-1).byteOffset, "number");
});

test("repeated session metadata is tolerated and reruns are deterministic", () => {
  const target = path.join(tmp, "rollout-repeated-00000000-0000-4000-8000-000000000000.jsonl");
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const records = [
    { type: "session_meta", payload: { id: owner } },
    { type: "session_meta", payload: { id: owner, session_id: "synthetic-family" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7150000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "agent_message", message: "repeat-safe", phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "repeat-safe" } },
  ];
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const first = readRolloutFile(target);
  const second = readRolloutFile(target);
  assert.deepEqual(first.records, second.records);
  assert.deepEqual(first.diagnostics, second.diagnostics);
  assert.equal(correlateDispatch(first, "7150000000-7-abcdef0123456789").text, "repeat-safe");
});

test("provenance-linked ancestor metadata is inert while the current owner stays pinned", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const ancestor = "22222222-2222-4222-8222-222222222222";
  const turn = "33333333-3333-4333-8333-333333333333";
  const dispatch = "7151000000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-lineage-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        parent_thread_id: parent,
        forked_from_id: parent,
        subagent_history_start_ordinal: 4,
      },
    },
    { ordinal: 1, type: "session_meta", payload: { id: parent, forked_from_id: ancestor } },
    { ordinal: 2, type: "session_meta", payload: { id: ancestor } },
    { ordinal: 3, type: "session_meta", payload: { id: parent, forked_from_id: ancestor } },
    { ordinal: 4, type: "event_msg", payload: { type: "thread_settings_applied" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  fs.appendFileSync(target, `${[
    { ordinal: 5, type: "event_msg", payload: { type: "task_started", thread_id: owner, turn_id: turn } },
    {
      ordinal: 6,
      type: "event_msg",
      payload: {
        type: "user_message",
        thread_id: owner,
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
    {
      ordinal: 7,
      type: "event_msg",
      payload: {
        type: "agent_message",
        thread_id: owner,
        turn_id: turn,
        phase: "final_answer",
        message: "lineage-safe",
      },
    },
    {
      ordinal: 8,
      type: "event_msg",
      payload: {
        type: "task_complete",
        thread_id: owner,
        turn_id: turn,
        last_agent_message: "lineage-safe",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const observedDelta = [];
  const delta = readRolloutFile(target, {
    cursor: baseline.cursor,
    onObservedRecord: (item) => observedDelta.push(item),
  });
  assert.equal(delta.ok, true);
  assert.equal(delta.records.length, 4);
  assert.equal(observedDelta.length, 4);
  assert.equal(delta.cursor.rolloutThreadId, owner);
  assert.deepEqual(delta.cursor.rolloutLineageIds, [owner, parent, ancestor].sort());
  assert.equal(correlateDispatch(delta, dispatch).text, "lineage-safe");
  assert.equal(readRolloutFile(target).ok, true);

  const foreignLifecycle = path.join(tmp, `rollout-lineage-direct-${owner}.jsonl`);
  fs.writeFileSync(foreignLifecycle, `${[
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        parent_thread_id: parent,
        forked_from_id: parent,
        subagent_history_start_ordinal: 2,
      },
    },
    { ordinal: 1, type: "session_meta", payload: { id: parent } },
    { ordinal: 2, type: "event_msg", payload: { type: "thread_settings_applied" } },
    { ordinal: 3, type: "event_msg", payload: { type: "task_started", thread_id: parent, turn_id: turn } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const rejected = readRolloutFile(foreignLifecycle, { retainRecords: false });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.reason, "rollout-owner-mismatch");

  const parentOnly = path.join(tmp, `rollout-lineage-parent-only-${owner}.jsonl`);
  fs.writeFileSync(parentOnly, `${[
    { type: "session_meta", payload: { id: owner, parent_thread_id: parent } },
    { type: "session_meta", payload: { id: parent } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parentOnlyRejected = readRolloutFile(parentOnly, { retainRecords: false });
  assert.equal(parentOnlyRejected.ok, false);
  assert.equal(parentOnlyRejected.reason, "rollout-owner-mismatch");
});

test("fork history before the producer ordinal cannot certify child dispatch or activity", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const ancestorTurn = "22222222-2222-4222-8222-222222222222";
  const childTurn = "33333333-3333-4333-8333-333333333333";
  const ancestorDispatch = "7152000000-7-abcdef0123456789";
  const childDispatch = "7153000000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-fork-boundary-${owner}.jsonl`);
  const records = [
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        parent_thread_id: parent,
        forked_from_id: parent,
        subagent_history_start_ordinal: 6,
      },
    },
    { ordinal: 1, type: "session_meta", payload: { id: parent } },
    { ordinal: 2, type: "event_msg", payload: { type: "task_started", turn_id: ancestorTurn } },
    { ordinal: 3, type: "event_msg", payload: { type: "user_message", turn_id: ancestorTurn, message: `read C:/x/${ancestorDispatch}.task.md and proceed` } },
    { ordinal: 4, type: "event_msg", payload: { type: "agent_message", turn_id: ancestorTurn, phase: "final_answer", message: "ancestor body" } },
    { ordinal: 5, type: "event_msg", payload: { type: "task_complete", turn_id: ancestorTurn, last_agent_message: "ancestor body" } },
    { ordinal: 6, type: "event_msg", payload: { type: "thread_settings_applied" } },
    { ordinal: 7, type: "event_msg", payload: { type: "task_started", turn_id: childTurn } },
    { ordinal: 8, type: "event_msg", payload: { type: "user_message", turn_id: childTurn, message: `read C:/x/${childDispatch}.task.md and proceed` } },
    { ordinal: 9, type: "event_msg", payload: { type: "agent_message", turn_id: childTurn, phase: "final_answer", message: "child body" } },
    { ordinal: 10, type: "event_msg", payload: { type: "task_complete", turn_id: childTurn, last_agent_message: "child body" } },
  ];
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);

  const parsed = readRolloutFile(target);
  assert.equal(parsed.ok, true);
  assert.equal(correlateDispatch(parsed, ancestorDispatch).status, "none");
  assert.equal(correlateDispatch(parsed, childDispatch).status, "complete");
  assert.equal(correlateDispatch(parsed, childDispatch).text, "child body");
  assert.equal(inspectRolloutMarker(target, "ancestor body").taskCompleteAfterAgentMarker, false);
  const activity = readRolloutActivity(target, { rolloutThreadId: owner });
  assert.equal(activity.parsed.ok, true);
  assert.equal(activity.turnActivity, "closed");
});

test("repair RED: a fork cursor cannot be retyped as nonfork to admit unordinal growth", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatch = "7153500000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-fork-cursor-mode-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        forked_from_id: parent,
        subagent_history_start_ordinal: 1,
      },
    },
    { ordinal: 1, type: "event_msg", payload: { type: "thread_settings_applied" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);

  const forged = {
    ...baseline.cursor,
    forkHistoryScope: {
      mode: "nonfork",
      forkedFromId: null,
      startOrdinal: null,
      nextOrdinal: null,
      boundarySeen: false,
    },
  };
  fs.appendFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", thread_id: owner, turn_id: turn } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        thread_id: owner,
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "agent_message",
        thread_id: owner,
        turn_id: turn,
        phase: "final_answer",
        message: "must-not-certify",
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "task_complete",
        thread_id: owner,
        turn_id: turn,
        last_agent_message: "must-not-certify",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const resumed = readRolloutFile(target, { cursor: forged });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  const mismatch = resumed.diagnostics.find(
    (item) => item.code === "fork-history-cursor-mismatch",
  );
  assert.ok(mismatch);
  assert.deepEqual(Object.keys(mismatch).sort(), ["code", "path", "reason"]);
  assert.equal(JSON.stringify(mismatch).includes("must-not-certify"), false);
});

test("repair RED: a fork cursor next ordinal is bound to its consumed prefix", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatch = "7153600000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-fork-cursor-ordinal-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        forked_from_id: parent,
        subagent_history_start_ordinal: 2,
      },
    },
    { ordinal: 1, type: "session_meta", payload: { id: parent } },
    { ordinal: 2, type: "event_msg", payload: { type: "thread_settings_applied" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  assert.equal(baseline.cursor.forkHistoryScope.nextOrdinal, 3);

  const forged = {
    ...baseline.cursor,
    forkHistoryScope: {
      ...baseline.cursor.forkHistoryScope,
      nextOrdinal: 100,
    },
  };
  fs.appendFileSync(target, `${[
    { ordinal: 100, type: "event_msg", payload: { type: "task_started", thread_id: owner, turn_id: turn } },
    {
      ordinal: 101,
      type: "event_msg",
      payload: {
        type: "user_message",
        thread_id: owner,
        turn_id: turn,
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
    {
      ordinal: 102,
      type: "event_msg",
      payload: {
        type: "agent_message",
        thread_id: owner,
        turn_id: turn,
        phase: "final_answer",
        message: "must-not-certify",
      },
    },
    {
      ordinal: 103,
      type: "event_msg",
      payload: {
        type: "task_complete",
        thread_id: owner,
        turn_id: turn,
        last_agent_message: "must-not-certify",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const genuine = readRolloutFile(target, { cursor: baseline.cursor });
  assert.equal(genuine.ok, false);
  assert.equal(genuine.reason, "rollout-history-boundary-invalid");
  for (const [name, scope] of [
    [
      "parent",
      {
        ...baseline.cursor.forkHistoryScope,
        forkedFromId: "33333333-3333-4333-8333-333333333333",
      },
    ],
    [
      "boundary",
      {
        ...baseline.cursor.forkHistoryScope,
        startOrdinal: 1,
      },
    ],
  ]) {
    const rejected = readRolloutFile(target, {
      cursor: { ...baseline.cursor, forkHistoryScope: scope },
    });
    assert.equal(rejected.ok, false, name);
    assert.equal(rejected.reason, "invalid-cursor", name);
    assert.equal(
      rejected.diagnostics.some((item) => item.code === "fork-history-cursor-mismatch"),
      true,
      name,
    );
  }
  const resumed = readRolloutFile(target, { cursor: forged });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  assert.equal(
    resumed.diagnostics.some((item) => item.code === "fork-history-cursor-mismatch"),
    true,
  );
});

await test("repair RED: a nonfork cursor owner and lineage are bound to its consumed prefix", async () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const forgedOwner = "11111111-1111-4111-8111-111111111111";
  const forgedAncestor = "33333333-3333-4333-8333-333333333333";
  const turn = "22222222-2222-4222-8222-222222222222";
  const marker = "SANITIZED_CURSOR_OWNER_MARKER";
  const target = path.join(tmp, `rollout-cursor-owner-nonfork-${owner}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n`,
  );
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  fs.appendFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: marker } },
    {
      type: "event_msg",
      payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: marker },
    },
    {
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turn, last_agent_message: marker },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const forgedCursor = {
    ...baseline.cursor,
    rolloutThreadId: forgedOwner,
    rolloutLineageIds: [forgedOwner],
  };
  const resumed = readRolloutFile(target, {
    cursor: forgedCursor,
    rolloutThreadId: forgedOwner,
  });
  assert.equal(resumed.ok, false);
  assert.equal(resumed.reason, "invalid-cursor");
  const mismatch = resumed.diagnostics.find(
    (item) => item.code === "rollout-owner-cursor-mismatch",
  );
  assert.ok(mismatch);
  assert.deepEqual(Object.keys(mismatch).sort(), ["code", "path", "reason"]);
  assert.equal(JSON.stringify(mismatch).includes(marker), false);

  const forgedLineage = readRolloutFile(target, {
    cursor: {
      ...baseline.cursor,
      rolloutLineageIds: [owner, forgedAncestor].sort(),
    },
    rolloutThreadId: owner,
  });
  assert.equal(forgedLineage.ok, false);
  assert.equal(forgedLineage.reason, "invalid-cursor");

  const proof = await pollRolloutForMarker(target, marker, 10, 1, {
    cursor: forgedCursor,
    expectedTurnId: turn,
    expectedThreadId: forgedOwner,
    now: () => 0,
    sleep: async () => {},
  });
  assert.equal(proof.ok, false);
});

test("repair RED: a fork cursor owner and lineage are bound to its consumed prefix", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const forgedOwner = "22222222-2222-4222-8222-222222222222";
  const forgedAncestor = "33333333-3333-4333-8333-333333333333";
  const turn = "00000000-0000-4000-8000-00000000c0de";
  const marker = "SANITIZED_FORK_CURSOR_OWNER_MARKER";
  const target = path.join(tmp, `rollout-cursor-owner-fork-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    {
      ordinal: 0,
      type: "session_meta",
      payload: {
        id: owner,
        forked_from_id: parent,
        subagent_history_start_ordinal: 1,
      },
    },
    { ordinal: 1, type: "event_msg", payload: { type: "thread_settings_applied" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(baseline.ok, true);
  fs.appendFileSync(target, `${[
    { ordinal: 2, type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    {
      ordinal: 3,
      type: "event_msg",
      payload: { type: "user_message", turn_id: turn, message: marker },
    },
    {
      ordinal: 4,
      type: "event_msg",
      payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: marker },
    },
    {
      ordinal: 5,
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turn, last_agent_message: marker },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  for (const [name, cursor, expectedOwner] of [
    [
      "owner",
      {
        ...baseline.cursor,
        rolloutThreadId: forgedOwner,
        rolloutLineageIds: [forgedOwner, parent].sort(),
      },
      forgedOwner,
    ],
    [
      "lineage",
      {
        ...baseline.cursor,
        rolloutLineageIds: [owner, parent, forgedAncestor].sort(),
      },
      owner,
    ],
  ]) {
    const resumed = readRolloutFile(target, {
      cursor,
      rolloutThreadId: expectedOwner,
    });
    assert.equal(resumed.ok, false, name);
    assert.equal(resumed.reason, "invalid-cursor", name);
    assert.equal(
      resumed.diagnostics.some((item) => item.code === "rollout-owner-cursor-mismatch"),
      true,
      name,
    );
  }
});

test("forks without an exact producer boundary fail closed without timestamp guessing", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-fork-no-boundary-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { ordinal: 0, type: "session_meta", payload: { id: owner, forked_from_id: parent } },
    { ordinal: 1, type: "event_msg", payload: { type: "task_started", thread_id: owner, turn_id: "33333333-3333-4333-8333-333333333333" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = readRolloutFile(target, { rolloutThreadId: owner });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "rollout-history-boundary-missing");
});

test("ordinal-less forks are read as non-forks rather than refused", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatch = "8400000000-4-abcdef0123456789";
  const cases = [
    ["user", { thread_source: "user" }],
    ["subagent", { thread_source: "subagent", history_mode: "legacy" }],
  ];
  for (const [name, meta] of cases) {
    const target = path.join(tmp, `rollout-fork-no-ordinal-${name}-${owner}.jsonl`);
    fs.writeFileSync(target, `${[
      { type: "session_meta", payload: { id: owner, forked_from_id: parent, ...meta } },
      { type: "session_meta", payload: { id: parent } },
      { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
      { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: `read C:/x/${dispatch}.task.md and proceed` } },
      { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: `${name} body` } },
      { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: `${name} body` } },
    ].map((item) => JSON.stringify(item)).join("\n")}\n`);
    const result = readRolloutFile(target, { rolloutThreadId: owner });
    assert.equal(result.ok, true, name);
    assert.ok(!result.reason, name);
    assert.equal(
      result.diagnostics.some((item) => item.code === "rollout-history-boundary-missing"),
      false,
      name,
    );
    assert.equal(readRolloutActivity(target, { rolloutThreadId: owner }).turnActivity, "closed", name);
    const correlated = correlateDispatch(result, dispatch);
    assert.equal(correlated.status, "complete", name);
    assert.equal(correlated.text, `${name} body`, name);
    assert.equal(correlated.lifecycle.certifiable, true, name);
  }
});

test("a fork that declares record ordinals without a boundary still fails closed", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-fork-ordinal-no-boundary-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { ordinal: 0, type: "session_meta", payload: { id: owner, forked_from_id: parent, history_mode: "producer-ordinal" } },
    { ordinal: 1, type: "event_msg", payload: { type: "task_started", turn_id: "22222222-2222-4222-8222-222222222222" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = readRolloutFile(target, { rolloutThreadId: owner });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "rollout-history-boundary-missing");
});

test("fork boundary values, ordinal order, and boundary record shape fail closed", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const parent = "11111111-1111-4111-8111-111111111111";
  const cases = [
    ["zero", 0, [{ ordinal: 0, type: "session_meta" }]],
    ["string", "1", [{ ordinal: 0, type: "session_meta" }]],
    ["fractional", 1.5, [{ ordinal: 0, type: "session_meta" }]],
    ["negative", -1, [{ ordinal: 0, type: "session_meta" }]],
    ["gap", 2, [{ ordinal: 2, type: "event_msg", payload: { type: "thread_settings_applied" } }]],
    ["wrong-record", 1, [{ ordinal: 1, type: "event_msg", payload: { type: "task_started" } }]],
    ["beyond-eof", 2, [{ ordinal: 1, type: "session_meta", payload: { id: parent } }]],
  ];
  for (const [name, boundary, tail] of cases) {
    const target = path.join(tmp, `rollout-fork-boundary-${name}-${owner}.jsonl`);
    const first = {
      ordinal: 0,
      type: "session_meta",
      payload: { id: owner, forked_from_id: parent, subagent_history_start_ordinal: boundary },
    };
    const normalizedTail = tail.map((item) => ({
      ...item,
      payload: item.payload || { id: owner, forked_from_id: parent },
    }));
    fs.writeFileSync(target, `${[first, ...normalizedTail].map((item) => JSON.stringify(item)).join("\n")}\n`);
    const result = readRolloutFile(target, { rolloutThreadId: owner });
    assert.equal(result.ok, false, name);
    assert.equal(result.reason, "rollout-history-boundary-invalid", name);
  }
});

test("session metadata pins the first rollout owner and rejects conflicting repeats", () => {
  const target = path.join(tmp, "rollout-owner-conflict-00000000-0000-4000-8000-000000000000.jsonl");
  const owner = "00000000-0000-4000-8000-000000000000";
  const conflictingOwner = "11111111-1111-4111-8111-111111111111";
  fs.writeFileSync(target, [
    { type: "session_meta", payload: { id: owner } },
    { type: "session_meta", payload: { id: conflictingOwner } },
  ].map((item) => JSON.stringify(item)).join("\n") + "\n");
  const result = readRolloutFile(target, { retainRecords: false });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "rollout-owner-mismatch");
  assert.equal(
    result.diagnostics.some(
      (item) => item.code === "schema-drift" && item.reason === "rollout-thread-id-mismatch",
    ),
    true,
  );
});

test("invalid session metadata is a file-global owner-integrity failure", () => {
  for (const [name, payload] of [
    ["missing", {}],
    ["invalid", { id: "not-a-uuid" }],
  ]) {
    const target = path.join(tmp, `rollout-owner-${name}-00000000-0000-4000-8000-000000000000.jsonl`);
    fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload })}\n`);
    const result = readRolloutFile(target, { retainRecords: false });
    assert.equal(result.ok, false, name);
    assert.equal(result.reason, "rollout-owner-invalid", name);
    assert.equal(
      result.diagnostics.some(
        (item) => item.code === "schema-drift" && item.reason === "rollout-thread-id-invalid",
      ),
      true,
      name,
    );
  }
});

test("a rollout without pinned owner metadata cannot certify a body", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7155000000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-ownerless-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turn,
        message: `read C:/x/${dispatchId}.task.md and proceed`,
      },
    },
    {
      type: "event_msg",
      payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" },
    },
    {
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turn, last_agent_message: "MUST-NOT-SERVE" },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, dispatchId);
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, "rollout-owner-missing");
  assert.equal(result.status, "none");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.certifiable, false);
});

test("a later session_meta cannot rescue a non-owner first record", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7155500000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-late-owner-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "session_meta", payload: { id: owner } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turn,
        message: `read C:/x/${dispatchId}.task.md and proceed`,
      },
    },
    {
      type: "event_msg",
      payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" },
    },
    {
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turn, last_agent_message: "MUST-NOT-SERVE" },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, dispatchId);
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, "rollout-owner-missing");
  assert.equal(result.status, "none");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.certifiable, false);
});

test("direct event thread identity cannot contradict the pinned rollout owner", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const foreign = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7156000000-7-abcdef0123456789";
  const normalized = normalizeRolloutRecord({
    type: "event_msg",
    payload: {
      type: "user_message",
      thread_id: foreign,
      turn_id: turn,
      message: `read C:/x/${dispatchId}.task.md and proceed`,
    },
  }, { rolloutThreadId: owner });
  assert.equal(normalized.knownPair, false);
  assert.equal(normalized.text, "");

  const target = path.join(tmp, `rollout-direct-foreign-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", thread_id: foreign, turn_id: turn } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        thread_id: foreign,
        turn_id: turn,
        message: `read C:/x/${dispatchId}.task.md and proceed`,
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "agent_message",
        thread_id: foreign,
        phase: "final_answer",
        message: "FOREIGN-THREAD-BODY",
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "task_complete",
        thread_id: foreign,
        turn_id: turn,
        last_agent_message: "FOREIGN-THREAD-BODY",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, dispatchId);
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, "rollout-owner-mismatch");
  assert.equal(result.status, "none");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.certifiable, false);
});

test("an owner conflict before a later completed turn cannot serve a body", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const conflictingOwner = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7160000000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-owner-global-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "session_meta", payload: { id: conflictingOwner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "MUST-NOT-SERVE" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, dispatchId);
  assert.equal(parsed.ok, false);
  assert.equal(result.status, "none");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.certifiable, false);
});

test("an owner conflict after a completed turn retroactively blocks certification", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const conflictingOwner = "11111111-1111-4111-8111-111111111111";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7170000000-7-abcdef0123456789";
  const target = path.join(tmp, `rollout-owner-post-terminal-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "MUST-NOT-SERVE" } },
    { type: "session_meta", payload: { id: conflictingOwner } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, dispatchId);
  assert.equal(parsed.ok, false);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
});

test("malformed post-terminal record thread identity blocks file-global certification", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "7175000000-7-abcdef0123456789";
  const body = "must remain uncertified";
  const base = [
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: body } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: body } },
  ];
  const malformedRecords = [
    { type: "event_msg", payload: { type: "token_count", thread_id: "", info: { total: 1 } } },
    {
      type: "event_msg",
      payload: {
        type: "item_completed",
        turn_id: turn,
        thread_id: owner,
        item: { type: "Reasoning", thread_id: 7 },
      },
    },
    {
      type: "event_msg",
      payload: {
        thread_id: owner,
        item: { type: "agent_message", thread_id: "", message: "legacy malformed owner" },
      },
    },
  ];
  for (const [index, malformed] of malformedRecords.entries()) {
    const target = path.join(tmp, `rollout-owner-malformed-post-${index}-${owner}.jsonl`);
    fs.writeFileSync(target, `${[...base, malformed].map((item) => JSON.stringify(item)).join("\n")}\n`);
    const parsed = readRolloutFile(target);
    const result = correlateDispatch(parsed, dispatchId);
    assert.equal(parsed.ok, false, `variant ${index}`);
    assert.equal(parsed.reason, "rollout-owner-invalid", `variant ${index}`);
    assert.equal(result.status, "none", `variant ${index}`);
    assert.equal(result.text, null, `variant ${index}`);
    assert.equal(result.lifecycle.certifiable, false, `variant ${index}`);
    assert.ok(
      parsed.diagnostics.some(
        (item) => item.code === "schema-drift" && item.reason === "rollout-thread-id-invalid",
      ),
      `variant ${index}`,
    );
  }
});

test("malformed JSON before the target window is counted but does not misattribute", () => {
  const target = path.join(tmp, "rollout-outside-00000000-0000-4000-8000-000000000000.jsonl");
  const tail = [
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7200000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "agent_message", message: "outside-safe", phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: "outside-safe" } },
  ].map((item) => JSON.stringify(item));
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } })}\n{bad json}\n${tail.join("\n")}\n`);
  const parsed = readRolloutFile(target);
  const result = correlateDispatch(parsed, "7200000000-7-abcdef0123456789");
  assert.equal(parsed.parseErrorCount, 1);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "outside-safe");
});

test("intervening user message and completion-body mismatch both fail closed", () => {
  const ambiguousPath = path.join(tmp, "rollout-ambiguous-00000000-0000-4000-8000-000000000000.jsonl");
  const ambiguous = [
    { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7300000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "user_message", message: "second user message" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: null } },
  ];
  fs.writeFileSync(ambiguousPath, `${ambiguous.map((item) => JSON.stringify(item)).join("\n")}\n`);
  assert.equal(correlateDispatch(readRolloutFile(ambiguousPath), "7300000000-7-abcdef0123456789").reason, "ambiguous");

  const mismatchPath = path.join(tmp, "rollout-mismatch-00000000-0000-4000-8000-000000000000.jsonl");
  const mismatch = [
    ambiguous[0],
    ambiguous[1],
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7400000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "agent_message", message: "selected final", phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: "different copy" } },
  ];
  fs.writeFileSync(mismatchPath, `${mismatch.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = correlateDispatch(readRolloutFile(mismatchPath), "7400000000-7-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unavailable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
  assert.ok(result.diagnostics.some((item) => item.code === "completion-message-mismatch"));
});

test("turn-id start requires a same-id terminal record", () => {
  const target = path.join(tmp, "rollout-terminal-id-00000000-0000-4000-8000-000000000000.jsonl");
  const records = [
    { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: "read C:/x/7500000000-7-abcdef0123456789.task.md and proceed" } },
    { type: "event_msg", payload: { type: "agent_message", message: "must not complete", phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", last_agent_message: "must not complete" } },
  ];
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = correlateDispatch(readRolloutFile(target), "7500000000-7-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.ok(result.diagnostics.some((item) => item.code === "terminal-turn-id-missing"));
});

test("changed physical identity under a cursor is fail-visible", () => {
  const target = path.join(tmp, "rollout-replaced-00000000-0000-4000-8000-000000000000.jsonl");
  const archived = `${target}.old`;
  fs.copyFileSync(nestedPath, target);
  const initial = readRolloutFile(target);
  fs.renameSync(target, archived);
  fs.copyFileSync(nestedPath, target);
  const result = readRolloutFile(target, { cursor: initial.cursor });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "file-replaced");
});

test("post-read path rotation is structured instead of throwing", () => {
  const target = path.join(tmp, "rollout-rotated-00000000-0000-4000-8000-000000000000.jsonl");
  fs.copyFileSync(nestedPath, target);
  const originalStat = fs.statSync;
  fs.statSync = function injectedStat(filePath, ...args) {
    if (filePath === target) {
      const error = new Error("synthetic rotation");
      error.code = "ENOENT";
      throw error;
    }
    return originalStat.call(fs, filePath, ...args);
  };
  let result;
  try {
    result = readRolloutFile(target);
  } finally {
    fs.statSync = originalStat;
  }
  assert.equal(result.ok, false);
  assert.equal(result.reason, "file-replaced");
  assert.ok(result.diagnostics.some((item) => item.code === "path-revalidation-failed"));
});

test("locator honors explicit path and validates owner identity", () => {
  const explicit = locateRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: basicPath,
    sessionsRoot: path.join(tmp, "unused"),
  });
  assert.equal(explicit.status, "found");
  assert.equal(explicit.authority, "explicit");
  const stat = fs.statSync(basicPath, { bigint: true });
  assert.equal(explicit.candidates[0].identityKey, `${stat.dev}:${stat.ino}`);
  const mismatch = locateRollout({
    threadId: "22222222-2222-4222-8222-222222222222",
    rolloutPath: basicPath,
  });
  assert.equal(mismatch.status, "unavailable");
  assert.equal(mismatch.reason, "identity-mismatch");
});

test("locator admits a DB-designated paginated rollout only with bound root metadata", () => {
  const root = "11111111-1111-4111-8111-111111111111";
  const page = "33333333-3333-4333-8333-333333333333";
  const historyBase = "00000000-0000-4000-8000-00000000c0de";
  const directory = path.join(tmp, "explicit-page");
  fs.mkdirSync(directory, { recursive: true });
  const target = path.join(directory, `rollout-2026-08-30T00-00-00-${root}_${page}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({
    type: "session_meta",
    payload: {
      id: root,
      session_id: root,
      history_mode: "paginated",
      history_base: { thread_id: historyBase },
    },
  })}\n`);

  assert.deepEqual(parseRolloutBasename(target), {
    rootThreadId: root,
    pageId: page,
    paginated: true,
  });
  const result = locateRollout({ threadId: root, rolloutPath: target });
  assert.equal(result.status, "found");
  assert.equal(result.authority, "explicit");
  assert.equal(result.candidates[0].pageId, page);
  assert.equal(result.candidates[0].paginated, true);
});

test("paginated rollout grammar and root metadata fail closed on malformed identities", () => {
  const root = "11111111-1111-4111-8111-111111111111";
  const wrongRoot = "22222222-2222-4222-8222-222222222222";
  const page = "33333333-3333-4333-8333-333333333333";
  const historyBase = "00000000-0000-4000-8000-00000000c0de";
  const directory = path.join(tmp, "invalid-pages");
  fs.mkdirSync(directory, { recursive: true });
  const validPayload = {
    id: root,
    session_id: root,
    history_mode: "paginated",
    history_base: { thread_id: historyBase },
  };
  const cases = [
    ["wrong-root", `rollout-case-${wrongRoot}_${page}.jsonl`, validPayload],
    ["malformed-page", `rollout-case-${root}_not-a-page.jsonl`, validPayload],
    ["extra-suffix", `rollout-case-${root}_${page}_extra.jsonl`, validPayload],
    ["wrong-session", `rollout-session-${root}_${page}.jsonl`, { ...validPayload, session_id: wrongRoot }],
    ["wrong-mode", `rollout-mode-${root}_${page}.jsonl`, { ...validPayload, history_mode: "full" }],
    ["bad-history", `rollout-history-${root}_${page}.jsonl`, {
      ...validPayload,
      history_base: { thread_id: "not-a-uuid" },
    }],
  ];
  for (const [name, basename, payload] of cases) {
    const target = path.join(directory, basename);
    fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload })}\n`);
    const result = locateRollout({ threadId: root, rolloutPath: target });
    assert.equal(result.status, "unavailable", name);
    assert.equal(result.reason, "identity-mismatch", name);
  }
});

test("discovery refuses to choose between distinct valid paginated rollout pages", () => {
  const root = "11111111-1111-4111-8111-111111111111";
  const historyBase = "00000000-0000-4000-8000-00000000c0de";
  const directory = path.join(tmp, "sessions-pages");
  const pages = [
    "33333333-3333-4333-8333-333333333333",
    "00000000-0000-4000-8000-000000000000",
  ];
  pages.forEach((page, index) => {
    const pageDirectory = path.join(directory, String(index));
    fs.mkdirSync(pageDirectory, { recursive: true });
    const target = path.join(pageDirectory, `rollout-page-${root}_${page}.jsonl`);
    fs.writeFileSync(target, `${JSON.stringify({
      type: "session_meta",
      payload: {
        id: root,
        session_id: root,
        history_mode: "paginated",
        history_base: { thread_id: historyBase },
      },
    })}\n`);
    fs.utimesSync(target, new Date(1000 + index * 1000), new Date(1000 + index * 1000));
  });
  const result = locateRollout({ threadId: root, sessionsRoot: directory });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.reason, "multiple-candidates");
  assert.equal(result.candidates.length, 2);
});

test("discovery keeps a target-UUID filename schema near-match fail-visible", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const directory = path.join(tmp, "sessions-name-drift");
  fs.mkdirSync(directory, { recursive: true });
  fs.copyFileSync(basicPath, path.join(directory, path.basename(basicPath)));
  fs.writeFileSync(
    path.join(directory, `rollout-future-${threadId}_unsupported-suffix.jsonl`),
    `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`,
  );
  const result = locateRollout({ threadId, sessionsRoot: directory });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.reason, "candidate-set-unresolved");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-name-unrecognized"));
});

test("discovery does not let a trailing UUID reclassify target-named schema drift", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const otherThreadId = "22222222-2222-4222-8222-222222222222";
  const directory = path.join(tmp, "sessions-name-drift-trailing-uuid");
  fs.mkdirSync(directory, { recursive: true });
  fs.copyFileSync(basicPath, path.join(directory, path.basename(basicPath)));
  const driftedName = `rollout-new-${threadId}-v2-${otherThreadId}.jsonl`;
  assert.equal(parseRolloutBasename(driftedName)?.rootThreadId, otherThreadId);
  fs.writeFileSync(
    path.join(directory, driftedName),
    `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`,
  );
  const result = locateRollout({ threadId, sessionsRoot: directory });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.reason, "candidate-set-unresolved");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-name-unrecognized"));
});

test("another root's recognized page-id equal to the target is not schema drift", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const otherRoot = "22222222-2222-4222-8222-222222222222";
  const directory = path.join(tmp, "sessions-known-other-page");
  fs.mkdirSync(directory, { recursive: true });
  fs.copyFileSync(basicPath, path.join(directory, path.basename(basicPath)));
  fs.writeFileSync(
    path.join(directory, `rollout-other-${otherRoot}_${threadId}.jsonl`),
    `${JSON.stringify({
      type: "session_meta",
      payload: {
        id: otherRoot,
        session_id: otherRoot,
        history_mode: "paginated",
        history_base: { thread_id: "33333333-3333-4333-8333-333333333333" },
      },
    })}\n`,
  );
  const result = locateRollout({ threadId, sessionsRoot: directory });
  assert.equal(result.status, "found");
  assert.equal(result.candidates.length, 1);
  assert.equal(result.diagnostics.some((item) => item.code === "rollout-name-unrecognized"), false);
});

test("discovery cannot certify an old rollout beside an identity-invalid exact page", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const pageId = "33333333-3333-4333-8333-333333333333";
  const directory = path.join(tmp, "sessions-invalid-page");
  fs.mkdirSync(directory, { recursive: true });
  fs.copyFileSync(basicPath, path.join(directory, path.basename(basicPath)));
  fs.writeFileSync(
    path.join(directory, `rollout-future-${threadId}_${pageId}.jsonl`),
    `${JSON.stringify({ type: "session_meta", payload: { id: "22222222-2222-4222-8222-222222222222" } })}\n`,
  );
  const result = locateRollout({ threadId, sessionsRoot: directory });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.reason, "candidate-set-unresolved");
  assert.ok(result.diagnostics.some((item) => item.code === "identity-mismatch"));
});

test("locator deduplicates physical aliases before ambiguity", () => {
  const root = path.join(tmp, "sessions-alias");
  const a = path.join(root, "a", path.basename(basicPath));
  const b = path.join(root, "b", path.basename(basicPath));
  fs.mkdirSync(path.dirname(a), { recursive: true });
  fs.mkdirSync(path.dirname(b), { recursive: true });
  fs.copyFileSync(basicPath, a);
  fs.linkSync(a, b);
  const result = locateRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: root,
  });
  assert.equal(result.status, "found");
  assert.equal(result.candidates.length, 1);
  assert.equal(result.aliasCount, 2);
});

test("locator fails visible on distinct equal-authority candidates", () => {
  const root = path.join(tmp, "sessions-conflict");
  for (const dir of ["a", "b"]) {
    const target = path.join(root, dir, path.basename(basicPath));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(basicPath, target);
  }
  const result = locateRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: root,
  });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.candidates.length, 2);
});

test("UUID-scoped candidate discovery obeys an injected deadline", () => {
  const root = path.join(tmp, "sessions-deadline");
  const target = path.join(root, "a", path.basename(basicPath));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(basicPath, target);
  let ticks = 0;
  const result = locateRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    sessionsRoot: root,
    deadlineAt: 1,
    now: () => ++ticks,
  });
  assert.equal(result.status, "unavailable");
  assert.equal(result.reason, "deadline-exceeded");
});

test("write-proof inspection preserves marker plus later completion gate", () => {
  const marker = "latest final";
  const proof = inspectRolloutMarker(basicPath, marker);
  assert.equal(proof.agentMarkerSeen, true);
  assert.equal(proof.taskCompleteAfterAgentMarker, true);
  assert.equal(proof.parseErrorCount, 0);
});

test("legacy marker inspection cannot certify across a post-terminal owner failure", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const marker = "SANITIZED_OWNER_MARKER";
  for (const [name, ownerRecord, reason] of [
    [
      "conflict",
      { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
      "rollout-owner-mismatch",
    ],
    ["invalid", { type: "session_meta", payload: { id: "not-a-uuid" } }, "rollout-owner-invalid"],
  ]) {
    const target = path.join(tmp, `rollout-marker-owner-${name}-${owner}.jsonl`);
    fs.writeFileSync(target, `${[
      { type: "session_meta", payload: { id: owner } },
      { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
      { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: marker } },
      { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: marker } },
      { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: marker } },
      ownerRecord,
    ].map((item) => JSON.stringify(item)).join("\n")}\n`);
    const proof = inspectRolloutMarker(target, marker);
    assert.equal(proof.error, reason, name);
    assert.equal(proof.taskCompleteAfterAgentMarker, false, name);
  }
});

test("legacy marker inspection cannot certify before a stable EOF", () => {
  const target = path.join(tmp, "rollout-marker-eof-race-11111111-1111-4111-8111-111111111111.jsonl");
  fs.copyFileSync(basicPath, target);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total: 1 } } })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let proof;
  try {
    proof = inspectRolloutMarker(target, "latest final");
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(proof.taskCompleteAfterAgentMarker, false);
  assert.equal(proof.error, "rollout-read-not-at-eof");
});

test("path growth after descriptor revalidation keeps the reader and marker proof fail-closed", () => {
  const target = path.join(tmp, "rollout-marker-path-race-11111111-1111-4111-8111-111111111111.jsonl");
  fs.copyFileSync(basicPath, target);
  const originalStat = fs.statSync;
  let statCalls = 0;
  fs.statSync = function injectedStat(filePath, ...args) {
    statCalls += 1;
    if (statCalls === 1) {
      fs.appendFileSync(target, `${JSON.stringify({
        type: "event_msg",
        payload: { type: "token_count", thread_id: null },
      })}\n`);
    }
    return originalStat.call(fs, filePath, ...args);
  };
  let parsed;
  try {
    parsed = readRolloutFile(target);
  } finally {
    fs.statSync = originalStat;
  }
  assert.equal(statCalls, 2);
  assert.equal(parsed.ok, true);
  assert.equal(isCompleteReaderCursor(parsed.cursor), false);
  assert.ok(parsed.diagnostics.some((item) => item.code === "file-grew-after-read"));

  const proofTarget = path.join(tmp, "rollout-marker-proof-path-race-11111111-1111-4111-8111-111111111111.jsonl");
  fs.copyFileSync(basicPath, proofTarget);
  statCalls = 0;
  fs.statSync = function injectedProofStat(filePath, ...args) {
    statCalls += 1;
    if (statCalls === 1) {
      fs.appendFileSync(proofTarget, `${JSON.stringify({
        type: "event_msg",
        payload: { type: "token_count", info: { total: 1 } },
      })}\n`);
    }
    return originalStat.call(fs, filePath, ...args);
  };
  let proof;
  try {
    proof = inspectRolloutMarker(proofTarget, "latest final");
  } finally {
    fs.statSync = originalStat;
  }
  assert.equal(proof.taskCompleteAfterAgentMarker, false);
  assert.equal(proof.error, "rollout-read-not-at-eof");
});

test("write-proof routes post-send evidence through the shared poller gate", () => {
  const proofPath = path.join(path.dirname(process.env.MODULE), "codex_ipc_write_proof.mjs");
  const source = fs.readFileSync(proofPath, "utf8");
  assert.match(source, /from "\.\/codex_ipc_rollout_reader\.mjs"/);
  assert.match(source, /export async function collectPostSendEvidence\(/);
  assert.match(source, /rolloutProbe = await poll\(/);
  assert.match(source, /const sendCertified = isCertifiedSendOccurrence\(normalizedSend\)/);
  assert.match(source, /sendCertified &&/);
  assert.match(source, /snapshotCompare\.ok === true/);
  assert.doesNotMatch(source, /function sleepSync\(/);
  assert.doesNotMatch(source, /function inspectRolloutMarker\(/);
  const readerSource = fs.readFileSync(process.env.MODULE, "utf8");
  assert.doesNotMatch(readerSource, /records\s*=\s*records\.concat/);
});

await test("poller uses injected in-process time without child sleeps", async () => {
  let now = 0;
  let sleeps = 0;
  const proof = await pollRolloutForMarker(basicPath, "latest final", 10, 2, {
    now: () => now,
    sleep: async (ms) => {
      sleeps += 1;
      now += ms;
    },
  });
  assert.equal(proof.ok, true);
  assert.equal(sleeps, 0);
});

await test("poller rejects records from an integrity-failed read", async () => {
  const target = path.join(tmp, "rollout-proof-rewrite-00000000-0000-4000-8000-000000000000.jsonl");
  fs.copyFileSync(basicPath, target);
  const originalSize = fs.statSync(target).size;
  const originalRead = fs.readSync;
  let injected = false;
  fs.readSync = function injectedRead(descriptor, ...args) {
    const bytesRead = originalRead.call(fs, descriptor, ...args);
    if (!injected && bytesRead > 0 && args[2] > 4096) {
      injected = true;
      fs.writeFileSync(target, Buffer.alloc(originalSize, 0x20));
    }
    return bytesRead;
  };
  let proof;
  try {
    proof = await pollRolloutForMarker(target, "latest final", 10, 1);
  } finally {
    fs.readSync = originalRead;
  }
  assert.equal(proof.ok, false);
  assert.equal(proof.lastObservation.error, "file-replaced");
  assert.equal(proof.lastObservation.agentMarkerSeen, false);
});

await test("repair RED: strict prefix deadline is not misreported as owner change", async () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const target = path.join(tmp, `rollout-proof-prefix-deadline-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "world_state", payload: { padding: "x".repeat(256 * 1024) } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);

  let prefixChecks = 0;
  const proof = await pollRolloutForMarker(target, "SANITIZED_DEADLINE_MARKER", 10, 1, {
    cursor: baseline.cursor,
    expectedTurnId: turn,
    expectedThreadId: owner,
    now: () => {
      if (!(new Error().stack || "").includes("updatePrefixHash")) return 0;
      prefixChecks += 1;
      return prefixChecks >= 2 ? 10 : 0;
    },
    sleep: async () => {},
  });
  assert.equal(proof.ok, false);
  assert.equal(proof.attempts, 1);
  assert.deepEqual(proof.diagnostics, ["deadline-exceeded"]);
  assert.equal(proof.lastObservation.error, "deadline-exceeded");
  assert.equal(prefixChecks, 2);
});

await test("strict proof cannot certify a read whose file grew after observed EOF", async () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "22222222-2222-4222-8222-222222222222";
  const marker = "SANITIZED_EOF_MARKER";
  const target = path.join(tmp, `rollout-proof-eof-race-${owner}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  fs.appendFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: marker } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: marker } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({
        type: "session_meta",
        payload: { id: "11111111-1111-4111-8111-111111111111" },
      })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let proof;
  try {
    proof = await pollRolloutForMarker(target, marker, 10, 1, {
      cursor: baseline.cursor,
      expectedTurnId: turn,
      expectedThreadId: owner,
      now: () => 0,
      sleep: async () => {},
    });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(proof.ok, false);
  assert.equal(proof.diagnostics.includes("rollout-read-not-at-eof"), true);
});

test("write-proof baseline requires one shared complete-EOF cursor predicate before send", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const target = path.join(tmp, `rollout-baseline-eof-race-${owner}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: owner } })}\n`);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({ type: "world_state", payload: {} })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let baseline;
  try {
    baseline = readRolloutFile(target, {
      retainRecords: false,
      rolloutThreadId: owner,
    });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), false);
  let sendCalls = 0;
  const authorization = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: false },
    { parsed: baseline, turnActivity: "closed" },
    trustedPreSendSnapshot(owner, target),
    () => {
      sendCalls += 1;
      return { ok: true };
    },
  );
  assert.equal(authorization.ok, false);
  assert.equal(authorization.stage, "baseline-integrity");
  assert.equal(sendCalls, 0);
});

test("repair RED: write-proof baseline recomputes owner-bound turn activity before send", () => {
  assert.equal(typeof readRolloutActivity, "function");
  const owner = "00000000-0000-4000-8000-000000000000";
  const closedTurn = "11111111-1111-4111-8111-111111111111";
  const openTurn = "22222222-2222-4222-8222-222222222222";
  const target = path.join(tmp, `rollout-baseline-activity-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: closedTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: closedTurn, message: "first" } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: closedTurn, phase: "final_answer", message: "done" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: closedTurn, last_agent_message: "done" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: openTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: openTurn, message: "new work" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const baseline = readRolloutActivity(target, {
    rolloutThreadId: owner,
  });
  assert.equal(baseline.parsed.ok, true);
  assert.equal(baseline.parsed.integrityValidated, true);
  assert.equal(isCompleteReaderCursor(baseline.parsed.cursor), true);
  assert.equal(baseline.turnActivity, "open");
  let sendCalls = 0;
  const authorization = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: false },
    baseline,
    trustedPreSendSnapshot(owner, target),
    () => {
      sendCalls += 1;
      return { ok: true };
    },
  );
  assert.equal(authorization.ok, false);
  assert.equal(authorization.stage, "baseline-activity");
  assert.equal(sendCalls, 0);
});

test("repair RED: owner-bound activity keeps a closed turn with schema drift ambiguous", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-baseline-drift-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: "work" } },
    { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: turn } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: null } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const baseline = readRolloutActivity(target, { rolloutThreadId: owner });
  assert.equal(baseline.parsed.ok, true);
  assert.ok(baseline.parsed.diagnostics.some((item) => item.code === "schema-drift"));
  assert.equal(baseline.turnActivity, "ambiguous");
  let sendCalls = 0;
  const authorization = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: true },
    baseline,
    trustedPreSendSnapshot(owner, target),
    () => {
      sendCalls += 1;
      return { ok: true };
    },
  );
  assert.equal(authorization.ok, false);
  assert.equal(authorization.stage, "baseline-activity");
  assert.equal(sendCalls, 0);
});

test("write-proof authorization invokes the send exactly once for a closed certified baseline", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-baseline-authorized-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: "work" } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: "done" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "done" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutActivity(target, { rolloutThreadId: owner });
  assert.equal(baseline.parsed.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.parsed.cursor), true);
  assert.equal(baseline.turnActivity, "closed");
  let sendCalls = 0;
  const authorization = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: false },
    baseline,
    trustedPreSendSnapshot(owner, target),
    () => {
      sendCalls += 1;
      return { ok: true, response: "stub" };
    },
  );
  assert.equal(authorization.ok, true);
  assert.equal(authorization.stage, "sent");
  assert.deepEqual(authorization.send, { ok: true, response: "stub" });
  assert.equal(sendCalls, 1);

  const thrown = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: false },
    baseline,
    trustedPreSendSnapshot(owner, target),
    () => { throw new Error("synthetic post-invocation failure"); },
  );
  assert.equal(thrown.ok, true);
  assert.equal(thrown.stage, "sent");
  assert.equal(thrown.send.ok, false);
  assert.equal(thrown.send.sendOccurrence, "unknown");
  assert.match(thrown.send.error, /send processing failed after invocation began/);
});

test("fresh pre-send target evidence fails closed before invoking the sender", () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-fresh-gate-${owner}.jsonl`);
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: owner } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turn, message: "work" } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turn, phase: "final_answer", message: "done" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turn, last_agent_message: "done" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const baseline = readRolloutActivity(target, { rolloutThreadId: owner });
  const valid = trustedPreSendSnapshot(owner, target);
  assert.deepEqual(validatePreSendSnapshot({ threadId: owner }, valid), {
    ok: true,
    reasons: [],
    rolloutPath: target,
  });

  const invalidCases = [
    ["archived", (item) => { item.db.threads.target.archived = 1; }],
    ["null-archive-state", (item) => { item.db.threads.target.archived = null; }],
    ["string-archive-state", (item) => { item.db.threads.target.archived = "0"; }],
    ["unstable-config", (item) => { item.config.stableDuringRead = false; }],
    ["unstable-db", (item) => { item.db.stableDuringRead = false; }],
    ["failed-quick-check", (item) => { item.db.quickCheck = "corrupt"; }],
    ["missing-fresh-path", (item) => { item.db.threads.target.rolloutPath = null; }],
  ];
  for (const [name, mutate] of invalidCases) {
    const item = JSON.parse(JSON.stringify(valid));
    mutate(item);
    let sendCalls = 0;
    const authorization = authorizeBaselineAndSend(
      { threadId: owner, allowMidTurn: false },
      baseline,
      item,
      () => {
        sendCalls += 1;
        return { ok: true };
      },
    );
    assert.equal(authorization.ok, false, name);
    assert.equal(authorization.stage, "fresh-target-state", name);
    assert.equal(sendCalls, 0, name);
  }

  const otherPath = path.join(tmp, `rollout-stale-path-${owner}.jsonl`);
  const pathMismatch = trustedPreSendSnapshot(owner, otherPath);
  let mismatchSendCalls = 0;
  const mismatch = authorizeBaselineAndSend(
    { threadId: owner, allowMidTurn: false },
    baseline,
    pathMismatch,
    () => {
      mismatchSendCalls += 1;
      return { ok: true };
    },
  );
  assert.equal(mismatch.ok, false);
  assert.equal(mismatch.stage, "baseline-integrity");
  assert.equal(mismatch.rolloutPathBound, false);
  assert.equal(mismatchSendCalls, 0);
});

await test("post-send exceptions remain structured and never become retry-safe", async () => {
  const owner = "00000000-0000-4000-8000-000000000000";
  const turn = "11111111-1111-4111-8111-111111111111";
  const opts = {
    threadId: owner,
    marker: "SANITIZED_PROOF_MARKER",
    pollMs: 1,
    pollAttempts: 1,
    allowThreadChangeIds: [],
  };
  const send = {
    ok: true,
    sendOccurrence: "confirmed",
    followerRequestCount: 1,
    matchingFollowerRequestCount: 1,
    response: { result: { result: { turn: { id: turn } } } },
  };
  const validPoll = () => ({
    ok: true,
    lastObservation: {
      expectedTurnId: turn,
      proofTurnId: turn,
      agentMarkerSeen: true,
      taskCompleteAfterAgentMarker: true,
    },
  });
  const validCompare = () => ({
    ok: true,
    config: {
      sha256Unchanged: true,
      selectedKeysUnchanged: true,
      stableDuringReads: true,
    },
    db: {
      snapshotPrerequisitesTrusted: true,
      snapshotTargetIdentityBound: true,
      stableDuringReads: true,
      targetOwnerAndArchiveStateBound: true,
      rolloutPathUnchanged: true,
      threadHashMapsPresent: true,
      threadHashIdentitiesValid: true,
      targetThreadChanged: true,
      unexpectedNonTargetChangedIds: [],
      addedIds: [],
      removedIds: [],
    },
  });
  const pollAndSnapshotFailure = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => { throw new Error("synthetic poll failure"); },
      snapshot: () => { throw new Error("synthetic snapshot failure"); },
    },
  );
  assert.equal(pollAndSnapshotFailure.ok, false);
  assert.equal(pollAndSnapshotFailure.verificationStatus, "sent-but-unverified");
  assert.equal(pollAndSnapshotFailure.retrySafe, false);
  assert.equal(pollAndSnapshotFailure.after, null);
  assert.deepEqual(
    pollAndSnapshotFailure.postSendFailures.map((item) => item.stage),
    ["rollout-poll", "after-snapshot"],
  );

  const compareFailure = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => { throw new Error("synthetic compare failure"); },
    },
  );
  assert.equal(compareFailure.ok, false);
  assert.equal(compareFailure.verificationStatus, "sent-but-unverified");
  assert.equal(compareFailure.retrySafe, false);
  assert.deepEqual(compareFailure.postSendFailures.map((item) => item.stage), ["snapshot-compare"]);
  assert.equal(compareFailure.compare.reason, "post-send-compare-failed");

  const nullPoll = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => null,
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => validCompare(),
    },
  );
  assert.equal(nullPoll.ok, false);
  assert.equal(nullPoll.verificationStatus, "sent-but-unverified");
  assert.equal(nullPoll.retrySafe, false);
  assert.deepEqual(nullPoll.postSendFailures.map((item) => item.stage), ["rollout-poll-result"]);
  assert.equal(nullPoll.rolloutProbe.ok, false);

  const nullCompare = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => null,
    },
  );
  assert.equal(nullCompare.ok, false);
  assert.equal(nullCompare.verificationStatus, "sent-but-unverified");
  assert.equal(nullCompare.retrySafe, false);
  assert.deepEqual(nullCompare.postSendFailures.map((item) => item.stage), ["snapshot-compare-result"]);
  assert.equal(nullCompare.compare.ok, false);

  const incompletePoll = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => ({ ok: true }),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => validCompare(),
    },
  );
  assert.equal(incompletePoll.ok, false);
  assert.deepEqual(incompletePoll.postSendFailures.map((item) => item.stage), ["rollout-poll-result"]);
  assert.equal(incompletePoll.rolloutProbe.ok, false);

  const incompleteCompare = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => ({ ok: true }),
    },
  );
  assert.equal(incompleteCompare.ok, false);
  assert.deepEqual(incompleteCompare.postSendFailures.map((item) => item.stage), ["snapshot-compare-result"]);
  assert.equal(incompleteCompare.compare.ok, false);

  const unstableDbCompare = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => {
        const result = validCompare();
        result.db.stableDuringReads = false;
        return result;
      },
    },
  );
  assert.equal(unstableDbCompare.ok, false);
  assert.deepEqual(unstableDbCompare.postSendFailures.map((item) => item.stage), ["snapshot-compare-result"]);
  assert.equal(unstableDbCompare.compare.ok, false);

  const ambiguousHashIdentityCompare = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => {
        const result = validCompare();
        result.db.threadHashIdentitiesValid = false;
        return result;
      },
    },
  );
  assert.equal(ambiguousHashIdentityCompare.ok, false);
  assert.deepEqual(
    ambiguousHashIdentityCompare.postSendFailures.map((item) => item.stage),
    ["snapshot-compare-result"],
  );

  let uncertifiedPollCalls = 0;
  const uncertifiedSend = await collectPostSendEvidence(
    opts,
    {
      send: {
        ...send,
        sendOccurrence: "unknown",
        followerRequestCount: 0,
        matchingFollowerRequestCount: 0,
      },
      rolloutPath: "synthetic-rollout.jsonl",
      rolloutBaselineCursor: {},
      before: {},
    },
    {
      pollRolloutForMarker: async () => {
        uncertifiedPollCalls += 1;
        return validPoll();
      },
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => validCompare(),
    },
  );
  assert.equal(uncertifiedSend.ok, false);
  assert.equal(uncertifiedSend.verificationStatus, "send-outcome-unknown");
  assert.equal(uncertifiedSend.rolloutProbe.attempts, 0);
  assert.equal(
    uncertifiedSend.rolloutProbe.diagnostics.some((item) => item.includes("send-outcome-unknown")),
    true,
  );
  assert.equal(uncertifiedPollCalls, 0);

  let wrongCardinalityPollCalls = 0;
  const wrongCardinalitySend = await collectPostSendEvidence(
    opts,
    {
      send: {
        ...send,
        followerRequestCount: 2,
        matchingFollowerRequestCount: 1,
      },
      rolloutPath: "synthetic-rollout.jsonl",
      rolloutBaselineCursor: {},
      before: {},
    },
    {
      pollRolloutForMarker: async () => {
        wrongCardinalityPollCalls += 1;
        return validPoll();
      },
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => validCompare(),
    },
  );
  assert.equal(wrongCardinalitySend.ok, false);
  assert.equal(wrongCardinalitySend.verificationStatus, "sent-but-unverified");
  assert.equal(wrongCardinalitySend.rolloutProbe.attempts, 0);
  assert.equal(
    wrongCardinalitySend.rolloutProbe.diagnostics.some((item) => item.includes("sent-but-unverified")),
    true,
  );
  assert.equal(wrongCardinalityPollCalls, 0);

  for (const [occurrence, expectedStatus] of [
    ["unknown", "send-outcome-unknown"],
    ["confirmed", "sent-but-unverified"],
  ]) {
    let missingCountPollCalls = 0;
    const missingCountSend = await collectPostSendEvidence(
      opts,
      {
        send: {
          ok: true,
          sendOccurrence: occurrence,
          response: send.response,
        },
        rolloutPath: "synthetic-rollout.jsonl",
        rolloutBaselineCursor: {},
        before: {},
      },
      {
        pollRolloutForMarker: async () => {
          missingCountPollCalls += 1;
          return validPoll();
        },
        snapshot: () => ({ ok: true }),
        compareSnapshots: () => validCompare(),
      },
    );
    assert.equal(missingCountSend.ok, false, occurrence);
    assert.equal(missingCountSend.verificationStatus, expectedStatus, occurrence);
    assert.equal(missingCountSend.rolloutProbe.attempts, 0, occurrence);
    assert.equal(
      missingCountSend.rolloutProbe.diagnostics.some((item) => item.includes(expectedStatus)),
      true,
      occurrence,
    );
    assert.equal(missingCountPollCalls, 0, occurrence);
  }

  const mismatchedSnapshotTarget = await collectPostSendEvidence(
    opts,
    { send, rolloutPath: "synthetic-rollout.jsonl", rolloutBaselineCursor: {}, before: {} },
    {
      pollRolloutForMarker: async () => validPoll(),
      snapshot: () => ({ ok: true }),
      compareSnapshots: () => {
        const result = validCompare();
        result.db.snapshotTargetIdentityBound = false;
        return result;
      },
    },
  );
  assert.equal(mismatchedSnapshotTarget.ok, false);
  assert.deepEqual(
    mismatchedSnapshotTarget.postSendFailures.map((item) => item.stage),
    ["snapshot-compare-result"],
  );
});

await test("poller reads only appended records and stops at its bounded deadline", async () => {
  const target = path.join(tmp, "rollout-proof-00000000-0000-4000-8000-000000000000.jsonl");
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } })}\n`);
  let now = 0;
  let sleeps = 0;
  const proofPromise = pollRolloutForMarker(target, "PROOF_MARKER", 2, 3, {
    now: () => now,
    sleep: async (ms) => {
      sleeps += 1;
      now += ms;
      if (sleeps === 1) {
        fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "agent_message", message: "PROOF_MARKER", phase: "final_answer" } })}\n${JSON.stringify({ type: "event_msg", payload: { type: "task_complete", last_agent_message: "PROOF_MARKER" } })}\n`);
      }
    },
  });
  const proof = await proofPromise;
  assert.equal(proof.ok, true);
  assert.equal(proof.attempts, 2);
  assert.equal(sleeps, 1);

  now = 0;
  const expired = await pollRolloutForMarker(target, "ABSENT_MARKER", 2, 3, {
    now: () => now,
    sleep: async (ms) => { now += ms; },
  });
  assert.equal(expired.ok, false);
  assert.ok(now <= 6);
});

// ---- A-05 regression guard (GREEN): a wrong-turn user-message stays fail-closed ----------
// The already-fixed wrong-turn-reply defect (fixed at base 0fbd517). Must remain GREEN: a
// user_message whose turn_id disagrees with its enclosing turn must never serve that turn's
// body. Fixture: rollout-a05-wrongturn-33333333-3333-4333-8333-333333333333.jsonl.
test("A-05 guard: user-message turn-id mismatch refuses to serve a wrong-turn body", () => {
  const a05 = path.join(
    fixtures,
    "rollout-a05-wrongturn-33333333-3333-4333-8333-333333333333.jsonl",
  );
  const result = correlateDispatch(readRolloutFile(a05), "1500000000-5-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.ok(result.diagnostics.some((item) => item.code === "user-message-turn-id-mismatch"));
});

// ---- A1 transition matrix: exact 8-key snapshots through both adapters -------------------------
const SNAP_KEYS = [
  "activity", "boundaryMode", "diagnostics", "sequence",
  "superseded", "terminalLine", "terminalType", "turnId",
];
const meta = { type: "session_meta", payload: { id: "00000000-0000-4000-8000-000000000000" } };
const ev = (type, extra = {}) => ({ type: "event_msg", payload: { type, ...extra } });
const writeAndRead = (name, records) => {
  const target = path.join(tmp, `rollout-tm-${name}-00000000-0000-4000-8000-000000000000.jsonl`);
  fs.writeFileSync(target, `${records.map((r) => JSON.stringify(r)).join("\n")}\n`);
  return readRolloutFile(target);
};
const snapshotsOf = (parsed) => {
  const acc = createTurnBoundaryAccumulator();
  const out = [];
  for (const record of parsed.records || []) out.push(...acc.push(record).snapshots);
  out.push(...acc.finish(parsed.diagnostics));
  return out;
};

test("repair RED: wrong explicit semantic roles make their turn uncertifiable", () => {
  const roleThread = "11111111-1111-4111-8111-111111111111";
  const roleTurn = "22222222-2222-4222-8222-222222222222";
  const semanticRecord = (shape, semanticType, role, message) => {
    const extra = {
      turn_id: roleTurn,
      role,
      ...(semanticType === "agent_message" ? { phase: "final_answer" } : {}),
      message,
    };
    if (shape === "direct") return ev(semanticType, extra);
    if (shape === "wrapped") {
      return {
        type: "event_msg",
        payload: {
          type: "item_completed",
          turn_id: roleTurn,
          thread_id: roleThread,
          item: {
            id: `item-${semanticType}`,
            type: semanticType === "agent_message" ? "AgentMessage" : "UserMessage",
            ...extra,
          },
        },
      };
    }
    return {
      type: "event_msg",
      payload: {
        turn_id: roleTurn,
        thread_id: roleThread,
        item: { type: semanticType, ...extra },
      },
    };
  };

  for (const shape of ["direct", "wrapped", "legacy"]) {
    for (const corruptSemantic of ["user_message", "agent_message"]) {
      const dispatch = `8350000000-${shape.length}-abcdef0123456789`;
      const marker = `read C:/x/${dispatch}.task.md and proceed`;
      const records = [
        { type: "session_meta", payload: { id: roleThread } },
        ev("task_started", { turn_id: roleTurn }),
        ...(corruptSemantic === "user_message"
          ? [
              semanticRecord(shape, "user_message", "assistant", marker),
              ev("user_message", { turn_id: roleTurn, message: marker }),
              ev("agent_message", {
                turn_id: roleTurn,
                phase: "final_answer",
                message: "otherwise valid body",
              }),
            ]
          : [
              ev("user_message", { turn_id: roleTurn, message: marker }),
              semanticRecord(shape, "agent_message", "user", "otherwise valid body"),
            ]),
        ev("task_complete", { turn_id: roleTurn, last_agent_message: "otherwise valid body" }),
      ];
      const parsed = writeAndRead(`semantic-role-${shape}-${corruptSemantic}`, records);
      assert.equal(
        parsed.diagnostics.some((item) => item.code === "schema-drift"),
        true,
        `${shape}/${corruptSemantic}`,
      );
      const result = correlateDispatch(parsed, dispatch);
      assert.equal(result.status, "none", `${shape}/${corruptSemantic}`);
      assert.equal(result.reason, "unparseable", `${shape}/${corruptSemantic}`);
      assert.equal(result.text, null, `${shape}/${corruptSemantic}`);
      assert.equal(result.lifecycle.status, "unavailable", `${shape}/${corruptSemantic}`);
      assert.equal(result.lifecycle.certifiable, false, `${shape}/${corruptSemantic}`);
    }
  }

  for (const shape of ["direct", "wrapped"]) {
    const dispatch = `8351000000-${shape.length}-abcdef0123456789`;
    const marker = `read C:/x/${dispatch}.task.md and proceed`;
    const parsed = writeAndRead(`semantic-role-sole-marker-${shape}`, [
      { type: "session_meta", payload: { id: roleThread } },
      ev("task_started", { turn_id: roleTurn }),
      semanticRecord(shape, "user_message", "assistant", marker),
      ev("agent_message", {
        turn_id: roleTurn,
        phase: "final_answer",
        message: "must-not-serve",
      }),
      ev("task_complete", { turn_id: roleTurn, last_agent_message: "must-not-serve" }),
    ]);
    assert.equal(
      parsed.diagnostics.some((item) => item.code === "schema-drift"),
      true,
      `sole-marker/${shape}`,
    );
    const result = correlateDispatch(parsed, dispatch);
    assert.equal(result.status, "none", `sole-marker/${shape}`);
    assert.equal(result.reason, "unparseable", `sole-marker/${shape}`);
    assert.equal(result.text, null, `sole-marker/${shape}`);
    assert.equal(result.lifecycle.status, "unavailable", `sole-marker/${shape}`);
    assert.equal(result.lifecycle.certifiable, false, `sole-marker/${shape}`);
  }
});

test("dispatch correlator cannot certify a hard-failed or incomplete reader projection", () => {
  const dispatch = "8400000000-4-abcdef0123456789";
  const records = [
    meta,
    ev("task_started", { turn_id: "11111111-1111-4111-8111-111111111111" }),
    ev("user_message", {
      turn_id: "11111111-1111-4111-8111-111111111111",
      message: `read C:/x/${dispatch}.task.md and proceed`,
    }),
    ev("agent_message", {
      turn_id: "11111111-1111-4111-8111-111111111111",
      phase: "final_answer",
      message: "certified body",
    }),
    ev("task_complete", {
      turn_id: "11111111-1111-4111-8111-111111111111",
      last_agent_message: "certified body",
    }),
  ];
  const parsed = writeAndRead("correlator-reader-integrity", records);
  assert.equal(correlateDispatch(parsed, dispatch).status, "complete");

  for (const reason of ["file-truncated", "file-replaced"]) {
    const failed = correlateDispatch({
      ...parsed,
      ok: false,
      reason,
      diagnostics: [{ code: reason }],
    }, dispatch);
    assert.equal(failed.status, "none", reason);
    assert.equal(failed.reason, "unparseable", reason);
    assert.equal(failed.text, null, reason);
    assert.equal(failed.lifecycle.status, "unavailable", reason);
    assert.equal(failed.lifecycle.certifiable, false, reason);
    assert.ok(failed.diagnostics.some((item) => item.code === reason), reason);
  }

  const incomplete = correlateDispatch({
    ...parsed,
    cursor: { ...parsed.cursor, size: parsed.cursor.size + 1 },
  }, dispatch);
  assert.equal(incomplete.status, "none");
  assert.equal(incomplete.reason, "pending");
  assert.equal(incomplete.text, null);
  assert.equal(incomplete.lifecycle.status, "pending");
  assert.equal(incomplete.lifecycle.certifiable, false);
  assert.ok(incomplete.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

test("transition matrix: explicit-id complete emits one closed 8-key snapshot through both adapters", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-x" }),
    ev("user_message", { turn_id: "turn-x", message: "read C:/x/tm1-1-abcdef0123456789.task.md and proceed" }),
    ev("agent_message", { message: "final body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-x", last_agent_message: "final body" }),
  ];
  const parsed = writeAndRead("complete", records);
  const snaps = snapshotsOf(parsed);
  assert.equal(snaps.length, 1);
  assert.deepEqual(Object.keys(snaps[0]).sort(), SNAP_KEYS);
  assert.equal(snaps[0].sequence, 0);
  assert.equal(snaps[0].turnId, "turn-x");
  assert.equal(snaps[0].boundaryMode, "turn-id");
  assert.equal(snaps[0].activity, "closed");
  assert.equal(snaps[0].terminalType, "task_complete");
  assert.equal(typeof snaps[0].terminalLine, "number");
  assert.equal(snaps[0].superseded, false);
  assert.deepEqual(snaps[0].diagnostics, []);
  assert.equal(correlateDispatch(parsed, "tm1-1-abcdef0123456789").status, "complete");
  assert.equal(summarizeThreadActivity(snaps.at(-1), "found").turnActivity, "closed");
});

test("transition matrix: emitted snapshots are frozen and reject mutation", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-f" }),
    ev("user_message", { turn_id: "turn-f", message: "read C:/x/tmf-1-abcdef0123456789.task.md and proceed" }),
    ev("task_complete", { turn_id: "turn-f", last_agent_message: null }),
  ];
  const snaps = snapshotsOf(writeAndRead("frozen", records));
  assert.equal(snaps.length, 1);
  assert.ok(Object.isFrozen(snaps[0]), "boundary snapshot must be frozen");
  assert.ok(Object.isFrozen(snaps[0].diagnostics), "snapshot diagnostics must be frozen");
  assert.throws(() => {
    snaps[0].activity = "open";
  }, TypeError);
});

test("transition matrix: ordered-fallback terminal is closed with ordered-fallback boundaryMode", () => {
  const records = [
    meta,
    ev("task_started"),
    ev("user_message", { message: "read C:/x/tm2-2-abcdef0123456789.task.md and proceed" }),
    ev("agent_message", { message: "ordered body", phase: "final_answer" }),
    ev("task_complete", { last_agent_message: "ordered body" }),
  ];
  const parsed = writeAndRead("ordered", records);
  const snaps = snapshotsOf(parsed);
  assert.equal(snaps.length, 1);
  assert.equal(snaps[0].turnId, null);
  assert.equal(snaps[0].boundaryMode, "ordered-fallback");
  assert.equal(snaps[0].activity, "closed");
  assert.equal(correlateDispatch(parsed, "tm2-2-abcdef0123456789").boundaryMode, "ordered-fallback");
});

test("transition matrix: user turn-id mismatch is an ambiguous snapshot with a boundary diagnostic", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-a" }),
    ev("user_message", { turn_id: "turn-b", message: "read C:/x/tm3-3-abcdef0123456789.task.md and proceed" }),
    ev("task_complete", { turn_id: "turn-a", last_agent_message: null }),
  ];
  const parsed = writeAndRead("mismatch", records);
  const snaps = snapshotsOf(parsed);
  assert.equal(snaps[0].activity, "ambiguous");
  assert.ok(snaps[0].diagnostics.some((d) => d.code === "user-message-turn-id-mismatch"));
  assert.equal(summarizeThreadActivity(snaps.at(-1), "found").turnActivity, "ambiguous");
  assert.equal(correlateDispatch(parsed, "tm3-3-abcdef0123456789").reason, "unparseable");
});

test("transition matrix: supersession emits an ambiguous prior turn and an open latest turn", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-a" }),
    ev("user_message", { turn_id: "turn-a", message: "read C:/x/tm4-4-abcdef0123456789.task.md and proceed" }),
    ev("task_started", { turn_id: "turn-b" }),
    ev("user_message", { turn_id: "turn-b", message: "unrelated" }),
  ];
  const snaps = snapshotsOf(writeAndRead("supersede", records));
  assert.equal(snaps.length, 2);
  assert.equal(snaps[0].superseded, true);
  assert.equal(snaps[0].activity, "ambiguous");
  assert.equal(snaps[1].superseded, false);
  assert.equal(snaps[1].activity, "open");
  assert.equal(summarizeThreadActivity(snaps.at(-1), "found").turnActivity, "open");
});

test("transition matrix: an in-turn parse gap is an ambiguous snapshot", () => {
  const target = path.join(tmp, "rollout-tm-parsegap-00000000-0000-4000-8000-000000000000.jsonl");
  const lines = [
    meta,
    ev("task_started", { turn_id: "turn-g" }),
    ev("user_message", { turn_id: "turn-g", message: "read C:/x/tm5-5-abcdef0123456789.task.md and proceed" }),
  ].map((r) => JSON.stringify(r));
  fs.writeFileSync(
    target,
    `${lines.join("\n")}\n{bad json}\n${JSON.stringify(ev("task_complete", { turn_id: "turn-g", last_agent_message: null }))}\n`,
  );
  const snaps = snapshotsOf(readRolloutFile(target));
  assert.equal(snaps[0].activity, "ambiguous");
  assert.ok(snaps[0].diagnostics.some((d) => d.code === "malformed-json"));
});

test("transition matrix: turn_aborted terminal is a closed snapshot with terminalType turn_aborted", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-x" }),
    ev("user_message", { turn_id: "turn-x", message: "read C:/x/tm6-6-abcdef0123456789.task.md and proceed" }),
    ev("turn_aborted", { turn_id: "turn-x" }),
  ];
  const snaps = snapshotsOf(writeAndRead("aborted", records));
  assert.equal(snaps[0].terminalType, "turn_aborted");
  assert.equal(snaps[0].activity, "closed");
});

test("zero-snapshot: a found rollout with no emitted boundary maps to ambiguous without null-deref", () => {
  const records = [meta, { type: "event_msg", payload: { type: "token_count", info: { total: 1 } } }];
  const snaps = snapshotsOf(writeAndRead("zerosnap", records));
  assert.equal(snaps.length, 0);
  assert.equal(summarizeThreadActivity(snaps.at(-1), "found").turnActivity, "ambiguous");
  assert.equal(summarizeThreadActivity(null, "found").turnActivity, "ambiguous");
  assert.equal(summarizeThreadActivity({ activity: "closed" }, "unavailable").turnActivity, "ambiguous");
  assert.equal(summarizeThreadActivity({ activity: "closed" }, "ambiguous").turnActivity, "ambiguous");
});

// ---- A1/F1 drift fail-closed (RED at 9434721, GREEN after the fix): a COMPLETED turn with -------
// in-window schema drift must not project a closed activity. The accumulator is fed the FULL
// normalized parse stream exactly the way the A4 inspector feeds it (every record, drift included),
// so the boundary snapshot itself must carry the drift attribution for push-finalized turns.
test("drift fail-closed: in-window schema drift on a completed turn degrades activity to ambiguous", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-d" }),
    { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: "turn-d", message: "unknown in-window record" } },
    ev("user_message", { turn_id: "turn-d", message: "read C:/x/tmd-9-abcdef0123456789.task.md and proceed" }),
    ev("agent_message", { message: "drifted body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-d", last_agent_message: "drifted body" }),
  ];
  const target = path.join(tmp, "rollout-tm-driftclosed-00000000-0000-4000-8000-000000000000.jsonl");
  fs.writeFileSync(target, `${records.map((r) => JSON.stringify(r)).join("\n")}\n`);
  // Inspector feeding pattern (codex_ipc_session_inspect.mjs parseRollout): normalize and push
  // EVERY parsed line; collect one schema-drift diagnostic per unknown pair; finish with them.
  const acc = createTurnBoundaryAccumulator();
  const driftDiagnostics = [];
  const snaps = [];
  const lines = fs.readFileSync(target, "utf8").split("\n").filter(Boolean);
  lines.forEach((line, index) => {
    const normalized = normalizeRolloutRecord(JSON.parse(line), { line: index + 1 });
    snaps.push(...acc.push(normalized).snapshots);
    if (!normalized.knownPair) driftDiagnostics.push({ code: "schema-drift", line: index + 1 });
  });
  snaps.push(...acc.finish(driftDiagnostics));
  const last = snaps.reduce(
    (latest, snap) => (latest === null || snap.sequence > latest.sequence ? snap : latest),
    null,
  );
  assert.ok(last, "expected a boundary snapshot for the completed turn");
  assert.equal(last.terminalType, "task_complete");
  assert.notEqual(last.activity, "closed");
  assert.equal(last.activity, "ambiguous");
  assert.ok(last.diagnostics.some((d) => d.code === "schema-drift"));
  assert.equal(summarizeThreadActivity(last, "found").turnActivity, "ambiguous");
  // Consistency: the dispatch lifecycle adapter refuses the SAME records (existing behavior).
  const result = correlateDispatch(readRolloutFile(target), "tmd-9-abcdef0123456789");
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
});

test("drift fail-closed: a drift-free completed turn stays closed through the full-stream feed", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-e" }),
    ev("user_message", { turn_id: "turn-e", message: "read C:/x/tme-9-abcdef0123456789.task.md and proceed" }),
    ev("agent_message", { message: "clean body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-e", last_agent_message: "clean body" }),
  ];
  const target = path.join(tmp, "rollout-tm-driftfree-00000000-0000-4000-8000-000000000000.jsonl");
  fs.writeFileSync(target, `${records.map((r) => JSON.stringify(r)).join("\n")}\n`);
  const acc = createTurnBoundaryAccumulator();
  const snaps = [];
  const lines = fs.readFileSync(target, "utf8").split("\n").filter(Boolean);
  lines.forEach((line, index) => {
    snaps.push(...acc.push(normalizeRolloutRecord(JSON.parse(line), { line: index + 1 })).snapshots);
  });
  snaps.push(...acc.finish([]));
  assert.equal(snaps.at(-1).activity, "closed");
  assert.equal(summarizeThreadActivity(snaps.at(-1), "found").turnActivity, "closed");
  assert.equal(correlateDispatch(readRolloutFile(target), "tme-9-abcdef0123456789").lifecycle.status, "complete");
});

// ---- Harvester correlation deltas (RED-before at base b2aec66, GREEN after A1) -----------------
test("repair RED: a distinct later same-turn-id user invalidates correlation", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-a" }),
    ev("user_message", { turn_id: "turn-a", message: "read C:/x/tm7-7-abcdef0123456789.task.md and proceed" }),
    ev("user_message", { turn_id: "turn-a", message: "one more note" }),
    ev("agent_message", { message: "same-turn body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-a", last_agent_message: "same-turn body" }),
  ];
  const result = correlateDispatch(writeAndRead("sameturn", records), "tm7-7-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "ambiguous");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
  assert.ok(result.diagnostics.some((item) => item.code === "intervening-user-message"));
});

test("delta: a non-null agent-message turn-id that disagrees fails closed as none", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-a" }),
    ev("user_message", { turn_id: "turn-a", message: "read C:/x/tm8-8-abcdef0123456789.task.md and proceed" }),
    ev("agent_message", { turn_id: "turn-b", message: "wrong-turn body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-a", last_agent_message: "wrong-turn body" }),
  ];
  const result = correlateDispatch(writeAndRead("agentmismatch", records), "tm8-8-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.ok(result.diagnostics.some((d) => d.code === "agent-message-turn-id-mismatch"));
});

// ---- Named-dispatch task ownership: turn_id alone cannot absorb a distinct later user event ----
test("repair RED: a same-turn-id task change cannot certify the dispatch complete", () => {
  const a06 = path.join(
    fixtures,
    "rollout-a06-sameturn-11111111-1111-4111-8111-111111111111.jsonl",
  );
  const result = correlateDispatch(readRolloutFile(a06), "1600000000-6-abcdef0123456789");
  assert.equal(result.status, "none");
  assert.equal(result.reason, "ambiguous");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
});

// ---- A-04 (GREEN after A4/Phase-3): the marker proof is turn-id-bound, not pure line order ------
// Cross-turn: agent marker in turn-1 (no terminal there) + task_complete only in turn-2 (marker
// absent) MUST NOT prove completion. Same-turn: agent marker then a matching task_complete in the
// SAME turn MUST prove completion.
await test("A-04: a cross-turn marker proof is ok:false (turn-id-bound completion)", async () => {
  const a04 = path.join(
    fixtures,
    "rollout-a04-crossturn-22222222-2222-4222-8222-222222222222.jsonl",
  );
  const proof = await pollRolloutForMarker(a04, "A04_PROOF_MARKER", 10, 1, {
    now: () => 0,
    sleep: async () => {},
  });
  assert.equal(proof.ok, false);
  assert.equal(
    inspectRolloutMarker(a04, "A04_PROOF_MARKER").taskCompleteAfterAgentMarker,
    false,
  );
});

await test("A-04: a same-turn agent marker plus its matching task_complete is ok:true", async () => {
  const target = path.join(tmp, "rollout-a04-sameturn-22222222-2222-4222-8222-222222222222.jsonl");
  fs.writeFileSync(
    target,
    [
      { type: "session_meta", payload: { id: "22222222-2222-4222-8222-222222222222" } },
      ev("task_started", { turn_id: "turn-1" }),
      ev("user_message", { turn_id: "turn-1", message: "read C:/x/1400000000-4-abcdef0123456789.task.md and proceed" }),
      ev("agent_message", { message: "A04_PROOF_MARKER completed in turn one", phase: "final_answer" }),
      ev("task_complete", { turn_id: "turn-1", last_agent_message: "A04_PROOF_MARKER completed in turn one" }),
    ].map((r) => JSON.stringify(r)).join("\n") + "\n",
  );
  const proof = await pollRolloutForMarker(target, "A04_PROOF_MARKER", 10, 1, {
    now: () => 0,
    sleep: async () => {},
  });
  assert.equal(proof.ok, true);
  assert.equal(inspectRolloutMarker(target, "A04_PROOF_MARKER").taskCompleteAfterAgentMarker, true);
});

// ---- Sanitized wrapper/body/proof repair contract -----------------------------------------------
const WRAPPER_THREAD = "11111111-1111-4111-8111-111111111111";
const WRAPPER_TURN = "22222222-2222-4222-8222-222222222222";
const WRAPPER_TYPES = [
  "AgentMessage",
  "UserMessage",
  "Reasoning",
  "CommandExecution",
  "ContextCompaction",
  "FileChange",
  "SubAgentActivity",
  "CollabAgentToolCall",
  "Extension",
  "McpToolCall",
  "DynamicToolCall",
];
// Named inert classes admitted by owner ruling B-1 (2026-09-03): observed on Codex's own
// thread-delegation path (FunctionCallOutput) and in 2026/03-04 rollouts (Plan).
const INERT_NAMED_TYPES = ["FunctionCallOutput", "Plan"];
const completedItem = (type, extra = {}, outer = {}) => ({
  type: "event_msg",
  payload: {
    type: "item_completed",
    turn_id: WRAPPER_TURN,
    thread_id: WRAPPER_THREAD,
    ...outer,
    item: { id: `item-${type}`, type, ...extra },
  },
});
// Feeds the FULL observation stream (not only retained records) through the boundary machine,
// which is the only path a lifecycle-inert item_completed wrapper ever reaches.
const activityOfRecords = (name, records) => {
  const target = path.join(tmp, `rollout-act-${name}-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(target, `${records.map((r) => JSON.stringify(r)).join("\n")}\n`);
  return readRolloutActivity(target, { rolloutThreadId: WRAPPER_THREAD }).turnActivity;
};

test("repair RED: item_completed normalization is exact, outer-bound, and envelope-discriminated", () => {
  for (const type of WRAPPER_TYPES) {
    const record = normalizeRolloutRecord(
      completedItem(type, { content: [{ type: "output_text", text: `body-${type}` }] }),
      { rolloutThreadId: WRAPPER_THREAD },
    );
    assert.equal(record.knownPair, true, `expected known wrapper type ${type}`);
    assert.equal(record.turnId, WRAPPER_TURN);
    assert.equal(record.threadId, WRAPPER_THREAD);
    if (type !== "UserMessage" && type !== "AgentMessage") {
      assert.equal(record.payloadType, "item_completed", `${type} must remain lifecycle-inert`);
      assert.equal(record.text, "", `${type} must not expose semantic text`);
      assert.equal(record.phase, null, `${type} must not expose a phase`);
      assert.equal(record.role, null, `${type} must not expose a role`);
    }
  }

  const user = normalizeRolloutRecord(
    completedItem("UserMessage", { content: [{ type: "input_text", text: "sanitized task marker" }] }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(user.payloadType, "user_message");
  assert.equal(user.text, "sanitized task marker");

  const agent = normalizeRolloutRecord(
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "sanitized final" }],
    }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(agent.payloadType, "agent_message");
  assert.equal(agent.phase, "final_answer");
  assert.equal(agent.text, "sanitized final");

  for (const bad of [
    completedItem("agent_message"),
    completedItem("FutureItem", { content: [{ type: "output_text", text: "future body" }] }),
    completedItem("AgentMessage", { turn_id: "other-turn" }),
    completedItem("AgentMessage", {}, { turn_id: undefined }),
    completedItem("AgentMessage", {}, { thread_id: "33333333-3333-4333-8333-333333333333" }),
  ]) {
    const rejected = normalizeRolloutRecord(bad, { rolloutThreadId: WRAPPER_THREAD });
    assert.equal(rejected.knownPair, false);
    assert.equal(rejected.text, "");
    assert.equal(rejected.phase, null);
    assert.equal(rejected.role, null);
  }

  const started = normalizeRolloutRecord({
    type: "event_msg",
    payload: {
      type: "item_started",
      turn_id: WRAPPER_TURN,
      item: { type: "AgentMessage", message: "must stay nested" },
    },
  });
  assert.equal(started.payloadType, "item_started");
  assert.equal(started.text, "");
  assert.equal(started.knownPair, false);

  const direct = normalizeRolloutRecord({
    type: "event_msg",
    payload: {
      type: "task_complete",
      turn_id: WRAPPER_TURN,
      last_agent_message: "outer terminal",
      item: { type: "agent_message", message: "nested spoof" },
    },
  });
  assert.equal(direct.payloadType, "task_complete");
  assert.equal(direct.lastAgentMessage, "outer terminal");

  const response = normalizeRolloutRecord({
    type: "response_item",
    payload: {
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: "response root" }],
      item: { type: "user_message", message: "nested spoof" },
    },
  });
  assert.equal(response.payloadType, "message");
  assert.equal(response.text, "response root");
});

test("repair RED: named inert item classes stay lifecycle-neutral and certify their turn", () => {
  for (const type of INERT_NAMED_TYPES) {
    const record = normalizeRolloutRecord(
      completedItem(type, type === "FunctionCallOutput"
        ? { name: "send_message_to_thread", namespace: "codex_app", output: "<delegation/>" }
        : { steps: [{ step: "one", status: "completed" }] }),
      { rolloutThreadId: WRAPPER_THREAD },
    );
    assert.equal(record.knownPair, true, `${type} must be an allowlisted inert class`);
    assert.equal(record.payloadType, "item_completed", `${type} must remain lifecycle-inert`);
    assert.equal(record.text, "", `${type} must not expose semantic text`);
    assert.equal(record.phase, null, `${type} must not expose a phase`);
    assert.equal(record.role, null, `${type} must not expose a role`);
    assert.equal(record.unknownItemClass, null, `${type} is named, not unknown`);
  }

  const dispatch = "8300000000-3-abcdef0123456789";
  const parsed = writeAndRead("inert-named-classes", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    ...INERT_NAMED_TYPES.map((type) => completedItem(type, { output: "opaque" })),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "delegating body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "delegating body" }),
  ]);
  assert.equal(parsed.diagnostics.some((item) => item.code === "schema-drift"), false);
  assert.equal(parsed.diagnostics.some((item) => item.code === "unknown-item-class"), false);
  const result = correlateDispatch(parsed, dispatch);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "delegating body");
  assert.equal(result.lifecycle.certifiable, true);
  assert.equal(activityOfRecords("inert-named-classes-activity", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ...INERT_NAMED_TYPES.map((type) => completedItem(type, { output: "opaque" })),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "x" }),
  ]), "closed");
});

test("repair RED: an unknown item class is inert-but-logged unless it carries body or role fields", () => {
  const inert = normalizeRolloutRecord(
    completedItem("FutureInertItem", { name: "opaque", output: "opaque" }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(inert.knownPair, true);
  assert.equal(inert.payloadType, "item_completed");
  assert.equal(inert.itemType, "FutureInertItem");
  assert.equal(inert.unknownItemClass, "FutureInertItem");
  assert.equal(inert.text, "");
  assert.equal(inert.phase, null);
  assert.equal(inert.role, null);

  for (const key of ["content", "text", "phase", "role"]) {
    const poison = normalizeRolloutRecord(
      completedItem("FutureBodyItem", { [key]: key === "content" ? [] : "x" }),
      { rolloutThreadId: WRAPPER_THREAD },
    );
    assert.equal(poison.knownPair, false, `${key} must keep an unknown class fail-closed`);
    assert.equal(poison.unknownItemClass, null, `${key} is drift, not an inert unknown`);
    assert.equal(poison.text, "");
  }

  const identityBroken = normalizeRolloutRecord(
    completedItem("FutureInertItem", {}, { thread_id: "33333333-3333-4333-8333-333333333333" }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(identityBroken.knownPair, false);
  assert.equal(identityBroken.unknownItemClass, null);

  const dispatch = "8310000000-3-abcdef0123456789";
  const inertParsed = writeAndRead("unknown-inert-class", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    completedItem("FutureInertItem", { name: "opaque", output: "opaque" }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "unaffected body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "unaffected body" }),
  ]);
  assert.equal(inertParsed.diagnostics.some((item) => item.code === "schema-drift"), false);
  const logged = inertParsed.diagnostics.filter((item) => item.code === "unknown-item-class");
  assert.equal(logged.length, 1);
  assert.equal(logged[0].itemType, "FutureInertItem");
  assert.equal(typeof logged[0].line, "number");
  const inertResult = correlateDispatch(inertParsed, dispatch);
  assert.equal(inertResult.status, "complete");
  assert.equal(inertResult.text, "unaffected body");
  assert.equal(inertResult.lifecycle.certifiable, true);

  const poisonDispatch = "8320000000-3-abcdef0123456789";
  const poisonParsed = writeAndRead("unknown-body-class", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${poisonDispatch}.task.md and proceed` }],
    }),
    completedItem("FutureBodyItem", {
      content: [{ type: "output_text", text: "unreadable body" }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "poisoned body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "poisoned body" }),
  ]);
  const drift = poisonParsed.diagnostics.filter((item) => item.code === "schema-drift");
  assert.equal(drift.length, 1);
  assert.equal(drift[0].itemType, "FutureBodyItem");
  const poisonResult = correlateDispatch(poisonParsed, poisonDispatch);
  assert.notEqual(poisonResult.status, "complete");
  assert.equal(poisonResult.lifecycle.certifiable, false);
});

// IPC-ROLLOUT-SCHEMA-AUDIT.md section 11.2 (2026-09-03) relaxed section 6.2 for unknown classes
// and explicitly did NOT relax it for the other two: "Missing class and casing drift are
// unchanged: both remain poison and fail closed." An inert admission must also be able to name
// the class it logs, which a class-less record cannot, so admitting one would certify a turn with
// no audit trail at all. Separator drift is folded in with casing drift; see the reader comment.
test("repair RED: a missing or drifted item class stays poison, never an inert unknown", () => {
  const withoutItemType = () => {
    const record = completedItem("FutureInertItem", { name: "opaque", output: "opaque" });
    delete record.payload.item.type;
    return record;
  };
  const notInert = [
    ["missing class", withoutItemType()],
    ["numeric class", completedItem("FutureInertItem", { type: 7 })],
    ["null class", completedItem("FutureInertItem", { type: null })],
    ["object class", completedItem("FutureInertItem", { type: { a: 1 } })],
    ["lowercase drift on a promoted class", completedItem("agentmessage", { output: "opaque" })],
    ["uppercase drift on a promoted class", completedItem("AGENTMESSAGE", { output: "opaque" })],
    ["mixed-case drift on a promoted class", completedItem("AgentMEssage", { output: "opaque" })],
    ["separator drift on a promoted class", completedItem("agent_message", { output: "opaque" })],
    ["separator drift on a named inert class", completedItem("functioncalloutput", { output: "opaque" })],
    ["mixed drift on a lifecycle-inert class", completedItem("Command_Execution", { output: "opaque" })],
  ];
  for (const [label, record] of notInert) {
    const rejected = normalizeRolloutRecord(record, { rolloutThreadId: WRAPPER_THREAD });
    assert.equal(rejected.knownPair, false, `${label} must stay fail-closed`);
    assert.equal(rejected.unknownItemClass, null, `${label} is not an inert unknown class`);
    assert.equal(rejected.text, "", `${label} must expose no text`);
    assert.equal(rejected.phase, null);
    assert.equal(rejected.role, null);
  }
  // A genuinely new class next to them stays inert, so the assertions above cannot pass merely
  // because every unnamed class is poison again.
  const stillInert = normalizeRolloutRecord(
    completedItem("FutureInertItem", { name: "opaque", output: "opaque" }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(stillInert.knownPair, true);
  assert.equal(stillInert.unknownItemClass, "FutureInertItem");

  // A drifted promoted class whose body sits under a key outside ITEM_BODY_BEARING_KEYS is the
  // case that made this fail-closed condition load-bearing: `message` is read by
  // textFromAllowedFields but is not a poison key, so without the fold a real final answer would
  // have gone inert and unlogged.
  const driftedFinal = normalizeRolloutRecord(
    completedItem("agent_message", { message: "a final answer this reader must not drop" }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(driftedFinal.knownPair, false);
  assert.equal(driftedFinal.unknownItemClass, null);
  assert.equal(driftedFinal.text, "");

  const missingDispatch = "8330000000-3-abcdef0123456789";
  const missingParsed = writeAndRead("missing-item-class", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${missingDispatch}.task.md and proceed` }],
    }),
    withoutItemType(),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "unreachable body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "unreachable body" }),
  ]);
  const missingDrift = missingParsed.diagnostics.filter((item) => item.code === "schema-drift");
  assert.equal(missingDrift.length, 1, "a class-less wrapper emits exactly one schema-drift");
  assert.equal(missingDrift[0].itemType, null);
  assert.equal(
    missingParsed.diagnostics.some((item) => item.code === "unknown-item-class"),
    false,
    "a class-less record must never be admitted as an inert unknown",
  );
  const missingResult = correlateDispatch(missingParsed, missingDispatch);
  assert.notEqual(missingResult.status, "complete");
  assert.equal(missingResult.lifecycle.certifiable, false);
  assert.equal(activityOfRecords("missing-item-class-activity", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    withoutItemType(),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "unreachable body" }),
  ]), "ambiguous");
});

// ---- Envelope-level inert classes (owner decision OD-35, 2026-09-03) -------------------------
// `token_usage_record` is a top-level envelope the producer writes with no `payload.type` at all.
// The shipped reader and every candidate before this change read it as an unknown envelope/payload
// pair, so it poisoned its turn: an ordinary completed turn read `ambiguous` on the producer
// version now in use. The synthetic record below mirrors the observed shape - the same eight
// payload keys - with synthetic identifiers and counts. No observed bytes are reproduced.
const USAGE_BLOCK = {
  input_tokens: 1024,
  cached_input_tokens: 512,
  cache_write_input_tokens: 0,
  output_tokens: 128,
  reasoning_output_tokens: 64,
  total_tokens: 1152,
};
const tokenUsageRecord = (extra = {}) => ({
  type: "token_usage_record",
  payload: {
    thread_id: WRAPPER_THREAD,
    turn_id: WRAPPER_TURN,
    session_id: WRAPPER_THREAD,
    root_turn_id: WRAPPER_TURN,
    response_id: "resp_synthetic_0001",
    usage: { ...USAGE_BLOCK },
    turn_token_usage: { ...USAGE_BLOCK },
    thread_token_usage: { ...USAGE_BLOCK },
    ...extra,
  },
});

test("repair RED: a current-format rollout carrying token_usage_record closes and certifies", () => {
  const record = normalizeRolloutRecord(tokenUsageRecord(), { rolloutThreadId: WRAPPER_THREAD });
  assert.equal(record.knownPair, true, "token_usage_record is a named inert envelope");
  assert.equal(record.envelopeType, "token_usage_record");
  assert.equal(record.payloadType, null);
  assert.equal(record.unknownEnvelopeType, null, "a named envelope is not an unknown one");
  assert.equal(record.text, "", "an inert envelope must not expose semantic text");
  assert.equal(record.role, null);
  assert.equal(record.phase, null);

  // Naming the envelope does not relax record-owner integrity: a thread_id that is not the
  // rollout's own still fails the file closed, exactly as it does for every other record.
  const foreign = normalizeRolloutRecord(
    tokenUsageRecord({ thread_id: "33333333-3333-4333-8333-333333333333" }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(foreign.knownPair, false, "a foreign owner keeps the record fail-closed");

  const dispatch = "8340000000-3-abcdef0123456789";
  const stream = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "current-format body" }],
    }),
    tokenUsageRecord(),
    ev("token_count", { turn_id: WRAPPER_TURN, info: { total_token_usage: { ...USAGE_BLOCK } } }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "current-format body" }),
  ];
  const parsed = writeAndRead("token-usage-record", stream);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.diagnostics.some((item) => item.code === "schema-drift"), false);
  assert.equal(parsed.diagnostics.some((item) => item.code === "unknown-envelope-type"), false);
  const result = correlateDispatch(parsed, dispatch);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "current-format body");
  assert.equal(result.lifecycle.certifiable, true);
  assert.equal(activityOfRecords("token-usage-record-activity", stream), "closed");

  // The marker-proof path reads the same stream through readRolloutFile, so it inherits the
  // envelope rule rather than re-deriving it.
  const markerTarget = path.join(tmp, `rollout-tur-marker-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(markerTarget, `${stream.map((r) => JSON.stringify(r)).join("\n")}\n`);
  const proof = inspectRolloutMarker(markerTarget, "current-format body");
  assert.equal(proof.agentMarkerSeen, true);
  assert.equal(proof.taskCompleteAfterAgentMarker, true);
  assert.equal(proof.error, null);
  assert.equal(proof.parseErrorCount, 0);
});

test("repair RED: an unknown typeless envelope is inert-but-logged and certifies its turn", () => {
  const futureEnvelope = (payload) => ({ type: "future_envelope_x", payload });
  const inert = normalizeRolloutRecord(
    futureEnvelope({ thread_id: WRAPPER_THREAD, turn_id: WRAPPER_TURN, counter: 3 }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(inert.knownPair, true);
  assert.equal(inert.envelopeType, "future_envelope_x");
  assert.equal(inert.payloadType, null);
  assert.equal(inert.unknownEnvelopeType, "future_envelope_x");
  assert.equal(inert.text, "");
  assert.equal(inert.role, null);
  assert.equal(inert.phase, null);

  // A payload-less unknown envelope carries nothing to lose and is admitted on the same terms.
  const bare = normalizeRolloutRecord({ type: "future_envelope_y" }, { rolloutThreadId: WRAPPER_THREAD });
  assert.equal(bare.knownPair, true);
  assert.equal(bare.unknownEnvelopeType, "future_envelope_y");

  const dispatch = "8350000000-3-abcdef0123456789";
  const stream = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    futureEnvelope({ thread_id: WRAPPER_THREAD, turn_id: WRAPPER_TURN, counter: 1 }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "unaffected by the new envelope" }],
    }),
    futureEnvelope({ thread_id: WRAPPER_THREAD, turn_id: WRAPPER_TURN, counter: 2 }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "unaffected by the new envelope" }),
  ];
  const parsed = writeAndRead("unknown-typeless-envelope", stream);
  assert.equal(parsed.diagnostics.some((item) => item.code === "schema-drift"), false);
  const logged = parsed.diagnostics.filter((item) => item.code === "unknown-envelope-type");
  assert.equal(logged.length, 2, "every occurrence is logged, so the diagnostics carry the count");
  assert.equal(logged[0].envelopeType, "future_envelope_x");
  assert.equal(logged[0].payloadType, null);
  assert.equal(typeof logged[0].line, "number");
  // Admitted, but never retained: an inert envelope must not enter the correlation stream.
  assert.equal(
    (parsed.records || []).some((item) => item.envelopeType === "future_envelope_x"),
    false,
    "an inert unknown envelope must never be retained for correlation",
  );
  const result = correlateDispatch(parsed, dispatch);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "unaffected by the new envelope");
  assert.equal(result.lifecycle.certifiable, true);
  assert.equal(activityOfRecords("unknown-typeless-envelope-activity", stream), "closed");
});

// The envelope rule is the twin of owner ruling B-1 for item classes, and it fails closed in the
// same four directions. An unknown envelope that declares a payload type is an unknown PAIR, which
// is what `schema-drift` has always meant; one that carries an item is a wrapper shape whose
// adapter this reader owns; one whose payload is not a plain object, or carries a body- or
// role-bearing key, could hold a reply body the reader would drop while certifying the turn.
test("repair RED: an unknown envelope that declares a pair, an item, or a body stays poison", () => {
  const notInert = [
    ["declared payload type", { type: "future_envelope_x", payload: { type: "future_event" } }],
    ["non-string payload type", { type: "future_envelope_x", payload: { type: 7 } }],
    ["null payload type", { type: "future_envelope_x", payload: { type: null } }],
    [
      "carries an item",
      {
        type: "future_envelope_x",
        payload: { item: { id: "i", type: "AgentMessage", content: [{ text: "hidden" }] } },
      },
    ],
    ["string payload", { type: "future_envelope_x", payload: "a final answer as a bare string" }],
    ["array payload", { type: "future_envelope_x", payload: [{ text: "hidden" }] }],
    ["body under content", { type: "future_envelope_x", payload: { content: [{ text: "hidden" }] } }],
    ["body under text", { type: "future_envelope_x", payload: { text: "hidden" } }],
    ["body under message", { type: "future_envelope_x", payload: { message: "hidden final answer" } }],
    ["role", { type: "future_envelope_x", payload: { role: "assistant" } }],
    ["phase", { type: "future_envelope_x", payload: { phase: "final_answer" } }],
    ["non-string envelope type", { type: 7, payload: { counter: 1 } }],
    ["absent envelope type", { payload: { counter: 1 } }],
  ];
  for (const [label, record] of notInert) {
    const rejected = normalizeRolloutRecord(record, { rolloutThreadId: WRAPPER_THREAD });
    assert.equal(rejected.knownPair, false, `${label} must stay fail-closed`);
    assert.equal(rejected.unknownEnvelopeType, null, `${label} is not an inert unknown envelope`);
  }
  // Deliberately NOT asserted above: that a rejected envelope's `text` is empty. An unknown
  // envelope carrying `content`/`text`/`message` has always had those fields projected onto the
  // normalized record, and this change does not touch that. What makes the record harmless is
  // that `knownPair === false` keeps it out of correlation retention and poisons its turn, which
  // is what the end-to-end fixture below proves. Asserting an empty `text` here would assert a
  // contract the reader has never had.

  // A foreign record owner keeps an otherwise-inert unknown envelope poison.
  const foreign = normalizeRolloutRecord(
    {
      type: "future_envelope_x",
      payload: { thread_id: "33333333-3333-4333-8333-333333333333", counter: 1 },
    },
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(foreign.knownPair, false);
  assert.equal(foreign.unknownEnvelopeType, null);

  // A named envelope next to them is still admitted, so the assertions above cannot pass merely
  // because every unnamed envelope became poison again.
  const stillInert = normalizeRolloutRecord(
    { type: "future_envelope_x", payload: { thread_id: WRAPPER_THREAD, counter: 1 } },
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(stillInert.knownPair, true);
  assert.equal(stillInert.unknownEnvelopeType, "future_envelope_x");

  const poisonDispatch = "8360000000-3-abcdef0123456789";
  const poisonStream = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${poisonDispatch}.task.md and proceed` }],
    }),
    { type: "future_envelope_x", payload: { turn_id: WRAPPER_TURN, message: "unreadable body" } },
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "poisoned body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "poisoned body" }),
  ];
  const poisonParsed = writeAndRead("unknown-envelope-body", poisonStream);
  const drift = poisonParsed.diagnostics.filter((item) => item.code === "schema-drift");
  assert.equal(drift.length, 1, "a body-bearing unknown envelope emits exactly one schema-drift");
  assert.equal(drift[0].envelopeType, "future_envelope_x");
  assert.equal(
    poisonParsed.diagnostics.some((item) => item.code === "unknown-envelope-type"),
    false,
    "a body-bearing envelope must never be admitted as an inert unknown",
  );
  const poisonResult = correlateDispatch(poisonParsed, poisonDispatch);
  assert.notEqual(poisonResult.status, "complete");
  assert.equal(poisonResult.lifecycle.certifiable, false);
  assert.equal(activityOfRecords("unknown-envelope-body-activity", poisonStream), "ambiguous");
});

test("repair RED: semantic event roles are presence-aware across direct, wrapped, and legacy shapes", () => {
  const semanticBody = (semanticType, extra = {}) => ({
    turn_id: WRAPPER_TURN,
    ...(semanticType === "agent_message" ? { phase: "final_answer" } : {}),
    message: `${semanticType}-body`,
    ...extra,
  });
  const shapes = {
    direct: (semanticType, extra = {}) => ({
      type: "event_msg",
      payload: { type: semanticType, ...semanticBody(semanticType, extra) },
    }),
    wrapped: (semanticType, extra = {}) => completedItem(
      semanticType === "agent_message" ? "AgentMessage" : "UserMessage",
      semanticBody(semanticType, extra),
    ),
    legacy: (semanticType, extra = {}) => ({
      type: "event_msg",
      payload: {
        turn_id: WRAPPER_TURN,
        thread_id: WRAPPER_THREAD,
        item: { type: semanticType, ...semanticBody(semanticType, extra) },
      },
    }),
  };
  const contracts = [
    {
      semanticType: "agent_message",
      expectedRole: "assistant",
      wrongRoles: ["user", "system", "tool", null, 7],
    },
    {
      semanticType: "user_message",
      expectedRole: "user",
      wrongRoles: ["assistant", "system", "tool", null, 7],
    },
  ];

  for (const [shapeName, makeRecord] of Object.entries(shapes)) {
    for (const { semanticType, expectedRole, wrongRoles } of contracts) {
      for (const [controlName, extra] of [
        ["absent", {}],
        ["exact", { role: expectedRole }],
      ]) {
        const normalized = normalizeRolloutRecord(makeRecord(semanticType, extra), {
          rolloutThreadId: WRAPPER_THREAD,
        });
        assert.equal(normalized.knownPair, true, `${shapeName}/${semanticType}/${controlName}`);
        assert.equal(normalized.payloadType, semanticType, `${shapeName}/${semanticType}/${controlName}`);
        assert.equal(normalized.text, `${semanticType}-body`, `${shapeName}/${semanticType}/${controlName}`);
        assert.equal(
          normalized.role,
          controlName === "exact" ? expectedRole : null,
          `${shapeName}/${semanticType}/${controlName}`,
        );
      }

      for (const role of wrongRoles) {
        const normalized = normalizeRolloutRecord(makeRecord(semanticType, { role }), {
          rolloutThreadId: WRAPPER_THREAD,
        });
        assert.equal(normalized.knownPair, false, `${shapeName}/${semanticType}/${String(role)}`);
        assert.equal(normalized.payloadType, semanticType, `${shapeName}/${semanticType}/${String(role)}`);
        assert.equal(normalized.text, "", `${shapeName}/${semanticType}/${String(role)}`);
        assert.equal(normalized.role, null, `${shapeName}/${semanticType}/${String(role)}`);
        assert.equal(normalized.phase, null, `${shapeName}/${semanticType}/${String(role)}`);
      }
    }
  }
});

test("repair RED: UUID turn identities compare case-insensitively", () => {
  const caseTurn = "00000000-0000-4000-8000-00000000c0de";
  const upperTurn = caseTurn.toUpperCase();
  const wrapped = normalizeRolloutRecord(
    completedItem("AgentMessage", {
      turn_id: upperTurn,
      phase: "final_answer",
      content: [{ type: "output_text", text: "case-stable body" }],
    }, { turn_id: caseTurn }),
    { rolloutThreadId: WRAPPER_THREAD },
  );
  assert.equal(wrapped.knownPair, true);
  assert.equal(wrapped.turnId, caseTurn);
  assert.equal(wrapped.text, "case-stable body");

  const legacy = normalizeRolloutRecord({
    type: "event_msg",
    payload: {
      turn_id: upperTurn,
      item: {
        type: "user_message",
        turn_id: caseTurn,
        message: "case-stable task",
      },
    },
  });
  assert.equal(legacy.knownPair, true);
  assert.equal(legacy.turnId, caseTurn);
  assert.equal(legacy.text, "case-stable task");
});

await test("repair RED: strict marker proof canonicalizes the expected UUID turn", async () => {
  const marker = "SANITIZED_CASE_MARKER";
  const caseTurn = "00000000-0000-4000-8000-00000000c0de";
  const target = path.join(tmp, `rollout-case-proof-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  fs.appendFileSync(target, `${[
    { type: "event_msg", payload: { type: "task_started", turn_id: caseTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: caseTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: caseTurn, phase: "final_answer", message: marker } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: caseTurn, last_agent_message: marker } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const proof = await pollRolloutForMarker(target, marker, 10, 1, {
    cursor: baseline.cursor,
    expectedTurnId: caseTurn.toUpperCase(),
    expectedThreadId: WRAPPER_THREAD,
    now: () => 0,
    sleep: async () => {},
  });
  assert.equal(proof.ok, true);
});

await test("unchanged rollout polls skip full reads but final revalidation cannot certify", async () => {
  const marker = "SANITIZED_NO_GROWTH_MARKER";
  const target = path.join(tmp, `rollout-no-growth-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  assert.equal(inspectRolloutNoGrowth(target, baseline.cursor).unchanged, true);
  let clock = 0;
  let fullReads = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => { clock += ms; },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
  });
  assert.equal(proof.ok, false);
  assert.equal(proof.attempts, 3);
  assert.equal(fullReads, 1, "only the mandatory final certifying read should run");
});

await test("rollout growth exits the fast path and can certify marker completion", async () => {
  const marker = "SANITIZED_GROWTH_MARKER";
  const target = path.join(tmp, `rollout-growth-fast-path-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  let clock = 0;
  let fullReads = 0;
  let sleeps = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
      sleeps += 1;
      if (sleeps === 1) {
        fs.appendFileSync(target, `${[
          ev("task_started", { turn_id: WRAPPER_TURN }),
          completedItem("UserMessage", {
            content: [{ type: "input_text", text: marker }],
          }),
          completedItem("AgentMessage", {
            phase: "final_answer",
            content: [{ type: "output_text", text: marker }],
          }),
          ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
        ].map((item) => JSON.stringify(item)).join("\n")}\n`);
      }
    },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
  });
  assert.equal(proof.ok, true);
  assert.equal(sleeps, 1);
  assert.equal(fullReads, 1, "growth must immediately re-enter the full reader");
});

await test("strict polling retries a temporarily missing pinned rollout", async () => {
  const marker = "SANITIZED_TRANSIENT_MISSING_MARKER";
  const target = path.join(tmp, `rollout-transient-missing-${WRAPPER_THREAD}.jsonl`);
  const held = `${target}.held`;
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  fs.renameSync(target, held);
  let clock = 0;
  let sleeps = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
      sleeps += 1;
      if (sleeps === 1) {
        fs.appendFileSync(held, `${[
          ev("task_started", { turn_id: WRAPPER_TURN }),
          completedItem("UserMessage", {
            content: [{ type: "input_text", text: marker }],
          }),
          completedItem("AgentMessage", {
            phase: "final_answer",
            content: [{ type: "output_text", text: marker }],
          }),
          ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
        ].map((item) => JSON.stringify(item)).join("\n")}\n`);
        fs.renameSync(held, target);
      }
    },
  });
  assert.equal(proof.ok, true);
  assert.equal(proof.attempts, 2);
  assert.equal(sleeps, 1);
});

await test("strict polling rejects a replacement that appears after a missing read", async () => {
  const marker = "SANITIZED_MISSING_REPLACEMENT_MARKER";
  const target = path.join(tmp, `rollout-missing-replacement-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const baseline = readRolloutFile(target, { retainRecords: false });
  fs.renameSync(target, `${target}.held`);
  let clock = 0;
  let sleeps = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
      sleeps += 1;
      if (sleeps === 1) {
        fs.writeFileSync(target, `${[
          { type: "session_meta", payload: { id: WRAPPER_THREAD } },
          ev("task_started", { turn_id: WRAPPER_TURN }),
          completedItem("UserMessage", {
            content: [{ type: "input_text", text: marker }],
          }),
          completedItem("AgentMessage", {
            phase: "final_answer",
            content: [{ type: "output_text", text: marker }],
          }),
          ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
        ].map((item) => JSON.stringify(item)).join("\n")}\n`);
      }
    },
  });
  assert.equal(proof.ok, false);
  assert.equal(proof.attempts, 2);
  assert.equal(sleeps, 1);
  assert.equal(proof.lastObservation.error, "file-replaced");
});

await test("physical rollout replacement exits the fast path and fails closed", async () => {
  const marker = "SANITIZED_REPLACEMENT_MARKER";
  const target = path.join(tmp, `rollout-replacement-fast-path-${WRAPPER_THREAD}.jsonl`);
  const line = `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`;
  fs.writeFileSync(target, line);
  const baseline = readRolloutFile(target, { retainRecords: false });
  let clock = 0;
  let fullReads = 0;
  let replaced = false;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
      if (!replaced) {
        fs.renameSync(target, `${target}.old`);
        fs.writeFileSync(target, line);
        replaced = true;
      }
    },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
  });
  assert.equal(replaced, true);
  assert.equal(proof.ok, false);
  assert.equal(fullReads, 1);
});

await test("same-size tampering is detected by the forced final certifying read", async () => {
  const marker = "SANITIZED_TAMPER_MARKER";
  const otherOwner = "33333333-3333-4333-8333-333333333333";
  const target = path.join(tmp, `rollout-same-size-fast-path-${WRAPPER_THREAD}.jsonl`);
  const original = `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`;
  const tampered = `${JSON.stringify({ type: "session_meta", payload: { id: otherOwner } })}\n`;
  assert.equal(Buffer.byteLength(tampered), Buffer.byteLength(original));
  fs.writeFileSync(target, original);
  const baseline = readRolloutFile(target, { retainRecords: false });
  let clock = 0;
  let sleeps = 0;
  let fullReads = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async (ms) => {
      clock += ms;
      sleeps += 1;
      if (sleeps === 1) fs.writeFileSync(target, tampered);
    },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
  });
  assert.equal(proof.ok, false);
  assert.equal(proof.attempts, 3);
  assert.equal(sleeps, 2, "one same-size poll must remain non-certifying before the edge");
  assert.equal(fullReads, 1, "the final attempt must run full prefix and owner validation");
});

await test("deadline elapsed during no-growth sleep cannot yield stale certification", async () => {
  const marker = "SANITIZED_DEADLINE_JUMP_MARKER";
  const target = path.join(tmp, `rollout-deadline-jump-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`,
  );
  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: WRAPPER_THREAD,
  });
  let clock = 0;
  let fullReads = 0;
  const proof = await pollRolloutForMarker(target, marker, 10, 3, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => clock,
    sleep: async () => {
      clock = 100;
    },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
  });
  assert.equal(proof.ok, false);
  assert.equal(proof.attempts, 1);
  assert.equal(fullReads, 0);
  assert.match(proof.warnings.join(" "), /did not reach/);
});

test("repair RED: typeless legacy items preserve corroborating outer identity and reject conflicts", () => {
  const outerOnly = normalizeRolloutRecord({
    type: "event_msg",
    payload: {
      turn_id: WRAPPER_TURN,
      thread_id: WRAPPER_THREAD,
      item: { type: "user_message", message: "sanitized legacy marker" },
    },
  }, { rolloutThreadId: WRAPPER_THREAD });
  assert.equal(outerOnly.knownPair, true);
  assert.equal(outerOnly.turnId, WRAPPER_TURN);
  assert.equal(outerOnly.threadId, WRAPPER_THREAD);
  assert.equal(outerOnly.text, "sanitized legacy marker");

  for (const item of [
    { type: "user_message", turn_id: "other-turn", message: "must not correlate" },
    {
      type: "user_message",
      thread_id: "33333333-3333-4333-8333-333333333333",
      message: "must not correlate",
    },
  ]) {
    const conflict = normalizeRolloutRecord({
      type: "event_msg",
      payload: {
        turn_id: WRAPPER_TURN,
        thread_id: WRAPPER_THREAD,
        item,
      },
    }, { rolloutThreadId: WRAPPER_THREAD });
    assert.equal(conflict.knownPair, false);
    assert.equal(conflict.turnId, WRAPPER_TURN);
    assert.equal(conflict.threadId, WRAPPER_THREAD);
    assert.equal(conflict.text, "");
  }
});

test("repair RED: wrapped semantic records correlate while known inert items stay lifecycle-neutral", () => {
  const dispatch = "8100000000-1-abcdef0123456789";
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    ...WRAPPER_TYPES.filter((type) => type !== "UserMessage" && type !== "AgentMessage")
      .map((type) => completedItem(type, { content: [] })),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "wrapped body" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "wrapped body" }),
  ];
  const parsed = writeAndRead("wrapped-complete", records);
  assert.equal(parsed.diagnostics.some((item) => item.code === "schema-drift"), false);
  const result = correlateDispatch(parsed, dispatch);
  assert.equal(result.status, "complete");
  assert.equal(result.text, "wrapped body");
  assert.equal(result.finalMessageCount, 1);
  assert.equal(result.lifecycle.status, "complete");
  assert.equal(result.lifecycle.certifiable, true);
});

test("repair RED: identity-backed user and cross-form agent duplicates collapse", () => {
  const dispatch = "8200000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  const duplicateRecords = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      id: "stable-user-delivery",
      content: [{ type: "input_text", text: marker }],
    }),
    completedItem("UserMessage", {
      id: "stable-user-delivery",
      content: [{ type: "input_text", text: marker }],
    }),
    ev("agent_message", { turn_id: WRAPPER_TURN, phase: "final_answer", message: "one body" }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "one body" }],
    }),
    { type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "one body" }] } },
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "one body" }),
  ];
  const duplicate = correlateDispatch(writeAndRead("wrapped-duplicate", duplicateRecords), dispatch);
  assert.equal(duplicate.status, "complete");
  assert.equal(duplicate.text, "one body");
  assert.equal(duplicate.duplicateCount, 1);
  assert.equal(duplicate.finalMessageCount, 1);

});

test("repair RED: terminal copy selects exactly one of multiple explicit final bodies", () => {
  const dispatch = "8210000000-2-abcdef0123456789";
  const selectedBody = "terminal-selected body";
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", {
      turn_id: WRAPPER_TURN,
      message: `read C:/x/${dispatch}.task.md and proceed`,
    }),
    ev("agent_message", {
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: selectedBody,
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "later nonterminal body" }],
    }),
    ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: selectedBody,
    }),
  ];
  const result = correlateDispatch(writeAndRead("terminal-selects-final", records), dispatch);
  assert.equal(result.status, "complete");
  assert.equal(result.text, selectedBody);
  // Owner ruling D-34 / OD-11 (2026-09-03): the disambiguation is disclosed, not erased. The true
  // number of distinct logical finals is reported, and the certifying path carries a diagnostic
  // saying the terminal copy chose among them. This assertion is the inversion of the absence
  // assertion that stood here; the audit erratum of 2026-09-03 is its authority.
  assert.equal(result.finalMessageCount, 2);
  assert.equal(result.lifecycle.status, "complete");
  assert.equal(result.lifecycle.certifiable, true);
  const disclosure = result.diagnostics.filter(
    (item) => item.code === "terminal-copy-disambiguated",
  );
  assert.equal(disclosure.length, 1);
  assert.equal(disclosure[0].count, 2);
  assert.equal(disclosure[0].turnId, WRAPPER_TURN);
  // The hard-conflict signal stays reserved for turns that do NOT certify.
  assert.equal(
    result.diagnostics.some((item) => item.code === "multiple-final-message-bodies"),
    false,
  );

  // A single final body certifies with neither the count inflated nor the disclosure emitted.
  const soleDispatch = "8211000000-2-abcdef0123456789";
  const sole = correlateDispatch(writeAndRead("terminal-single-final", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: `read C:/x/${soleDispatch}.task.md and proceed` }),
    ev("agent_message", { turn_id: WRAPPER_TURN, phase: "final_answer", message: "only body" }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "only body" }),
  ]), soleDispatch);
  assert.equal(sole.status, "complete");
  assert.equal(sole.finalMessageCount, 1);
  assert.equal(
    sole.diagnostics.some((item) => item.code === "terminal-copy-disambiguated"),
    false,
  );
});

test("repair RED: an item_completed wrapper reaches the boundary machine and closes its turn", () => {
  // F2 gap: every other wrapper test feeds correlateDispatch, whose record stream is filtered to
  // RETAINED records, so no test had ever pushed an item_completed wrapper through the turn
  // boundary accumulator itself. readRolloutActivity feeds the FULL observation stream, which is
  // the path the observer, the waiter and the write-proof preflight actually use.
  const closed = activityOfRecords("wrapper-through-accumulator", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: "current-format user delivery" }],
    }),
    completedItem("Reasoning", { content: [] }),
    completedItem("CommandExecution", { content: [] }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "current-format final" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "current-format final" }),
  ]);
  assert.equal(closed, "closed");

  // The same stream with one in-turn unknown body-bearing class must still read ambiguous, so the
  // test cannot pass merely because wrappers are invisible to the machine.
  const poisoned = activityOfRecords("wrapper-through-accumulator-drift", [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: "current-format user delivery" }],
    }),
    completedItem("FutureBodyItem", {
      content: [{ type: "output_text", text: "unreadable" }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "current-format final" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "current-format final" }),
  ]);
  assert.equal(poisoned, "ambiguous");
});

await test("repair RED: strict marker proof binds the terminal-selected final rather than record order", async () => {
  const marker = "SANITIZED_TERMINAL_SELECTED_MARKER";
  const selectedBody = `${marker}: terminal-selected body`;
  const target = path.join(tmp, `rollout-terminal-selected-proof-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`,
  );
  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: WRAPPER_THREAD,
  });
  fs.appendFileSync(target, `${[
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      id: "terminal-selected-user-delivery",
      content: [{ type: "input_text", text: `controlled task ${marker}` }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: selectedBody }],
    }),
    ev("agent_message", {
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: "later nonterminal body",
    }),
    ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: selectedBody,
    }),
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const proof = await pollRolloutForMarker(target, marker, 10, 1, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => 0,
    sleep: async () => {},
  });
  assert.equal(proof.ok, true);
});

test("repair RED: multiple explicit finals fail closed without one exact terminal match", () => {
  const dispatch = "8220000000-2-abcdef0123456789";
  const prefix = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", {
      turn_id: WRAPPER_TURN,
      message: `read C:/x/${dispatch}.task.md and proceed`,
    }),
    ev("agent_message", {
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: "candidate body A",
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "candidate body B" }],
    }),
  ];
  for (const [name, terminal] of [
    ["nonmatching", ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: "candidate body C",
    })],
    ["empty", ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: "",
    })],
    ["missing", ev("task_complete", { turn_id: WRAPPER_TURN })],
  ]) {
    const result = correlateDispatch(
      writeAndRead(`terminal-selection-${name}`, [...prefix, terminal]),
      dispatch,
    );
    assert.equal(result.status, "none", name);
    assert.equal(result.reason, "unavailable", name);
    assert.equal(result.text, null, name);
    assert.equal(result.lifecycle.status, "unavailable", name);
    assert.equal(result.lifecycle.certifiable, false, name);
  }
});

test("repair RED: phase-less cross-form dedup preserves provenance in either order", () => {
  const dispatch = "8230000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  const directLegacy = ev("agent_message", {
    turn_id: WRAPPER_TURN,
    message: "legacy terminal body",
  });
  const wrappedModern = completedItem("AgentMessage", {
    content: [{ type: "output_text", text: "legacy terminal body" }],
  });
  for (const [name, semanticRecords] of [
    ["wrapped-first", [wrappedModern, directLegacy]],
    ["legacy-first", [directLegacy, wrappedModern]],
  ]) {
    const records = [
      { type: "session_meta", payload: { id: WRAPPER_THREAD } },
      ev("task_started", { turn_id: WRAPPER_TURN }),
      ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
      ...semanticRecords,
      ev("task_complete", {
        turn_id: WRAPPER_TURN,
        last_agent_message: "legacy terminal body",
      }),
    ];
    const result = correlateDispatch(writeAndRead(`phase-less-${name}`, records), dispatch);
    assert.equal(result.status, "complete", name);
    assert.equal(result.text, "legacy terminal body", name);
    assert.equal(result.lifecycle.certifiable, true, name);
  }
});

test("repair RED: in-turn pre-marker malformed JSON blocks lifecycle and harvest certification", () => {
  const dispatch = "8250000000-2-abcdef0123456789";
  const target = path.join(tmp, `rollout-pre-marker-malformed-${WRAPPER_THREAD}.jsonl`);
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    "{malformed-json",
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "must not be served" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "must not be served" }),
  ];
  fs.writeFileSync(
    target,
    `${records.map((record) => typeof record === "string" ? record : JSON.stringify(record)).join("\n")}\n`,
  );
  const result = correlateDispatch(readRolloutFile(target), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
  assert.ok(result.diagnostics.some((item) => item.code === "malformed-json"));
});

test("repair RED: a turn the boundary machine calls ambiguous can never be certified", () => {
  const dispatch = "8270000000-2-abcdef0123456789";
  const target = path.join(tmp, `rollout-unbound-fail-open-${WRAPPER_THREAD}.jsonl`);
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    "{bad json}",
    ev("user_message", { message: `read C:/x/${dispatch}.task.md and proceed` }),
    ev("agent_message", { phase: "final_answer", message: "leaked body" }),
    ev("task_complete", { last_agent_message: "leaked body" }),
  ];
  fs.writeFileSync(
    target,
    `${records.map((record) => typeof record === "string" ? record : JSON.stringify(record)).join("\n")}\n`,
  );
  // The same file, the same parse: the activity projection and the dispatch projection are two
  // views of one boundary machine and must not disagree about whether the turn is trustworthy.
  const activity = readRolloutActivity(target, { rolloutThreadId: WRAPPER_THREAD });
  assert.equal(activity.turnActivity, "ambiguous");
  assert.equal(activity.boundarySnapshot.boundaryMode, "unbound");

  const result = correlateDispatch(readRolloutFile(target), dispatch);
  assert.equal(result.lifecycle.certifiable, false);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.status, "none");
  assert.equal(result.text, null);
  assert.ok(result.diagnostics.some((item) => item.code === "malformed-json"));
});

test("repair RED: a repeated identical user event remains an intervening-user refusal", () => {
  const dispatch = "8260000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started"),
    ev("user_message", { message: marker }),
    ev("agent_message", { phase: "final_answer", message: "must not be served" }),
    ev("user_message", { message: marker }),
    ev("task_complete", { last_agent_message: "must not be served" }),
  ];
  const result = correlateDispatch(writeAndRead("repeated-user-event", records), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "ambiguous");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
  assert.ok(result.diagnostics.some((item) => item.code === "intervening-user-message"));
});

test("repair RED: same-text cross-form user after agent output is a new delivery", () => {
  const dispatch = "8262000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "must not be served" }],
    }),
    completedItem("UserMessage", {
      id: "distinct-later-item",
      content: [{ type: "input_text", text: marker }],
    }),
    ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: "must not be served",
    }),
  ];
  const result = correlateDispatch(writeAndRead("cross-form-later-user", records), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "ambiguous");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
  assert.ok(result.diagnostics.some((item) => item.code === "intervening-user-message"));
});

test("repair RED: a final before the dispatch marker cannot certify that dispatch", () => {
  const dispatch = "8265000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("agent_message", {
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: "earlier unrelated final",
    }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
    ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: "earlier unrelated final",
    }),
  ];
  const result = correlateDispatch(writeAndRead("pre-marker-final", records), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unavailable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "complete");
  assert.equal(result.lifecycle.certifiable, false);
});

test("repair RED: a wrapped agent body without final_answer phase cannot certify", () => {
  const dispatch = "8266000000-2-abcdef0123456789";
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    completedItem("AgentMessage", {
      content: [{ type: "output_text", text: "must not be served" }],
    }),
    ev("task_complete", {
      turn_id: WRAPPER_TURN,
      last_agent_message: "must not be served",
    }),
  ];
  const result = correlateDispatch(writeAndRead("wrapped-phase-missing", records), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unavailable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "complete");
  assert.equal(result.lifecycle.certifiable, false);
});

test("repair RED: an explicit final requires one matching terminal body copy", () => {
  const dispatch = "8270000000-2-abcdef0123456789";
  const marker = `read C:/x/${dispatch}.task.md and proceed`;
  for (const [name, terminal] of [
    ["null", ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: null })],
    ["missing", ev("task_complete", { turn_id: WRAPPER_TURN })],
  ]) {
    const records = [
      { type: "session_meta", payload: { id: WRAPPER_THREAD } },
      ev("task_started", { turn_id: WRAPPER_TURN }),
      ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
      ev("agent_message", {
        turn_id: WRAPPER_TURN,
        phase: "final_answer",
        message: "must not be served",
      }),
      terminal,
    ];
    const result = correlateDispatch(writeAndRead(`terminal-copy-${name}`, records), dispatch);
    assert.equal(result.status, "none", name);
    assert.equal(result.reason, "unavailable", name);
    assert.equal(result.text, null, name);
    assert.equal(result.lifecycle.status, "unavailable", name);
    assert.equal(result.lifecycle.certifiable, false, name);
    assert.ok(
      result.diagnostics.some((item) => item.code === "completion-message-mismatch"),
      name,
    );
  }
});

test("repair RED: in-turn schema drift blocks both lifecycle and served rollout body", () => {
  const dispatch = "8300000000-3-abcdef0123456789";
  const records = [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      content: [{ type: "input_text", text: `read C:/x/${dispatch}.task.md and proceed` }],
    }),
    { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: WRAPPER_TURN } },
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: "must not be served" }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "must not be served" }),
  ];
  const result = correlateDispatch(writeAndRead("wrapped-drift", records), dispatch);
  assert.equal(result.status, "none");
  assert.equal(result.reason, "unparseable");
  assert.equal(result.text, null);
  assert.equal(result.lifecycle.status, "unavailable");
  assert.equal(result.lifecycle.certifiable, false);
});

test("repair RED: injected rollout owner cannot disagree with a reader cursor", () => {
  const ownerA = WRAPPER_THREAD;
  const ownerB = "33333333-3333-4333-8333-333333333333";
  const target = path.join(tmp, `rollout-cursor-owner-option-${ownerA}.jsonl`);
  fs.writeFileSync(
    target,
    `${JSON.stringify({ type: "session_meta", payload: { id: ownerA } })}\n`,
  );
  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: ownerA,
  });
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);

  const mismatched = readRolloutFile(target, {
    cursor: baseline.cursor,
    retainRecords: false,
    rolloutThreadId: ownerB,
  });
  assert.equal(mismatched.ok, false);
  assert.equal(mismatched.integrityValidated, false);
});

await test("repair RED: a cursor revalidates its first owner beyond the trailing anchor", async () => {
  const ownerA = WRAPPER_THREAD;
  const ownerB = "33333333-3333-4333-8333-333333333333";
  const marker = "SANITIZED_CURSOR_OWNER_MARKER";
  const target = path.join(tmp, `rollout-cursor-owner-rewrite-${ownerA}.jsonl`);
  const ownerLineA = `${JSON.stringify({ type: "session_meta", payload: { id: ownerA } })}\n`;
  const ownerLineB = `${JSON.stringify({ type: "session_meta", payload: { id: ownerB } })}\n`;
  assert.equal(Buffer.byteLength(ownerLineA), Buffer.byteLength(ownerLineB));
  fs.writeFileSync(target, `${ownerLineA}${JSON.stringify({
    type: "world_state",
    payload: { padding: "x".repeat(7000) },
  })}\n`);

  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: ownerA,
  });
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);
  assert.ok(baseline.cursor.size > 6 * 1024);
  assert.ok(Buffer.byteLength(ownerLineA) < baseline.cursor.anchorEndOffset - 4096);

  const beforeRewrite = fs.statSync(target, { bigint: true });
  const descriptor = fs.openSync(target, "r+");
  try {
    const ownerBytes = Buffer.from(ownerLineB, "utf8");
    assert.equal(fs.writeSync(descriptor, ownerBytes, 0, ownerBytes.length, 0), ownerBytes.length);
  } finally {
    fs.closeSync(descriptor);
  }
  const afterRewrite = fs.statSync(target, { bigint: true });
  assert.equal(afterRewrite.dev, beforeRewrite.dev);
  assert.equal(afterRewrite.ino, beforeRewrite.ino);
  assert.equal(afterRewrite.size, beforeRewrite.size);

  fs.appendFileSync(target, `${[
    ev("task_started", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
    }),
    ev("user_message", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      message: marker,
    }),
    ev("agent_message", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: marker,
    }),
    ev("task_complete", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      last_agent_message: marker,
    }),
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const delta = readRolloutFile(target, {
    cursor: baseline.cursor,
    retainRecords: false,
    rolloutThreadId: ownerA,
  });
  const proof = await pollRolloutForMarker(target, marker, 10, 1, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: ownerA,
    now: () => 0,
    sleep: async () => {},
  });
  assert.deepEqual(
    { deltaOk: delta.ok, proofOk: proof.ok },
    { deltaOk: false, proofOk: false },
  );
});

await test("repair RED: a cursor revalidates every consumed owner-bearing prefix record", async () => {
  const ownerA = WRAPPER_THREAD;
  const ownerB = "33333333-3333-4333-8333-333333333333";
  const marker = "SANITIZED_CURSOR_PREFIX_MARKER";
  const target = path.join(tmp, `rollout-cursor-prefix-rewrite-${ownerA}.jsonl`);
  const meta = { type: "session_meta", payload: { id: ownerA } };
  const ownedA = {
    type: "event_msg",
    payload: { type: "token_count", thread_id: ownerA, info: { total: 1 } },
  };
  const ownedB = {
    ...ownedA,
    payload: { ...ownedA.payload, thread_id: ownerB },
  };
  const ownedLineA = JSON.stringify(ownedA);
  const ownedLineB = JSON.stringify(ownedB);
  assert.equal(Buffer.byteLength(ownedLineA), Buffer.byteLength(ownedLineB));
  fs.writeFileSync(target, `${[
    JSON.stringify(meta),
    ownedLineA,
    JSON.stringify({ type: "world_state", payload: { padding: "x".repeat(9000) } }),
  ].join("\n")}\n`);

  const baseline = readRolloutFile(target, {
    retainRecords: false,
    rolloutThreadId: ownerA,
  });
  assert.equal(baseline.ok, true);
  assert.equal(isCompleteReaderCursor(baseline.cursor), true);
  assert.ok(Buffer.byteLength(ownedLineA) < baseline.cursor.anchorEndOffset - 4096);

  const original = fs.readFileSync(target, "utf8");
  fs.writeFileSync(target, original.replace(ownedLineA, ownedLineB));
  fs.appendFileSync(target, `${[
    ev("task_started", { thread_id: ownerA, turn_id: WRAPPER_TURN }),
    ev("user_message", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      message: marker,
    }),
    ev("agent_message", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      phase: "final_answer",
      message: marker,
    }),
    ev("task_complete", {
      thread_id: ownerA,
      turn_id: WRAPPER_TURN,
      last_agent_message: marker,
    }),
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  const delta = readRolloutFile(target, {
    cursor: baseline.cursor,
    retainRecords: false,
    rolloutThreadId: ownerA,
  });
  const proof = await pollRolloutForMarker(target, marker, 10, 1, {
    cursor: baseline.cursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: ownerA,
    now: () => 0,
    sleep: async () => {},
  });
  assert.deepEqual(
    { deltaOk: delta.ok, proofOk: proof.ok },
    { deltaOk: false, proofOk: false },
  );
  assert.ok(delta.diagnostics.some((item) => item.code === "consumed-prefix-changed"));
});

await test("repair RED: strict marker proof starts at a cursor and binds phase, body, turn, and drift", async () => {
  const marker = "SANITIZED_PROOF_MARKER";
  const makeTarget = (name, appended) => {
    const target = path.join(tmp, `rollout-proof-${name}-${WRAPPER_THREAD}.jsonl`);
    fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
    const baseline = readRolloutFile(target, { retainRecords: false });
    fs.appendFileSync(target, `${appended.map((item) => JSON.stringify(item)).join("\n")}\n`);
    return { target, cursor: baseline.cursor };
  };
  const strictPoll = ({ target, cursor }, expectedTurnId = WRAPPER_TURN) => pollRolloutForMarker(
    target,
    marker,
    10,
    1,
    {
      cursor,
      expectedTurnId,
      expectedThreadId: WRAPPER_THREAD,
      now: () => 0,
      sleep: async () => {},
    },
  );

  const oldTarget = path.join(tmp, `rollout-proof-old-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(oldTarget, [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    ev("task_started", { turn_id: "old-turn" }),
    ev("agent_message", { phase: "final_answer", message: marker }),
    ev("task_complete", { turn_id: "old-turn", last_agent_message: marker }),
  ].map((item) => JSON.stringify(item)).join("\n") + "\n");
  const oldCursor = readRolloutFile(oldTarget, { retainRecords: false }).cursor;
  assert.equal((await strictPoll({ target: oldTarget, cursor: oldCursor })).ok, false);

  const unownedTarget = path.join(tmp, "rollout-proof-unowned.jsonl");
  fs.writeFileSync(unownedTarget, "");
  const unownedCursor = readRolloutFile(unownedTarget, { retainRecords: false }).cursor;
  fs.appendFileSync(unownedTarget, [
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
    ev("agent_message", { turn_id: WRAPPER_TURN, phase: "final_answer", message: marker }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
  ].map((item) => JSON.stringify(item)).join("\n") + "\n");
  assert.equal(
    (await strictPoll({ target: unownedTarget, cursor: unownedCursor })).ok,
    false,
    "strict proof requires an independently observed rollout thread owner",
  );

  const rebound = makeTarget("owner-rebound", [
    { type: "session_meta", payload: { id: "33333333-3333-4333-8333-333333333333" } },
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
    ev("agent_message", { turn_id: WRAPPER_TURN, phase: "final_answer", message: marker }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
  ]);
  assert.equal(
    (await strictPoll(rebound)).ok,
    false,
    "a post-cursor session owner change invalidates strict proof",
  );

  const positive = makeTarget("positive", [
    ev("task_started", { turn_id: WRAPPER_TURN }),
    completedItem("UserMessage", {
      id: "proof-user-delivery",
      content: [{ type: "input_text", text: `controlled task ${marker}` }],
    }),
    completedItem("UserMessage", {
      id: "proof-user-delivery",
      content: [{ type: "input_text", text: `controlled task ${marker}` }],
    }),
    completedItem("AgentMessage", {
      phase: "final_answer",
      content: [{ type: "output_text", text: marker }],
    }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
  ]);
  assert.equal((await strictPoll(positive)).ok, true);
  assert.equal(
    (await strictPoll({
      target: positive.target,
      cursor: { partialBase64: "", rolloutThreadId: WRAPPER_THREAD },
    })).ok,
    false,
    "strict proof rejects a partial forged cursor that can replay old records",
  );
  assert.equal(
    (await pollRolloutForMarker(positive.target, marker, 10, 1, {
      cursor: positive.cursor,
      expectedTurnId: WRAPPER_TURN,
      now: () => 0,
      sleep: async () => {},
    })).ok,
    false,
    "strict proof requires expected thread identity as one atomic contract",
  );

  const largeTarget = path.join(tmp, `rollout-proof-large-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(largeTarget, [
    { type: "session_meta", payload: { id: WRAPPER_THREAD } },
    { type: "world_state", payload: { padding: "x".repeat(5000) } },
  ].map((item) => JSON.stringify(item)).join("\n") + "\n");
  const largeCursor = readRolloutFile(largeTarget, { retainRecords: false }).cursor;
  fs.appendFileSync(largeTarget, [
    ev("task_started", { turn_id: WRAPPER_TURN }),
    ev("user_message", { turn_id: WRAPPER_TURN, message: marker }),
    ev("agent_message", { turn_id: WRAPPER_TURN, phase: "final_answer", message: marker }),
    ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
  ].map((item) => JSON.stringify(item)).join("\n") + "\n");
  assert.equal(
    (await strictPoll({ target: largeTarget, cursor: largeCursor })).ok,
    true,
    "reader-issued EOF cursors remain valid when the anchor hashes a trailing 4 KiB window",
  );

  for (const [name, appended, expectedTurnId] of [
    ["commentary", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "commentary", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], WRAPPER_TURN],
    ["body-mismatch", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: "different terminal" }),
    ], WRAPPER_TURN],
    ["terminal-null", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: null }),
    ], WRAPPER_TURN],
    ["terminal-missing", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN }),
    ], WRAPPER_TURN],
    ["user-after-final", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: "operator interruption" }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], WRAPPER_TURN],
    ["user-before-final", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: "operator changed the task" }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], WRAPPER_TURN],
    ["wrong-turn", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], "33333333-3333-4333-8333-333333333333"],
    ["missing-user-marker", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], WRAPPER_TURN],
    ["drift", [
      ev("task_started", { turn_id: WRAPPER_TURN }),
      completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
      completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
      { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: WRAPPER_TURN } },
      ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
    ], WRAPPER_TURN],
  ]) {
    assert.equal((await strictPoll(makeTarget(name, appended), expectedTurnId)).ok, false, name);
  }

  const multiTarget = path.join(tmp, `rollout-proof-multipoll-${WRAPPER_THREAD}.jsonl`);
  fs.writeFileSync(multiTarget, `${JSON.stringify({ type: "session_meta", payload: { id: WRAPPER_THREAD } })}\n`);
  const multiCursor = readRolloutFile(multiTarget, { retainRecords: false }).cursor;
  let multiNow = 0;
  let multiSleeps = 0;
  const multiProof = await pollRolloutForMarker(multiTarget, marker, 10, 3, {
    cursor: multiCursor,
    expectedTurnId: WRAPPER_TURN,
    expectedThreadId: WRAPPER_THREAD,
    now: () => multiNow,
    sleep: async (ms) => {
      multiNow += ms;
      multiSleeps += 1;
      const chunk = multiSleeps === 1
        ? [
            ev("task_started", { turn_id: WRAPPER_TURN }),
            completedItem("UserMessage", { content: [{ type: "input_text", text: marker }] }),
          ]
        : [
            completedItem("AgentMessage", { phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
            ev("task_complete", { turn_id: WRAPPER_TURN, last_agent_message: marker }),
          ];
      fs.appendFileSync(multiTarget, `${chunk.map((item) => JSON.stringify(item)).join("\n")}\n`);
    },
  });
  assert.equal(multiProof.ok, true);
  assert.equal(multiSleeps, 2);

  const proofSource = fs.readFileSync(
    path.join(path.dirname(process.env.MODULE), "codex_ipc_write_proof.mjs"),
    "utf8",
  );
  assert.match(
    proofSource,
    /locateRollout\(\{\s*threadId:\s*opts\.threadId,\s*rolloutPath,?\s*\}\)/s,
  );
  assert.match(proofSource, /rolloutBinding\.status\s*!==\s*"found"/);
  assert.match(
    proofSource,
    /readRolloutActivity\(rolloutBinding\.path,\s*\{\s*retainRecords:\s*false,\s*rolloutThreadId:\s*opts\.threadId,\s*expectedIdentityKey:\s*rolloutBinding\.candidates\?\.\[0\]\?\.identityKey,?\s*\}\)/s,
  );
  assert.match(proofSource, /cursor:\s*rolloutBaseline\.cursor/);
  assert.match(proofSource, /rolloutBaseline\.cursor\.rolloutThreadId/);
  assert.match(proofSource, /rollout-thread-id-mismatch/);
  assert.match(proofSource, /expectedTurnId:\s*sendTurnId/);
  assert.match(proofSource, /expectedThreadId:\s*opts\.threadId/);
  const auditSource = fs.readFileSync(
    path.join(path.dirname(process.env.MODULE), "codex_ipc_contract_audit.mjs"),
    "utf8",
  );
  assert.match(auditSource, /authorizeBaselineAndSend/);
  assert.doesNotMatch(
    auditSource,
    /writeProofText\.indexOf/,
    "the contract audit must not treat formatting-sensitive source order as behavioral proof",
  );
  const req011Source = auditSource.match(
    /check\("REQ-011"[\s\S]*?check\("REQ-018"/,
  )?.[0];
  assert.ok(req011Source, "REQ-011 must remain present in the contract audit");
  assert.doesNotMatch(
    req011Source,
    /["']"ok": true["']/,
    "REQ-011 must not depend on pretty-printed client JSON",
  );
  for (const certificationAnchor of [
    "writeProofSendMarkerTask",
    String.raw`commandReportedSuccess\s*=\s*command\.ok\s*&&\s*parsed\?\.ok\s*===\s*true`,
    String.raw`targetThreadBound\s*=\s*parsed\?\.targetThreadId\s*===\s*opts\.threadId`,
    String.raw`responseReportedSuccess\s*=\s*parsed\?\.response\?\.resultType\s*===\s*"success"`,
    String.raw`clientReportedSuccess\s*=\s*commandReportedSuccess\s*&&\s*targetThreadBound\s*&&\s*responseReportedSuccess`,
    String.raw`exactOneTargetSend\s*=\s*followerRequests\.length\s*===\s*1\s*&&\s*matchingFollowerRequests\.length\s*===\s*1`,
    String.raw`clientResultCertified\s*=\s*clientReportedSuccess\s*&&\s*exactOneTargetSend`,
    String.raw`ok:\s*clientResultCertified`,
  ]) {
    assert.ok(req011Source.includes(certificationAnchor), certificationAnchor);
  }
  const req015Source = auditSource.match(
    /check\("REQ-015"[\s\S]*?check\("REQ-016"/,
  )?.[0];
  assert.ok(req015Source, "REQ-015 must remain present in the contract audit");
  assert.doesNotMatch(
    req015Source,
    /["']"ok": true["']/,
    "REQ-015 must not depend on pretty-printed inspector JSON",
  );
  for (const structuralAnchor of [
    "inspectedTargetClassifier",
    "classify_inspected_target",
    String.raw`value\?\.ok\s*!==\s*true`,
    String.raw`db\?\.exists\s*===\s*true`,
    String.raw`db\?\.readOnlyOpenOk\s*===\s*true`,
    String.raw`thread\?\.exists\s*!==\s*true`,
    String.raw`typeof\s+thread\.id`,
    String.raw`thread\.id\.toLowerCase`,
    String.raw`thread\.archived\s*===\s*1`,
    String.raw`thread\.archived\s*!==\s*0`,
  ]) {
    assert.ok(req015Source.includes(structuralAnchor), structuralAnchor);
  }
  const req016Source = auditSource.match(
    /check\("REQ-016"[\s\S]*?check\("REQ-017"/,
  )?.[0];
  assert.ok(req016Source, "REQ-016 must remain present in the contract audit");
  assert.doesNotMatch(
    req016Source,
    /["']"ok": true["']/,
    "REQ-016 must not depend on pretty-printed client JSON",
  );
  for (const successAnchor of [
    "authoritativeSuccessClassifier",
    "initialLiveSendPath",
    "postAutoloadRetryPath",
    String.raw`const\s+target\s*=\s*String\(process\.argv\[1\]\s*\|\|\s*""\)\.toLowerCase\(\)`,
    String.raw`value\?\.ok\s*===\s*true`,
    String.raw`String\(value\?\.targetThreadId\s*\|\|\s*""\)\.toLowerCase\(\)\s*===\s*target`,
    String.raw`value\?\.response\?\.resultType\s*===\s*"success"`,
    String.raw`Array\.isArray\(value\?\.sentRequests\)`,
    String.raw`item\?\.name\s*===\s*"thread-follower-start-turn"`,
    String.raw`item\?\.json\?\.method\s*===\s*"thread-follower-start-turn"`,
    String.raw`followers\.length\s*===\s*1`,
    String.raw`follower\?\.name\s*===\s*"thread-follower-start-turn"`,
    String.raw`follower\?\.json\?\.method\s*===\s*"thread-follower-start-turn"`,
    String.raw`typeof\s+follower\?\.json\?\.params\?\.conversationId\s*===\s*"string"`,
    String.raw`follower\.json\.params\.conversationId\.toLowerCase\(\)\s*===\s*target`,
  ]) {
    assert.ok(req016Source.includes(successAnchor), successAnchor);
  }
});

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
