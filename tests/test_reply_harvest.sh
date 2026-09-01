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
const { DEFAULT_OBSERVE_BUDGET_MS, observeRollout } = await import(pathToFileURL(process.env.OBSERVER));
const { inspectRolloutNoGrowth, readRolloutFile } = await import(
  new URL("./codex_ipc_rollout_reader.mjs", pathToFileURL(process.env.OBSERVER)),
);
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
const cleanBasic = path.join(
  tmp,
  "rollout-clean-11111111-1111-4111-8111-111111111111.jsonl",
);
const basicRecords = fs.readFileSync(basic, "utf8").trimEnd().split(/\r?\n/);
fs.writeFileSync(cleanBasic, `${basicRecords.slice(0, -1).join("\n")}\n`);
const uniqueBasic = path.join(
  tmp,
  "rollout-unique-11111111-1111-4111-8111-111111111111.jsonl",
);
const mirroredBasic = path.join(
  tmp,
  "rollout-mirrored-11111111-1111-4111-8111-111111111111.jsonl",
);
const uniqueTurn = "33333333-3333-4333-8333-333333333333";
const uniqueMarker = `read C:/synthetic/${dispatch}.task.md and proceed`;
fs.writeFileSync(uniqueBasic, `${[
  { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
  { type: "event_msg", payload: { type: "task_started", turn_id: uniqueTurn } },
  { type: "event_msg", payload: { type: "user_message", turn_id: uniqueTurn, message: uniqueMarker } },
  { type: "event_msg", payload: { type: "agent_message", turn_id: uniqueTurn, phase: "final_answer", message: "latest final" } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: uniqueTurn, last_agent_message: "latest final" } },
].map((item) => JSON.stringify(item)).join("\n")}\n`);
const mirroredUser = {
  type: "event_msg",
  payload: {
    type: "item_completed",
    turn_id: uniqueTurn,
    thread_id: "11111111-1111-4111-8111-111111111111",
    item: {
      id: "stable-user-delivery",
      type: "UserMessage",
      content: [{ type: "input_text", text: uniqueMarker }],
    },
  },
};
fs.writeFileSync(mirroredBasic, `${[
  { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
  { type: "event_msg", payload: { type: "task_started", turn_id: uniqueTurn } },
  mirroredUser,
  mirroredUser,
  { type: "event_msg", payload: { type: "agent_message", turn_id: uniqueTurn, phase: "final_answer", message: "mirrored final" } },
  {
    type: "event_msg",
    payload: {
      type: "item_completed",
      turn_id: uniqueTurn,
      thread_id: "11111111-1111-4111-8111-111111111111",
      item: {
        id: "stable-agent-delivery",
        type: "AgentMessage",
        phase: "final_answer",
        content: [{ type: "output_text", text: "mirrored final" }],
      },
    },
  },
  { type: "event_msg", payload: { type: "task_complete", turn_id: uniqueTurn, last_agent_message: "mirrored final" } },
].map((item) => JSON.stringify(item)).join("\n")}\n`);

async function swapAfterLocatorValidation(target, replacementRecords, action) {
  const originalOpen = fs.openSync;
  const originalClose = fs.closeSync;
  const targetPath = path.resolve(target);
  const locatorDescriptors = new Set();
  let armed = true;
  let injected = false;
  fs.openSync = function injectedOpen(filePath, ...args) {
    const descriptor = originalOpen.call(fs, filePath, ...args);
    if (armed && path.resolve(String(filePath)) === targetPath) {
      locatorDescriptors.add(descriptor);
    }
    return descriptor;
  };
  fs.closeSync = function injectedClose(descriptor, ...args) {
    const isLocatorDescriptor = armed && locatorDescriptors.has(descriptor);
    const result = originalClose.call(fs, descriptor, ...args);
    if (isLocatorDescriptor) {
      armed = false;
      locatorDescriptors.delete(descriptor);
      fs.writeFileSync(
        target,
        `${replacementRecords.map((item) => JSON.stringify(item)).join("\n")}\n`,
      );
      injected = true;
    }
    return result;
  };
  try {
    return { result: await action(), injected };
  } finally {
    fs.openSync = originalOpen;
    fs.closeSync = originalClose;
  }
}

function rolloutReadBindings(sourcePath) {
  const source = fs.readFileSync(sourcePath, "utf8");
  return [...source.matchAll(/\breadRolloutFile(?:Impl)?\s*\(/g)].map((match) => {
    const start = source.indexOf("(", match.index);
    let depth = 0;
    let quote = null;
    let escaped = false;
    for (let index = start; index < source.length; index += 1) {
      const character = source[index];
      if (quote !== null) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === '"' || character === "'" || character === "`") {
        quote = character;
      } else if (character === "(") {
        depth += 1;
      } else if (character === ")") {
        depth -= 1;
        if (depth === 0) {
          return /\brolloutThreadId\s*:/.test(source.slice(start, index + 1));
        }
      }
    }
    return false;
  });
}

await test("observe budget default reflects measured pickup p90", () => {
  assert.equal(DEFAULT_OBSERVE_BUDGET_MS, 20000);
});

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

