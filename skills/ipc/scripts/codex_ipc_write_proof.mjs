#!/usr/bin/env node
// Controlled live-write proof harness for Codex Desktop IPC.
//
// Default behavior is dry-run/read-only. Live mode requires --send and
// --ack-live-write, inspects the target first, revalidates the runtime, captures
// before/after snapshots in memory, sends one marker task, and compares the
// isolation evidence. It does not write SQLite, config, or proof artifacts.

import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pollRolloutForMarker } from "./codex_ipc_rollout_reader.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_TIMEOUT_MS = 9000;
const DEFAULT_POLL_MS = 2000;
const DEFAULT_POLL_ATTEMPTS = 45;
// Optional operator-designated test thread (see codex_ipc_client.mjs). No default is shipped.
const AUTHORIZED_TEST_THREAD_ID = process.env.CODEX_IPC_AUTHORIZED_TEST_THREAD || null;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function usage() {
  return `Usage:
  node scripts/codex_ipc_write_proof.mjs --thread <uuid> [options]

Dry-run/read-only by default:
  node scripts/codex_ipc_write_proof.mjs --thread <uuid>

Live controlled proof:
  node scripts/codex_ipc_write_proof.mjs --thread <uuid> --send --ack-live-write --allow-any-thread

Options:
  --thread <uuid>                  Explicit target conversation/thread id. Required.
  --marker <text>                  Unique proof marker. Default: generated CODEX_IPC_PROOF_<uuid>.
  --task <text>                    Exact task to send. Defaults to a no-edit marker ack request.
  --timeout-ms <n>                 IPC/revalidation timeout. Default: ${DEFAULT_TIMEOUT_MS}
  --poll-ms <n>                    Rollout polling interval after send. Default: ${DEFAULT_POLL_MS}
  --poll-attempts <n>              Rollout polling attempts after send. Default: ${DEFAULT_POLL_ATTEMPTS}
  --allow-thread-change <uuid>     Permit an expected non-target row change during compare.
                                   May be repeated for operator/control threads.
  --allow-mid-turn                 Permit sending even if inspection suggests the target is mid-turn.
  --send                           Actually send one follower-start-turn through the maintained client.
  --ack-live-write                 Required with --send; acknowledges this starts a real turn.
  --allow-any-thread               Pass through to the maintained IPC client for explicit UUID sends.
  --help                           Show this help.

Safety:
  Dry-run is the default and performs no IPC write. Live mode sends exactly one
  marker task to exactly one explicit conversationId through codex_ipc_client.mjs.
  It fails closed on missing target evidence, archived target, mid-turn target
  unless --allow-mid-turn is present, revalidation failure, send failure, or
  isolation compare failure.`;
}

