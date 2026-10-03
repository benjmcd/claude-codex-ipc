#!/usr/bin/env bash
# Hermetic delegation completion-contract verification. No host sessions, IPC, or network.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node is unavailable; IPC wait tests require optional Node."
    exit 0
fi

WAIT=""
for candidate in \
    "$DIR/../skills/ipc/scripts/codex_ipc_wait.mjs" \
    "$DIR/../scripts/codex_ipc_wait.mjs"; do
    [[ -f "$candidate" ]] && WAIT="$candidate" && break
done
[[ -n "$WAIT" ]] || { echo "FAIL: codex_ipc_wait.mjs not found" >&2; exit 1; }

TMP="$(mktemp -d)" && [[ -n "$TMP" && -d "$TMP" ]] \
    || { echo "FATAL: could not create waiter temporary directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

WAIT="$WAIT" TMPDIR_TEST="$TMP" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const waitPath = process.env.WAIT;
const tmp = process.env.TMPDIR_TEST;
let currentFixtureRoot = tmp;
const thread = "11111111-1111-4111-8111-111111111111";
const ownTurn = "00000000-0000-4000-8000-00000000c0de";
const otherTurn = "22222222-2222-4222-8222-222222222222";
const dispatch = "9100000000-1-abcdef0123456789";
const taskName = `${dispatch}.task.md`;

const api = await import(pathToFileURL(waitPath));
const {
  DEFAULT_WAIT_BUDGET_MS,
  DEFAULT_WAIT_INTERVAL_MS,
  parseWaitArgs,
  waitForCompletion,
} = api;
const { assessRolloutPageSupersession, readRolloutFile } = await import(
  pathToFileURL(path.join(path.dirname(waitPath), "codex_ipc_rollout_reader.mjs"))
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

function sessionMeta(id = thread) {
  return { type: "session_meta", payload: { id } };
}

function event(type, turnId, extra = {}) {
  return {
    type: "event_msg",
    payload: {
      type,
      ...(turnId === undefined ? {} : { turn_id: turnId }),
      ...extra,
    },
  };
}

function ownOpenRecords() {
  return [
    sessionMeta(),
    event("task_started", ownTurn),
    event("user_message", ownTurn, { message: `read C:/handoff/${taskName} and proceed` }),
  ];
}

function ownCompletedRecords(body = "certified rollout body") {
  return [
    ...ownOpenRecords(),
    event("agent_message", ownTurn, { phase: "final_answer", message: body }),
    event("task_complete", ownTurn, { last_agent_message: body }),
  ];
}

function writeRollout(directory, records, id = thread, prefix = "rollout") {
  fs.mkdirSync(directory, { recursive: true });
  const target = path.join(directory, `${prefix}-${id}.jsonl`);
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  return target;
}

function writeSuccessor(directory, predecessorRecords, cutoff, pageId) {
  const target = path.join(directory, "successor", `rollout-page-${thread}_${pageId}.jsonl`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify({
    type: "session_meta",
    payload: {
      id: thread,
      session_id: thread,
      history_mode: "paginated",
      history_base: { thread_id: thread, end_byte_offset: cutoff },
    },
  })}\n`);
  const lines = predecessorRecords.map((item) => JSON.stringify(item));
  const markerOffset = lines
    .slice(0, 2)
    .reduce((size, line) => size + Buffer.byteLength(line) + 1, 0);
  const markerEndOffset = markerOffset + Buffer.byteLength(lines[2]) + 1;
  return { target, markerOffset, markerEndOffset };
}

function writeReply(target, body = "verified reply") {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, body);
  return target;
}

function caseDir(name) {
  const target = path.join(tmp, name);
  fs.mkdirSync(target, { recursive: true });
  currentFixtureRoot = target;
  return target;
}

function directOptions(root, rolloutPath, replyPath, extra = {}) {
  return {
    threadId: thread,
    dispatchId: dispatch,
    rolloutPath,
    sessionsRoot: root,
    transportRoot: path.join(root, "transport"),
    replyPath,
    sessionId: null,
    budgetMs: 0,
    intervalMs: DEFAULT_WAIT_INTERVAL_MS,
    ...extra,
  };
}

// The spawn timeout is a hang kill-switch, not a performance bound: correct = child node
// cold-start (2-3s under battery load) + sub-second tool work; wrong = a lingering/hung child,
// which still surfaces as a spawn error at the kill floor. 15000 is >=3x the worst loaded
// correct path (~4s) so load can never masquerade as a hang.
function cli(args, env = {}, timeout = 15000) {
  return spawnSync(process.execPath, [waitPath, ...args], {
    cwd: tmp,
    encoding: "utf8",
    timeout,
    env: {
      ...process.env,
      HOME: tmp,
      USERPROFILE: tmp,
      CODEX_IPC_ROOT: path.join(tmp, "default-transport"),
      CODEX_IPC_ROLLOUT_PATH: "",
      CODEX_IPC_SESSIONS_ROOT: currentFixtureRoot,
      CODEX_IPC_WAIT_BUDGET_MS: "",
      CODEX_IPC_WAIT_INTERVAL_MS: "",
      ...env,
    },
  });
}

function assertToken(result, token) {
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.signal, null);
  assert.equal(result.stdout, `${token}\n`);
}

await test("module exports side-effect-free wait API and documented defaults", () => {
  assert.equal(DEFAULT_WAIT_BUDGET_MS, 0);
  assert.equal(DEFAULT_WAIT_INTERVAL_MS, 250);
  assert.equal(typeof waitForCompletion, "function");
  const imported = spawnSync(
    process.execPath,
    ["--input-type=module", "-e", `await import(${JSON.stringify(pathToFileURL(waitPath).href)})`],
    // Kill-switch only (hang vs silent import); a loaded cold-start alone can cost 2-3s.
    { encoding: "utf8", timeout: 15000 },
  );
  assert.equal(imported.status, 0, imported.stderr);
  assert.equal(imported.stdout, "");
  assert.equal(imported.stderr, "");
  assert.doesNotMatch(fs.readFileSync(waitPath, "utf8"), /node:sqlite/);
});

await test("E1 waiter path aliases preserve flag then environment then default precedence", () => {
  const envPage = path.join(tmp, "env-page.jsonl");
  const flagPage = path.join(tmp, "flag-page.jsonl");
  const envRoot = path.join(tmp, "env-sessions");
  const flagRoot = path.join(tmp, "flag-sessions");
  const baseArgs = ["--thread", thread, "--dispatch", dispatch];
  const fromEnvironment = parseWaitArgs(baseArgs, {
    CODEX_IPC_ROLLOUT_PATH: envPage,
    CODEX_IPC_SESSIONS_ROOT: envRoot,
  }).options;
  assert.equal(fromEnvironment.rolloutPath, envPage);
  assert.equal(fromEnvironment.sessionsRoot, envRoot);

  const fromFlags = parseWaitArgs([
    ...baseArgs,
    "--rollout-path", flagPage,
    "--sessions-root", flagRoot,
  ], {
    CODEX_IPC_ROLLOUT_PATH: "\u0000invalid",
    CODEX_IPC_SESSIONS_ROOT: envRoot,
  }).options;
  assert.equal(fromFlags.rolloutPath, flagPage);
  assert.equal(fromFlags.sessionsRoot, flagRoot);

  const empty = parseWaitArgs(baseArgs, {
    CODEX_IPC_ROLLOUT_PATH: "",
    CODEX_IPC_SESSIONS_ROOT: "",
  }).options;
  const absent = parseWaitArgs(baseArgs, {}).options;
  assert.equal(empty.rolloutPath, absent.rolloutPath);
  assert.equal(empty.sessionsRoot, absent.sessionsRoot);
  assert.throws(
    () => parseWaitArgs(baseArgs, { CODEX_IPC_ROLLOUT_PATH: "bad\npath" }),
    (error) => error?.code === "IPC_ROLLOUT_PATH_INVALID",
  );
});

await test("done requires own task_complete plus a regular readable reply", async () => {
  const root = caseDir("done");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "done");
});

await test("a successor cutoff at the dispatch marker vetoes stale-page completion", async () => {
  const root = caseDir("page-abandoned");
  const records = ownCompletedRecords();
  const rollout = writeRollout(path.join(root, "predecessor"), records);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const offsets = writeSuccessor(
    root,
    records,
    records.slice(0, 2).reduce(
      (size, item) => size + Buffer.byteLength(JSON.stringify(item)) + 1,
      0,
    ),
    "33333333-3333-4333-8333-333333333333",
  );
  assert.equal(offsets.markerOffset, records.slice(0, 2).reduce(
    (size, item) => size + Buffer.byteLength(JSON.stringify(item)) + 1,
    0,
  ));
  const result = await waitForCompletion(directOptions(root, rollout, reply, { sessionsRoot: root }));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "dispatch-history-abandoned"));
});

await test("a successor preserving the dispatch still vetoes stale-page completion", async () => {
  const root = caseDir("page-superseded");
  const records = ownCompletedRecords();
  const rollout = writeRollout(path.join(root, "predecessor"), records);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const lines = records.map((item) => JSON.stringify(item));
  const markerEndOffset = lines
    .slice(0, 3)
    .reduce((size, line) => size + Buffer.byteLength(line) + 1, 0);
  writeSuccessor(
    root,
    records,
    markerEndOffset,
    "33333333-3333-4333-8333-333333333333",
  );
  const result = await waitForCompletion(directOptions(root, rollout, reply, { sessionsRoot: root }));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-page-superseded"));
});

await test("cross-date authority requires a known containing discovery root for primary and fallback", async () => {
  const root = caseDir("cross-date-scope");
  const records = ownCompletedRecords();
  const rollout = writeRollout(path.join(root, "2026", "09", "28"), records);
  const lines = records.map((item) => JSON.stringify(item));
  const cutoff = lines.slice(0, 2).reduce((size, line) => size + Buffer.byteLength(line) + 1, 0);
  writeSuccessor(path.join(root, "2026", "09", "30"), records, cutoff, otherTurn);
  const wrongRoot = path.join(tmp, "wrong-scope");
  fs.mkdirSync(wrongRoot);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  for (const sessionsRoot of [undefined, wrongRoot, path.join(root, "missing")]) {
    for (const replyPath of [reply, path.join(root, "absent.reply.md")]) {
      const result = await waitForCompletion(directOptions(root, rollout, replyPath, {
        sessionsRoot, acceptRolloutFallback: true,
      }));
      assert.equal(result.token, "unavailable");
      assert.equal(result.replySource, undefined);
      assert.ok(result.diagnostics.some((item) => item.code === "page-supersession-unproven"));
    }
  }
  const result = await waitForCompletion(directOptions(root, rollout, reply, {
    acceptRolloutFallback: true,
  }));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) => item.code === "dispatch-history-abandoned"));
});

await test("a nested directory link blocks WAIT completion but preserves an independent primary harvest", async () => {
  const root = caseDir("nested-link-wait");
  const scope = path.join(root, "scope");
  const records = ownCompletedRecords();
  const rollout = writeRollout(scope, records);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const absent = path.join(root, "absent.reply.md");
  const cutoff = records.slice(0, 2).reduce(
    (size, item) => size + Buffer.byteLength(JSON.stringify(item)) + 1, 0,
  );
  const successor = writeSuccessor(path.join(root, "future"), records, cutoff, otherTurn);
  for (const replyPath of [reply, absent]) {
    const current = await waitForCompletion(directOptions(scope, rollout, replyPath, {
      acceptRolloutFallback: true,
    }));
    assert.equal(current.token, "done");
  }
  const alias = path.join(root, "scope-alias");
  fs.symlinkSync(scope, alias, process.platform === "win32" ? "junction" : "dir");
  assert.equal((await waitForCompletion(directOptions(alias, rollout, reply))).token, "done");

  fs.symlinkSync(path.dirname(successor.target), path.join(scope, "future"),
    process.platform === "win32" ? "junction" : "dir");
  for (const replyPath of [reply, absent]) {
    const result = await waitForCompletion(directOptions(scope, rollout, replyPath, {
      acceptRolloutFallback: true,
    }));
    assert.equal(result.token, "unavailable");
    assert.equal(result.replySource, undefined);
    assert.ok(result.diagnostics.some((item) => item.code === "page-supersession-unproven"
      && item.reason === "candidate-set-unresolved"));
  }
  const { harvestDispatch } = await import(
    pathToFileURL(path.join(path.dirname(waitPath), "codex_ipc_reply_harvest.mjs"))
  );
  const primary = harvestDispatch(directOptions(scope, rollout, reply));
  assert.equal(primary.source, "reply-file");
  assert.equal(primary.replyPath, reply);
  assert.equal(primary.replySupersessionStatus, "unavailable");
  assert.equal(primary.replySupersessionCaution, true);
  assert.ok(primary.diagnostics.some((item) => item.code === "page-supersession-unproven"));
  const fallback = harvestDispatch(directOptions(scope, rollout, absent));
  assert.equal(fallback.source, "none");
  assert.equal(fallback.reason, "unavailable");

  const fileScope = path.join(root, "file-scope");
  const fileRollout = writeRollout(fileScope, records);
  fs.symlinkSync(successor.target, path.join(fileScope, path.basename(successor.target)), "file");
  const fileResult = await waitForCompletion(directOptions(fileScope, fileRollout, absent, {
    acceptRolloutFallback: true,
  }));
  assert.equal(fileResult.token, "unavailable");
  assert.ok(fileResult.diagnostics.some((item) => item.code === "dispatch-history-abandoned"));
});

await test("a reused dispatch id makes an older primary reply unavailable", async () => {
  const root = caseDir("mixed-source-freshness");
  const rollout = writeRollout(root, [
    ...ownCompletedRecords("older certified body"),
    event("task_started", otherTurn),
    event("user_message", otherTurn, { message: `read C:/handoff/${taskName} and proceed` }),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const primary = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(primary.token, "unavailable");
  assert.equal(primary.replySource, undefined);
  assert.ok(primary.diagnostics.some((item) => item.code === "dispatch-id-reused"));
  assert.ok(primary.diagnostics.some((item) => item.code === "reply-unverified"));

  const fallback = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true },
  ));
  assert.equal(fallback.token, "unavailable");
  assert.equal(fallback.replySource, undefined);
  assert.ok(fallback.diagnostics.some((item) => item.code === "dispatch-id-reused"));
});

await test("opaque post-completion tails caution primary and block rollout fallback", async () => {
  for (const [name, tail] of [
    ["schema", `${JSON.stringify(event("future_lifecycle_event", undefined))}\n`],
    ["malformed", "{\"type\":\n"],
  ]) {
    const root = caseDir(`opaque-freshness-${name}`);
    const rollout = writeRollout(root, ownCompletedRecords());
    fs.appendFileSync(rollout, tail);
    const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
    const primary = await waitForCompletion(directOptions(root, rollout, reply));
    assert.equal(primary.token, "unavailable", name);
    assert.equal(primary.replySource, undefined, name);
    assert.ok(primary.diagnostics.some((item) => item.code === "dispatch-freshness-unsettled"), name);
    assert.ok(primary.diagnostics.some((item) => item.code === "reply-unverified"), name);

    const fallback = await waitForCompletion(directOptions(
      root,
      rollout,
      path.join(root, "missing.reply.md"),
      { acceptRolloutFallback: true },
    ));
    assert.equal(fallback.token, "unavailable", name);
    assert.equal(fallback.replySource, undefined, name);
    assert.ok(fallback.diagnostics.some((item) => item.code === "dispatch-freshness-unsettled"), name);
  }
});

await test("a reused dispatch id stays unavailable after both occurrences settle", async () => {
  const root = caseDir("mixed-fallback-complete");
  const newBody = "new certified body";
  const rollout = writeRollout(root, [
    ...ownCompletedRecords("older certified body"),
    event("task_started", otherTurn),
    event("user_message", otherTurn, { message: `read C:/handoff/${taskName} and proceed` }),
    event("agent_message", otherTurn, { phase: "final_answer", message: newBody }),
    event("task_complete", otherTurn, { last_agent_message: newBody }),
  ]);
  let sleeps = 0;
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, budgetMs: 30, intervalMs: 10 },
  ), {
    now: () => 0,
    sleep: async () => {
      sleeps += 1;
    },
  });
  assert.equal(result.token, "unavailable");
  assert.equal(result.replySource, undefined);
  assert.ok(result.diagnostics.some((item) => item.code === "dispatch-id-reused"));
  assert.equal(sleeps, 0);
});

await test("aborted wins even when a reply is present and marks it unverified", () => {
  const root = caseDir("aborted");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("turn_aborted", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", reply,
  ]);
  assertToken(result, "aborted");
  assert.match(result.stderr, /reply-unverified/);
  assert.match(result.stderr, /"code":"turn-error"/);
  assert.match(result.stderr, /"kind":"turn_aborted"/);
});

await test("C7 task error keeps reply-file primacy and emits empty-model evidence", () => {
  const root = caseDir("turn-error-primary");
  const rollout = writeRollout(root, [
    ...ownOpenRecords().slice(0, 2),
    { type: "turn_context", payload: { turn_id: ownTurn, model: "" } },
    ownOpenRecords()[2],
    event("task_complete", ownTurn, {
      last_agent_message: null,
      error: { message: "synthetic failure", codex_error_info: "PRIVATE-SIBLING" },
    }),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", reply,
  ]);
  assertToken(result, "done");
  assert.match(result.stderr, /"code":"turn-error"/);
  assert.match(result.stderr, /"turnError":\{"kind":"task_complete"/);
  assert.match(result.stderr, /"excerpt":"synthetic failure"/);
  assert.match(result.stderr, /"code":"turn-model-state"/);
  assert.match(result.stderr, /"appliedModel":\{"state":"empty"\}/);
  assert.doesNotMatch(result.stderr, /PRIVATE-SIBLING/);
});

await test("C7 task error without a reply remains reply-missing with named diagnostics", () => {
  const root = caseDir("turn-error-missing");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("task_complete", ownTurn, {
      last_agent_message: null,
      error: { message: "synthetic missing reply" },
    }),
  ]);
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", path.join(root, "missing.reply.md"),
  ]);
  assertToken(result, "reply-missing");
  assert.match(result.stderr, /"code":"turn-error"/);
  assert.match(result.stderr, /"assistantOutput":false/);
});

await test("aborted notes an existing reply even when metadata access is denied", async () => {
  const root = caseDir("aborted-unreadable-reply");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("turn_aborted", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const originalLstat = fs.lstatSync;
  fs.lstatSync = (target, ...args) => {
    if (path.resolve(target) === path.resolve(reply)) {
      const error = new Error("access denied");
      error.code = "EACCES";
      throw error;
    }
    return originalLstat(target, ...args);
  };
  try {
    const result = await waitForCompletion(directOptions(root, rollout, reply));
    assert.equal(result.token, "aborted");
    assert.ok(result.diagnostics.some((item) => item.code === "reply-unverified"));
  } finally {
    fs.lstatSync = originalLstat;
  }
});

await test("newer turn supersedes own open turn and later terminal cannot certify it", async () => {
  const root = caseDir("superseded");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("task_started", otherTurn),
    event("user_message", otherTurn, { message: "unrelated compaction follow-up" }),
    event("task_complete", otherTurn),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "superseded");
});

await test("reply-missing follows own un-superseded task_complete", async () => {
  const root = caseDir("reply-missing");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.reply.md")),
  );
  assert.equal(result.token, "reply-missing");
});

await test("pending reports an observed own turn that is still open", async () => {
  const root = caseDir("pending");
  const rollout = writeRollout(root, ownOpenRecords());
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.reply.md")),
  );
  assert.equal(result.token, "pending");
});

await test("unavailable reports no authoritative rollout candidate", () => {
  const root = caseDir("unavailable");
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--sessions-root", path.join(root, "no-sessions"),
    "--transport-root", path.join(root, "transport"),
  ]);
  assertToken(result, "unavailable");
});

await test("completed unrelated turn before compaction is not borrowed by own open turn", async () => {
  const root = caseDir("compaction");
  const rollout = writeRollout(root, [
    sessionMeta(),
    event("task_started", otherTurn),
    event("user_message", otherTurn, { message: "unrelated" }),
    event("task_complete", otherTurn),
    { type: "event_msg", payload: { type: "context_compacted" } },
    ...ownOpenRecords().slice(1),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "pending");
});

await test("goal continuation keeps rollout fallback bound to the completed dispatch turn", async () => {
  const root = caseDir("goal-continuation-complete");
  const rollout = writeRollout(root, [
    ...ownCompletedRecords("OWN"),
    event("task_started", otherTurn),
    event("agent_message", otherTurn, { phase: "final_answer", message: "OTHER" }),
    event("task_complete", otherTurn, { last_agent_message: "OTHER" }),
  ]);
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true },
  ));
  assert.equal(result.token, "done");
  assert.equal(result.replySource, "rollout-fallback");
  assert.deepEqual(result.diagnostics, []);
});

await test("goal continuation cannot lend its body to a bodyless dispatch terminal", async () => {
  const root = caseDir("goal-continuation-bodyless");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("task_complete", ownTurn, { last_agent_message: null }),
    event("task_started", otherTurn),
    event("agent_message", otherTurn, { phase: "final_answer", message: "OTHER" }),
    event("task_complete", otherTurn, { last_agent_message: "OTHER" }),
  ]);
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true },
  ));
  assert.equal(result.token, "reply-missing");
  assert.equal(result.replySource, undefined);
  assert.deepEqual(result.diagnostics, []);
});

await test("dispatch marker requires an exact task basename boundary", async () => {
  const root = caseDir("basename-boundary");
  const rollout = writeRollout(root, [
    sessionMeta(),
    event("task_started", ownTurn),
    event("user_message", ownTurn, { message: `prefix${taskName}suffix` }),
    event("task_complete", ownTurn),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "pending");
});

await test("turn-id mismatch is unavailable rather than completion", async () => {
  const root = caseDir("turn-mismatch");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", otherTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "unavailable");
});

await test("user-message turn-id mismatch cannot identify the dispatch own turn", async () => {
  const root = caseDir("user-turn-mismatch");
  const rollout = writeRollout(root, [
    sessionMeta(),
    event("task_started", ownTurn),
    event("user_message", otherTurn, { message: `read C:/handoff/${taskName} and proceed` }),
    event("task_complete", ownTurn),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "unavailable");
});

await test("malformed JSON inside the own turn prevents determination", async () => {
  const root = caseDir("schema-failure");
  const rollout = writeRollout(root, ownOpenRecords());
  fs.appendFileSync(rollout, "{malformed\n");
  fs.appendFileSync(rollout, `${JSON.stringify(event("task_complete", ownTurn))}\n`);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "unavailable");
});

await test("schema drift anywhere inside the dispatch turn prevents determination", async () => {
  const root = caseDir("schema-drift-window");
  const rollout = writeRollout(root, [
    sessionMeta(),
    event("task_started", ownTurn),
    event("future_lifecycle", ownTurn, { message: "unknown turn event" }),
    event("user_message", ownTurn, { message: `read C:/handoff/${taskName} and proceed` }),
    event("task_complete", ownTurn),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "unavailable");
});

await test("transport-root CLI scan uses a single reply-path hit for completion", () => {
  const root = caseDir("scan-single");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const transport = path.join(root, "transport");
  writeReply(path.join(transport, "session-a", thread, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--transport-root", transport,
  ]);
  assertToken(result, "done");
});

await test("multiple reply-path scan hits are unavailable and never guessed", async () => {
  const root = caseDir("scan-ambiguous");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const transport = path.join(root, "transport");
  writeReply(path.join(transport, "session-a", thread, `${dispatch}.reply.md`), "one");
  writeReply(path.join(transport, "session-b", thread, `${dispatch}.reply.md`), "two");
  const result = await waitForCompletion(
    directOptions(root, rollout, null, { transportRoot: transport }),
  );
  assert.equal(result.token, "unavailable");
});

await test("reply-path scan ambiguity is unavailable while the own turn is still open", async () => {
  const root = caseDir("scan-ambiguous-pending");
  const rollout = writeRollout(root, ownOpenRecords());
  const transport = path.join(root, "transport");
  writeReply(path.join(transport, "session-a", thread, `${dispatch}.reply.md`), "one");
  writeReply(path.join(transport, "session-b", thread, `${dispatch}.reply.md`), "two");
  const result = await waitForCompletion(
    directOptions(root, rollout, null, { transportRoot: transport }),
  );
  assert.equal(result.token, "unavailable");
});

await test("symlinked reply is not accepted as done", async () => {
  const root = caseDir("reply-symlink");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const real = writeReply(path.join(root, "real.reply.md"));
  const alias = path.join(root, "alias.reply.md");
  try {
    fs.symlinkSync(real, alias, "file");
    const result = await waitForCompletion(directOptions(root, rollout, alias));
    assert.equal(result.token, "reply-missing");
  } catch (error) {
    if (error?.code !== "EPERM") throw error;
    writeReply(alias, "not followed");
    const originalLstat = fs.lstatSync;
    fs.lstatSync = (target, ...args) => {
      if (path.resolve(target) === path.resolve(alias)) {
        return { isSymbolicLink: () => true, isFile: () => false };
      }
      return originalLstat(target, ...args);
    };
    try {
      const result = await waitForCompletion(directOptions(root, rollout, alias));
      assert.equal(result.token, "reply-missing");
    } finally {
      fs.lstatSync = originalLstat;
    }
  }
});

await test("reply changed to a symlink during validation is not accepted as done", async () => {
  const root = caseDir("reply-symlink-race");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const originalLstat = fs.lstatSync;
  let replyLstatCalls = 0;
  fs.lstatSync = (target, ...args) => {
    if (path.resolve(target) === path.resolve(reply)) {
      replyLstatCalls += 1;
      if (replyLstatCalls > 1) {
        return { isSymbolicLink: () => true, isFile: () => false };
      }
    }
    return originalLstat(target, ...args);
  };
  try {
    const result = await waitForCompletion(directOptions(root, rollout, reply));
    assert.equal(result.token, "reply-missing");
  } finally {
    fs.lstatSync = originalLstat;
  }
  assert.ok(replyLstatCalls >= 2);
});

await test("non-regular reply path is not accepted as done", async () => {
  const root = caseDir("reply-directory");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const directory = path.join(root, "directory.reply.md");
  fs.mkdirSync(directory);
  const result = await waitForCompletion(directOptions(root, rollout, directory));
  assert.equal(result.token, "reply-missing");
});

await test("explicit reply-path CLI flag wins over a valid session-derived reply", () => {
  const root = caseDir("reply-explicit-wins");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const transport = path.join(root, "transport");
  writeReply(path.join(transport, "session-a", thread, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout,
    "--reply-path", path.join(root, "absent.md"),
    "--session", "session-a", "--transport-root", transport,
  ]);
  assertToken(result, "reply-missing");
});

await test("session derives reply under transport root and CODEX_IPC_ROOT supplies its default", () => {
  const root = caseDir("session-derived");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const transport = path.join(root, "transport");
  writeReply(path.join(transport, "session-a", thread, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--session", "session-a", "--rollout-path", rollout,
  ], { CODEX_IPC_ROOT: transport });
  assertToken(result, "done");
});

await test("explicit rollout path wins over ambiguous sessions-root candidates", () => {
  const root = caseDir("rollout-explicit-wins");
  const sessions = path.join(root, "sessions");
  const explicit = writeRollout(
    path.join(sessions, "explicit"),
    [...ownOpenRecords(), event("task_complete", ownTurn)],
  );
  writeRollout(path.join(sessions, "a"), ownOpenRecords(), thread, "first");
  writeRollout(path.join(sessions, "b"), ownOpenRecords(), thread, "second");
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", explicit, "--sessions-root", sessions,
    "--reply-path", reply,
  ]);
  assertToken(result, "done");
});

await test("canonical home discovery root certifies an explicit current page without a root flag", () => {
  const sessions = path.join(tmp, ".codex", "sessions");
  const rollout = writeRollout(path.join(sessions, "2026", "09", "28"), ownCompletedRecords());
  const reply = path.join(tmp, "default-absent.reply.md");
  const result = cli([
    "--thread", thread, "--dispatch", dispatch, "--rollout-path", rollout,
    "--reply-path", reply, "--accept-rollout-fallback",
  ], { CODEX_IPC_SESSIONS_ROOT: "" });
  assertToken(result, "done");
  assert.match(result.stderr, /rollout-fallback/);
});

await test("wrapper observer and printed WAIT preserve the same inspector page and discovery scope", () => {
  const root = caseDir("wrapper-scope");
  const rollout = writeRollout(root, ownCompletedRecords());
  const wrapperPath = path.join(path.dirname(waitPath), "handoff_to_codex.sh");
  const source = fs.readFileSync(wrapperPath, "utf8").replace(/\r$/gm, "");
  const extract = (start, end) => source.slice(source.indexOf(start), source.indexOf(end));
  const functions = [
    extract("    classify_inspected_target() {", "    # Safe manual preparation"),
    extract("    print_wait_hint() {", "    # One read-only target snapshot"),
    extract("    observe_rollout() {", "    print_confirmation_disclaimer() {"),
  ].join("\n");
  const quote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
  for (const sessionsRoot of [root, ...(process.platform === "win32" ? [path.toNamespacedPath(root)] : [])]) {
    const pagePath = process.platform === "win32" ? path.toNamespacedPath(rollout) : rollout;
    const inspected = {
      ok: true,
      dbThread: { exists: true, readOnlyOpenOk: true, thread: {
        exists: true, id: thread, archived: 0, model: "synthetic", rolloutPath: pagePath,
      } },
      targetClassification: { kind: "root", parentThreadId: null, reasons: [], warnings: [] },
      rollout: { sessionsRoot, primary: { parsedOk: true },
        selection: { status: "found", authority: "db.rollout_path", path: pagePath } },
    };
    const script = `${functions}
INSPECT_OUTPUT=${quote(JSON.stringify(inspected))}
IPC_CID=${quote(thread)}
INSPECT_FIELDS=$(classify_inspected_target)
IFS=$'\\t' read -r INSPECT_CLASS INSPECT_PARENT INSPECT_WARNING INSPECT_ROLLOUT_PATH INSPECT_SESSIONS_ROOT <<< "$INSPECT_FIELDS"
SCRIPT_DIR=${quote(path.dirname(waitPath))}
DISPATCH_ID=${quote(dispatch)}
INBOUND=${quote(path.join(root, "absent.reply.md"))}
WAIT_LINE=$(print_wait_hint)
printf '%s\\n' "$WAIT_LINE"
node() { command node -e 'console.log(JSON.stringify(process.argv.slice(1)))' -- "$@"; }
eval "\${WAIT_LINE#WAIT: }"
node() { command node -e 'console.error("OBS_ARGS " + JSON.stringify(process.argv.slice(1)))' -- "$@"; printf 'rollout-pending\\n'; }
observe_rollout
`;
    const scriptPath = path.join(root, "wrapper-check.sh");
    fs.writeFileSync(scriptPath, script);
    const result = spawnSync(process.platform === "win32" ? "C:/Program Files/Git/bin/bash.exe" : "bash",
      ["--noprofile", "--norc", scriptPath], { encoding: "utf8", cwd: root, env: process.env });
    assert.equal(result.status, 0, result.stderr);
    const lines = result.stdout.trimEnd().split("\n");
    assert.match(lines[0], /^WAIT: node /);
    assert.equal(lines[2], "rollout-pending");
    const waitArgs = JSON.parse(lines[1]);
    const observerArgs = JSON.parse(result.stderr.split("\n").find((line) => line.startsWith("OBS_ARGS ")).slice(9));
    for (const args of [waitArgs, observerArgs]) {
      assert.ok(args.includes("--rollout-path") && args.includes("--sessions-root"),
        JSON.stringify({ inspected, stdout: result.stdout, stderr: result.stderr }));
      assert.equal(args[args.indexOf("--thread") + 1], thread);
      assert.equal(args[args.indexOf("--dispatch") + 1], dispatch);
      assert.equal(path.resolve(args[args.indexOf("--rollout-path") + 1]), path.resolve(rollout));
      assert.equal(path.resolve(args[args.indexOf("--sessions-root") + 1]), path.resolve(root));
    }
  }
});

await test("sessions-root locator is used when no rollout path is explicit", () => {
  const root = caseDir("sessions-root");
  const sessions = path.join(root, "sessions");
  writeRollout(
    path.join(sessions, "nested"),
    [...ownOpenRecords(), event("task_complete", ownTurn)],
  );
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--sessions-root", sessions, "--reply-path", reply,
  ]);
  assertToken(result, "done");
});

await test("budget zero is single-shot while bounded polling uses injected time", async () => {
  const root = caseDir("fake-time");
  const rollout = writeRollout(root, ownOpenRecords());
  const reply = path.join(root, `${dispatch}.reply.md`);
  let sleepCalls = 0;
  const single = await waitForCompletion(
    directOptions(root, rollout, reply),
    { now: () => 0, sleep: async () => { sleepCalls += 1; } },
  );
  assert.equal(single.token, "pending");
  assert.equal(sleepCalls, 0);

  let clock = 0;
  const bounded = await waitForCompletion(
    directOptions(root, rollout, reply, { budgetMs: 100, intervalMs: 10 }),
    {
      now: () => clock,
      sleep: async (ms) => {
        sleepCalls += 1;
        clock += ms;
        if (sleepCalls === 1) {
          fs.appendFileSync(rollout, `${JSON.stringify(event("task_complete", ownTurn))}\n`);
          writeReply(reply);
        }
      },
    },
  );
  assert.equal(bounded.token, "done");
  assert.equal(sleepCalls, 1);
  assert.equal(clock, 10);
});

await test("bounded polling can discover a rollout candidate created after the first scan", async () => {
  const root = caseDir("late-rollout");
  const sessions = path.join(root, "sessions");
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  let clock = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, null, reply, { sessionsRoot: sessions, budgetMs: 100, intervalMs: 10 }),
    {
      now: () => clock,
      sleep: async (ms) => {
        sleepCalls += 1;
        clock += ms;
        if (sleepCalls === 1) {
          writeRollout(
            path.join(sessions, "nested"),
            [...ownOpenRecords(), event("task_complete", ownTurn)],
          );
        }
      },
    },
  );
  assert.equal(result.token, "done");
  assert.equal(sleepCalls, 1);
});

await test("bounded expiry returns pending without wall-clock sleep", async () => {
  const root = caseDir("fake-expiry");
  const rollout = writeRollout(root, ownOpenRecords());
  let clock = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), { budgetMs: 25, intervalMs: 10 }),
    {
      now: () => clock,
      sleep: async (ms) => { sleepCalls += 1; clock += ms; },
    },
  );
  assert.equal(result.token, "pending");
  assert.equal(clock, 25);
  assert.equal(sleepCalls, 3);
});

await test("later page-authority expiry cannot reuse an earlier pending result", async () => {
  for (const grows of [false, true]) {
    const root = caseDir(`later-page-deadline-${grows}`);
    const rollout = writeRollout(root, ownOpenRecords());
    let clock = 0;
    let assessments = 0;
    let sleeps = 0;
    const result = await waitForCompletion(
      directOptions(root, rollout, path.join(root, "missing.md"), {
        acceptRolloutFallback: true, budgetMs: 30, intervalMs: 10,
      }),
      {
        now: () => clock,
        sleep: async (ms) => {
          clock += ms;
          sleeps += 1;
          if (grows) {
            fs.appendFileSync(rollout,
              `${ownCompletedRecords().slice(3).map((item) => JSON.stringify(item)).join("\n")}\n`);
          }
        },
        assessRolloutPageSupersession: (options) => {
          assessments += 1;
          // Cover both the no-growth and post-read required assessments.
          if (assessments === 2) clock = options.deadlineAt;
          const assessment = assessRolloutPageSupersession(options);
          if (assessments === 1) assert.equal(assessment.status, "current");
          return assessment;
        },
      },
    );
    assert.equal(result.token, "unavailable");
    assert.equal(result.replySource, undefined);
    assert.equal(assessments, 2);
    assert.equal(sleeps, 1);
    assert.deepEqual(result.diagnostics, [
      { code: "page-supersession-unproven", reason: "deadline-exceeded" },
    ]);
  }
});

await test("first page-authority expiry cannot certify a primary or rollout fallback", async () => {
  for (const primary of [true, false]) {
    const root = caseDir(`first-page-deadline-${primary}`);
    const rollout = writeRollout(root, ownCompletedRecords());
    const reply = path.join(root, `${dispatch}.reply.md`);
    if (primary) writeReply(reply);
    let clock = 0;
    let assessments = 0;
    const result = await waitForCompletion(
      directOptions(root, rollout, reply, {
        acceptRolloutFallback: true, budgetMs: 20, intervalMs: 10,
      }),
      {
        now: () => clock,
        sleep: async () => { throw new Error("an authority refusal must not sleep"); },
        assessRolloutPageSupersession: (options) => {
          assessments += 1;
          clock = options.deadlineAt;
          return assessRolloutPageSupersession(options);
        },
      },
    );
    assert.equal(result.token, "unavailable");
    assert.equal(result.replySource, undefined);
    assert.equal(assessments, 1);
    assert.deepEqual(result.diagnostics, [
      { code: "page-supersession-unproven", reason: "deadline-exceeded" },
    ]);
  }
});

await test("budget-edge pending preserves its evaluation without reassessment", async () => {
  for (const budgetMs of [20, 0]) {
    const root = caseDir(`evaluated-pending-${budgetMs}`);
    const rollout = writeRollout(root, [
      sessionMeta(),
      event("future_lifecycle_event", undefined),
      ...ownOpenRecords().slice(1),
    ]);
    const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
    let clock = 0;
    let assessments = 0;
    const result = await waitForCompletion(
      directOptions(root, rollout, reply, { budgetMs, intervalMs: 10 }),
      {
        now: () => clock,
        sleep: async () => { throw new Error("the evaluated pending result must not sleep"); },
        assessRolloutPageSupersession: (options) => {
          assessments += 1;
          const assessment = assessRolloutPageSupersession(options);
          if (assessments === 1) {
            assert.equal(assessment.status, "current");
            // The required assessment finished; a repeated tail assessment starts too late.
            if (budgetMs > 0) clock = options.deadlineAt;
          }
          return assessment;
        },
      },
    );
    assert.equal(result.token, "pending");
    assert.equal(result.replySource, undefined);
    assert.equal(assessments, 1);
    // The cumulative pre-turn parser diagnostic remains once; pending resolution adds none.
    assert.equal(result.diagnostics.filter((item) => item.code === "schema-drift").length, 1);
    assert.ok(!result.diagnostics.some((item) => item.code === "page-supersession-unproven"));
  }
});

await test("wait skips unchanged full reads and revalidates at the budget edge", async () => {
  const root = caseDir("no-growth-fast-path");
  const rollout = writeRollout(root, ownOpenRecords());
  let clock = 0;
  let fullReads = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), {
      budgetMs: 25,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
        sleepCalls += 1;
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(result.token, "pending");
  assert.equal(sleepCalls, 3);
  assert.equal(fullReads, 2, "initial and budget-edge certification reads only");
});

await test("a successor appearing during no-growth wait vetoes the bound page", async () => {
  const root = caseDir("successor-during-no-growth");
  const records = ownOpenRecords();
  const rollout = writeRollout(path.join(root, "predecessor"), records);
  const cutoff = fs.statSync(rollout).size;
  let clock = 0;
  let sleepCalls = 0;
  let fullReads = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), {
      sessionsRoot: root,
      budgetMs: 25,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
        sleepCalls += 1;
        if (sleepCalls === 1) {
          writeSuccessor(root, records, cutoff, "33333333-3333-4333-8333-333333333333");
        }
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(result.token, "unavailable");
  assert.equal(sleepCalls, 1);
  assert.equal(fullReads, 1);
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-page-superseded"));
});

await test("a successor appearing at the forced final read vetoes rollout fallback", async () => {
  const root = caseDir("successor-at-final-read");
  const records = ownOpenRecords();
  const completion = [
    event("agent_message", ownTurn, {
      phase: "final_answer",
      message: "must not escape stale page",
    }),
    event("task_complete", ownTurn, { last_agent_message: "must not escape stale page" }),
  ];
  const rollout = writeRollout(path.join(root, "predecessor"), records);
  let clock = 0;
  let fullReads = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), {
      sessionsRoot: root,
      acceptRolloutFallback: true,
      budgetMs: 25,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async (ms) => { clock += ms; },
      readRolloutFile: (...args) => {
        fullReads += 1;
        if (fullReads === 2) {
          fs.appendFileSync(
            rollout,
            `${completion.map((item) => JSON.stringify(item)).join("\n")}\n`,
          );
          writeSuccessor(
            root,
            [...records, ...completion],
            fs.statSync(rollout).size,
            "33333333-3333-4333-8333-333333333333",
          );
        }
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(result.token, "unavailable");
  assert.equal(result.replySource, undefined);
  assert.equal(fullReads, 2);
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-page-superseded"));
});

await test("sleep overshoot cannot combine stale rollout certification with a newly appeared reply", async () => {
  const root = caseDir("sleep-overshoot-stale-certification");
  const rollout = writeRollout(root, ownOpenRecords());
  const reply = path.join(root, `${dispatch}.reply.md`);
  let clock = 0;
  let fullReads = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, reply, {
      acceptRolloutFallback: true,
      budgetMs: 20,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async () => {
        writeReply(reply);
        clock = 100;
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        if (fullReads > 1) {
          return { ok: false, reason: "same-size-rewrite-invalid", diagnostics: [] };
        }
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(fs.existsSync(reply), true);
  assert.equal(clock, 100);
  assert.equal(fullReads, 1);
  assert.equal(result.token, "pending");
});

await test("wait growth re-enters full validation and can certify completion", async () => {
  const root = caseDir("growth-fast-path");
  const rollout = writeRollout(root, ownOpenRecords());
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  let clock = 0;
  let fullReads = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, reply, { budgetMs: 30, intervalMs: 10 }),
    {
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
        sleepCalls += 1;
        if (sleepCalls === 1) {
          fs.appendFileSync(rollout, `${JSON.stringify(event("task_complete", ownTurn))}\n`);
        }
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(result.token, "done");
  assert.equal(result.replySource, "reply-file");
  assert.equal(fullReads, 2, "growth must trigger a full delta read");
});

await test("wait fails closed when an unchanged path is physically replaced", async () => {
  const root = caseDir("replacement-fast-path");
  const records = ownOpenRecords();
  const rollout = writeRollout(root, records);
  let clock = 0;
  let fullReads = 0;
  let replaced = false;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), {
      budgetMs: 30,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
        if (!replaced) {
          fs.renameSync(rollout, `${rollout}.old`);
          fs.writeFileSync(
            rollout,
            `${records.map((item) => JSON.stringify(item)).join("\n")}\n`,
          );
          replaced = true;
        }
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(replaced, true);
  assert.equal(result.token, "unavailable");
  assert.equal(fullReads, 2);
});

await test("page authority detects same-size tampering before forced edge revalidation", async () => {
  const root = caseDir("same-size-fast-path");
  const records = ownOpenRecords();
  const rollout = writeRollout(root, records);
  const otherThread = "33333333-3333-4333-8333-333333333333";
  const tampered = [sessionMeta(otherThread), ...records.slice(1)];
  const originalText = `${records.map((item) => JSON.stringify(item)).join("\n")}\n`;
  const tamperedText = `${tampered.map((item) => JSON.stringify(item)).join("\n")}\n`;
  assert.equal(Buffer.byteLength(tamperedText), Buffer.byteLength(originalText));
  let clock = 0;
  let fullReads = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), {
      budgetMs: 25,
      intervalMs: 10,
    }),
    {
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
        sleepCalls += 1;
        if (sleepCalls === 1) fs.writeFileSync(rollout, tamperedText);
      },
      readRolloutFile: (...args) => {
        fullReads += 1;
        return readRolloutFile(...args);
      },
    },
  );
  assert.equal(result.token, "unavailable");
  assert.equal(sleepCalls, 1, "the unchanged-page veto must inspect authority on the next poll");
  assert.equal(fullReads, 1, "page revalidation must fail closed without rereading a replaced owner");
});

await test("a distinct operator message inside a turn-id'd own turn blocks completion", async () => {
  // A turn id binds lifecycle boundaries, not task ownership. A distinct later user instruction
  // can change the task whose final body is being certified, so the named dispatch fails closed.
  const root = caseDir("intervening-user-with-turn-id");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("user_message", ownTurn, { message: "operator note typed mid-turn" }),
    event("task_complete", ownTurn),
  ]);
  const reply = path.join(root, "reply.md");
  fs.writeFileSync(reply, "body");
  const result = await waitForCompletion(directOptions(root, rollout, reply), { now: () => 0 });
  assert.equal(result.token, "unavailable");
});

await test("an intervening user message without turn ids remains ambiguous", async () => {
  // The fallback rule still applies where turn_id is genuinely absent.
  const root = caseDir("intervening-user-no-turn-id");
  const rollout = writeRollout(root, [
    sessionMeta(),
    event("task_started", undefined),
    event("user_message", undefined, { message: `read C:/handoff/${taskName} and proceed` }),
    event("user_message", undefined, { message: "operator note typed mid-turn" }),
    event("task_complete", undefined),
  ]);
  const reply = path.join(root, "reply.md");
  fs.writeFileSync(reply, "body");
  const result = await waitForCompletion(directOptions(root, rollout, reply), { now: () => 0 });
  assert.equal(result.token, "unavailable");
});

await test("first read exhausting the budget yields pending, not unavailable", async () => {
  // Regression: a read that only ran out of budget is not an authority failure. The candidate
  // exists and parses; we simply never finished observing it. The clock is already past the
  // deadline when the first read runs.
  const root = caseDir("deadline-first-read");
  const rollout = writeRollout(root, ownOpenRecords());
  let calls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), { budgetMs: 5, intervalMs: 1 }),
    {
      // Stay inside the budget while the candidate is located, then jump past the deadline so
      // the read itself is the only thing that fails.
      now: () => {
        calls += 1;
        return calls <= 2 ? 0 : 1000;
      },
      sleep: async () => {},
    },
  );
  assert.equal(result.token, "pending");
});

await test("a deadline-truncated prefix cannot certify completion before EOF", async () => {
  const root = caseDir("deadline-complete-prefix");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("agent_message", ownTurn, {
      phase: "final_answer",
      message: "must wait for EOF",
    }),
    event("task_complete", ownTurn, { last_agent_message: "must wait for EOF" }),
  ]);
  fs.appendFileSync(rollout, " ".repeat(300000));
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  let ticks = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, reply, { budgetMs: 4, intervalMs: 1 }),
    { now: () => ++ticks, sleep: async () => {} },
  );
  assert.equal(result.token, "pending");
});

await test("a concurrently grown completed prefix cannot certify before stable EOF", async () => {
  const root = caseDir("growth-complete-prefix");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("agent_message", ownTurn, {
      phase: "final_answer",
      message: "must wait for stable EOF",
    }),
    event("task_complete", ownTurn, { last_agent_message: "must wait for stable EOF" }),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(rollout, `${JSON.stringify(event("token_count", undefined, { info: { total: 1 } }))}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  try {
    result = await waitForCompletion(directOptions(root, rollout, reply), { now: () => 0 });
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.token, "pending");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("a concurrently grown completion certifies after a later stable EOF", async () => {
  const root = caseDir("growth-complete-retry");
  const rollout = writeRollout(root, [
    ...ownOpenRecords(),
    event("agent_message", ownTurn, {
      phase: "final_answer",
      message: "stable EOF body",
    }),
    event("task_complete", ownTurn, { last_agent_message: "stable EOF body" }),
  ]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const originalFstat = fs.fstatSync;
  let fstatCalls = 0;
  fs.fstatSync = function injectedFstat(descriptor, ...args) {
    fstatCalls += 1;
    if (fstatCalls === 3) {
      fs.appendFileSync(rollout, `${JSON.stringify(event("token_count", undefined, { info: { total: 1 } }))}\n`);
    }
    return originalFstat.call(fs, descriptor, ...args);
  };
  let result;
  let clock = 0;
  try {
    result = await waitForCompletion(
      directOptions(root, rollout, reply, { budgetMs: 2, intervalMs: 1 }),
      { now: () => clock, sleep: async (ms) => { clock += ms; } },
    );
  } finally {
    fs.fstatSync = originalFstat;
  }
  assert.equal(result.token, "done");
  assert.equal(result.replySource, "reply-file");
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-read-not-at-eof"));
});

await test("readable candidate plus later budget expiry yields pending, not unavailable", async () => {
  // The candidate was read successfully at least once, then the budget expired mid-poll.
  const root = caseDir("deadline-partial-read");
  const rollout = writeRollout(root, ownOpenRecords());
  let clock = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), { budgetMs: 20, intervalMs: 5 }),
    {
      now: () => clock,
      sleep: async (ms) => { clock += ms; },
    },
  );
  assert.equal(result.token, "pending");
});

await test("direct wait API normalizes a zero interval instead of polling unboundedly", async () => {
  const root = caseDir("direct-zero-interval");
  const rollout = writeRollout(root, ownOpenRecords());
  let clock = 0;
  let sleepCalls = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, path.join(root, "missing.md"), { budgetMs: 10, intervalMs: 0 }),
    {
      now: () => clock,
      sleep: async (ms) => {
        sleepCalls += 1;
        if (sleepCalls > 2) throw new Error("unbounded zero-interval polling");
        clock += ms;
      },
    },
  );
  assert.equal(result.token, "pending");
  assert.equal(sleepCalls, 1);
  assert.equal(clock, 10);
});

