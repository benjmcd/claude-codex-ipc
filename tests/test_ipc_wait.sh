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

// --- Settings-only response items and archived (zstd) rollout pages ---
const zlibApi = (await import("node:zlib")).default;
const crypto = await import("node:crypto");
const zstdAvailable = typeof zlibApi.zstdCompressSync === "function";

function ownCompletedWithInTurn(extraRecords, body = "settings turn body") {
  const records = ownOpenRecords();
  return [
    ...records,
    ...extraRecords,
    event("agent_message", ownTurn, { phase: "final_answer", message: body }),
    event("task_complete", ownTurn, { last_agent_message: body }),
  ];
}

const configurationUpdate = {
  type: "response_item",
  payload: { type: "configuration_update", reasoning: { effort: "high" } },
};
const additionalTools = {
  type: "response_item",
  payload: {
    type: "additional_tools",
    id: "fixture-tools",
    role: "developer",
    tools: [{ type: "namespace", name: "fixture", description: "fixture tools", tools: [{ type: "function", name: "noop" }] }],
  },
};

await test("settings-only response items inside the dispatch turn keep rollout fallback certifiable", async () => {
  const root = caseDir("settings-items-in-turn");
  const rollout = writeRollout(root, ownCompletedWithInTurn([configurationUpdate, additionalTools]));
  const parsed = readRolloutFile(rollout);
  assert.equal(parsed.diagnostics.some((item) => item.code === "schema-drift"), false);
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

for (const [label, record] of [
  ["steer-input context", {
    type: "retained_context",
    payload: { type: "native_steer_ownership", version: 1, record: { phase: "steer", items: [{ type: "message" }] } },
  }],
  ["configuration update carrying a body key", {
    type: "response_item",
    payload: { type: "configuration_update", reasoning: { effort: "high" }, content: [{ text: "body" }] },
  }],
  ["tool manifest with a non-developer role", {
    type: "response_item",
    payload: { ...additionalTools.payload, role: "user" },
  }],
  ["tool manifest carrying a message", {
    type: "response_item",
    payload: { ...additionalTools.payload, message: "body" },
  }],
  ["configuration update carrying an unobserved key", {
    type: "response_item",
    payload: { ...configurationUpdate.payload, output: "unobserved" },
  }],
  ["tool manifest carrying an unobserved key", {
    type: "response_item",
    payload: { ...additionalTools.payload, item: { type: "message" } },
  }],
]) {
  await test(`${label} inside the dispatch turn stays schema drift and is not certified`, async () => {
    const root = caseDir(`settings-drift-${label.replace(/[^a-z]+/giu, "-")}`);
    const rollout = writeRollout(root, ownCompletedWithInTurn([record]));
    const parsed = readRolloutFile(rollout);
    assert.ok(parsed.diagnostics.some((item) => item.code === "schema-drift"));
    const result = await waitForCompletion(directOptions(
      root,
      rollout,
      path.join(root, "missing.reply.md"),
      { acceptRolloutFallback: true },
    ));
    assert.notEqual(result.token, "done");
  });
}

function pagedRecords(pageId, base = thread) {
  return [
    {
      type: "session_meta",
      payload: {
        id: thread,
        session_id: thread,
        history_mode: "paginated",
        history_base: { thread_id: base, end_byte_offset: 0 },
      },
    },
    ...ownCompletedRecords().slice(1),
  ];
}

function writePagedRollout(directory, pageId, records) {
  fs.mkdirSync(directory, { recursive: true });
  const target = path.join(directory, `rollout-page-${thread}_${pageId}.jsonl`);
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  return target;
}

function writeArchive(target, text) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(
    target,
    zstdAvailable ? zlibApi.zstdCompressSync(Buffer.from(text)) : Buffer.from("not zstd"),
  );
  return target;
}

// Page ids reuse the public-safety scanner's synthetic allowlist.
const currentPageId = "33333333-3333-4333-8333-333333333333";
const archivedPageId = "00000000-0000-4000-8000-000000000000";

await test("an archived legacy root page beside the current page does not unresolve the page set", async () => {
  const root = caseDir("archived-legacy-root");
  const rollout = writePagedRollout(path.join(root, "2026", "11", "17"), currentPageId, pagedRecords(currentPageId));
  // A legacy archive is never opened: its bytes need not even be valid zstd.
  fs.mkdirSync(path.join(root, "2026", "10", "20"), { recursive: true });
  fs.writeFileSync(path.join(root, "2026", "10", "20", `rollout-root-${thread}.jsonl.zst`), "legacy archive");
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, sessionsRoot: root },
  ));
  assert.equal(result.token, "done");
  assert.equal(result.replySource, "rollout-fallback");
  assert.equal(result.diagnostics.some((item) => item.code === "candidate-set-unresolved"), false);
  const cliResult = cli([
    "--thread", thread, "--dispatch", dispatch, "--rollout-path", rollout,
    "--sessions-root", root, "--reply-path", path.join(root, "missing.reply.md"),
    "--accept-rollout-fallback", "--status-exit-codes",
  ]);
  assert.equal(cliResult.status, 0, cliResult.stderr);
  assert.equal(cliResult.stdout, "done\n");
  assert.match(cliResult.stderr, /"source":"rollout-fallback"/);
});

await test("an archived paginated page that is not the bound page's successor leaves it current", async () => {
  const root = caseDir("archived-unrelated-page");
  const rollout = writePagedRollout(path.join(root, "2026", "11", "17"), currentPageId, pagedRecords(currentPageId));
  writeArchive(
    path.join(root, "2026", "10", "30", `rollout-page-${thread}_${archivedPageId}.jsonl.zst`),
    `${JSON.stringify(pagedRecords(archivedPageId)[0])}\n${JSON.stringify(event("task_started", otherTurn))}\n`,
  );
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, sessionsRoot: root },
  ));
  if (zstdAvailable) {
    assert.equal(result.token, "done");
    assert.equal(result.replySource, "rollout-fallback");
  } else {
    assert.equal(result.token, "unavailable");
    assert.ok(result.diagnostics.some((item) => item.reason === "archive-unsupported"));
  }
});