await test("invalid thread identity cautions while preserving the primary reply", () => {
  const reply = path.join(tmp, "invalid-thread-primary.reply.md");
  fs.writeFileSync(reply, "PRIMARY");
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: reply,
    threadId: "not-a-uuid",
    sessionsRoot: path.join(tmp, "does-not-exist"),
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-authority-unavailable"));
  assert.ok(result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
});

await test("standalone supersession marker warns without replacing the primary reply", () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "8400000000-8-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-superseded-${threadId}.jsonl`);
  const finalMessage = "REPLY-SUPERSEDED\nInspect the completed thread before relying on the reply file.";
  fs.writeFileSync(reply, "PRIMARY-MUST-STAY");
  const records = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
    { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", message: finalMessage, phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: finalMessage } },
  ];
  fs.writeFileSync(rollout, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = harvestDispatch({
    threadId,
    dispatchId,
    replyPath: reply,
    rolloutPath: rollout,
    maxBytes: 4096,
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.bodyBase64, null);
  assert.equal(fs.readFileSync(reply, "utf8"), "PRIMARY-MUST-STAY");
  assert.equal(result.replySuperseded, true);
  assert.equal(result.replySupersessionStatus, "confirmed");
});

await test("discussion of supersession marker does not warn", () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "8500000000-8-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-discussion-${threadId}.jsonl`);
  const finalMessage = "This quotes the completion marker below without superseding the reply:\nREPLY-SUPERSEDED\nEnd quotation.";
  fs.writeFileSync(reply, "PRIMARY-DISCUSSION");
  const records = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "33333333-3333-4333-8333-333333333333" } },
    { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", message: finalMessage, phase: "final_answer" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "33333333-3333-4333-8333-333333333333", last_agent_message: finalMessage } },
  ];
  fs.writeFileSync(rollout, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = harvestDispatch({
    threadId,
    dispatchId,
    replyPath: reply,
    rolloutPath: rollout,
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "not-seen");
  assert.deepEqual(result.diagnostics, []);
});

await test("dispatch-ID reuse makes primary supersession unavailable and suppresses fallback", () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const firstTurn = "11111111-1111-4111-8111-111111111111";
  const secondTurn = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "8550000000-8-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-mixed-supersession-${threadId}.jsonl`);
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const supersession = "REPLY-SUPERSEDED\nOlder completed occurrence.";
  fs.writeFileSync(rollout, `${[
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: firstTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: firstTurn, phase: "final_answer", message: supersession } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: firstTurn, last_agent_message: supersession } },
    { type: "event_msg", payload: { type: "task_started", turn_id: secondTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);

  fs.writeFileSync(reply, "PRIMARY-REMAINS-PRESENT");
  const primary = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
  assert.equal(primary.source, "reply-file");
  assert.equal(primary.replySuperseded, false);
  assert.equal(primary.replySupersessionStatus, "unavailable");
  assert.equal(primary.replySupersessionCaution, true);
  assert.ok(primary.diagnostics.some((item) => item.code === "dispatch-id-reused"));
  assert.equal(fs.readFileSync(reply, "utf8"), "PRIMARY-REMAINS-PRESENT");

  const absentReply = path.join(tmp, `${dispatchId}-absent.reply.md`);
  const fallback = harvestDispatch({ threadId, dispatchId, replyPath: absentReply, rolloutPath: rollout });
  assert.equal(fallback.source, "none");
  assert.equal(fallback.reason, "unavailable");
  assert.equal(fallback.bodyBase64, "");
  assert.equal(fallback.duplicateCount, 2);
  assert.ok(fallback.diagnostics.some((item) => item.code === "dispatch-id-reused"));
});

await test("dispatch-ID reuse and opaque-tail uncertainty suppress fallback conservatively", () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const firstTurn = "11111111-1111-4111-8111-111111111111";
  const secondTurn = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "8560000000-8-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const supersession = "REPLY-SUPERSEDED\nOlder completed occurrence.";
  const completedPrefix = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: firstTurn } },
    { type: "event_msg", payload: { type: "user_message", turn_id: firstTurn, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: firstTurn, phase: "final_answer", message: supersession } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: firstTurn, last_agent_message: supersession } },
  ];
  const cases = [
    [
      "conflict",
      [
        { type: "event_msg", payload: { type: "task_started", turn_id: secondTurn } },
        { type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } },
        { type: "event_msg", payload: { type: "agent_message", turn_id: secondTurn, phase: "final_answer", message: "candidate A" } },
        { type: "event_msg", payload: { type: "agent_message", turn_id: secondTurn, phase: "final_answer", message: "candidate B" } },
        { type: "event_msg", payload: { type: "task_complete", turn_id: secondTurn, last_agent_message: "candidate A" } },
      ],
      false,
      "dispatch-mixed-state",
      true,
    ],
    [
      "orphan-marker",
      [{ type: "event_msg", payload: { type: "user_message", turn_id: secondTurn, message: marker } }],
      false,
      "dispatch-mixed-state",
      true,
    ],
    [
      "schema",
      [{ type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: secondTurn } }],
      false,
      "dispatch-freshness-unsettled",
      false,
    ],
    ["malformed", [], true, "dispatch-freshness-unsettled", false],
  ];
  for (const [name, suffix, addMalformed, diagnosticCode, reused] of cases) {
    const reply = path.join(tmp, `${dispatchId}-${name}.reply.md`);
    const absentReply = path.join(tmp, `${dispatchId}-${name}-absent.reply.md`);
    const rollout = path.join(tmp, `rollout-mixed-${name}-${threadId}.jsonl`);
    const completeText = [...completedPrefix, ...suffix]
      .map((item) => JSON.stringify(item))
      .join("\n");
    fs.writeFileSync(rollout, `${completeText}\n${addMalformed ? "{\"type\":\n" : ""}`);
    fs.writeFileSync(reply, `PRIMARY-${name}`);

    const primary = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
    assert.equal(primary.source, "reply-file", name);
    assert.equal(primary.replySuperseded, !reused, name);
    assert.equal(primary.replySupersessionStatus, reused ? "unavailable" : "confirmed", name);
    assert.equal(primary.replySupersessionCaution, true, name);
    assert.ok(primary.diagnostics.some(
      (item) => item.code === (reused ? "dispatch-id-reused" : diagnosticCode),
    ), name);

    const fallback = harvestDispatch({
      threadId,
      dispatchId,
      replyPath: absentReply,
      rolloutPath: rollout,
    });
    assert.equal(fallback.source, "none", name);
    assert.equal(fallback.reason, "unavailable", name);
    assert.equal(fallback.bodyBase64, "", name);
    assert.ok(fallback.diagnostics.some(
      (item) => item.code === (reused ? "dispatch-id-reused" : diagnosticCode),
    ), name);
  }
});

await test("opaque tails make negative supersession and rollout fallback unavailable", () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const turnId = "11111111-1111-4111-8111-111111111111";
  const dispatchId = "8570000000-8-abcdef0123456789";
  const marker = `read C:/x/${dispatchId}.task.md and proceed`;
  const body = "ordinary completed body";
  const prefix = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: marker } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: body } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: body } },
  ];
  for (const [name, tail] of [
    ["schema", `${JSON.stringify({ type: "event_msg", payload: { type: "future_lifecycle_event" } })}\n`],
    ["malformed", "{\"type\":\n"],
  ]) {
    const rollout = path.join(tmp, `rollout-negative-${name}-${threadId}.jsonl`);
    const reply = path.join(tmp, `${dispatchId}-${name}.reply.md`);
    fs.writeFileSync(rollout, `${prefix.map((item) => JSON.stringify(item)).join("\n")}\n${tail}`);
    fs.writeFileSync(reply, `PRIMARY-${name}`);
    const primary = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
    assert.equal(primary.replySuperseded, false, name);
    assert.equal(primary.replySupersessionStatus, "unavailable", name);
    assert.equal(primary.replySupersessionCaution, true, name);
    assert.ok(primary.diagnostics.some((item) => item.code === "reply-supersession-schema-unknown"), name);

    const fallback = harvestDispatch({
      threadId,
      dispatchId,
      replyPath: `${reply}.absent`,
      rolloutPath: rollout,
    });
    assert.equal(fallback.source, "none", name);
    assert.equal(fallback.reason, "unavailable", name);
    assert.equal(fallback.bodyBase64, "", name);
    assert.ok(fallback.diagnostics.some((item) => item.code === "dispatch-freshness-unsettled"), name);
  }
});

await test("marker in an unterminated superseded turn does not warn", () => {
  const threadId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "5000000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}-unterminated.reply.md`);
  const source = path.join(
    process.env.FIXTURES,
    `rollout-superseded-${threadId}.jsonl`,
  );
  const rollout = path.join(tmp, `rollout-unterminated-${threadId}.jsonl`);
  const records = fs.readFileSync(source, "utf8").trim().split("\n").map(JSON.parse);
  records[3].payload.message = "REPLY-SUPERSEDED\nThis turn never reached its own terminal.";
  fs.writeFileSync(rollout, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  fs.writeFileSync(reply, "PROVISIONAL-PRIMARY");
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
});

await test("partial-tail supersession evidence stays pending and diagnostic", () => {
  const threadId = "33333333-3333-4333-8333-333333333333";
  const turnId = "00000000-0000-4000-8000-00000000c0de";
  const dispatchId = "5050000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-partial-supersession-${threadId}.jsonl`);
  const finalMessage = "REPLY-SUPERSEDED\nThis marker is followed by an incomplete tail.";
  fs.writeFileSync(reply, "PRIMARY-REMAINS-AUTHORITATIVE");
  const completePrefix = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: finalMessage } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: finalMessage } },
  ].map((item) => JSON.stringify(item)).join("\n");
  fs.writeFileSync(rollout, `${completePrefix}\n{\"type\":`);
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "pending");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("unavailable rollout authority is explicit while primary remains authoritative", () => {
  const threadId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "5060000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  fs.writeFileSync(reply, "PRIMARY-ONLY");
  const result = harvestDispatch({
    threadId,
    dispatchId,
    replyPath: reply,
    sessionsRoot: path.join(tmp, "missing-supersession-root"),
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, false);
  assert.ok(result.diagnostics.length > 0);
});

await test("non-benign discovery failure cautions while primary remains authoritative", () => {
  const threadId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "5065000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const unreadableRoot = path.join(tmp, "sessions-root-is-a-file");
  fs.writeFileSync(reply, "PRIMARY-ONLY");
  fs.writeFileSync(unreadableRoot, "not a directory");
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, sessionsRoot: unreadableRoot });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "directory-unreadable"));
  assert.ok(result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
});