await test("zero and malformed interval knobs warn and use the documented default", () => {
  const root = caseDir("interval-warning");
  const rollout = writeRollout(root, ownOpenRecords());
  const common = [
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", path.join(root, "missing.md"),
  ];
  const zero = cli([...common, "--interval-ms", "0"]);
  assertToken(zero, "pending");
  assert.match(zero.stderr, /wait interval must be a positive integer; using default 250/);

  const malformed = cli(common, { CODEX_IPC_WAIT_INTERVAL_MS: `bad\u0085value` });
  assertToken(malformed, "pending");
  assert.match(malformed.stderr, /wait interval must be a positive integer; using default 250/);
  assert.doesNotMatch(malformed.stderr, /\u0085/u);

  const malformedFlag = cli([...common, "--interval-ms", "bad"]);
  assertToken(malformedFlag, "pending");
  assert.match(malformedFlag.stderr, /wait interval must be a positive integer; using default 250/);
});

await test("flags override environment knobs", () => {
  const root = caseDir("flag-precedence");
  const rollout = writeRollout(root, ownOpenRecords());
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", path.join(root, "missing.md"),
    "--budget-ms", "0", "--interval-ms", "5",
  ], {
    CODEX_IPC_WAIT_BUDGET_MS: "malformed",
    CODEX_IPC_WAIT_INTERVAL_MS: "malformed",
  });
  assertToken(result, "pending");
  assert.doesNotMatch(result.stderr, /using default/);
});