await test("an archived paginated successor still vetoes the bound page", async () => {
  const root = caseDir("archived-successor");
  const records = pagedRecords(currentPageId);
  const rollout = writePagedRollout(path.join(root, "2026", "11", "17"), currentPageId, records);
  const cutoff = Buffer.byteLength(`${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  writeArchive(
    path.join(root, "2026", "11", "20", `rollout-page-${thread}_${archivedPageId}.jsonl.zst`),
    `${JSON.stringify({
      type: "session_meta",
      payload: {
        id: thread,
        session_id: thread,
        history_mode: "paginated",
        history_base: { thread_id: currentPageId, end_byte_offset: cutoff },
      },
    })}\n`,
  );
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, sessionsRoot: root },
  ));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) =>
    zstdAvailable ? item.code === "rollout-page-superseded" : item.reason === "archive-unsupported"));
});

await test("an archived successor with a large header and a highly compressible tail still vetoes", async () => {
  const root = caseDir("archived-successor-large-header");
  const records = pagedRecords(currentPageId);
  const rollout = writePagedRollout(path.join(root, "2026", "11", "17"), currentPageId, records);
  const cutoff = Buffer.byteLength(`${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  // A ~400 KB header is not done by the first compressed windows, and the 30 MB repetitive tail
  // overflows the 24 MB record cap as soon as a window reaches it: only the bisection finds the
  // header's newline.
  const header = JSON.stringify({
    type: "session_meta",
    payload: {
      id: thread,
      session_id: thread,
      history_mode: "paginated",
      history_base: { thread_id: currentPageId, end_byte_offset: cutoff },
      base_instructions: { text: crypto.randomBytes(200 * 1024).toString("hex") },
    },
  });
  writeArchive(
    path.join(root, "2026", "11", "20", `rollout-page-${thread}_${archivedPageId}.jsonl.zst`),
    `${header}\n${"x".repeat(30 * 1024 * 1024)}\n`,
  );
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, sessionsRoot: root },
  ));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) =>
    zstdAvailable ? item.code === "rollout-page-superseded" : item.reason === "archive-unsupported"));
});

await test("an unreadable archived paginated page fails the page set closed", async () => {
  const root = caseDir("archived-unreadable");
  const rollout = writePagedRollout(path.join(root, "2026", "11", "17"), currentPageId, pagedRecords(currentPageId));
  fs.mkdirSync(path.join(root, "2026", "10", "30"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "2026", "10", "30", `rollout-page-${thread}_${archivedPageId}.jsonl.zst`),
    "not a zstd frame",
  );
  const result = await waitForCompletion(directOptions(
    root,
    rollout,
    path.join(root, "missing.reply.md"),
    { acceptRolloutFallback: true, sessionsRoot: root },
  ));
  assert.equal(result.token, "unavailable");
  assert.ok(result.diagnostics.some((item) =>
    item.code === "page-supersession-unproven" &&
    item.reason === (zstdAvailable ? "archive-invalid" : "archive-unsupported")));
});

// A live bound page keeps growing while its turn runs. Same-identity growth after a certifying
// read, with that read's end still a record boundary, is a stale snapshot: the waiter keeps
// polling and never certifies on it. A shrink, a rewritten end, a successor page or an identity
// change stays terminal.
function appendRecords(target, records) {
  fs.appendFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
}

function growingReader(afterRead) {
  let reads = 0;
  const reader = (filePath, options) => {
    const result = readRolloutFile(filePath, options);
    afterRead(reads, filePath);
    reads += 1;
    return result;
  };
  reader.reads = () => reads;
  return reader;
}

function steppedClock(extra = {}) {
  let clock = 0;
  return { now: () => clock, sleep: async (ms) => { clock += ms; }, ...extra };
}

function growthOptions(root, rollout, extra = {}) {
  return directOptions(root, rollout, path.join(root, "missing.reply.md"), {
    acceptRolloutFallback: true,
    budgetMs: 100,
    intervalMs: 10,
    ...extra,
  });
}

await test("append-only growth after a certifying read keeps polling and certifies once settled", async () => {
  const root = caseDir("growth-stale-then-done");
  const rollout = writeRollout(root, ownOpenRecords());
  const reader = growingReader((index, target) => {
    if (index === 0) {
      appendRecords(target, [event("agent_message", ownTurn, { phase: "commentary", message: "working" })]);
    } else if (index === 1) {
      appendRecords(target, [
        event("agent_message", ownTurn, { phase: "final_answer", message: "grown body" }),
        event("task_complete", ownTurn, { last_agent_message: "grown body" }),
      ]);
    }
  });
  const result = await waitForCompletion(growthOptions(root, rollout), steppedClock({ readRolloutFile: reader }));
  assert.equal(result.token, "done", JSON.stringify(result));
  assert.equal(result.replySource, "rollout-fallback");
  assert.equal(reader.reads(), 3);
  assert.equal(
    result.diagnostics.filter((item) => item.code === "page-snapshot-stale").length,
    1,
    "a stale snapshot is recorded once",
  );
  assert.ok(result.diagnostics.some((item) =>
    item.code === "page-snapshot-stale" && item.reason === "bound-page-grew"));
  assert.ok(!result.diagnostics.some((item) => item.code === "page-supersession-unproven"));
});