await test("unrecognized target rollout filename cautions without becoming a candidate", () => {
  const threadId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "5066000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const sessionsRoot = path.join(tmp, "sessions-name-drift");
  fs.mkdirSync(sessionsRoot, { recursive: true });
  fs.writeFileSync(reply, "PRIMARY-ONLY");
  fs.writeFileSync(
    path.join(sessionsRoot, `rollout-future-${threadId}_unsupported-suffix.jsonl`),
    `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`,
  );
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, sessionsRoot });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-name-unrecognized"));
});

await test("unresolved discovery set cannot serve an older rollout fallback", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const dispatchId = dispatch;
  const sessionsRoot = path.join(tmp, "sessions-unresolved-fallback");
  fs.mkdirSync(sessionsRoot, { recursive: true });
  fs.copyFileSync(cleanBasic, path.join(sessionsRoot, path.basename(cleanBasic)));
  fs.writeFileSync(
    path.join(sessionsRoot, `rollout-future-${threadId}_unsupported-suffix.jsonl`),
    `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`,
  );
  const result = harvestDispatch({
    threadId,
    dispatchId,
    replyPath: path.join(tmp, "absent-unresolved.reply.md"),
    sessionsRoot,
  });
  assert.equal(result.source, "none");
  assert.equal(result.reason, "ambiguous");
  assert.ok(result.diagnostics.some((item) => item.code === "candidate-set-unresolved"));
});

await test("ambiguous rollout discovery cautions while primary remains authoritative", () => {
  const threadId = "00000000-0000-4000-8000-00000000c0de";
  const dispatchId = "5070000000-5-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const sessionsRoot = path.join(tmp, "ambiguous-supersession-root");
  fs.mkdirSync(path.join(sessionsRoot, "a"), { recursive: true });
  fs.mkdirSync(path.join(sessionsRoot, "b"), { recursive: true });
  fs.writeFileSync(reply, "PRIMARY-AMBIGUOUS");
  const metadata = `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`;
  fs.writeFileSync(path.join(sessionsRoot, "a", `rollout-a-${threadId}.jsonl`), metadata);
  fs.writeFileSync(path.join(sessionsRoot, "b", `rollout-b-${threadId}.jsonl`), metadata);
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, sessionsRoot });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "multiple-candidates"));
  assert.ok(result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
});

await test("dispatch-ID reuse never supplies a rollout fallback body", () => {
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: path.join(tmp, "absent.reply.md"),
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: cleanBasic,
    maxBytes: 4096,
  });
  assert.equal(result.source, "none");
  assert.equal(result.reason, "unavailable");
  assert.equal(result.bodyBase64, "");
  assert.equal(result.duplicateCount, 2);
  assert.ok(result.diagnostics.some((item) => item.code === "dispatch-id-reused"));
});

await test("dispatch-ID reuse keeps a primary viewable but supersession uncertifiable", () => {
  const replyPath = path.join(tmp, "duplicate-primary.reply.md");
  fs.writeFileSync(replyPath, "PRIMARY-STAYS-VIEWABLE");
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath,
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: cleanBasic,
  });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replyPath, replyPath);
  assert.equal(result.bodyBase64, null);
  assert.equal(fs.readFileSync(replyPath, "utf8"), "PRIMARY-STAYS-VIEWABLE");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "dispatch-id-reused"));
});

await test("a unique completed rollout is selected only when primary is unavailable", () => {
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: path.join(tmp, "unique-absent.reply.md"),
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: uniqueBasic,
  });
  assert.equal(result.source, "rollout-fallback");
  assert.equal(Buffer.from(result.bodyBase64, "base64").toString("utf8"), "latest final");
  assert.equal(result.duplicateCount, 1);
});

await test("identity-backed mirrored records preserve one safe fallback occurrence", () => {
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: path.join(tmp, "mirrored-absent.reply.md"),
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: mirroredBasic,
  });
  assert.equal(result.source, "rollout-fallback");
  assert.equal(Buffer.from(result.bodyBase64, "base64").toString("utf8"), "mirrored final");
  assert.equal(result.duplicateCount, 1);
});