await test("malformed budget and unknown options are usage errors only", () => {
  const badBudget = cli([
    "--thread", thread, "--dispatch", dispatch, "--budget-ms", "bad",
  ]);
  assert.notEqual(badBudget.status, 0);
  assert.equal(badBudget.stdout, "");
  assert.match(badBudget.stderr, /budget/);
  assert.match(badBudget.stderr, /Usage:/);

  const badBudgetEnv = cli([
    "--thread", thread, "--dispatch", dispatch,
  ], { CODEX_IPC_WAIT_BUDGET_MS: "bad" });
  assert.notEqual(badBudgetEnv.status, 0);
  assert.equal(badBudgetEnv.stdout, "");
  assert.match(badBudgetEnv.stderr, /wait budget/);

  const unknown = cli(["--thread", thread, "--dispatch", dispatch, "--unknown"]);
  assert.notEqual(unknown.status, 0);
  assert.equal(unknown.stdout, "");
  assert.match(unknown.stderr, /Usage:/);

  const missingThread = cli(["--dispatch", dispatch]);
  assert.notEqual(missingThread.status, 0);
  assert.equal(missingThread.stdout, "");
  assert.match(missingThread.stderr, /--thread must be a UUID/);

  const missingDispatch = cli(["--thread", thread]);
  assert.notEqual(missingDispatch.status, 0);
  assert.equal(missingDispatch.stdout, "");
  assert.match(missingDispatch.stderr, /--dispatch must be a dispatch id/);
});