await test("growth on every read stays pending through the budget and never certifies", async () => {
  const root = caseDir("growth-stale-endless");
  const rollout = writeRollout(root, ownCompletedRecords("already complete body"));
  const reader = growingReader((index, target) => {
    appendRecords(target, [event("token_count", undefined, { info: { total: index } })]);
  });
  const result = await waitForCompletion(
    growthOptions(root, rollout, { budgetMs: 50 }),
    steppedClock({ readRolloutFile: reader }),
  );
  assert.equal(result.token, "pending", JSON.stringify(result));
  assert.ok(reader.reads() >= 2);
  assert.ok(result.diagnostics.some((item) => item.code === "page-snapshot-stale"));
});

await test("a page that shrinks after the read stays unavailable", async () => {
  const root = caseDir("growth-shrink");
  const rollout = writeRollout(root, ownOpenRecords());
  const reader = growingReader((index, target) => {
    if (index === 0) {
      const text = fs.readFileSync(target, "utf8");
      fs.writeFileSync(target, text.slice(0, text.length - 8));
    }
  });
  const result = await waitForCompletion(growthOptions(root, rollout), steppedClock({ readRolloutFile: reader }));
  assert.equal(result.token, "unavailable", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) =>
    item.code === "page-supersession-unproven" && item.reason === "bound-page-size-changed"));
});

await test("growth whose old end is no longer a record boundary stays unavailable", async () => {
  const root = caseDir("growth-rewritten-end");
  const rollout = writeRollout(root, ownOpenRecords());
  const reader = growingReader((index, target) => {
    if (index === 0) {
      const text = fs.readFileSync(target, "utf8");
      fs.writeFileSync(target, `${text.slice(0, -1)} ${JSON.stringify(event("token_count", undefined))}\n`);
    }
  });
  const result = await waitForCompletion(growthOptions(root, rollout), steppedClock({ readRolloutFile: reader }));
  assert.equal(result.token, "unavailable", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) =>
    item.code === "page-supersession-unproven" && item.reason === "bound-page-size-changed"));
});

await test("a successor page still vetoes a growing bound page", async () => {
  const root = caseDir("growth-successor");
  const records = ownOpenRecords();
  const rollout = writeRollout(root, records);
  const reader = growingReader((index, target) => {
    if (index === 0) {
      const cutoff = fs.statSync(target).size;
      appendRecords(target, [event("agent_message", ownTurn, { phase: "commentary", message: "working" })]);
      writeSuccessor(root, records, cutoff, currentPageId);
    }
  });
  const result = await waitForCompletion(growthOptions(root, rollout), steppedClock({ readRolloutFile: reader }));
  assert.equal(result.token, "unavailable", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) => item.code === "rollout-page-superseded"));
  assert.ok(!result.diagnostics.some((item) => item.code === "page-snapshot-stale"));
});

await test("a replaced bound page (new identity, larger) stays unavailable", async () => {
  const root = caseDir("growth-identity-swap");
  const rollout = writeRollout(root, ownOpenRecords());
  const reader = growingReader((index, target) => {
    if (index === 0) {
      const text = fs.readFileSync(target, "utf8");
      fs.renameSync(target, `${target}.old`);
      fs.writeFileSync(target, `${text}${JSON.stringify(event("token_count", undefined))}\n`);
    }
  });
  const result = await waitForCompletion(growthOptions(root, rollout), steppedClock({ readRolloutFile: reader }));
  assert.equal(result.token, "unavailable", JSON.stringify(result));
  assert.ok(result.diagnostics.some((item) =>
    item.code === "page-supersession-unproven" && item.reason === "bound-page-identity-changed"));
});

await test("the page assessor separates stale growth from a shrink and from an unchanged page", () => {
  const root = caseDir("growth-assessor");
  const rollout = writeRollout(root, ownOpenRecords());
  const size = fs.statSync(rollout).size;
  const firstLineEnd = Buffer.byteLength(JSON.stringify(sessionMeta())) + 1;
  const assess = (expectedSize) => assessRolloutPageSupersession({
    threadId: thread,
    rolloutPath: rollout,
    sessionsRoot: root,
    expectedSize,
  });
  assert.equal(assess(size).status, "current");
  const stale = assess(firstLineEnd);
  assert.equal(stale.status, "stale");
  assert.deepEqual(
    stale.diagnostics.map((item) => [item.code, item.reason, item.expectedSize, item.size]),
    [["page-snapshot-stale", "bound-page-grew", firstLineEnd, size]],
  );
  assert.equal(assess(firstLineEnd - 1).status, "unproven", "a non-boundary snapshot end");
  assert.equal(assess(size + 1).status, "unproven", "a shrink");
  assert.equal(assess(-1).status, "unproven", "a negative snapshot size");
});

await test("--materialize-reply requires the fallback flag and a resolvable reply path", () => {
  const base = ["--thread", thread, "--dispatch", dispatch, "--materialize-reply"];
  assert.throws(
    () => parseWaitArgs([...base, "--reply-path", path.join(tmp, `${dispatch}.reply.md`)], {}),
    /--materialize-reply requires --accept-rollout-fallback/,
  );
  assert.throws(
    () => parseWaitArgs([...base, "--accept-rollout-fallback"], {}),
    /--materialize-reply requires --reply-path or --session/,
  );
  assert.equal(parseWaitArgs([...base, "--accept-rollout-fallback", "--session", "sid"], {})
    .options.materializeReply, true);
});

