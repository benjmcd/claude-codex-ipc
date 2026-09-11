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
import { realpathSync } from "node:fs";
import {
  isCompleteReaderCursor,
  locateRollout,
  pollRolloutForMarker,
  readRolloutFile,
  readRolloutActivity,
} from "./codex_ipc_rollout_reader.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_TIMEOUT_MS = 9000;
const DEFAULT_POLL_MS = 2000;
const DEFAULT_POLL_ATTEMPTS = 45;
// Optional operator-designated test thread (see codex_ipc_client.mjs). No default is shipped.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AUTHORIZED_TEST_THREAD_VALUE = process.env.CODEX_IPC_AUTHORIZED_TEST_THREAD || "";
const AUTHORIZED_TEST_THREAD_ID = UUID_RE.test(AUTHORIZED_TEST_THREAD_VALUE)
  ? AUTHORIZED_TEST_THREAD_VALUE.toLowerCase()
  : null;

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
  opts.threadId = opts.threadId.toLowerCase();

  for (const allowedThreadId of opts.allowThreadChangeIds) {
    if (!UUID_RE.test(allowedThreadId)) {
      throw new Error("--allow-thread-change must be a UUID");
    }
  }
  opts.allowThreadChangeIds = opts.allowThreadChangeIds.map((value) => value.toLowerCase());

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