await test("runtime diagnostics escape C0 C1 and ESC bytes and remain parseable JSON", () => {
  const root = caseDir("diagnostic-hygiene");
  const envelopeType = `future\u0000\u001b\u007f\u0085envelope`;
  const payloadType = `future\u001f\u009bpayload`;
  const records = [
    sessionMeta(),
    { type: envelopeType, payload: { type: payloadType } },
    ...ownOpenRecords().slice(1),
    event("task_complete", ownTurn),
  ];
  const rollout = writeRollout(root, records);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", reply,
  ]);
  assertToken(result, "done");
  assert.doesNotMatch(result.stderr, /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u);
  assert.match(result.stderr, /\\u0000/);
  assert.match(result.stderr, /\\u001b/);
  assert.match(result.stderr, /\\u001f/);
  assert.match(result.stderr, /\\u007f/);
  assert.match(result.stderr, /\\u0085/);
  assert.match(result.stderr, /\\u009b/);
  const prefix = "WAIT_DIAGNOSTIC ";
  const line = result.stderr.split("\n").find((item) => item.startsWith(prefix));
  assert.ok(line);
  const diagnostic = JSON.parse(line.slice(prefix.length));
  assert.equal(diagnostic.envelopeType, envelopeType);
  assert.equal(diagnostic.payloadType, payloadType);
});