await test("the waiter keeps a rollout-only reply only with --materialize-reply; stdout stays the token", () => {
  const root = caseDir("wait-materialize");
  const rollout = writeRollout(root, ownCompletedRecords("materialized body"));
  const channel = path.join(root, "transport", "sid", thread);
  fs.mkdirSync(channel, { recursive: true });
  fs.writeFileSync(path.join(channel, taskName), "task\n");
  const replyPath = path.join(channel, `${dispatch}.reply.md`);
  const copyPath = path.join(channel, `${dispatch}.reply.rollout.md`);
  const args = [
    "--thread", thread, "--dispatch", dispatch, "--reply-path", replyPath,
    "--rollout-path", rollout, "--sessions-root", root, "--accept-rollout-fallback",
  ];
  const plain = cli(args);
  assert.equal(plain.status, 0, plain.stderr);
  assert.equal(plain.stdout, "done\n");
  assert.equal(fs.existsSync(copyPath), false, "the waiter is read-only without the flag");
  const first = cli([...args, "--materialize-reply"]);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.stdout, "done\n");
  assert.match(first.stderr, /"code":"reply-materialized","bytes":17,"sha256":"[0-9a-f]{64}"/);
  assert.equal(fs.readFileSync(copyPath, "utf8"), "materialized body");
  assert.equal(fs.existsSync(replyPath), false, "the primary reply file is never written");
  const second = cli([...args, "--materialize-reply", "--status-exit-codes"]);
  assert.equal(second.status, 0, second.stderr);
  assert.equal(second.stdout, "done\n");
  assert.match(second.stderr, /"code":"reply-materialize-refused","reason":"materialized-present"/);
  assert.equal(fs.readFileSync(copyPath, "utf8"), "materialized body");
});

// --queue-id: the opt-in, read-only queue-store check for a --deliver queue dispatch. Fixtures
// are throwaway SQLite files under this suite's temporary directory; nothing reads ~/.codex.
const queueId = "0f0f0001-0000-4000-8000-000000000001";
const { QUEUE_NOT_STARTED_GRACE_MS } = api;

async function writeQueueStore(target, rows) {
  const { DatabaseSync } = await import("node:sqlite");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.rmSync(target, { force: true });
  const db = new DatabaseSync(target);
  try {
    db.exec(
      "create table queued_items (id text primary key not null, thread_id text not null, " +
        "payload_json text not null, queue_order integer not null, created_at_ms integer not null, " +
        "updated_at_ms integer not null)",
    );
    const insert = db.prepare("insert into queued_items values (?,?,?,?,?,?)");
    rows.forEach((row, index) =>
      insert.run(row.id, row.threadId, "{}", index, row.createdAtMs, row.createdAtMs));
  } finally {
    db.close();
  }
  return target;
}

function queueDiagnostics(stderr) {
  return stderr.split(/\r?\n/u)
    .filter((line) => line.startsWith("WAIT_DIAGNOSTIC "))
    .map((line) => JSON.parse(line.slice("WAIT_DIAGNOSTIC ".length)))
    .filter((item) => /^queue/.test(item.code));
}

await test("--queue-id parses as an opt-in UUID with its store path; --queue-db needs it", () => {
  const base = ["--thread", thread, "--dispatch", dispatch];
  const plain = parseWaitArgs(base, { CODEX_IPC_QUEUE_DB: "/env/queue.sqlite" }).options;
  assert.equal(plain.queueItemId, null, "no queue check without --queue-id");
  assert.equal(plain.queueDbPath, null, "the environment alone does not enable the check");
  const flagged = parseWaitArgs([...base, "--queue-id", queueId.toUpperCase()], {}).options;
  assert.equal(flagged.queueItemId, queueId);
  assert.match(flagged.queueDbPath, /[\\/]\.codex[\\/]queue_1\.sqlite$/);
  assert.equal(parseWaitArgs([...base, "--queue-id", queueId],
    { CODEX_IPC_QUEUE_DB: "/env/queue.sqlite" }).options.queueDbPath, "/env/queue.sqlite");
  assert.equal(parseWaitArgs([...base, "--queue-id", queueId, "--queue-db", "/flag/q.sqlite"],
    { CODEX_IPC_QUEUE_DB: "/env/queue.sqlite" }).options.queueDbPath, "/flag/q.sqlite");
  assert.throws(() => parseWaitArgs([...base, "--queue-id", "not-a-uuid"], {}),
    /--queue-id must be a UUID/);
  assert.throws(() => parseWaitArgs([...base, "--queue-db", "/flag/q.sqlite"], {}),
    /--queue-db requires --queue-id/);
  assert.equal(QUEUE_NOT_STARTED_GRACE_MS, 30000);
});

await test("an ordinary wait never reads the queue store", async () => {
  const root = caseDir("queue-not-enabled");
  const rollout = writeRollout(root, ownOpenRecords());
  let reads = 0;
  const result = await waitForCompletion(directOptions(root, rollout, null), {
    readQueuedItem: async () => { reads += 1; return { status: "present" }; },
  });
  assert.equal(result.token, "pending");
  assert.equal(reads, 0);
  assert.equal(result.diagnostics.some((item) => /^queue/.test(item.code)), false);
});

await test("a stale queued item with no dispatch turn reports queued-not-started once, live, token unchanged", async () => {
  const root = caseDir("queue-not-started");
  const rollout = writeRollout(root, [sessionMeta()]);
  let clock = 1_000_000;
  const live = [];
  let reads = 0;
  const result = await waitForCompletion(
    directOptions(root, rollout, null, {
      budgetMs: 5000, intervalMs: 1000, queueItemId: queueId, queueDbPath: "unused",
    }),
    {
      now: () => clock,
      sleep: async (ms) => { clock += ms; },
      readQueuedItem: async (request) => {
        reads += 1;
        assert.deepEqual(request, { dbPath: "unused", queueId });
        return {
          status: "present", queueId, threadId: thread,
          createdAtMs: clock - QUEUE_NOT_STARTED_GRACE_MS - 1,
        };
      },
      onDiagnostic: (item) => live.push(item),
    },
  );
  assert.equal(result.token, "pending", "the queue check never changes the token");
  assert.equal(reads, 1, "a reported item is not read again");
  assert.equal(live.length, 1);
  assert.equal(live[0].code, "queued-not-started");
  assert.equal(live[0].queueId, queueId);
  assert.deepEqual(live[0].possibleCauses,
    ["thread-busy", "thread-not-loaded", "last-turn-interrupted"]);
  assert.equal(result.diagnostics.filter((item) => item.code === "queued-not-started").length, 1);
});