await test("terminal binding selects one body while unbound conflicts and schema drift fail closed", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const turnId = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "8600000000-8-abcdef0123456789";
  const prefix = [
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/x/${dispatchId}.task.md and proceed` } },
  ];
  const selectedPath = path.join(tmp, `rollout-body-terminal-selected-${threadId}.jsonl`);
  fs.writeFileSync(selectedPath, `${[
    ...prefix,
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "SAFE" } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "OTHER" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "SAFE" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const selected = harvestDispatch({
    dispatchId,
    threadId,
    replyPath: path.join(tmp, "selected-absent.reply.md"),
    rolloutPath: selectedPath,
  });
  assert.equal(selected.source, "rollout-fallback");
  assert.equal(selected.reason, null);
  assert.equal(Buffer.from(selected.bodyBase64, "base64").toString("utf8"), "SAFE");

  const unboundPath = path.join(tmp, `rollout-body-unbound-${threadId}.jsonl`);
  fs.writeFileSync(unboundPath, `${[
    ...prefix,
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "SAFE" } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "OTHER" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "NEITHER" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const unbound = harvestDispatch({
    dispatchId,
    threadId,
    replyPath: path.join(tmp, "unbound-absent.reply.md"),
    rolloutPath: unboundPath,
  });
  assert.equal(unbound.source, "none");
  assert.equal(unbound.reason, "unavailable");
  assert.equal(unbound.bodyBase64, "");

  const driftPath = path.join(tmp, `rollout-body-drift-${threadId}.jsonl`);
  fs.writeFileSync(driftPath, `${[
    ...prefix,
    { type: "event_msg", payload: { type: "future_lifecycle_event", turn_id: turnId } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "MUST-NOT-SERVE" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const drift = harvestDispatch({
    dispatchId,
    threadId,
    replyPath: path.join(tmp, "drift-absent.reply.md"),
    rolloutPath: driftPath,
  });
  assert.equal(drift.source, "none");
  assert.equal(drift.reason, "unparseable");
  assert.equal(drift.bodyBase64, "");
});

await test("file-global rollout owner conflict cannot escape through fallback", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const conflictingThreadId = "22222222-2222-4222-8222-222222222222";
  const turnId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "8650000000-8-abcdef0123456789";
  const rolloutPath = path.join(tmp, `rollout-owner-global-${threadId}.jsonl`);
  fs.writeFileSync(rolloutPath, `${[
    { type: "session_meta", payload: { id: threadId } },
    { type: "session_meta", payload: { id: conflictingThreadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "MUST-NOT-SERVE" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "MUST-NOT-SERVE" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = harvestDispatch({
    dispatchId,
    threadId,
    replyPath: path.join(tmp, "owner-global-absent.reply.md"),
    rolloutPath,
  });
  assert.equal(result.source, "none");
  assert.equal(result.bodyBase64, "");
  assert.equal(result.reason, "unparseable");
});

await test("post-locator reads remain bound to the requested rollout owner", async () => {
  const ownerA = "11111111-1111-4111-8111-111111111111";
  const ownerB = "22222222-2222-4222-8222-222222222222";
  const turnId = "33333333-3333-4333-8333-333333333333";
  const dispatchId = "8660000000-8-abcdef0123456789";
  const makeInitial = (name) => {
    const target = path.join(tmp, `rollout-${name}-${ownerA}.jsonl`);
    fs.writeFileSync(
      target,
      `${JSON.stringify({ type: "session_meta", payload: { id: ownerA } })}\n`,
    );
    return target;
  };
  const ownerBRecords = (finalMessage) => [
    { type: "session_meta", payload: { id: ownerB } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        turn_id: turnId,
        message: `read C:/sanitized/${dispatchId}.task.md and proceed`,
      },
    },
    {
      type: "event_msg",
      payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: finalMessage },
    },
    {
      type: "event_msg",
      payload: { type: "task_complete", turn_id: turnId, last_agent_message: finalMessage },
    },
  ];

  const fallbackPath = makeInitial("owner-swap-fallback");
  const fallback = await swapAfterLocatorValidation(
    fallbackPath,
    ownerBRecords("OWNER-B-MUST-NOT-SERVE"),
    () => harvestDispatch({
      dispatchId,
      threadId: ownerA,
      replyPath: path.join(tmp, "owner-swap-absent.reply.md"),
      rolloutPath: fallbackPath,
    }),
  );

  const supersessionPath = makeInitial("owner-swap-supersession");
  const replyPath = path.join(tmp, "owner-swap-primary.reply.md");
  fs.writeFileSync(replyPath, "PRIMARY-STAYS-AUTHORITATIVE");
  const supersession = await swapAfterLocatorValidation(
    supersessionPath,
    ownerBRecords("REPLY-SUPERSEDED\nOWNER-B-MUST-NOT-ANNOTATE"),
    () => harvestDispatch({
      dispatchId,
      threadId: ownerA,
      replyPath,
      rolloutPath: supersessionPath,
    }),
  );

  const observerPath = makeInitial("owner-swap-observer");
  let clock = 0;
  const observer = await swapAfterLocatorValidation(
    observerPath,
    ownerBRecords("OWNER-B-ADMISSION-MUST-NOT-COUNT"),
    () => observeRollout({
      threadId: ownerA,
      dispatchId,
      rolloutPath: observerPath,
      budgetMs: 2,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { clock += ms; } }),
  );

  assert.deepEqual(
    {
      fallbackInjected: fallback.injected,
      fallbackSource: fallback.result.source,
      fallbackBody: fallback.result.bodyBase64,
      supersessionInjected: supersession.injected,
      replySuperseded: supersession.result.replySuperseded,
      replySupersessionStatus: supersession.result.replySupersessionStatus,
      supersessionDiagnostic: supersession.result.diagnostics.some(
        (item) => item.code === "reply-supersession-unavailable",
      ),
      observerInjected: observer.injected,
      observerToken: observer.result.token,
      harvesterReadBindings: rolloutReadBindings(process.env.HARVESTER),
      observerReadBindings: rolloutReadBindings(process.env.OBSERVER),
    },
    {
      fallbackInjected: true,
      fallbackSource: "none",
      fallbackBody: "",
      supersessionInjected: true,
      replySuperseded: false,
      replySupersessionStatus: "unavailable",
      supersessionDiagnostic: true,
      observerInjected: true,
      observerToken: "rollout-unavailable",
      harvesterReadBindings: [true, true],
      observerReadBindings: [true],
    },
  );
});

await test("a terminal-selected supersession annotates without replacing the primary reply", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const turnId = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "8700000000-8-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-supersession-conflict-${threadId}.jsonl`);
  const supersession = "REPLY-SUPERSEDED\nThis candidate conflicts with another final.";
  fs.writeFileSync(reply, "PRIMARY-UNCHANGED");
  fs.writeFileSync(rollout, `${[
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: supersession } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "OTHER" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: supersession } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, true);
  assert.equal(result.replySupersessionStatus, "confirmed");
  assert.equal(result.replySupersessionCaution, false);
  assert.ok(!result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
  assert.equal(fs.readFileSync(reply, "utf8"), "PRIMARY-UNCHANGED");
});

await test("an unbound supersession body cannot annotate a primary reply", () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const turnId = "22222222-2222-4222-8222-222222222222";
  const dispatchId = "8710000000-8-abcdef0123456789";
  const reply = path.join(tmp, `${dispatchId}.reply.md`);
  const rollout = path.join(tmp, `rollout-supersession-unbound-${threadId}.jsonl`);
  const supersession = "REPLY-SUPERSEDED\nThis candidate conflicts with another final.";
  fs.writeFileSync(reply, "PRIMARY-UNCHANGED");
  fs.writeFileSync(rollout, `${[
    { type: "session_meta", payload: { id: threadId } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/x/${dispatchId}.task.md and proceed` } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: supersession } },
    { type: "event_msg", payload: { type: "agent_message", phase: "final_answer", message: "OTHER" } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "NEITHER" } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const result = harvestDispatch({ threadId, dispatchId, replyPath: reply, rolloutPath: rollout });
  assert.equal(result.source, "reply-file");
  assert.equal(result.replySuperseded, false);
  assert.equal(result.replySupersessionStatus, "unavailable");
  assert.equal(result.replySupersessionCaution, true);
  assert.ok(result.diagnostics.some((item) => item.code === "reply-supersession-unavailable"));
  assert.equal(fs.readFileSync(reply, "utf8"), "PRIMARY-UNCHANGED");
});

await test("directory or symlink-like non-regular primary does not block fallback", () => {
  const notRegular = path.join(tmp, "not-regular.reply.md");
  fs.mkdirSync(notRegular);
  const result = harvestDispatch({
    dispatchId: dispatch,
    replyPath: notRegular,
    threadId: "11111111-1111-4111-8111-111111111111",
    rolloutPath: uniqueBasic,
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

await test("repair RED: current response compaction is inert during admission observation", async () => {
  const target = path.join(
    tmp,
    "rollout-observer-compaction-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    {
      type: "response_item",
      payload: {
        type: "compaction",
        id: "sanitized-compaction",
        encrypted_content: "sanitized",
        internal_chat_message_metadata_passthrough: null,
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  let clock = 0;
  const result = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: dispatch,
    rolloutPath: target,
    budgetMs: 1,
    intervalMs: 1,
  }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
  assert.equal(result.token, "rollout-hit", JSON.stringify(result));
  assert.equal(result.diagnostics.some((item) => item.code === "schema-drift"), false);
});

await test("observer admits an exact known-form user marker despite unrelated schema drift", async () => {
  const target = path.join(
    tmp,
    "rollout-observer-schema-hit-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    { type: "event_msg", payload: { type: "future_lifecycle_event" } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  let clock = 0;
  const result = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: dispatch,
    rolloutPath: target,
    budgetMs: 1,
    intervalMs: 1,
  }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
  assert.equal(result.token, "rollout-hit", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) => item.code === "schema-drift"));
});

await test("observer retains an exact admission across growth despite unrelated schema drift", async () => {
  const target = path.join(
    tmp,
    "rollout-observer-schema-retry-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    { type: "event_msg", payload: { type: "future_lifecycle_event" } },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(
        target,
        `${JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total: 1 } } })}\n`,
      );
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  let clock = 0;
  let sleeps = 0;
  try {
    result = await observeRollout({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 2,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { sleeps += 1; clock += ms; } });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.token, "rollout-hit", JSON.stringify(result));
  assert.ok(sleeps >= 1);
  assert.ok(result.diagnostics.some((item) => item.code === "schema-drift"));
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("observer rejects drifted and malformed would-be admissions", async () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const driftedPath = path.join(tmp, `rollout-observer-drifted-admission-${threadId}.jsonl`);
  fs.writeFileSync(driftedPath, `${[
    { type: "session_meta", payload: { id: threadId } },
    {
      type: "future_event",
      payload: {
        type: "user_message",
        message: `read C:/x/${dispatch}.task.md and proceed`,
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const malformedPath = path.join(tmp, `rollout-observer-malformed-admission-${threadId}.jsonl`);
  fs.writeFileSync(
    malformedPath,
    `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n` +
      `{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"read C:/x/${dispatch}.task.md and proceed\"}\n`,
  );
  let clock = 0;
  const deps = { now: () => clock, sleep: async (ms) => { clock += ms; } };
  const drifted = await observeRollout({
    threadId,
    dispatchId: dispatch,
    rolloutPath: driftedPath,
    budgetMs: 1,
    intervalMs: 1,
  }, deps);
  clock = 0;
  const malformed = await observeRollout({
    threadId,
    dispatchId: dispatch,
    rolloutPath: malformedPath,
    budgetMs: 1,
    intervalMs: 1,
  }, deps);
  assert.equal(drifted.token, "rollout-unavailable", JSON.stringify(drifted));
  assert.ok(drifted.diagnostics.some((item) => item.code === "schema-drift"));
  assert.equal(malformed.token, "rollout-unavailable", JSON.stringify(malformed));
  assert.ok(malformed.diagnostics.some((item) => item.code === "malformed-json"));
});

await test("unrelated malformed records before or after an exact admission veto a hit", async () => {
  const threadId = "22222222-2222-4222-8222-222222222222";
  const owner = JSON.stringify({ type: "session_meta", payload: { id: threadId } });
  const admission = JSON.stringify({
    type: "event_msg",
    payload: {
      type: "user_message",
      message: `read C:/x/${dispatch}.task.md and proceed`,
    },
  });
  for (const placement of ["before", "after"]) {
    const target = path.join(tmp, `rollout-observer-malformed-${placement}-${threadId}.jsonl`);
    const body = placement === "before"
      ? [owner, "{unrelated malformed json}", admission]
      : [owner, admission, "{unrelated malformed json}"];
    fs.writeFileSync(target, `${body.join("\n")}\n`);
    let clock = 0;
    const result = await observeRollout({
      threadId,
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 1,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
    assert.equal(result.token, "rollout-unavailable", `${placement}: ${JSON.stringify(result)}`);
    assert.ok(
      result.diagnostics.some((item) => item.code === "malformed-json"),
      placement,
    );
  }
});

await test("observer does not certify a hit before a complete EOF read", async () => {
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
  assert.equal(result.token, "rollout-pending", JSON.stringify(result));
});

await test("harvester does not serve a completed prefix before stable EOF", () => {
  const target = path.join(tmp, "rollout-harvest-growth-11111111-1111-4111-8111-111111111111.jsonl");
  fs.copyFileSync(basic, target);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total: 1 } } })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  try {
    result = harvestDispatch({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      replyPath: path.join(tmp, "missing-growth.reply.md"),
      rolloutPath: target,
      maxBytes: 4096,
    });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.source, "none");
  assert.equal(result.reason, "pending");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("observer retains provisional admission but waits for stable EOF", async () => {
  const target = path.join(tmp, "rollout-observer-growth-11111111-1111-4111-8111-111111111111.jsonl");
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${dispatch}.task.md and proceed` } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total: 1 } } })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  let clock = 0;
  try {
    result = await observeRollout({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 1,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.token, "rollout-pending", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("observer certifies provisional admission after a later stable EOF", async () => {
  const target = path.join(tmp, "rollout-observer-growth-retry-11111111-1111-4111-8111-111111111111.jsonl");
  fs.writeFileSync(target, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${dispatch}.task.md and proceed` } },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(target, `${JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total: 1 } } })}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  let clock = 0;
  try {
    result = await observeRollout({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 2,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.token, "rollout-hit");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("observer skips unchanged intermediate polls but forces a final full read", async () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const target = path.join(tmp, `rollout-observer-no-growth-${threadId}.jsonl`);
  fs.writeFileSync(target, `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`);
  let clock = 0;
  let fullReads = 0;
  let noGrowthChecks = 0;
  const result = await observeRollout({
    threadId,
    dispatchId: dispatch,
    rolloutPath: target,
    budgetMs: 3,
    intervalMs: 1,
  }, {
    now: () => clock,
    sleep: async (ms) => { clock += ms; },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
    inspectRolloutNoGrowth: (...args) => {
      noGrowthChecks += 1;
      return inspectRolloutNoGrowth(...args);
    },
  });
  assert.equal(result.token, "rollout-pending", JSON.stringify(result));
  assert.equal(noGrowthChecks, 1);
  assert.equal(fullReads, 2);
});

await test("observer final full read catches a same-size rewrite hidden from no-growth metadata", async () => {
  const threadId = "11111111-1111-4111-8111-111111111111";
  const rewrittenThreadId = "22222222-2222-4222-8222-222222222222";
  const target = path.join(tmp, `rollout-observer-same-size-rewrite-${threadId}.jsonl`);
  const initial = `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`;
  const replacement = `${JSON.stringify({ type: "session_meta", payload: { id: rewrittenThreadId } })}\n`;
  assert.equal(Buffer.byteLength(initial), Buffer.byteLength(replacement));
  fs.writeFileSync(target, initial);
  let clock = 0;
  let sleeps = 0;
  let fullReads = 0;
  let noGrowthChecks = 0;
  const result = await observeRollout({
    threadId,
    dispatchId: dispatch,
    rolloutPath: target,
    budgetMs: 3,
    intervalMs: 1,
  }, {
    now: () => clock,
    sleep: async (ms) => {
      sleeps += 1;
      clock += ms;
      if (sleeps === 1) fs.writeFileSync(target, replacement);
    },
    readRolloutFile: (...args) => {
      fullReads += 1;
      return readRolloutFile(...args);
    },
    inspectRolloutNoGrowth: (...args) => {
      noGrowthChecks += 1;
      return inspectRolloutNoGrowth(...args);
    },
  });
  assert.equal(result.token, "rollout-unavailable", JSON.stringify(result));
  assert.equal(noGrowthChecks, 1);
  assert.equal(fullReads, 2);
  assert.ok(result.diagnostics.some((item) => item.code === "consumed-prefix-changed"));
});

await test("observer rejects admission from an integrity-failed read", async () => {
  const target = path.join(tmp, "rollout-observer-rewrite-11111111-1111-4111-8111-111111111111.jsonl");
  fs.copyFileSync(basic, target);
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
  let now = 0;
  let result;
  try {
    result = await observeRollout({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 1,
      intervalMs: 1,
    }, { now: () => now, sleep: async (ms) => { now += ms; } });
  } finally {
    fs.readSync = originalRead;
  }
  assert.equal(result.token, "rollout-unavailable");
});

await test("observer never carries admission forward from a rejected read", async () => {
  const target = path.join(tmp, "rollout-observer-rejected-marker-11111111-1111-4111-8111-111111111111.jsonl");
  const sessionOnly = `${JSON.stringify({
    type: "session_meta",
    payload: { id: "11111111-1111-4111-8111-111111111111" },
  })}\n`;
  fs.writeFileSync(target, `${sessionOnly}${JSON.stringify({
    type: "event_msg",
    payload: {
      type: "user_message",
      message: `read C:/x/${dispatch}.task.md and proceed`,
    },
  })}\n`);
  const originalRead = fs.readSync;
  let injected = false;
  fs.readSync = function injectedRead(descriptor, ...args) {
    const bytesRead = originalRead.call(fs, descriptor, ...args);
    if (!injected && bytesRead > 0 && args[2] > 4096) {
      injected = true;
      fs.writeFileSync(target, sessionOnly);
    }
    return bytesRead;
  };
  let result;
  let clock = 0;
  try {
    result = await observeRollout({
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: dispatch,
      rolloutPath: target,
      budgetMs: 2,
      intervalMs: 1,
    }, { now: () => clock, sleep: async (ms) => { clock += ms; } });
  } finally {
    fs.readSync = originalRead;
  }
  assert.equal(injected, true);
  assert.equal(result.token, "rollout-unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "file-truncated"));
});

await test("observer distinguishes pending from unavailable with fake time", async () => {
  let now = 0;
  const deps = {
    now: () => now,
    sleep: async (ms) => {
      now += ms;
    },
  };
  const pendingPath = path.join(
    tmp,
    "rollout-observer-pending-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(
    pendingPath,
    `${JSON.stringify({ type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } })}\n`,
  );
  const pending = await observeRollout(
    {
      threadId: "11111111-1111-4111-8111-111111111111",
      dispatchId: "8888888888-8-abcdef0123456789",
      rolloutPath: pendingPath,
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
  const safeNonHitPath = path.join(
    tmp,
    "rollout-observer-nonhit-11111111-1111-4111-8111-111111111111.jsonl",
  );
  fs.writeFileSync(safeNonHitPath, `${[
    { type: "session_meta", payload: { id: "11111111-1111-4111-8111-111111111111" } },
    {
      type: "response_item",
      payload: {
        type: "agent_message",
        content: "read C:/synthetic/9999999999-9-ffffffffffffffff.task.md and proceed",
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "user_message",
        message: "read C:/synthetic/1000000000-1-abcdef0123456789.task.md and proceed",
      },
    },
  ].map((item) => JSON.stringify(item)).join("\n")}\n`);
  const agentOnly = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: "9999999999-9-ffffffffffffffff",
    rolloutPath: safeNonHitPath,
    budgetMs: 2,
    intervalMs: 1,
  }, deps);
  now = 0;
  const substring = await observeRollout({
    threadId: "11111111-1111-4111-8111-111111111111",
    dispatchId: "1000000000-1-abcdef012345678",
    rolloutPath: safeNonHitPath,
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
diagnostics_are_control_safe(){
  node - "$1" <<'NODE'
const fs = require("node:fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const withoutLineEndings = text.replace(/\r?\n/g, "");
if (/[\u0000-\u001f\u007f-\u009f]/u.test(withoutLineEndings)) process.exit(1);
for (const escaped of ["\\u0000", "\\u001b", "\\u001f", "\\u007f", "\\u0085", "\\u009b"]) {
  if (!text.includes(escaped)) process.exit(1);
}
const prefix = "ROLLOUT_DIAGNOSTIC ";
const diagnostics = text.split(/\r?\n/).filter(Boolean).map((line) => {
  if (!line.startsWith(prefix)) process.exit(1);
  return JSON.parse(line.slice(prefix.length));
});
const drift = diagnostics.find((item) => item.code === "schema-drift");
if (!drift) process.exit(1);
if (drift.envelopeType !== "drift\u0000\u001b\u001f\u007f\u0085type") process.exit(1);
if (drift.payloadType !== "unknown\u009bshape") process.exit(1);
NODE
}

echo "== Wrong-turn final answer is never served as a dispatch reply =="
# Regression (audit A-05): the shared correlator accepted a user_message whose turn_id disagreed
# with its enclosing turn, so the harvester attributed THAT turn's final answer to this dispatch.
# `wait` refused; the viewer did not. Both must refuse.
MISMATCH="$TMP/rollout-mismatch-33333333-3333-4333-8333-333333333333.jsonl"
cat >"$MISMATCH" <<'JSONL'
{"type":"session_meta","payload":{"id":"33333333-3333-4333-8333-333333333333"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-A"}}
{"type":"event_msg","payload":{"type":"user_message","turn_id":"turn-B","message":"read C:/x/mismatch-dispatch.task.md and proceed"}}
{"type":"event_msg","payload":{"type":"agent_message","turn_id":"turn-A","phase":"final_answer","message":"WRONG-TURN-FINAL"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-A","last_agent_message":"WRONG-TURN-FINAL"}}
JSONL
MM_OUT="$(node "$HARVESTER" --thread 33333333-3333-4333-8333-333333333333 \
  --dispatch mismatch-dispatch --rollout-path "$MISMATCH" \
  --reply-path "$TMP/absent-mismatch.md" 2>/dev/null)"; MM_RC=$?
WRONG_B64="$(printf 'WRONG-TURN-FINAL' | base64 | tr -d '\n=')"
[[ $MM_RC -eq 0 ]] && [[ "$MM_OUT" == none* ]] && ! printf '%s' "$MM_OUT" | grep -q "$WRONG_B64" \
  && ok "harvester refuses a final answer from a turn that never carried the dispatch marker" \
  || no "harvester served a wrong-turn final (rc=$MM_RC out=$(printf '%s' "$MM_OUT" | cut -c1-80))"

echo "== Observer CLI contract =="
BASIC="$TMP/rollout-unique-11111111-1111-4111-8111-111111111111.jsonl"
OBS_HIT="$TMP/rollout-observer-cli-hit-11111111-1111-4111-8111-111111111111.jsonl"
cat >"$OBS_HIT" <<'JSONL'
{"type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111"}}
{"type":"event_msg","payload":{"type":"user_message","message":"read C:/x/1000000000-1-abcdef0123456789.task.md and proceed"}}
JSONL
ERR="$TMP/observer.err"
OUT="$(CODEX_IPC_OBSERVE_INTERVAL_MS=0 node "$OBSERVER" \
  --thread 11111111-1111-4111-8111-111111111111 \
  --dispatch 1000000000-1-abcdef0123456789 --rollout-path "$OBS_HIT" 2>"$ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == "rollout-hit" && "$(wc -l < <(printf '%s\n' "$OUT"))" -eq 1 ]] \
  && grep -qi 'warning.*interval' "$ERR" && ok "exact one-line hit token; invalid env warns on stderr" \
  || no "observer hit/stdout/warning contract (rc=$RC out=$OUT)"
OUT="$(node "$OBSERVER" --thread bad --dispatch x 2>"$ERR")"; RC=$?
[[ $RC -ne 0 && -z "$OUT" ]] && ok "usage error is nonzero with no outcome token" || no "usage error contract (rc=$RC out=$OUT)"
OUT="$(CODEX_IPC_ROLLOUT_MAX_RECORD_BYTES=1 node "$OBSERVER" \
  --thread 11111111-1111-4111-8111-111111111111 --dispatch 8888888888-8-abcdef0123456789 \
  --rollout-path "$OBS_HIT" --budget-ms 50 --interval-ms 10 2>"$ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == "rollout-unavailable" ]] \
  && ok "schema/record-cap failure maps to unavailable with exit 0" || no "observer cap mapping (rc=$RC out=$OUT)"

DIAGNOSTIC_ROLLOUT="$TMP/rollout-diagnostic-22222222-2222-4222-8222-222222222222.jsonl"
node - "$DIAGNOSTIC_ROLLOUT" <<'NODE'
const fs = require("node:fs");
const target = process.argv[2];
const records = [
  { type: "session_meta", payload: { id: "22222222-2222-4222-8222-222222222222" } },
  { type: "drift\u0000\u001b\u001f\u007f\u0085type", payload: { type: "unknown\u009bshape" } },
];
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
HARVEST_ERR="$TMP/harvest-diagnostic.err"
OUT="$(node "$HARVESTER" --thread 22222222-2222-4222-8222-222222222222 \
  --dispatch 8300000000-8-abcdef0123456789 --rollout-path "$DIAGNOSTIC_ROLLOUT" 2>"$HARVEST_ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == $'none\tunparseable\t0\t0\t0\t-\t' && "$OUT" != *$'\n'* ]] \
  && diagnostics_are_control_safe "$HARVEST_ERR" \
  && ok "harvester diagnostics fail closed and escape C0/C1 without changing stdout shape" \
  || no "harvester diagnostic byte hygiene (rc=$RC out=$OUT)"
OBSERVE_ERR="$TMP/observe-diagnostic.err"
OUT="$(node "$OBSERVER" --thread 22222222-2222-4222-8222-222222222222 \
  --dispatch 8300000000-8-abcdef0123456789 --rollout-path "$DIAGNOSTIC_ROLLOUT" \
  --budget-ms 50 --interval-ms 10 2>"$OBSERVE_ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == "rollout-unavailable" && "$OUT" != *$'\n'* ]] \
  && diagnostics_are_control_safe "$OBSERVE_ERR" \
  && ok "observer diagnostics fail closed and escape C0/C1 without changing its token" \
  || no "observer diagnostic byte hygiene (rc=$RC out=$OUT)"

SUPERSEDED_DISPATCH=8400000000-8-abcdef0123456789
SUPERSEDED_REPLY="$TMP/$SUPERSEDED_DISPATCH.reply.md"
SUPERSEDED_ROLLOUT="$TMP/rollout-superseded-22222222-2222-4222-8222-222222222222.jsonl"
SUPERSEDED_ERR="$TMP/superseded.err"
before_hash="$(sha256sum "$SUPERSEDED_REPLY")"
OUT="$(node "$HARVESTER" --thread 22222222-2222-4222-8222-222222222222 \
  --dispatch "$SUPERSEDED_DISPATCH" --reply-path "$SUPERSEDED_REPLY" \
  --rollout-path "$SUPERSEDED_ROLLOUT" 2>"$SUPERSEDED_ERR")"; RC=$?
after_hash="$(sha256sum "$SUPERSEDED_REPLY")"
[[ $RC -eq 0 && "$OUT" == $'reply-file\t-\t17\t17\t0\t-\t' && "$OUT" != *"PRIMARY-MUST-STAY"* \
  && "$before_hash" == "$after_hash" ]] \
  && grep -Fxq $'REPLY_SUPERSEDED_WARNING\tprimary reply may be superseded; inspect the dispatch thread before relying on it.' "$SUPERSEDED_ERR" \
  && ok "harvester warns on stderr while primary stdout and file stay unchanged" \
  || no "harvester superseded warning contract (rc=$RC out=$OUT)"

NOT_SEEN_DISPATCH=8500000000-8-abcdef0123456789
NOT_SEEN_ERR="$TMP/not-seen.err"
OUT="$(node "$HARVESTER" --thread 22222222-2222-4222-8222-222222222222 \
  --dispatch "$NOT_SEEN_DISPATCH" --reply-path "$TMP/$NOT_SEEN_DISPATCH.reply.md" \
  --rollout-path "$TMP/rollout-discussion-22222222-2222-4222-8222-222222222222.jsonl" \
  2>"$NOT_SEEN_ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == reply-file$'\t'* && ! -s "$NOT_SEEN_ERR" ]] \
  && ok "complete non-marker supersession check stays quiet" \
  || no "harvester non-marker quiet contract (rc=$RC out=$OUT err=$(tr '\n' ' ' < "$NOT_SEEN_ERR"))"

PARTIAL_DISPATCH=5050000000-5-abcdef0123456789
PARTIAL_ERR="$TMP/partial-supersession.err"
OUT="$(node "$HARVESTER" --thread 33333333-3333-4333-8333-333333333333 \
  --dispatch "$PARTIAL_DISPATCH" --reply-path "$TMP/$PARTIAL_DISPATCH.reply.md" \
  --rollout-path "$TMP/rollout-partial-supersession-33333333-3333-4333-8333-333333333333.jsonl" \
  2>"$PARTIAL_ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == reply-file$'\t'* ]] \
  && grep -Fxq $'REPLY_SUPERSESSION_UNCERTAIN\tpending\tselected primary may be stale; freshness and supersession could not be certified.' "$PARTIAL_ERR" \
  && grep -q '"code":"rollout-read-not-at-eof"' "$PARTIAL_ERR" \
  && ok "partial-tail supersession check emits a distinct pending caution" \
  || no "harvester partial supersession caution (rc=$RC out=$OUT)"

NO_CANDIDATE_CLI_DISPATCH=5060000000-5-abcdef0123456789
NO_CANDIDATE_CLI_ERR="$TMP/no-candidate-cli.err"
OUT="$(CODEX_IPC_SESSIONS_ROOT="$TMP/missing-cli-sessions" node "$HARVESTER" \
  --thread 33333333-3333-4333-8333-333333333333 --dispatch "$NO_CANDIDATE_CLI_DISPATCH" \
  --reply-path "$TMP/$NO_CANDIDATE_CLI_DISPATCH.reply.md" 2>"$NO_CANDIDATE_CLI_ERR")"; RC=$?
[[ $RC -eq 0 && "$OUT" == reply-file$'\t'* ]] \
  && ! grep -q $'^REPLY_SUPERSESSION_UNCERTAIN\t' "$NO_CANDIDATE_CLI_ERR" \
  && ok "ordinary CLI no-candidate status emits diagnostics without a caution" \
  || no "harvester no-candidate warning noise (rc=$RC out=$OUT)"

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
  && "$OUT" == *"reply files primary; rollouts are derived fallback"* \
  && "$OUT" == *"latest final"* && ! -e "$IPCROOT/$SID/$THREAD/1000000000-1-abcdef0123456789.reply.md" ]] \
  && ok "rollout fallback is labeled, banner-corrected, stdout-only, and read-only" \
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

SUPER_VIEW_DISPATCH=8600000000-8-abcdef0123456789
DISCUSS_VIEW_DISPATCH=8700000000-8-abcdef0123456789
VIEW_ROLLOUT="$SESSIONS/2026/07/09/$(basename "$BASIC")"
node - "$VIEW_ROLLOUT" "$SUPER_VIEW_DISPATCH" "$DISCUSS_VIEW_DISPATCH" <<'NODE'
const fs = require("node:fs");
const [target, superseded, discussion] = process.argv.slice(2);
const owner = "11111111-1111-4111-8111-111111111111";
const supersededFinal = "REPLY-SUPERSEDED\nInspect the completed thread before relying on the reply file.";
const discussionFinal = "This quotes the completion marker below without superseding the reply:\nREPLY-SUPERSEDED\nEnd quotation.";
const records = [
  { type: "session_meta", payload: { id: owner } },
  { type: "event_msg", payload: { type: "task_started", turn_id: "00000000-0000-4000-8000-00000000c0de" } },
  { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${superseded}.task.md and proceed` } },
  { type: "event_msg", payload: { type: "agent_message", message: supersededFinal, phase: "final_answer" } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: "00000000-0000-4000-8000-00000000c0de", last_agent_message: supersededFinal } },
  { type: "event_msg", payload: { type: "task_started", turn_id: "33333333-3333-4333-8333-333333333333" } },
  { type: "event_msg", payload: { type: "user_message", message: `read C:/x/${discussion}.task.md and proceed` } },
  { type: "event_msg", payload: { type: "agent_message", message: discussionFinal, phase: "final_answer" } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: "33333333-3333-4333-8333-333333333333", last_agent_message: discussionFinal } },
];
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
printf 'task' > "$IPCROOT/$SID/$THREAD/$SUPER_VIEW_DISPATCH.task.md"
printf 'SUPERSEDED-PRIMARY-BODY' > "$IPCROOT/$SID/$THREAD/$SUPER_VIEW_DISPATCH.reply.md"
printf 'task' > "$IPCROOT/$SID/$THREAD/$DISCUSS_VIEW_DISPATCH.task.md"
printf 'DISCUSSION-PRIMARY-BODY' > "$IPCROOT/$SID/$THREAD/$DISCUSS_VIEW_DISPATCH.reply.md"
before="$(manifest)"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$THREAD" 2>&1)"; RC=$?
after="$(manifest)"
[[ $RC -eq 0 && "$before" == "$after" && "$OUT" == *"SUPERSEDED-PRIMARY-BODY"* && "$OUT" == *"DISCUSSION-PRIMARY-BODY"* \
  && "$(printf '%s\n' "$OUT" | grep -Fc '[WARNING: REPLY-SUPERSEDED] Primary reply may be superseded; inspect the dispatch thread before relying on it.')" -eq 1 ]] \
  && ok "viewer annotates only standalone supersession while preserving primary bodies" \
  || no "viewer supersession annotation (rc=$RC)"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$THREAD" --paths-only 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"$SUPER_VIEW_DISPATCH"* && "$OUT" == *"$DISCUSS_VIEW_DISPATCH"* \
  && "$OUT" != *"REPLY-SUPERSEDED"* && "$OUT" != *"PRIMARY-BODY"* ]] \
  && ok "supersession annotation does not alter paths-only shape" \
  || no "viewer supersession paths-only contract (rc=$RC)"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" PATH="/usr/bin:/bin" bash "$VIEWER" -c "$THREAD" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"SUPERSEDED-PRIMARY-BODY"* && "$OUT" == *"DISCUSSION-PRIMARY-BODY"* \
  && "$OUT" != *"REPLY-SUPERSEDED"* ]] \
  && ok "Node absence leaves superseded primary rendering unaffected" \
  || no "viewer supersession no-Node contract (rc=$RC)"

NO_CANDIDATE_THREAD=22222222-2222-4222-8222-222222222222
NO_CANDIDATE_DISPATCH=8800000000-8-abcdef0123456789
mkdir -p "$IPCROOT/$SID/$NO_CANDIDATE_THREAD"
printf 'task' > "$IPCROOT/$SID/$NO_CANDIDATE_THREAD/$NO_CANDIDATE_DISPATCH.task.md"
printf 'PRIMARY-WITHOUT-ROLLOUT' > "$IPCROOT/$SID/$NO_CANDIDATE_THREAD/$NO_CANDIDATE_DISPATCH.reply.md"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$NO_CANDIDATE_THREAD" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-WITHOUT-ROLLOUT"* \
  && "$OUT" != *"REPLY-SUPERSESSION-UNAVAILABLE"* && "$OUT" != *"REPLY-SUPERSESSION-PENDING"* ]] \
  && ok "viewer keeps ordinary no-candidate supersession status quiet" \
  || no "viewer no-candidate supersession noise contract (rc=$RC)"