await test("single-shot CLI exits cleanly without a lingering process", () => {
  const root = caseDir("process-hygiene");
  const rollout = writeRollout(root, ownOpenRecords());
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--rollout-path", rollout, "--reply-path", path.join(root, "missing.md"),
  ]);
  // The default 15000 spawn timeout is the lingering-process discriminator: a hung child is
  // killed there and fails result.error; a loaded correct run (2-3s cold-start) passes freely.
  assertToken(result, "pending");
  assert.equal(result.error, undefined);
});

await test("positive-budget CLI exits within its bound without a lingering process", () => {
  const root = caseDir("bounded-process-hygiene");
  const started = Date.now();
  const result = cli([
    "--thread", thread, "--dispatch", dispatch,
    "--sessions-root", path.join(root, "missing-sessions"),
    "--transport-root", path.join(root, "transport"),
    "--budget-ms", "25", "--interval-ms", "10",
  ]);
  const elapsed = Date.now() - started;
  assertToken(result, "unavailable");
  assert.equal(result.error, undefined);
  assert.match(
    result.stderr,
    /ROLLOUT-PATH: Supply the inspector's database-designated page with --rollout-path <path>\./,
  );
  // correct = cold-start (2-3s loaded) + 25ms budget (~3.5s worst); wrong = lingering until the
  // 15000 spawn kill-switch. 9000 is >=2x the loaded correct path and 40% below the kill floor.
  assert.ok(elapsed < 9000, `bounded process took ${elapsed} ms`);
});