await test("a queued item inside the grace period, an item already gone, or a started dispatch reports nothing", async () => {
  const root = caseDir("queue-quiet");
  const empty = writeRollout(root, [sessionMeta()]);
  const run = async (rollout, item) => {
    const clock = 5_000_000;
    let reads = 0;
    const result = await waitForCompletion(
      directOptions(path.dirname(rollout), rollout, null, { queueItemId: queueId, queueDbPath: "unused" }),
      {
        now: () => clock,
        readQueuedItem: async () => {
          reads += 1;
          return typeof item === "function" ? item(clock) : item;
        },
      },
    );
    return { result, reads };
  };
  const young = await run(empty, (clock) =>
    ({ status: "present", queueId, threadId: thread, createdAtMs: clock - 1000 }));
  assert.equal(young.reads, 1);
  assert.equal(young.result.diagnostics.some((item) => /^queue/.test(item.code)), false);
  const gone = await run(empty, { status: "absent" });
  assert.equal(gone.result.diagnostics.some((item) => /^queue/.test(item.code)), false);
  const started = writeRollout(caseDir("queue-started"), ownOpenRecords());
  const raced = await run(started, (clock) =>
    ({ status: "present", queueId, threadId: thread, createdAtMs: clock - 600000 }));
  assert.equal(raced.result.token, "pending");
  assert.equal(raced.result.diagnostics.some((item) => /^queue/.test(item.code)), false,
    "a turn already carries the dispatch");
});

await test("an unreadable store or another thread's item is diagnosed once without changing the token", async () => {
  const root = caseDir("queue-unavailable");
  const rollout = writeRollout(root, [sessionMeta()]);
  const run = async (item) => {
    let clock = 0;
    return waitForCompletion(
      directOptions(root, rollout, null, {
        budgetMs: 3000, intervalMs: 1000, queueItemId: queueId, queueDbPath: "unused",
      }),
      { now: () => clock, sleep: async (ms) => { clock += ms; }, readQueuedItem: async () => item },
    );
  };
  const unavailable = await run({ status: "unavailable", reason: "queue-store-absent" });
  assert.equal(unavailable.token, "pending");
  assert.deepEqual(unavailable.diagnostics.filter((item) => /^queue/.test(item.code)),
    [{ code: "queue-check-unavailable", queueId, reason: "queue-store-absent" }]);
  const mismatch = await run({ status: "present", queueId, threadId: otherTurn, createdAtMs: 0 });
  assert.deepEqual(mismatch.diagnostics.filter((item) => /^queue/.test(item.code)),
    [{ code: "queue-item-thread-mismatch", queueId, threadId: otherTurn }]);
  const thrown = await waitForCompletion(
    directOptions(root, rollout, null, { queueItemId: queueId, queueDbPath: "unused" }),
    { readQueuedItem: async () => { throw new Error("synthetic read failure"); } },
  );
  assert.deepEqual(thrown.diagnostics.filter((item) => /^queue/.test(item.code)),
    [{ code: "queue-check-unavailable", queueId, reason: "queue-check-error" }]);
});

await test("CLI --queue-id reads a fixture store read-only and prints queued-not-started once; stdout and exit stay the wait's", async () => {
  const root = caseDir("queue-cli");
  const rollout = writeRollout(root, [sessionMeta()]);
  const store = path.join(root, "store", "queue_1.sqlite");
  await writeQueueStore(store, [{ id: queueId, threadId: thread, createdAtMs: Date.now() - 600000 }]);
  const before = fs.readFileSync(store);
  const args = ["--thread", thread, "--dispatch", dispatch, "--rollout-path", rollout,
    "--sessions-root", root, "--status-exit-codes"];
  const plain = cli(args);
  const flagged = cli([...args, "--queue-id", queueId, "--queue-db", store]);
  assert.equal(flagged.stdout, plain.stdout, "stdout is the determination token alone");
  assert.equal(flagged.status, plain.status, "the exit code is unchanged");
  assert.equal(flagged.stdout, "pending\n");
  const found = queueDiagnostics(flagged.stderr);
  assert.equal(found.length, 1, flagged.stderr);
  assert.equal(found[0].code, "queued-not-started");
  assert.equal(found[0].threadId, thread);
  assert.doesNotMatch(flagged.stderr, /ExperimentalWarning/, "the SQLite import warning is not printed");
  assert.deepEqual(queueDiagnostics(plain.stderr), []);
  assert.ok(before.equals(fs.readFileSync(store)), "the store is unchanged");
  assert.deepEqual(fs.readdirSync(path.dirname(store)), ["queue_1.sqlite"], "no sidecar was created");

  const fresh = path.join(root, "fresh", "queue_1.sqlite");
  await writeQueueStore(fresh, [{ id: queueId, threadId: thread, createdAtMs: Date.now() }]);
  assert.deepEqual(queueDiagnostics(cli([...args, "--queue-id", queueId, "--queue-db", fresh]).stderr), []);
  const absent = path.join(root, "absent", "queue_1.sqlite");
  await writeQueueStore(absent, []);
  assert.deepEqual(queueDiagnostics(cli([...args, "--queue-id", queueId, "--queue-db", absent]).stderr), []);
  const missing = cli([...args, "--queue-id", queueId, "--queue-db", path.join(root, "none.sqlite")]);
  assert.equal(missing.stdout, "pending\n");
  assert.deepEqual(queueDiagnostics(missing.stderr),
    [{ code: "queue-check-unavailable", queueId, reason: "queue-store-absent" }]);
  const defaulted = cli([...args, "--queue-id", queueId]);
  assert.deepEqual(queueDiagnostics(defaulted.stderr),
    [{ code: "queue-check-unavailable", queueId, reason: "queue-store-absent" }],
    "the default store is the isolated home's, which has none");
  const selected = cli([...args, "--queue-id", queueId, "--queue-db", store],
    { CODEX_IPC_SQLITE_READER: "{}" });
  assert.deepEqual(queueDiagnostics(selected.stderr),
    [{ code: "queue-check-unavailable", queueId, reason: "sqlite-reader-selected" }],
    "a selected Python reader never falls back to node:sqlite");
  const usage = cli([...args, "--queue-id", "nope"]);
  assert.equal(usage.status, 1);
  assert.equal(usage.stdout, "");
  assert.match(usage.stderr, /--queue-id must be a UUID/);
});