UNREADABLE_SESSIONS_ROOT="$TMP/sessions-root-is-a-file"
printf 'not a directory' > "$UNREADABLE_SESSIONS_ROOT"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$UNREADABLE_SESSIONS_ROOT" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$NO_CANDIDATE_THREAD" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-WITHOUT-ROLLOUT"* \
  && "$OUT" == *"[CAUTION: REPLY-SUPERSESSION-UNAVAILABLE] Selected primary may be stale; freshness and supersession could not be certified."* ]] \
  && ok "viewer surfaces non-benign supersession discovery failure" \
  || no "viewer non-benign supersession discovery caution (rc=$RC)"

AMBIGUOUS_THREAD=00000000-0000-4000-8000-00000000c0de
AMBIGUOUS_DISPATCH=8850000000-8-abcdef0123456789
mkdir -p "$IPCROOT/$SID/$AMBIGUOUS_THREAD" "$SESSIONS/2026/07/09/a" "$SESSIONS/2026/07/09/b"
printf 'task' > "$IPCROOT/$SID/$AMBIGUOUS_THREAD/$AMBIGUOUS_DISPATCH.task.md"
printf 'PRIMARY-WITH-AMBIGUOUS-ROLLOUT' > "$IPCROOT/$SID/$AMBIGUOUS_THREAD/$AMBIGUOUS_DISPATCH.reply.md"
printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$AMBIGUOUS_THREAD" \
  > "$SESSIONS/2026/07/09/a/rollout-a-$AMBIGUOUS_THREAD.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s"}}\n' "$AMBIGUOUS_THREAD" \
  > "$SESSIONS/2026/07/09/b/rollout-b-$AMBIGUOUS_THREAD.jsonl"
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$AMBIGUOUS_THREAD" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-WITH-AMBIGUOUS-ROLLOUT"* \
  && "$OUT" == *"[CAUTION: REPLY-SUPERSESSION-UNAVAILABLE] Selected primary may be stale; freshness and supersession could not be certified."* \
  && "$OUT" != *"[WARNING: REPLY-SUPERSEDED]"* ]] \
  && ok "viewer surfaces ambiguous supersession discovery without adding no-candidate noise" \
  || no "viewer ambiguous supersession caution contract (rc=$RC)"