function assertTokenExit(result, token, code) {
  assert.equal(result.signal, null);
  assert.equal(result.stdout, `${token}\n`, `stdout token for ${token}: got ${JSON.stringify(result.stdout)}`);
  assert.equal(result.status, code, `exit code for ${token}: ${result.stderr}`);
}

await test("A6: --status-exit-codes maps every determination; flagless stays all-exit-0", () => {
  const root = caseDir("a6-matrix");
  const base = (rollout, reply, extra = []) => [
    "--thread", thread, "--dispatch", dispatch, "--rollout-path", rollout, "--reply-path", reply, ...extra,
  ];

  // done = 0 in both modes
  const doneRollout = writeRollout(path.join(root, "done"), [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const doneReply = writeReply(path.join(root, "done", `${dispatch}.reply.md`));
  assertTokenExit(cli(base(doneRollout, doneReply)), "done", 0);
  assertTokenExit(cli(base(doneRollout, doneReply, ["--status-exit-codes"])), "done", 0);

  // reply-missing: flagless 0, flag 5
  const missReply = path.join(root, "done", "missing.md");
  assertTokenExit(cli(base(doneRollout, missReply)), "reply-missing", 0);
  assertTokenExit(cli(base(doneRollout, missReply, ["--status-exit-codes"])), "reply-missing", 5);

  // pending: flagless 0, flag 2
  const pendRollout = writeRollout(path.join(root, "pending"), ownOpenRecords());
  const pendReply = path.join(root, "pending", "missing.md");
  assertTokenExit(cli(base(pendRollout, pendReply)), "pending", 0);
  assertTokenExit(cli(base(pendRollout, pendReply, ["--status-exit-codes"])), "pending", 2);

  // aborted: flagless 0, flag 3
  const abRollout = writeRollout(path.join(root, "aborted"), [...ownOpenRecords(), event("turn_aborted", ownTurn)]);
  const abReply = writeReply(path.join(root, "aborted", `${dispatch}.reply.md`));
  assertTokenExit(cli(base(abRollout, abReply)), "aborted", 0);
  assertTokenExit(cli(base(abRollout, abReply, ["--status-exit-codes"])), "aborted", 3);

  // superseded: flagless 0, flag 4
  const supRollout = writeRollout(path.join(root, "superseded"), [
    ...ownOpenRecords(),
    event("task_started", otherTurn),
    event("user_message", otherTurn, { message: "unrelated" }),
    event("task_complete", otherTurn),
  ]);
  const supReply = writeReply(path.join(root, "superseded", `${dispatch}.reply.md`));
  assertTokenExit(cli(base(supRollout, supReply)), "superseded", 0);
  assertTokenExit(cli(base(supRollout, supReply, ["--status-exit-codes"])), "superseded", 4);

  // unavailable: flagless 0, flag 6 (no authoritative rollout candidate)
  const unavArgs = [
    "--thread", thread, "--dispatch", dispatch,
    "--sessions-root", path.join(root, "no-sessions"), "--transport-root", path.join(root, "transport"),
  ];
  assertTokenExit(cli(unavArgs), "unavailable", 0);
  assertTokenExit(cli([...unavArgs, "--status-exit-codes"]), "unavailable", 6);

  // usage error: exit 1, no determination token, in BOTH modes
  const badFlagless = cli(["--thread", thread]);
  assert.equal(badFlagless.stdout, "");
  assert.equal(badFlagless.status, 1);
  const badFlag = cli(["--thread", thread, "--status-exit-codes"]);
  assert.equal(badFlag.stdout, "");
  assert.equal(badFlag.status, 1);
});

await test("single-shot wait uses one locator read, one full read, and one page-authority read", async () => {
  // The supersession veto adds one first-record authority revalidation after the existing locator
  // and full-file reads. It must not re-locate, repeat the full read, or reopen the bound page as a
  // discovery candidate.
  const root = caseDir("read-count-spy");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const rolloutResolved = path.resolve(rollout);
  const originalOpen = fs.openSync;
  let rolloutOpens = 0;
  fs.openSync = (target, ...args) => {
    try {
      if (typeof target === "string" && path.resolve(target) === rolloutResolved) rolloutOpens += 1;
    } catch {}
    return originalOpen(target, ...args);
  };
  let result;
  try {
    result = await waitForCompletion(directOptions(root, rollout, reply));
  } finally {
    fs.openSync = originalOpen;
  }
  assert.equal(result.token, "done");
  assert.equal(rolloutOpens, 3);
});

await test("post-locator wait read remains bound to the requested rollout owner", async () => {
  const ownerB = "33333333-3333-4333-8333-333333333333";
  const root = caseDir("post-locator-owner-swap");
  const rollout = writeRollout(root, [sessionMeta()]);
  const rolloutResolved = path.resolve(rollout);
  const replacement = [
    sessionMeta(ownerB),
    event("task_started", ownTurn),
    event("user_message", ownTurn, { message: `read C:/handoff/${taskName} and proceed` }),
    event("agent_message", ownTurn, { phase: "final_answer", message: "OWNER-B-MUST-NOT-COUNT" }),
    event("task_complete", ownTurn, { last_agent_message: "OWNER-B-MUST-NOT-COUNT" }),
  ];
  const originalOpen = fs.openSync;
  const originalClose = fs.closeSync;
  const locatorDescriptors = new Set();
  let armed = true;
  let injected = false;
  fs.openSync = (target, ...args) => {
    const descriptor = originalOpen(target, ...args);
    if (armed && typeof target === "string" && path.resolve(target) === rolloutResolved) {
      locatorDescriptors.add(descriptor);
    }
    return descriptor;
  };
  fs.closeSync = (descriptor, ...args) => {
    const isLocatorDescriptor = armed && locatorDescriptors.has(descriptor);
    const result = originalClose(descriptor, ...args);
    if (isLocatorDescriptor) {
      armed = false;
      fs.writeFileSync(
        rollout,
        `${replacement.map((item) => JSON.stringify(item)).join("\n")}\n`,
      );
      injected = true;
    }
    return result;
  };
  let result;
  try {
    result = await waitForCompletion(
      directOptions(root, rollout, path.join(root, "missing.reply.md")),
    );
  } finally {
    fs.openSync = originalOpen;
    fs.closeSync = originalClose;
  }
  assert.equal(injected, true);
  assert.equal(result.token, "unavailable");
  const waitSource = fs.readFileSync(waitPath, "utf8");
  assert.match(
    waitSource,
    /const readRollout = injected\.readRolloutFile \|\| readRolloutFile/,
  );
  assert.match(
    waitSource,
    /readRollout\(candidatePath,\s*\{[\s\S]*?rolloutThreadId:\s*options\.threadId/,
  );
});

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