// Queue wake: the waiter wakes an unloaded thread once, through codex_ipc_wake.ps1. Every case here
// injects the runner, the platform and the environment; nothing runs PowerShell or reads ~/.claude.
const {
  QUEUE_WAKE_AFTER_MS,
  QUEUE_WAKE_NO_EFFECT_MS,
  parseWakeOutput,
  resolveWakeHostKind,
} = api;
const wakeExe = "C:\\Fixture\\Alt\\app\\ChatGPT.exe";

function wakeRoot(name, descriptor) {
  const root = caseDir(name);
  fs.mkdirSync(path.join(root, "transport"), { recursive: true });
  if (descriptor !== undefined) {
    fs.writeFileSync(path.join(root, "transport", "host-policy.json"),
      typeof descriptor === "string" ? descriptor : JSON.stringify(descriptor));
  }
  return root;
}
const alternateDescriptor = { schemaVersion: 1, intendedHost: { kind: "alternate", executable: wakeExe } };

function wakeDiagnostics(items) {
  return items.filter((item) => /^wake-/.test(item.code) || item.code === "queued-not-started");
}

// Runs a polling wait over a fresh queued item with an injected clock. `item(ageMs)` decides what
// the queue store returns; `runWake` records each call with the item's age at that moment.
async function runWakeCase({
  root, records = [sessionMeta()], budgetMs = 60000, wake = true, platform = "win32", env = {},
  item = () => "present", outcome, intendedHost = null, runWake, createdAgoMs = 0,
}) {
  const rollout = writeRollout(root, records);
  let clock = 2_000_000;
  const createdAtMs = clock - createdAgoMs;
  const calls = [];
  const live = [];
  const result = await waitForCompletion(
    directOptions(root, rollout, null, {
      budgetMs, intervalMs: 1000, queueItemId: queueId, queueDbPath: "unused", wake, intendedHost,
    }),
    {
      now: () => clock,
      sleep: async (ms) => { clock += ms; },
      platform,
      env,
      readQueuedItem: async () => {
        const state = item(clock - createdAtMs);
        return state === "present"
          ? { status: "present", queueId, threadId: thread, createdAtMs }
          : { status: state };
      },
      runWake: runWake || (async (request) => {
        calls.push({ request, ageMs: clock - createdAtMs });
        return outcome || {
          result: "forwarded", wakeCode: "wake-forwarded", reasons: [], launched: true,
          rootPid: 100, rootPidAfter: 100, helperPid: 555, helperExitCode: 0, exitStatus: 0,
        };
      }),
      onDiagnostic: (diagnostic) => live.push(diagnostic),
    },
  );
  return { result, calls, live };
}

await test("--no-wake and --intended-host need --queue-id; the wake is on by default for a queue dispatch", () => {
  const base = ["--thread", thread, "--dispatch", dispatch];
  assert.equal(parseWaitArgs(base, {}).options.wake, false, "no queue id, no wake");
  const queued = parseWaitArgs([...base, "--queue-id", queueId], {}).options;
  assert.equal(queued.wake, true);
  assert.equal(queued.intendedHost, null);
  assert.equal(parseWaitArgs([...base, "--queue-id", queueId, "--no-wake"], {}).options.wake, false);
  assert.equal(parseWaitArgs([...base, "--queue-id", queueId, "--intended-host", wakeExe], {})
    .options.intendedHost, wakeExe);
  assert.equal(parseWaitArgs([...base, "--queue-id", queueId, "--intended-host", "package"], {})
    .options.intendedHost, "package");
  assert.throws(() => parseWaitArgs([...base, "--no-wake"], {}), /--no-wake requires --queue-id/);
  assert.throws(() => parseWaitArgs([...base, "--intended-host", wakeExe], {}),
    /--intended-host requires --queue-id/);
  assert.throws(() => parseWaitArgs([...base, "--queue-id", queueId, "--intended-host", "relative\\ChatGPT.exe"], {}),
    /--intended-host must be package or an absolute executable path/);
  assert.equal(QUEUE_WAKE_AFTER_MS, 12000);
  assert.equal(QUEUE_WAKE_NO_EFFECT_MS, 15000);
});

await test("a queued item still queued at 12 s is woken exactly once, then wake-no-effect at +15 s, then queued-not-started", async () => {
  const root = wakeRoot("wake-once", alternateDescriptor);
  const { result, calls, live } = await runWakeCase({ root });
  assert.equal(result.token, "pending", "the wake never changes the token");
  assert.equal(calls.length, 1, "exactly one wake");
  assert.equal(calls[0].ageMs, QUEUE_WAKE_AFTER_MS, "at the first poll at or after 12 s");
  assert.deepEqual(calls[0].request, {
    threadId: thread, ipcRoot: path.join(root, "transport"), intendedHost: null, timeoutMs: 60000,
  });
  const codes = wakeDiagnostics(live).map((item) => item.code);
  assert.deepEqual(codes, ["wake-attempted", "wake-result", "wake-no-effect", "queued-not-started"]);
  const attempted = live.find((item) => item.code === "wake-attempted");
  assert.equal(attempted.ageMs, QUEUE_WAKE_AFTER_MS);
  assert.equal(attempted.threadId, thread);
  const outcome = live.find((item) => item.code === "wake-result");
  assert.equal(outcome.result, "forwarded");
  assert.equal(outcome.wakeCode, "wake-forwarded");
  assert.equal(outcome.launched, true);
  const noEffect = live.find((item) => item.code === "wake-no-effect");
  assert.equal(noEffect.sinceWakeMs, QUEUE_WAKE_NO_EFFECT_MS);
  assert.deepEqual(noEffect.possibleCauses,
    ["last-turn-interrupted", "thread-owned-by-another-writer", "app-not-ready"]);
  assert.equal(live.find((item) => item.code === "queued-not-started").ageMs, QUEUE_NOT_STARTED_GRACE_MS);
  assert.equal(result.diagnostics.filter((item) => /^wake-/.test(item.code)).length, 3,
    "each wake diagnostic is recorded once");
});