function parseArgs(argv) {
  const opts = {
    threadId: null,
    marker: null,
    task: null,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    pollMs: DEFAULT_POLL_MS,
    pollAttempts: DEFAULT_POLL_ATTEMPTS,
    allowThreadChangeIds: [],
    allowMidTurn: false,
    send: false,
    ackLiveWrite: false,
    allowAnyThread: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
      case "--conversation-id":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--marker":
        opts.marker = takeValue(argv, ++index, arg);
        break;
      case "--task":
        opts.task = takeValue(argv, ++index, arg);
        break;
      case "--timeout-ms":
        opts.timeoutMs = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--poll-ms":
        opts.pollMs = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--poll-attempts":
        opts.pollAttempts = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--allow-thread-change":
        opts.allowThreadChangeIds.push(takeValue(argv, ++index, arg));
        break;
      case "--allow-mid-turn":
        opts.allowMidTurn = true;
        break;
      case "--send":
        opts.send = true;
        break;
      case "--ack-live-write":
        opts.ackLiveWrite = true;
        break;
      case "--allow-any-thread":
        opts.allowAnyThread = true;
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return opts;
}

function takeValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parsePositiveInt(value, flag) {
  if (!/^\d+$/.test(String(value))) {
    throw new Error(`${flag} must be a positive integer`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}

function normalizeOptions(opts) {
  if (opts.help) {
    return opts;
  }

  if (!opts.threadId || !UUID_RE.test(opts.threadId)) {
    throw new Error("--thread must be an explicit UUID conversation/thread id");
  }

  for (const allowedThreadId of opts.allowThreadChangeIds) {
    if (!UUID_RE.test(allowedThreadId)) {
      throw new Error("--allow-thread-change must be a UUID");
    }
  }

  opts.marker = (opts.marker || `CODEX_IPC_PROOF_${randomUUID()}`).trim();
  if (!opts.marker || opts.marker.length < 12) {
    throw new Error("--marker must be a non-empty unique marker at least 12 characters long");
  }

  opts.task = (opts.task || defaultProofTask(opts.marker)).trim();
  if (!opts.task.includes(opts.marker)) {
    throw new Error("--task must include the proof marker so the rollout can be verified");
  }

  if (opts.send && !opts.ackLiveWrite) {
    throw new Error("--send requires --ack-live-write because this starts a real turn");
  }
  const isAuthorizedTestThread =
    AUTHORIZED_TEST_THREAD_ID && opts.threadId === AUTHORIZED_TEST_THREAD_ID;
  if (opts.send && !isAuthorizedTestThread && !opts.allowAnyThread) {
    throw new Error(
      "--send requires --allow-any-thread for this conversationId. (Alternatively, set " +
        "CODEX_IPC_AUTHORIZED_TEST_THREAD to a test thread you own to exempt that one id.)",
    );
  }

  return opts;
}

function defaultProofTask(marker) {
  return [
    `CONTROLLED IPC WRITE PROOF ${marker}.`,
    "Make no file edits and run no commands unless needed to inspect this prompt.",
    `Reply in chat with exactly: ${marker} ACK`,
  ].join(" ");
}

function runNode(scriptName, args, options = {}) {
  // Siblings are resolved relative to this script's own directory so the harness
  // works from any cwd (bundled skill, standalone install, or repo checkout).
  const scriptPath = path.join(SCRIPT_DIR, path.basename(scriptName));
  const result = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: SCRIPT_DIR,
    encoding: "utf8",
    timeout: options.timeoutMs || 120000,
    windowsHide: true,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    signal: result.signal,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? result.error.message : null,
    command: [process.execPath, scriptPath, ...args].join(" "),
  };
}

function parseJsonCommand(result, label) {
  if (!result.ok) {
    throw new Error(`${label} failed: ${summarizeCommandFailure(result)}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`${label} did not emit JSON: ${error.message}`);
  }
}

function summarizeCommandFailure(result) {
  return [
    `status=${result.status}`,
    result.signal ? `signal=${result.signal}` : null,
    result.error ? `error=${result.error}` : null,
    result.stderr.trim() ? `stderr=${result.stderr.trim().slice(0, 500)}` : null,
    result.stdout.trim() ? `stdout=${result.stdout.trim().slice(0, 500)}` : null,
  ]
    .filter(Boolean)
    .join("; ");
}

function inspectTarget(opts) {
  const result = runNode(
    "scripts/codex_ipc_session_inspect.mjs",
    ["--thread", opts.threadId, "--tail-events", "20"],
    { timeoutMs: 60000 },
  );
  const inspect = parseJsonCommand(result, "session inspect");
  const thread = inspect.dbThread?.thread;
  const activity = inspect.activitySignals || {};
  const failures = [];
  if (!inspect.ok) {
    failures.push("inspector result was not ok");
  }
  if (!thread?.exists) {
    failures.push("target thread was not found in the Desktop state DB");
  }
  if (thread?.archived) {
    failures.push("target thread is archived");
  }
  // A4: gate on the authoritative turnActivity (open/closed/ambiguous), not the historical
  // maybeMidTurn tail heuristic. A send requires a CLOSED latest turn; --allow-mid-turn may
  // override an OPEN turn only, never an AMBIGUOUS one (fail closed on ambiguity).
  const turnActivity = activity.turnActivity;
  if (turnActivity !== "closed") {
    if (turnActivity === "open" && opts.allowMidTurn) {
      // permitted mid-turn override
    } else if (turnActivity === "open") {
      failures.push("target turn is open (mid-turn); pass --allow-mid-turn only with explicit operator intent");
    } else {
      failures.push("target turn activity is ambiguous; refusing to send (not overridable by --allow-mid-turn)");
    }
  }
  return {
    ok: failures.length === 0,
    failures,
    summary: summarizeInspect(inspect),
    raw: inspect,
  };
}

function summarizeInspect(inspect) {
  const thread = inspect.dbThread?.thread || {};
  const rollout = inspect.rollout?.primary || {};
  const activity = inspect.activitySignals || {};
  return {
    threadId: thread.id || null,
    exists: Boolean(thread.exists),
    cwd: thread.cwd || null,
    title: thread.title || null,
    model: thread.model || null,
    reasoningEffort: thread.reasoningEffort || null,
    archived: thread.archived ?? null,
    rolloutPath: thread.rolloutPath || rollout.path || null,
    rolloutLineCount: rollout.lineCount || null,
    newestRolloutLine: activity.newestRolloutLine || null,
    lastTaskCompleteLine: activity.lastTaskCompleteLine || null,
    maybeMidTurn: Boolean(activity.maybeMidTurn),
    turnActivity: activity.turnActivity || null,
    activityConclusion: activity.conclusion || null,
  };
}

function revalidateRuntime(opts) {
  const result = runNode(
    "scripts/codex_ipc_revalidate.mjs",
    [
      "--thread",
      opts.threadId,
      "--allow-live-ipc-read",
      "--timeout-ms",
      String(Math.min(opts.timeoutMs, 5000)),
    ],
    { timeoutMs: 90000 },
  );
  return parseJsonCommand(result, "runtime revalidation");
}

function snapshot(opts) {
  const result = runNode(
    "scripts/codex_ipc_snapshot.mjs",
    ["--thread", opts.threadId, "--marker", opts.marker],
    { timeoutMs: 90000 },
  );
  return parseJsonCommand(result, "snapshot");
}

function sendMarkerTask(opts) {
  const args = [
    "--thread",
    opts.threadId,
    "--task",
    opts.task,
    "--send",
    "--ack-live-write",
    "--timeout-ms",
    String(opts.timeoutMs),
  ];
  if (opts.allowAnyThread) {
    args.push("--allow-any-thread");
  }
  const result = runNode("scripts/codex_ipc_client.mjs", args, {
    timeoutMs: opts.timeoutMs + 5000,
  });
  return parseJsonCommand(result, "IPC send");
}

function compareSnapshots(before, after, opts) {
  const beforeHashes = before.db?.threads?.threadRowHashById || {};
  const afterHashes = after.db?.threads?.threadRowHashById || {};
  const hashMapsPresent = Boolean(
    before.db?.threads?.threadRowHashById && after.db?.threads?.threadRowHashById,
  );
  const threadDiff = diffThreadHashes(
    beforeHashes,
    afterHashes,
    opts.threadId,
    opts.allowThreadChangeIds,
  );
  const marker = compareMarker(before.db?.marker, after.db?.marker);
  const markerIncreased = typeof marker?.delta === "number" && marker.delta > 0;
  const configShaEqual = before.config?.sha256 === after.config?.sha256;
  const configKeysEqual =
    hashJson(before.config?.keys || {}) === hashJson(after.config?.keys || {});
  const stableEvidence =
    before.config?.stableDuringRead === true &&
    after.config?.stableDuringRead === true &&
    before.db?.stableDuringRead === true &&
    after.db?.stableDuringRead === true;

  // NOTE (schema drift, observed live 2026-07-08): current Codex Desktop does not store
  // message text in the state-DB bytes at all — the marker appears only in the rollout
  // JSONL, which the separate rollout probe checks (agent marker + task_complete; strictly
  // stronger evidence). markerIncreased is therefore reported as diagnostics below but is
  // no longer a conjunct of the isolation compare; requiring it made every proof "fail"
  // despite proven delivery.
  return {
    ok:
      configShaEqual &&
      configKeysEqual &&
      hashMapsPresent &&
      stableEvidence &&
      before.db?.threads?.target?.exists === true &&
      after.db?.threads?.target?.exists === true &&
      threadDiff.targetChanged &&
      threadDiff.unexpectedNonTargetChangedIds.length === 0 &&
      threadDiff.addedIds.length === 0 &&
      threadDiff.removedIds.length === 0,
    config: {
      sha256Unchanged: configShaEqual,
      selectedKeysUnchanged: configKeysEqual,
      stableDuringReads:
        before.config?.stableDuringRead === true &&
        after.config?.stableDuringRead === true,
    },
    db: {
      stableDuringReads:
        before.db?.stableDuringRead === true && after.db?.stableDuringRead === true,
      targetExistsBefore: before.db?.threads?.target?.exists === true,
      targetExistsAfter: after.db?.threads?.target?.exists === true,
      threadHashMapsPresent: hashMapsPresent,
      targetThreadChanged: threadDiff.targetChanged,
      allowedNonTargetChangedIds: threadDiff.allowedNonTargetChangedIds,
      unexpectedNonTargetChangedIds: threadDiff.unexpectedNonTargetChangedIds,
      addedIds: threadDiff.addedIds,
      removedIds: threadDiff.removedIds,
      marker,
      markerIncreased,
    },
    warnings: [
      "This compare proves current snapshot invariants only.",
      "GUI visibility still requires user/app observation or prior confirmed Desktop rendering behavior.",
    ],
  };
}

function diffThreadHashes(beforeHashes, afterHashes, targetThreadId, allowThreadChangeIds) {
  const allowedIds = new Set(allowThreadChangeIds);
  const beforeIds = new Set(Object.keys(beforeHashes));
  const afterIds = new Set(Object.keys(afterHashes));
  const addedIds = [...afterIds].filter((id) => !beforeIds.has(id)).sort();
  const removedIds = [...beforeIds].filter((id) => !afterIds.has(id)).sort();
  const changedIds = [...beforeIds]
    .filter((id) => afterIds.has(id) && beforeHashes[id] !== afterHashes[id])
    .sort();
  return {
    targetChanged: changedIds.includes(targetThreadId),
    allowedNonTargetChangedIds: changedIds.filter((id) => id !== targetThreadId && allowedIds.has(id)),
    unexpectedNonTargetChangedIds: changedIds.filter(
      (id) => id !== targetThreadId && !allowedIds.has(id),
    ),
    addedIds,
    removedIds,
  };
}

function compareMarker(beforeMarker, afterMarker) {
  if (!beforeMarker && !afterMarker) {
    return null;
  }
  return {
    beforeCount: beforeMarker?.dbBinaryCount ?? null,
    afterCount: afterMarker?.dbBinaryCount ?? null,
    delta:
      typeof beforeMarker?.dbBinaryCount === "number" &&
      typeof afterMarker?.dbBinaryCount === "number"
        ? afterMarker.dbBinaryCount - beforeMarker.dbBinaryCount
        : null,
    textSha256: beforeMarker?.textSha256 || afterMarker?.textSha256 || null,
  };
}

function summarizeSnapshot(item) {
  return {
    ok: item.ok,
    generatedAt: item.generatedAt,
    targetThreadId: item.targetThreadId,
    configSha256: item.config?.sha256 || null,
    configStableDuringRead: item.config?.stableDuringRead ?? null,
    dbSha256: item.db?.sha256 || null,
    dbStableDuringRead: item.db?.stableDuringRead ?? null,
    targetThread: item.db?.threads?.target || null,
    threadHashMapsPresent: Boolean(item.db?.threads?.threadRowHashById),
    marker: item.db?.marker || null,
  };
}

function hashJson(value) {
  return sha256(JSON.stringify(sortValue(value)));
}

function sortValue(value) {
  if (Array.isArray(value)) {
    return value.map(sortValue);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, sortValue(item)]),
    );
  }
  return value;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function dryRun(opts, inspect) {
  return {
    ok: inspect.ok,
    mode: "codex-ipc-write-proof",
    dryRun: true,
    generatedAt: new Date().toISOString(),
    threadId: opts.threadId,
    marker: opts.marker,
    markerSha256: sha256(opts.marker),
    taskPreview: opts.task,
    targetInspection: inspect.summary,
    failures: inspect.failures,
    wouldRun: [
      "read-only session inspection",
      "read-only runtime revalidation with initialize only",
      "read-only before snapshot",
      "one live codex_ipc_client.mjs follower-start-turn",
      "rollout poll for agent marker response and task_complete",
      "read-only after snapshot",
      "in-memory config/thread/marker isolation compare",
    ],
    warnings: [
      "Dry-run only: no live IPC write was attempted.",
      "Live proof requires --send --ack-live-write and, for non-test threads, --allow-any-thread.",
    ],
  };
}

async function main() {
  let opts;
  try {
    opts = normalizeOptions(parseArgs(process.argv.slice(2)));
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    console.error("");
    console.error(usage());
    process.exit(1);
  }

  if (opts.help) {
    console.log(usage());
    return;
  }

  const inspect = inspectTarget(opts);
  if (!opts.send) {
    const result = dryRun(opts, inspect);
    console.log(JSON.stringify(result, null, 2));
    if (!result.ok) {
      process.exit(1);
    }
    return;
  }
  if (!inspect.ok) {
    console.log(
      JSON.stringify(
        {
          ok: false,
          mode: "codex-ipc-write-proof",
          dryRun: false,
          generatedAt: new Date().toISOString(),
          threadId: opts.threadId,
          markerSha256: sha256(opts.marker),
          targetInspection: inspect.summary,
          failures: inspect.failures,
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  const revalidation = revalidateRuntime(opts);
  if (!revalidation.ok) {
    console.log(
      JSON.stringify(
        {
          ok: false,
          mode: "codex-ipc-write-proof",
          dryRun: false,
          generatedAt: new Date().toISOString(),
          threadId: opts.threadId,
          markerSha256: sha256(opts.marker),
          targetInspection: inspect.summary,
          revalidation,
          failures: ["runtime revalidation failed"],
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  const before = snapshot(opts);
  const send = sendMarkerTask(opts);
  const rolloutPath = before.db?.threads?.target?.rolloutPath || inspect.summary.rolloutPath;
  const rolloutProbe = await pollRolloutForMarker(
    rolloutPath,
    opts.marker,
    opts.pollMs,
    opts.pollAttempts,
  );
  const after = snapshot(opts);
  const compare = compareSnapshots(before, after, opts);
  const ok = send.ok && rolloutProbe.ok && compare.ok;
  const result = {
    ok,
    mode: "codex-ipc-write-proof",
    dryRun: false,
    generatedAt: new Date().toISOString(),
    threadId: opts.threadId,
    markerSha256: sha256(opts.marker),
    targetInspection: inspect.summary,
    revalidationSummary: {
      ok: revalidation.ok,
      revalidationLevel: revalidation.revalidationLevel,
      failed: revalidation.summary?.failed || [],
      skipped: revalidation.summary?.skipped || [],
    },
    before: summarizeSnapshot(before),
    send: {
      ok: send.ok,
      responseType: send.response?.resultType || null,
      handledByClientId: send.response?.handledByClientId || null,
      turnId: send.response?.result?.turn?.id || send.response?.result?.turnId || null,
    },
    rolloutProbe,
    after: summarizeSnapshot(after),
    compare,
    warnings: [
      "This proof starts a real Codex model turn only when --send is present.",
      "No config writes, SQLite writes, or proof artifact writes are performed by this harness.",
    ],
  };

  console.log(JSON.stringify(result, null, 2));
  if (!ok) {
    process.exit(1);
  }
}

await main();