function parseInspectorCommand(result) {
  let value;
  try {
    value = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`session inspect did not emit JSON: ${error.message}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("session inspect did not emit a JSON object");
  }
  if (result.ok) return value;

  // The inspector intentionally exits 1 for a valid negative result. Admit only that exact
  // process contract; a signal, spawn/timeout error, another status, or contradictory ok:true
  // output remains an execution failure rather than trusted target-state evidence.
  if (
    result.status === 1 &&
    !result.signal &&
    !result.error &&
    value.ok === false
  ) {
    return value;
  }
  throw new Error(`session inspect failed: ${summarizeCommandFailure(result)}`);
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
  const inspect = parseInspectorCommand(result);
  const dbThread = inspect.dbThread;
  const thread = inspect.dbThread?.thread;
  const activity = inspect.activitySignals || {};
  const failures = [];
  if (!inspect.ok) {
    failures.push("inspector result was not ok");
  }
  if (dbThread?.exists !== true || dbThread?.readOnlyOpenOk !== true) {
    failures.push("target state DB authority was not read successfully");
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
  const activityFailure = turnActivityFailure(activity.turnActivity, opts.allowMidTurn);
  if (activityFailure) failures.push(activityFailure);
  return {
    ok: failures.length === 0,
    failures,
    summary: summarizeInspect(inspect),
    raw: inspect,
  };
}

function turnActivityFailure(turnActivity, allowMidTurn) {
  if (turnActivity === "closed" || (turnActivity === "open" && allowMidTurn)) return null;
  if (turnActivity === "open") {
    return "target turn is open (mid-turn); pass --allow-mid-turn only with explicit operator intent";
  }
  return "target turn activity is ambiguous; refusing to send (not overridable by --allow-mid-turn)";
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
  const command = runNode("scripts/codex_ipc_client.mjs", args, {
    timeoutMs: opts.timeoutMs + 5000,
  });
  let parsed;
  try {
    parsed = JSON.parse(command.stdout);
  } catch (error) {
    return {
      ok: false,
      response: null,
      sentRequests: [],
      sendOccurrence: "unknown",
      commandStatus: command.status,
      commandSignal: command.signal,
      error:
        command.ok
          ? `IPC send did not emit JSON: ${error.message}`
          : `IPC send outcome is unknown: ${summarizeCommandFailure(command)}`,
    };
  }
  const sentRequests = Array.isArray(parsed?.sentRequests) ? parsed.sentRequests : [];
  const followerRequests = sentRequests.filter(
    (item) =>
      item?.name === "thread-follower-start-turn" ||
      item?.json?.method === "thread-follower-start-turn",
  );
  const matchingFollowerRequests = followerRequests.filter(
    (item) =>
      item?.name === "thread-follower-start-turn" &&
      item?.json?.method === "thread-follower-start-turn" &&
      typeof item?.json?.params?.conversationId === "string" &&
      item.json.params.conversationId.toLowerCase() === opts.threadId.toLowerCase(),
  );
  const sendOccurrence = matchingFollowerRequests.length > 0 ? "confirmed" : "unknown";
  const exactOneTargetSend =
    followerRequests.length === 1 && matchingFollowerRequests.length === 1;
  const commandReportedSuccess = command.ok && parsed?.ok === true;
  const targetThreadBound = parsed?.targetThreadId === opts.threadId;
  const responseReportedSuccess = parsed?.response?.resultType === "success";
  const clientReportedSuccess =
    commandReportedSuccess && targetThreadBound && responseReportedSuccess;
  const clientResultCertified = clientReportedSuccess && exactOneTargetSend;
  let certificationError = null;
  if (!clientResultCertified) {
    if (!exactOneTargetSend) {
      certificationError = `IPC send cardinality/target could not be certified: followerRequests=${followerRequests.length}; matchingTargetRequests=${matchingFollowerRequests.length}`;
    } else if (!commandReportedSuccess) {
      certificationError = `IPC send did not produce a confirmed successful response: ${summarizeCommandFailure(command)}`;
    } else if (!targetThreadBound) {
      certificationError = `IPC send targetThreadId did not exactly match the canonical requested thread: expected=${opts.threadId}; actual=${String(parsed?.targetThreadId)}`;
    } else if (!responseReportedSuccess) {
      certificationError = `IPC send response resultType was not success: ${String(parsed?.response?.resultType)}`;
    } else {
      certificationError = "IPC send result failed certification";
    }
  }
  return {
    ...parsed,
    ok: clientResultCertified,
    sendOccurrence,
    followerRequestCount: followerRequests.length,
    matchingFollowerRequestCount: matchingFollowerRequests.length,
    commandStatus: command.status,
    commandSignal: command.signal,
    error: certificationError,
  };
}

function invokeSendSafely(send, opts) {
  try {
    return send(opts);
  } catch (error) {
    return {
      ok: false,
      response: null,
      sentRequests: [],
      sendOccurrence: "unknown",
      followerRequestCount: null,
      matchingFollowerRequestCount: null,
      commandStatus: null,
      commandSignal: null,
      error: `send processing failed after invocation began: ${error.message}`,
    };
  }
}

function pathIdentityKey(value) {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

export function validatePreSendSnapshot(opts, item) {
  const target = item?.db?.threads?.target;
  const rolloutPath = target?.rolloutPath;
  const targetId = typeof target?.id === "string" ? target.id.toLowerCase() : null;
  const threadHashes = item?.db?.threads?.threadRowHashById;
  const targetHash = threadHashes && typeof threadHashes === "object"
    ? Object.entries(threadHashes).find(
        ([threadId]) => threadId.toLowerCase() === opts.threadId.toLowerCase(),
      )?.[1]
    : null;
  const reasons = [];
  if (item?.ok !== true) reasons.push("snapshot-not-ok");
  if (item?.targetThreadId?.toLowerCase?.() !== opts.threadId.toLowerCase()) {
    reasons.push("snapshot-target-mismatch");
  }
  if (item?.config?.exists !== true || item.config.stableDuringRead !== true) {
    reasons.push("config-snapshot-unstable");
  }
  if (
    item?.db?.exists !== true ||
    item.db.readOnlyOpenOk !== true ||
    item.db.stableDuringRead !== true ||
    item.db.quickCheck !== "ok"
  ) {
    reasons.push("db-snapshot-untrusted");
  }
  if (target?.exists !== true || targetId !== opts.threadId.toLowerCase()) {
    reasons.push("fresh-target-missing-or-mismatched");
  }
  if (target?.archived !== 0) reasons.push("fresh-target-archive-state-invalid");
  if (typeof rolloutPath !== "string" || rolloutPath.length === 0) {
    reasons.push("fresh-rollout-path-missing");
  }
  if (
    typeof targetHash !== "string"
  ) {
    reasons.push("thread-hash-evidence-missing");
  }
  return {
    ok: reasons.length === 0,
    reasons,
    rolloutPath: reasons.length === 0 ? rolloutPath : null,
  };
}

// Keep the live send behind one behaviorally testable authorization boundary. Callers may
// inject a hermetic send stub; a failed integrity or activity gate must return without invoking
// it. This avoids relying on source-text ordering as proof that the guards dominate the send.
export function authorizeBaselineAndSend(
  opts,
  rolloutBaselineActivity,
  preSendSnapshot,
  send = sendMarkerTask,
  injected = {},
) {
  const preSendState = validatePreSendSnapshot(opts, preSendSnapshot);
  if (!preSendState.ok) {
    return {
      ok: false,
      stage: "fresh-target-state",
      failure: "fresh pre-send snapshot was not stable, owner-bound, active, and rollout-bound",
      preSendState,
      send: null,
    };
  }
  const rolloutBaseline = rolloutBaselineActivity?.parsed || {};
  const ownerBound =
    UUID_RE.test(rolloutBaseline.cursor?.rolloutThreadId || "") &&
    rolloutBaseline.cursor.rolloutThreadId.toLowerCase() === opts.threadId.toLowerCase();
  const rolloutPathBound =
    typeof rolloutBaseline.path === "string" &&
    pathIdentityKey(rolloutBaseline.path) === pathIdentityKey(preSendState.rolloutPath);
  if (
    !rolloutBaseline.ok ||
    !rolloutBaseline.integrityValidated ||
    rolloutBaseline.partialTail ||
    !rolloutBaseline.cursor ||
    !isCompleteReaderCursor(rolloutBaseline.cursor) ||
    !ownerBound ||
    !rolloutPathBound ||
    (rolloutBaseline.diagnostics || []).some(
      (item) => item.reason === "rollout-thread-id-mismatch",
    )
  ) {
    return {
      ok: false,
      stage: "baseline-integrity",
      failure: "rollout baseline could not be integrity-validated and owner-bound before send",
      ownerBound,
      rolloutPathBound,
      send: null,
    };
  }

  const activityFailure = turnActivityFailure(
    rolloutBaselineActivity?.turnActivity,
    opts.allowMidTurn,
  );
  if (activityFailure) {
    return {
      ok: false,
      stage: "baseline-activity",
      failure: activityFailure,
      ownerBound,
      send: null,
    };
  }

  const readRollout = injected.readRolloutFile || readRolloutFile;
  let finalParsed;
  try {
    finalParsed = readRollout(preSendState.rolloutPath, {
      cursor: rolloutBaseline.cursor,
      rolloutThreadId: opts.threadId,
      expectedIdentityKey: rolloutBaseline.cursor.identityKey,
      retainRecords: false,
    });
  } catch (error) {
    finalParsed = {
      ok: false,
      reason: "revalidation-exception",
      diagnostics: [{ code: "rollout-revalidation-exception", message: error.message }],
      cursor: null,
    };
  }
  const finalCursor = finalParsed?.cursor;
  const unchanged =
    finalParsed?.ok === true &&
    finalParsed.integrityValidated === true &&
    finalParsed.partialTail === false &&
    isCompleteReaderCursor(finalCursor) &&
    finalCursor.offset === rolloutBaseline.cursor.offset &&
    finalCursor.size === rolloutBaseline.cursor.size &&
    finalCursor.prefixSha256 === rolloutBaseline.cursor.prefixSha256;
  const finalRolloutCheck = {
    ok: finalParsed?.ok === true,
    unchanged,
    reason: unchanged ? null : finalParsed?.reason || "rollout-changed",
    diagnostics: finalParsed?.diagnostics || [],
  };
  if (!unchanged) {
    return {
      ok: false,
      stage: "baseline-revalidation",
      failure: "rollout baseline changed or could not be fully revalidated after the fresh pre-send snapshot",
      ownerBound,
      finalRolloutCheck,
      send: null,
    };
  }

  return {
    ok: true,
    stage: "sent",
    failure: null,
    ownerBound,
    finalRolloutCheck,
    send: invokeSendSafely(send, opts),
  };
}

function resolveSendTurnId(send) {
  const candidates = [
    send.response?.result?.result?.turn?.id,
    send.response?.result?.turn?.id,
    send.response?.result?.turnId,
  ];
  const presentCandidates = candidates.filter((value) => value !== null && value !== undefined);
  const invalidCandidateCount = presentCandidates.filter(
    (value) => typeof value !== "string" || !UUID_RE.test(value),
  ).length;
  const validIds = [
    ...new Set(
      candidates
        .filter((value) => typeof value === "string" && UUID_RE.test(value))
        .map((value) => value.toLowerCase()),
    ),
  ];
  if (invalidCandidateCount > 0) {
    return {
      status: "invalid",
      turnId: null,
      candidateCount: validIds.length,
      invalidCandidateCount,
    };
  }
  if (validIds.length === 1) {
    return {
      status: "resolved",
      turnId: validIds[0],
      candidateCount: 1,
      invalidCandidateCount: 0,
    };
  }
  return {
    status: validIds.length === 0 ? "missing" : "conflict",
    turnId: null,
    candidateCount: validIds.length,
    invalidCandidateCount: 0,
  };
}

function sendTurnIdDiagnostic(send, resolution) {
  if (send.ok && !isCertifiedSendOccurrence(send)) {
    if (send.sendOccurrence === "confirmed") {
      return "sent-but-unverified: IPC response success was not bound to exactly one target follower request";
    }
    return "send-outcome-unknown: IPC response success did not certify that one target follower request was emitted";
  }
  if (!send.ok) {
    if (send.sendOccurrence === "confirmed") {
      return "sent-but-unverified: the follower request was emitted, but the client did not report a successful response; rollout polling was not attempted";
    }
    return "send-outcome-unknown: the client result could not establish whether the follower request was emitted; rollout polling was not attempted";
  }
  if (resolution.status === "conflict") {
    return "sent-but-unverified: IPC send succeeded but the response contained conflicting valid turn ids";
  }
  if (resolution.status === "invalid") {
    return "sent-but-unverified: IPC send succeeded but a recognized response turn-id carrier was invalid";
  }
  return "sent-but-unverified: IPC send succeeded but the response did not contain a valid turn id";
}

function isCertifiedSendOccurrence(send) {
  return Boolean(
    send?.ok === true &&
    send.sendOccurrence === "confirmed" &&
    send.followerRequestCount === 1 &&
    send.matchingFollowerRequestCount === 1,
  );
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
  const sqliteEvidence =
    before.config?.exists === true &&
    after.config?.exists === true &&
    before.db?.exists === true &&
    after.db?.exists === true &&
    before.db?.readOnlyOpenOk === true &&
    after.db?.readOnlyOpenOk === true &&
    before.db?.quickCheck === "ok" &&
    after.db?.quickCheck === "ok";
  const beforeTarget = before.db?.threads?.target;
  const afterTarget = after.db?.threads?.target;
  const beforeSnapshotTargetId =
    typeof before.targetThreadId === "string" && UUID_RE.test(before.targetThreadId)
      ? before.targetThreadId.toLowerCase()
      : null;
  const afterSnapshotTargetId =
    typeof after.targetThreadId === "string" && UUID_RE.test(after.targetThreadId)
      ? after.targetThreadId.toLowerCase()
      : null;
  const snapshotTargetIdentityBound = Boolean(
    beforeSnapshotTargetId === opts.threadId && afterSnapshotTargetId === opts.threadId,
  );
  const targetStateBound =
    beforeTarget?.exists === true &&
    afterTarget?.exists === true &&
    beforeTarget.id?.toLowerCase?.() === opts.threadId.toLowerCase() &&
    afterTarget.id?.toLowerCase?.() === opts.threadId.toLowerCase() &&
    beforeTarget.archived === 0 &&
    afterTarget.archived === 0;
  const rolloutPathUnchanged =
    typeof beforeTarget?.rolloutPath === "string" &&
    typeof afterTarget?.rolloutPath === "string" &&
    pathIdentityKey(beforeTarget.rolloutPath) === pathIdentityKey(afterTarget.rolloutPath);

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
      threadDiff.identitiesValid &&
      stableEvidence &&
      sqliteEvidence &&
      snapshotTargetIdentityBound &&
      targetStateBound &&
      rolloutPathUnchanged &&
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
      snapshotPrerequisitesTrusted: sqliteEvidence,
      snapshotTargetIdentityBound,
      targetExistsBefore: beforeTarget?.exists === true,
      targetExistsAfter: afterTarget?.exists === true,
      targetOwnerAndArchiveStateBound: targetStateBound,
      rolloutPathUnchanged,
      threadHashMapsPresent: hashMapsPresent,
      threadHashIdentitiesValid: threadDiff.identitiesValid,
      invalidThreadHashIds: threadDiff.invalidIds,
      collidingThreadHashIds: threadDiff.collisionIds,
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
  const normalizedBefore = normalizeThreadHashMap(beforeHashes);
  const normalizedAfter = normalizeThreadHashMap(afterHashes);
  beforeHashes = normalizedBefore.hashes;
  afterHashes = normalizedAfter.hashes;
  const allowedIds = new Set(allowThreadChangeIds);
  const beforeIds = new Set(Object.keys(beforeHashes));
  const afterIds = new Set(Object.keys(afterHashes));
  const addedIds = [...afterIds].filter((id) => !beforeIds.has(id)).sort();
  const removedIds = [...beforeIds].filter((id) => !afterIds.has(id)).sort();
  const changedIds = [...beforeIds]
    .filter((id) => afterIds.has(id) && beforeHashes[id] !== afterHashes[id])
    .sort();
  return {
    identitiesValid: normalizedBefore.ok && normalizedAfter.ok,
    invalidIds: [...new Set([...normalizedBefore.invalidIds, ...normalizedAfter.invalidIds])].sort(),
    collisionIds: [...new Set([...normalizedBefore.collisionIds, ...normalizedAfter.collisionIds])].sort(),
    targetChanged: changedIds.includes(targetThreadId),
    allowedNonTargetChangedIds: changedIds.filter((id) => id !== targetThreadId && allowedIds.has(id)),
    unexpectedNonTargetChangedIds: changedIds.filter(
      (id) => id !== targetThreadId && !allowedIds.has(id),
    ),
    addedIds,
    removedIds,
  };
}

function normalizeThreadHashMap(hashes) {
  const normalized = {};
  const invalidIds = [];
  const collisionIds = [];
  for (const [rawId, hash] of Object.entries(hashes || {})) {
    if (!UUID_RE.test(rawId)) {
      invalidIds.push(rawId);
      continue;
    }
    const id = rawId.toLowerCase();
    if (Object.hasOwn(normalized, id)) {
      collisionIds.push(id);
      continue;
    }
    normalized[id] = hash;
  }
  return {
    ok: invalidIds.length === 0 && collisionIds.length === 0,
    hashes: normalized,
    invalidIds,
    collisionIds,
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

function postSendFailure(stage, error) {
  return {
    stage,
    message: error instanceof Error ? error.message : String(error),
  };
}

function hasBooleanOutcome(value) {
  return Boolean(
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    typeof value.ok === "boolean",
  );
}

function isTurnBoundPollProof(value, expectedTurnId) {
  const observed = value?.lastObservation;
  return Boolean(
    value?.ok === true &&
    observed &&
    typeof observed === "object" &&
    observed.expectedTurnId === expectedTurnId &&
    observed.proofTurnId === expectedTurnId &&
    observed.agentMarkerSeen === true &&
    observed.taskCompleteAfterAgentMarker === true,
  );
}

function isTrustedSnapshotCompare(value) {
  return Boolean(
    value?.ok === true &&
    value.config?.sha256Unchanged === true &&
    value.config?.selectedKeysUnchanged === true &&
    value.config?.stableDuringReads === true &&
    value.db?.snapshotPrerequisitesTrusted === true &&
    value.db?.snapshotTargetIdentityBound === true &&
    value.db?.stableDuringReads === true &&
    value.db?.targetOwnerAndArchiveStateBound === true &&
    value.db?.rolloutPathUnchanged === true &&
    value.db?.threadHashMapsPresent === true &&
    value.db?.threadHashIdentitiesValid === true &&
    value.db?.targetThreadChanged === true &&
    Array.isArray(value.db?.unexpectedNonTargetChangedIds) &&
    value.db.unexpectedNonTargetChangedIds.length === 0 &&
    Array.isArray(value.db?.addedIds) &&
    value.db.addedIds.length === 0 &&
    Array.isArray(value.db?.removedIds) &&
    value.db.removedIds.length === 0,
  );
}

export async function collectPostSendEvidence(
  opts,
  { send, rolloutPath, rolloutBaselineCursor, before },
  injected = {},
) {
  const poll = injected.pollRolloutForMarker || pollRolloutForMarker;
  const captureSnapshot = injected.snapshot || snapshot;
  const compare = injected.compareSnapshots || compareSnapshots;
  const normalizedSend = send || {
    ok: false,
    response: null,
    sendOccurrence: "unknown",
    error: "send result was missing after invocation began",
  };
  const turnIdResolution = resolveSendTurnId(normalizedSend);
  const sendTurnId = turnIdResolution.turnId;
  const sendCertified = isCertifiedSendOccurrence(normalizedSend);
  const postSendFailures = [];
  let rolloutProbe;
  if (sendCertified && turnIdResolution.status === "resolved") {
    try {
      rolloutProbe = await poll(
        rolloutPath,
        opts.marker,
        opts.pollMs,
        opts.pollAttempts,
        {
          cursor: rolloutBaselineCursor,
          expectedTurnId: sendTurnId,
          expectedThreadId: opts.threadId,
        },
      );
    } catch (error) {
      postSendFailures.push(postSendFailure("rollout-poll", error));
      rolloutProbe = {
        ok: false,
        attempts: 0,
        rolloutPath,
        markerSha256: sha256(opts.marker),
        diagnostics: ["post-send-rollout-poll-error"],
        warnings: ["The follower request may have been emitted. Negative bounded inspection cannot authorize a retry; require exact full-history non-admission or an explicit owner decision acknowledging duplicate-send risk."],
      };
    }
    if (!hasBooleanOutcome(rolloutProbe)) {
      postSendFailures.push(postSendFailure(
        "rollout-poll-result",
        new Error("rollout poll returned no structured boolean outcome"),
      ));
      rolloutProbe = {
        ok: false,
        attempts: 0,
        rolloutPath,
        markerSha256: sha256(opts.marker),
        diagnostics: ["post-send-rollout-poll-result-invalid"],
        warnings: ["The follower request may have been emitted. Negative bounded inspection cannot authorize a retry; require exact full-history non-admission or an explicit owner decision acknowledging duplicate-send risk."],
      };
    } else if (rolloutProbe.ok === true && !isTurnBoundPollProof(rolloutProbe, sendTurnId)) {
      postSendFailures.push(postSendFailure(
        "rollout-poll-result",
        new Error("rollout poll success was not bound to the returned turn and terminal marker proof"),
      ));
      rolloutProbe = {
        ...rolloutProbe,
        ok: false,
        diagnostics: [
          ...(Array.isArray(rolloutProbe.diagnostics) ? rolloutProbe.diagnostics : []),
          "post-send-rollout-proof-incomplete",
        ],
        warnings: ["The follower request may have been emitted. Negative bounded inspection cannot authorize a retry; require exact full-history non-admission or an explicit owner decision acknowledging duplicate-send risk."],
      };
    }
  } else {
    rolloutProbe = {
      ok: false,
      attempts: 0,
      rolloutPath,
      markerSha256: sha256(opts.marker),
      diagnostics: [sendTurnIdDiagnostic(normalizedSend, turnIdResolution)],
    };
  }

  let after = null;
  let snapshotCompare = {
    ok: false,
    reason: "post-send-snapshot-unavailable",
    warnings: ["Post-send isolation evidence was not available."],
  };
  try {
    after = await captureSnapshot(opts);
  } catch (error) {
    postSendFailures.push(postSendFailure("after-snapshot", error));
  }
  if (after) {
    try {
      snapshotCompare = await compare(before, after, opts);
    } catch (error) {
      postSendFailures.push(postSendFailure("snapshot-compare", error));
      snapshotCompare = {
        ok: false,
        reason: "post-send-compare-failed",
        warnings: ["Post-send isolation evidence could not be compared."],
      };
    }
    if (!hasBooleanOutcome(snapshotCompare)) {
      postSendFailures.push(postSendFailure(
        "snapshot-compare-result",
        new Error("snapshot compare returned no structured boolean outcome"),
      ));
      snapshotCompare = {
        ok: false,
        reason: "post-send-compare-result-invalid",
        warnings: ["Post-send isolation evidence returned an invalid comparison result."],
      };
    } else if (snapshotCompare.ok === true && !isTrustedSnapshotCompare(snapshotCompare)) {
      postSendFailures.push(postSendFailure(
        "snapshot-compare-result",
        new Error("snapshot compare success omitted required isolation evidence"),
      ));
      snapshotCompare = {
        ...snapshotCompare,
        ok: false,
        reason: "post-send-compare-proof-incomplete",
        warnings: ["Post-send isolation evidence omitted required proof fields."],
      };
    }
  }

  const ok =
    sendCertified &&
    rolloutProbe.ok === true &&
    snapshotCompare.ok === true &&
    postSendFailures.length === 0;
  const verificationStatus = ok
    ? "turn-bound"
    : normalizedSend.sendOccurrence === "confirmed"
      ? "sent-but-unverified"
      : "send-outcome-unknown";
  return {
    ok,
    send: normalizedSend,
    sendTurnId,
    turnIdResolution,
    verificationStatus,
    retrySafe: false,
    rolloutProbe,
    after,
    compare: snapshotCompare,
    postSendFailures,
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

  const rolloutPath = inspect.summary.rolloutPath;
  const rolloutBinding =
    typeof rolloutPath === "string" && rolloutPath.length > 0
      ? locateRollout({ threadId: opts.threadId, rolloutPath })
      : { status: "unavailable", reason: "no-candidate", authority: "explicit" };
  if (rolloutBinding.status !== "found") {
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
          failures: ["rollout baseline path could not be bound to the target identity before send"],
          rolloutBinding: {
            status: rolloutBinding.status,
            reason: rolloutBinding.reason || null,
            authority: rolloutBinding.authority || null,
          },
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }
  const rolloutBaselineActivity = readRolloutActivity(rolloutBinding.path, {
    retainRecords: false,
    rolloutThreadId: opts.threadId,
    expectedIdentityKey: rolloutBinding.candidates?.[0]?.identityKey,
  });
  const rolloutBaseline = rolloutBaselineActivity.parsed;
  const before = snapshot(opts);
  const preSendState = validatePreSendSnapshot(opts, before);
  if (!preSendState.ok) {
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
          before: summarizeSnapshot(before),
          failures: ["fresh pre-send snapshot was not stable, owner-bound, active, and rollout-bound"],
          preSendState,
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }
  const authorizedSend = authorizeBaselineAndSend(opts, rolloutBaselineActivity, before);
  if (!authorizedSend.ok && authorizedSend.stage === "baseline-integrity") {
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
          revalidationSummary: {
            ok: revalidation.ok,
            revalidationLevel: revalidation.revalidationLevel,
          },
          before: summarizeSnapshot(before),
          failures: [authorizedSend.failure],
          rolloutBaseline: {
            ok: rolloutBaseline.ok,
            reason: rolloutBaseline.reason || null,
            partialTail: rolloutBaseline.partialTail,
            ownerBound: authorizedSend.ownerBound,
          },
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  if (!authorizedSend.ok && authorizedSend.stage === "baseline-activity") {
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
          before: summarizeSnapshot(before),
          failures: [authorizedSend.failure],
          rolloutBaselineActivity: {
            turnActivity: rolloutBaselineActivity.turnActivity,
          },
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  if (!authorizedSend.ok) {
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
          before: summarizeSnapshot(before),
          failures: [authorizedSend.failure || "pre-send authorization failed"],
          authorizationStage: authorizedSend.stage,
          finalRolloutCheck: authorizedSend.finalRolloutCheck || null,
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  const postSend = await collectPostSendEvidence(opts, {
    send: authorizedSend.send,
    rolloutPath,
    rolloutBaselineCursor: rolloutBaseline.cursor,
    before,
  });
  const send = postSend.send;
  const ok = postSend.ok;
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
      occurrence: send.sendOccurrence,
      commandStatus: send.commandStatus,
      commandSignal: send.commandSignal,
      error: send.error,
      followerRequestCount: send.followerRequestCount ?? null,
      matchingFollowerRequestCount: send.matchingFollowerRequestCount ?? null,
      responseType: send.response?.resultType || null,
      responseError: send.response?.error ?? null,
      handledByClientId: send.response?.handledByClientId || null,
      turnId: postSend.sendTurnId,
      turnIdResolution: {
        status: postSend.turnIdResolution.status,
        candidateCount: postSend.turnIdResolution.candidateCount,
        invalidCandidateCount: postSend.turnIdResolution.invalidCandidateCount,
      },
      verificationStatus: postSend.verificationStatus,
      retrySafe: postSend.retrySafe,
    },
    rolloutProbe: postSend.rolloutProbe,
    after: postSend.after ? summarizeSnapshot(postSend.after) : null,
    compare: postSend.compare,
    postSendFailures: postSend.postSendFailures,
    warnings: [
      "This proof starts a real Codex model turn only when --send is present.",
      "No config writes, SQLite writes, or proof artifact writes are performed by this harness.",
      ...(!ok
        ? [
            `${postSend.verificationStatus}: the IPC send cannot be safely retried without first inspecting the target thread.`,
          ]
        : []),
    ],
  };

  console.log(JSON.stringify(result, null, 2));
  if (!ok) {
    process.exit(1);
  }
}

function isMainModule() {
  const entry = process.argv[1];
  if (!entry || entry === "-") return false;
  // Node keeps consumed eval code in execArgv, but excludes the script entry.
  // A print flag followed by another option can still launch a file normally.
  const args = process.execArgv;
  if (args.some((arg, index) => {
    if (arg === "-e" || arg === "-pe" || arg === "--eval" || arg.startsWith("--eval=")) return true;
    const print = arg === "-p" || arg === "--print" || arg.startsWith("--print=");
    const code = args[index + 1];
    return print && typeof code === "string" && code.length > 0 && !code.startsWith("-");
  })) return false;
  const moduleUrl = new URL(import.meta.url);
  if (moduleUrl.search || moduleUrl.hash) return false;
  return path.toNamespacedPath(realpathSync.native(path.resolve(entry))) ===
    path.toNamespacedPath(realpathSync.native(moduleUrl));
}

let runAsMain = false;
try {
  runAsMain = isMainModule();
} catch {
  console.error("ERROR: entrypoint-resolution-failed");
  process.exitCode = 1;
}
if (runAsMain) {
  await main();
}