await test("an item that starts before 12 s, or a turn that already carries the dispatch, is never woken", async () => {
  const early = await runWakeCase({
    root: wakeRoot("wake-started-early", alternateDescriptor),
    item: (ageMs) => (ageMs < 5000 ? "present" : "absent"),
  });
  assert.equal(early.calls.length, 0);
  assert.deepEqual(wakeDiagnostics(early.live), []);
  const carried = await runWakeCase({
    root: wakeRoot("wake-turn-carries", alternateDescriptor), records: ownOpenRecords(),
  });
  assert.equal(carried.calls.length, 0);
  assert.deepEqual(wakeDiagnostics(carried.live), []);
});

await test("--no-wake and a single-shot wait never wake", async () => {
  const off = await runWakeCase({ root: wakeRoot("wake-off", alternateDescriptor), wake: false });
  assert.equal(off.calls.length, 0);
  assert.deepEqual(wakeDiagnostics(off.live).map((item) => item.code), ["queued-not-started"],
    "the existing queue diagnostic is unchanged");
  const single = await runWakeCase({
    root: wakeRoot("wake-single-shot", alternateDescriptor), budgetMs: 0, createdAgoMs: 600000,
  });
  assert.equal(single.calls.length, 0);
  assert.equal(single.live.some((item) => /^wake-/.test(item.code)), false);
});

await test("not on Windows, the helper never runs: one wake-skipped not-windows", async () => {
  const { calls, live } = await runWakeCase({
    root: wakeRoot("wake-not-windows", alternateDescriptor), platform: "linux",
  });
  assert.equal(calls.length, 0);
  assert.deepEqual(live.filter((item) => /^wake-/.test(item.code)),
    [{ code: "wake-skipped", queueId, reason: "not-windows" }]);
  assert.equal(live.some((item) => item.code === "queued-not-started"), true);
});

await test("a package host is never woken, from any configuration layer; an invalid one is not either", async () => {
  const skipped = async (name, descriptor, extra = {}) => {
    const run = await runWakeCase({ root: wakeRoot(name, descriptor), ...extra });
    assert.equal(run.calls.length, 0, name);
    return run.live.filter((item) => /^wake-/.test(item.code));
  };
  assert.deepEqual(await skipped("wake-default", undefined),
    [{ code: "wake-skipped", queueId, reason: "host-package", source: "default" }]);
  assert.deepEqual(await skipped("wake-descriptor-package", { schemaVersion: 1, intendedHost: { kind: "package" } }),
    [{ code: "wake-skipped", queueId, reason: "host-package", source: "descriptor" }]);
  assert.deepEqual(await skipped("wake-env-package", alternateDescriptor, { env: { CODEX_IPC_INTENDED_HOST: "package" } }),
    [{ code: "wake-skipped", queueId, reason: "host-package", source: "environment" }]);
  assert.deepEqual(await skipped("wake-flag-package", alternateDescriptor, { intendedHost: "package" }),
    [{ code: "wake-skipped", queueId, reason: "host-package", source: "flag" }]);
  assert.deepEqual(await skipped("wake-descriptor-invalid", "{not json"),
    [{ code: "wake-skipped", queueId, reason: "host-policy-invalid", source: "descriptor" }]);
  assert.deepEqual(await skipped("wake-descriptor-kind", { schemaVersion: 1, intendedHost: { kind: "other" } }),
    [{ code: "wake-skipped", queueId, reason: "host-policy-invalid", source: "descriptor" }]);
  assert.deepEqual(await skipped("wake-env-empty", alternateDescriptor, { env: { CODEX_IPC_INTENDED_HOST: " " } }),
    [{ code: "wake-skipped", queueId, reason: "host-policy-invalid", source: "environment" }]);

  const envAlternate = await runWakeCase({
    root: wakeRoot("wake-env-alternate", { schemaVersion: 1, intendedHost: { kind: "package" } }),
    env: { CODEX_IPC_INTENDED_HOST: wakeExe },
  });
  assert.equal(envAlternate.calls.length, 1, "the environment outranks the descriptor");
  const flagAlternate = await runWakeCase({
    root: wakeRoot("wake-flag-alternate", undefined), intendedHost: wakeExe,
  });
  assert.equal(flagAlternate.calls.length, 1, "the handoff's --intended-host outranks the default");
  assert.equal(flagAlternate.calls[0].request.intendedHost, wakeExe, "and is passed to the helper");
});

