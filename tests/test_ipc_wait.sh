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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WAIT="$WAIT" TMPDIR_TEST="$TMP" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const waitPath = process.env.WAIT;
const tmp = process.env.TMPDIR_TEST;
const thread = "11111111-1111-4111-8111-111111111111";
const ownTurn = "00000000-0000-4000-8000-00000000c0de";
const otherTurn = "22222222-2222-4222-8222-222222222222";
const dispatch = "9100000000-1-abcdef0123456789";
const taskName = `${dispatch}.task.md`;

const api = await import(pathToFileURL(waitPath));
const { DEFAULT_WAIT_BUDGET_MS, DEFAULT_WAIT_INTERVAL_MS, waitForCompletion } = api;

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

function writeRollout(directory, records, id = thread, prefix = "rollout") {
  fs.mkdirSync(directory, { recursive: true });
  const target = path.join(directory, `${prefix}-${id}.jsonl`);
  fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
  return target;
}

function writeReply(target, body = "verified reply") {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, body);
  return target;
}

function caseDir(name) {
  const target = path.join(tmp, name);
  fs.mkdirSync(target, { recursive: true });
  return target;
}

function directOptions(root, rolloutPath, replyPath, extra = {}) {
  return {
    threadId: thread,
    dispatchId: dispatch,
    rolloutPath,
    sessionsRoot: path.join(root, "sessions"),
    transportRoot: path.join(root, "transport"),
    replyPath,
    sessionId: null,
    budgetMs: 0,
    intervalMs: DEFAULT_WAIT_INTERVAL_MS,
    ...extra,
  };
}

function cli(args, env = {}, timeout = 3000) {
  return spawnSync(process.execPath, [waitPath, ...args], {
    cwd: tmp,
    encoding: "utf8",
    timeout,
    env: {
      ...process.env,
      HOME: tmp,
      USERPROFILE: tmp,
      CODEX_IPC_ROOT: path.join(tmp, "default-transport"),
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
    { encoding: "utf8", timeout: 2000 },
  );
  assert.equal(imported.status, 0, imported.stderr);
  assert.equal(imported.stdout, "");
  assert.equal(imported.stderr, "");
  assert.doesNotMatch(fs.readFileSync(waitPath, "utf8"), /node:sqlite/);
});

await test("done requires own task_complete plus a regular readable reply", async () => {
  const root = caseDir("done");
  const rollout = writeRollout(root, [...ownOpenRecords(), event("task_complete", ownTurn)]);
  const reply = writeReply(path.join(root, `${dispatch}.reply.md`));
  const result = await waitForCompletion(directOptions(root, rollout, reply));
  assert.equal(result.token, "done");
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
  const explicit = writeRollout(
    path.join(root, "explicit"),
    [...ownOpenRecords(), event("task_complete", ownTurn)],
  );
  const sessions = path.join(root, "sessions");
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
  ], {}, 2000);
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
  ], {}, 2000);
  const elapsed = Date.now() - started;
  assertToken(result, "unavailable");
  assert.equal(result.error, undefined);
  assert.ok(elapsed < 1500, `bounded process took ${elapsed} ms`);
});

console.log(`RESULT: ${passed} passed, 0 failed`);
NODE
