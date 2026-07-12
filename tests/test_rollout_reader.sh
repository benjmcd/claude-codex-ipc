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
const {
  DEFAULT_MAX_RECORD_BYTES,
  correlateDispatch,
  createTurnBoundaryAccumulator,
  inspectRolloutMarker,
  locateRollout,
  pollRolloutForMarker,
  readRolloutFile,
  summarizeThreadActivity,
} = api;

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
  assert.equal(typeof locateRollout, "function");
  assert.equal(typeof correlateDispatch, "function");
  assert.ok(DEFAULT_MAX_RECORD_BYTES > 20 * 1024 * 1024);
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
  const result = correlateDispatch(basic, "9999999999-9-ffffffffffffffff");
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

test("reader enforces an injected hard elapsed deadline", () => {
  let ticks = 0;
  const result = readRolloutFile(basicPath, {
    deadlineAt: 2,
    now: () => ++ticks,
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, "deadline-exceeded");
  assert.equal(result.integrityValidated, true);
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

test("intervening user message is ambiguous and completion mismatch is diagnostic", () => {
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
  assert.equal(result.text, "selected final");
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

test("write-proof awaits the shared poller and keeps its proof gate", () => {
  const proofPath = path.join(path.dirname(process.env.MODULE), "codex_ipc_write_proof.mjs");
  const source = fs.readFileSync(proofPath, "utf8");
  assert.match(source, /from "\.\/codex_ipc_rollout_reader\.mjs"/);
  assert.match(source, /const rolloutProbe = await pollRolloutForMarker\(/);
  assert.match(source, /const ok = send\.ok && rolloutProbe\.ok && compare\.ok;/);
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

// ---- Harvester correlation deltas (RED-before at base b2aec66, GREEN after A1) -----------------
test("delta: a later same-turn-id user no longer defeats correlation", () => {
  const records = [
    meta,
    ev("task_started", { turn_id: "turn-a" }),
    ev("user_message", { turn_id: "turn-a", message: "read C:/x/tm7-7-abcdef0123456789.task.md and proceed" }),
    ev("user_message", { turn_id: "turn-a", message: "one more note" }),
    ev("agent_message", { message: "same-turn body", phase: "final_answer" }),
    ev("task_complete", { turn_id: "turn-a", last_agent_message: "same-turn body" }),
  ];
  const result = correlateDispatch(writeAndRead("sameturn", records), "tm7-7-abcdef0123456789");
  assert.equal(result.status, "complete");
  assert.equal(result.text, "same-turn body");
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

// ---- Pending RED fixtures (opt-in via IPC_RED_PENDING=1) ----------------------------------
// RED-first v0.1.6 fixtures. They assert the DESIRED post-fix behavior and therefore FAIL
// against current code (the defect reproduces). Gated OFF by default so the release runner's
// green battery is unaffected; un-gated (promoted to always-run) when the owning fix lands:
// A-06 in Phase 2 (A1 shared correlator), A-04 in Phase 3 (A4 marker-proof turn-binding).
// Observe RED with:  IPC_RED_PENDING=1 bash tests/test_rollout_reader.sh
if (process.env.IPC_RED_PENDING === "1") {
  test("A-06 (RED, pending A1/Phase-2): same-turn-id later user must still correlate complete", () => {
    const a06 = path.join(
      fixtures,
      "rollout-a06-sameturn-11111111-1111-4111-8111-111111111111.jsonl",
    );
    const result = correlateDispatch(readRolloutFile(a06), "1600000000-6-abcdef0123456789");
    // DESIRED: same-turn-id exemption -> complete. CURRENT wrong output: none / ambiguous.
    assert.equal(result.status, "complete");
    assert.equal(result.text, "a06 correlated final answer");
  });

  await test("A-04 (RED, pending A4/Phase-3): cross-turn marker proof must be ok:false", async () => {
    const a04 = path.join(
      fixtures,
      "rollout-a04-crossturn-22222222-2222-4222-8222-222222222222.jsonl",
    );
    // Agent marker in turn-1 (no terminal there); task_complete only in turn-2 (marker absent).
    const proof = await pollRolloutForMarker(a04, "A04_PROOF_MARKER", 10, 1, {
      now: () => 0,
      sleep: async () => {},
    });
    // DESIRED: turn-id-bound proof -> ok:false. CURRENT wrong output: ok:true (cross-turn).
    assert.equal(proof.ok, false);
    assert.equal(
      inspectRolloutMarker(a04, "A04_PROOF_MARKER").taskCompleteAfterAgentMarker,
      false,
    );
  });
}

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