await test("a refused or failed wake reports its code once and no wake-no-effect; queued-not-started still follows", async () => {
  const refused = await runWakeCase({
    root: wakeRoot("wake-refused", alternateDescriptor),
    outcome: { result: "refused", wakeCode: "app-not-running", reasons: ["app-not-running"], launched: false, exitStatus: 6 },
  });
  assert.equal(refused.calls.length, 1);
  assert.deepEqual(wakeDiagnostics(refused.live).map((item) => item.code),
    ["wake-attempted", "wake-result", "queued-not-started"]);
  const result = refused.live.find((item) => item.code === "wake-result");
  assert.equal(result.result, "refused");
  assert.equal(result.wakeCode, "app-not-running");
  assert.equal(result.exitStatus, 6);

  const thrown = await runWakeCase({
    root: wakeRoot("wake-thrown", alternateDescriptor),
    runWake: async () => { throw new Error("synthetic helper failure"); },
  });
  assert.deepEqual(thrown.live.filter((item) => item.code === "wake-result").map((item) => item.wakeCode),
    ["helper-error"]);
  assert.equal(thrown.live.some((item) => item.code === "wake-no-effect"), false);

  const unverified = await runWakeCase({
    root: wakeRoot("wake-unverified", alternateDescriptor),
    outcome: {
      result: "unverified", wakeCode: "wake-launch-not-exited", reasons: ["wake-launch-not-exited"],
      launched: true, helperPid: 555, exitStatus: 7,
    },
  });
  assert.deepEqual(wakeDiagnostics(unverified.live).map((item) => item.code),
    ["wake-attempted", "wake-result", "wake-no-effect", "queued-not-started"],
    "a launch that may have forwarded the URL is still followed up");
});

await test("parseWakeOutput keeps tokens and PIDs, drops paths, and rejects anything else", () => {
  const document = {
    schemaVersion: 1, tool: "codex_ipc_wake", result: "unverified", code: "host-changed",
    reasons: ["host-changed", "Not A Token"], launched: true, rootPid: 100, rootPidAfter: 200,
    helperPid: 555, helperExitCode: 0, userDataDir: "C:\\private\\desktop",
    command: { executable: wakeExe },
  };
  const parsed = parseWakeOutput(`noise\n${JSON.stringify(document)}\n`, 7);
  assert.deepEqual(parsed, {
    result: "unverified", wakeCode: "host-changed", reasons: ["host-changed"], launched: true,
    rootPid: 100, rootPidAfter: 200, helperPid: 555, helperExitCode: 0, exitStatus: 7,
  });
  assert.equal(JSON.stringify(parsed).includes("private"), false);
  for (const bad of ["", "not json", JSON.stringify({ ...document, tool: "other" }),
    JSON.stringify({ ...document, result: "woken" }), JSON.stringify({ ...document, code: "Bad Code" }),
    JSON.stringify({ ...document, schemaVersion: 2 })]) {
    assert.deepEqual(parseWakeOutput(bad, 1),
      { result: null, wakeCode: "helper-output-invalid", launched: false, exitStatus: 1 });
  }
});

await test("resolveWakeHostKind follows flag, environment, descriptor, then the package default", () => {
  const root = wakeRoot("wake-resolve", alternateDescriptor);
  const transportRoot = path.join(root, "transport");
  assert.deepEqual(resolveWakeHostKind({ transportRoot }, {}), { kind: "alternate", source: "descriptor" });
  assert.deepEqual(resolveWakeHostKind({ transportRoot, intendedHost: "package" }, { CODEX_IPC_INTENDED_HOST: wakeExe }),
    { kind: "package", source: "flag" });
  assert.deepEqual(resolveWakeHostKind({ transportRoot }, { CODEX_IPC_INTENDED_HOST: "package" }),
    { kind: "package", source: "environment" });
  assert.deepEqual(resolveWakeHostKind({ transportRoot: path.join(root, "absent") }, {}),
    { kind: "package", source: "default" });
  fs.writeFileSync(path.join(transportRoot, "host-policy.json"), `\uFEFF${JSON.stringify({ schemaVersion: 1 })}`);
  assert.deepEqual(resolveWakeHostKind({ transportRoot }, {}), { kind: "package", source: "default" });
});

await test("CLI: a polling queue wait on a package host skips the wake without running PowerShell; --no-wake is silent", async () => {
  const root = caseDir("wake-cli");
  const rollout = writeRollout(root, [sessionMeta()]);
  const store = path.join(root, "store", "queue_1.sqlite");
  await writeQueueStore(store, [{ id: queueId, threadId: thread, createdAtMs: Date.now() - 600000 }]);
  const transport = path.join(root, "transport");
  fs.mkdirSync(transport, { recursive: true });
  fs.writeFileSync(path.join(transport, "host-policy.json"),
    JSON.stringify({ schemaVersion: 1, intendedHost: { kind: "package" } }));
  const env = { ...process.env };
  delete env.CODEX_IPC_INTENDED_HOST;
  const args = ["--thread", thread, "--dispatch", dispatch, "--rollout-path", rollout,
    "--sessions-root", root, "--transport-root", transport, "--status-exit-codes",
    "--budget-ms", "1500", "--interval-ms", "500", "--queue-id", queueId, "--queue-db", store];
  const run = (extra) => spawnSync(process.execPath, [waitPath, ...args, ...extra], {
    cwd: tmp, encoding: "utf8", timeout: 30000,
    env: { ...env, HOME: tmp, USERPROFILE: tmp, CODEX_IPC_ROLLOUT_PATH: "", CODEX_IPC_WAIT_BUDGET_MS: "",
      CODEX_IPC_WAIT_INTERVAL_MS: "" },
  });
  const wakeLines = (stderr) => stderr.split(/\r?\n/u)
    .filter((line) => line.startsWith("WAIT_DIAGNOSTIC "))
    .map((line) => JSON.parse(line.slice("WAIT_DIAGNOSTIC ".length)))
    .filter((item) => /^wake-/.test(item.code));
  const woken = run([]);
  assert.equal(woken.stdout, "pending\n", woken.stderr);
  assert.equal(woken.status, 2, "the exit code is the wait's");
  assert.deepEqual(wakeLines(woken.stderr), [process.platform === "win32"
    ? { code: "wake-skipped", queueId, reason: "host-package", source: "descriptor" }
    : { code: "wake-skipped", queueId, reason: "not-windows" }]);
  const quiet = run(["--no-wake"]);
  assert.equal(quiet.stdout, "pending\n");
  assert.equal(quiet.status, 2);
  assert.deepEqual(wakeLines(quiet.stderr), []);
});

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