UNCERTAIN_THREAD=33333333-3333-4333-8333-333333333333
UNCERTAIN_DISPATCH=8900000000-8-abcdef0123456789
mkdir -p "$IPCROOT/$SID/$UNCERTAIN_THREAD"
printf 'task' > "$IPCROOT/$SID/$UNCERTAIN_THREAD/$UNCERTAIN_DISPATCH.task.md"
printf 'PRIMARY-WITH-UNCERTIFIABLE-ROLLOUT' > "$IPCROOT/$SID/$UNCERTAIN_THREAD/$UNCERTAIN_DISPATCH.reply.md"
cat > "$SESSIONS/2026/07/09/rollout-uncertifiable-$UNCERTAIN_THREAD.jsonl" <<JSONL
{"type":"session_meta","payload":{"id":"$UNCERTAIN_THREAD"}}
{unrelated malformed json}
JSONL
OUT="$(CODEX_IPC_ROOT="$IPCROOT" CODEX_IPC_SESSIONS_ROOT="$SESSIONS" \
  CLAUDE_CODE_SESSION_ID="$SID" bash "$VIEWER" -c "$UNCERTAIN_THREAD" 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-WITH-UNCERTIFIABLE-ROLLOUT"* \
  && "$OUT" == *"[CAUTION: REPLY-SUPERSESSION-UNAVAILABLE] Selected primary may be stale; freshness and supersession could not be certified."* \
  && "$OUT" != *"[WARNING: REPLY-SUPERSEDED]"* ]] \
  && ok "viewer exposes supersession uncertainty without weakening primary authority" \
  || no "viewer supersession uncertainty contract (rc=$RC)"

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
