#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { realpathSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  assessRolloutPageSupersession,
  createDispatchCorrelator,
  DEFAULT_MAX_RECORD_BYTES,
  inspectRolloutNoGrowth,
  isCompleteReaderCursor,
  locateRollout,
  normalizeRolloutCliPath,
  readRolloutFile,
  ROLLOUT_PATH_GUIDANCE,
  rolloutDiagnosticLines,
  rolloutPageGuidance,
} from "./codex_ipc_rollout_reader.mjs";
import { materializeDispatch } from "./codex_ipc_reply_harvest.mjs";

export const DEFAULT_WAIT_BUDGET_MS = 0;
export const DEFAULT_WAIT_INTERVAL_MS = 250;
// --queue-id: how long a queued item may sit before the waiter says it has not started. The
// runtime's queue service polls loaded threads about every 10 s, so a healthy idle thread starts
// the item well inside this window.
export const QUEUE_NOT_STARTED_GRACE_MS = 30000;
// --queue-id wake (on by default from the CLI, --no-wake opts out): an item still queued this long
// after it was queued is likely on a thread the App has not loaded, so the waiter asks the running
// App to load it once (codex_ipc_wake.ps1), then reports wake-no-effect if the item is still
// queued this long after the wake.
export const QUEUE_WAKE_AFTER_MS = 12000;
export const QUEUE_WAKE_NO_EFFECT_MS = 15000;
// The helper waits up to 15 s for its launch to exit; past this the waiter stops waiting for it
// (it never kills it) and reports helper-timeout.
export const QUEUE_WAKE_HELPER_TIMEOUT_MS = 60000;
const WAKE_RESULTS = new Set(["forwarded", "dry-run", "refused", "unverified"]);
const WAKE_TOKEN_RE = /^[a-z][a-z0-9-]{1,63}$/;
export const WAIT_TOKENS = Object.freeze([
  "done",
  "aborted",
  "superseded",
  "reply-missing",
  "pending",
  "unavailable",
]);

// A6 (D4): opt-in --status-exit-codes maps each determination token to a frozen exit code. Usage
// errors stay exit 1 with no token (handled before this map is consulted). Flagless mode never
// consults this map — every determination exits 0, byte-identically to prior releases.
export const STATUS_EXIT_CODES = Object.freeze({
  done: 0,
  pending: 2,
  aborted: 3,
  superseded: 4,
  "reply-missing": 5,
  unavailable: 6,
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Wait's dispatch lifecycle is a thin projection over the ONE shared boundary machine: it drives
// createDispatchCorrelator over the already-located, integrity-validated in-memory record snapshot
// and reads the correlator's `.lifecycle` (status/diagnostics/certifiable). It reimplements no
// start/terminal/id/supersession rule — the removed classifyDispatch was that duplicate machine.
function dispatchLifecycle(records, parserDiagnostics, dispatchId) {
  const correlator = createDispatchCorrelator(dispatchId);
  for (const record of records) correlator.push(record);
  const correlated = correlator.finish({ ok: true, diagnostics: parserDiagnostics });
  const duplicateCount = correlated.duplicateCount || 0;
  const diagnostics = [...(correlated.lifecycle?.diagnostics || [])];
  if (duplicateCount > 1) {
    diagnostics.push({
      code: "dispatch-id-reused",
      duplicateCount,
      message: "distinct dispatch occurrences share one reply-file identity",
    });
  }
  return {
    ...correlated.lifecycle,
    diagnostics,
    duplicateCount,
    latestOccurrence: correlated.latestOccurrence || null,
    freshness: correlated.freshness || null,
  };
}

function replyPathResolution(options) {
  if (options.replyPath) {
    return { status: "resolved", authority: "explicit", path: options.replyPath, diagnostics: [] };
  }
  if (options.sessionId) {
    return {
      status: "resolved",
      authority: "session",
      path: path.join(
        options.transportRoot,
        options.sessionId,
        options.threadId,
        `${options.dispatchId}.reply.md`,
      ),
      diagnostics: [],
    };
  }

  let sessions;
  try {
    sessions = fs.readdirSync(options.transportRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { status: "missing", authority: "scan", paths: [], diagnostics: [] };
    }
    return {
      status: "unavailable",
      authority: "scan",
      paths: [],
      diagnostics: [{ code: "reply-scan-error", path: options.transportRoot, message: error.message }],
    };
  }

  const paths = [];
  for (const entry of sessions.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
    const candidate = path.join(
      options.transportRoot,
      entry.name,
      options.threadId,
      `${options.dispatchId}.reply.md`,
    );
    try {
      fs.lstatSync(candidate);
      paths.push(candidate);
    } catch (error) {
      if (error?.code !== "ENOENT" && error?.code !== "ENOTDIR") {
        return {
          status: "unavailable",
          authority: "scan",
          paths,
          diagnostics: [{ code: "reply-scan-error", path: candidate, message: error.message }],
        };
      }
    }
  }
  if (paths.length > 1) {
    return {
      status: "ambiguous",
      authority: "scan",
      paths,
      diagnostics: [{ code: "reply-path-ambiguous", paths }],
    };
  }
  if (paths.length === 0) {
    return { status: "missing", authority: "scan", paths, diagnostics: [] };
  }
  return { status: "resolved", authority: "scan", path: paths[0], paths, diagnostics: [] };
}

function sameFileIdentity(left, right) {
  if (typeof left?.ino !== "bigint" || typeof right?.ino !== "bigint") return true;
  if (left.ino === 0n || right.ino === 0n) return true;
  return left.ino === right.ino && left.dev === right.dev;
}

function inspectReply(filePath) {
  if (!filePath) return { valid: false, present: false, diagnostics: [] };
  let stat;
  try {
    stat = fs.lstatSync(filePath, { bigint: true });
  } catch (error) {
    if (error?.code === "ENOENT" || error?.code === "ENOTDIR") {
      return { valid: false, present: false, diagnostics: [] };
    }
    return {
      valid: false,
      present: true,
      diagnostics: [{ code: "reply-unreadable", path: filePath, message: error.message }],
    };
  }
  if (stat.isSymbolicLink()) {
    return {
      valid: false,
      present: true,
      diagnostics: [{ code: "reply-symlink", path: filePath }],
    };
  }
  if (!stat.isFile()) {
    return {
      valid: false,
      present: true,
      diagnostics: [{ code: "reply-not-regular", path: filePath }],
    };
  }

  let descriptor;
  try {
    // O_NOFOLLOW is undefined on win32, so open-time symlink refusal is a no-op there. The
    // lstat pre-check above and the post-open identity comparison below are what actually
    // enforce "regular, non-symlink" on every platform.
    descriptor = fs.openSync(
      filePath,
      fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0),
    );
    const openedStat = fs.fstatSync(descriptor, { bigint: true });
    const finalStat = fs.lstatSync(filePath, { bigint: true });
    if (
      !openedStat.isFile() ||
      finalStat.isSymbolicLink() ||
      !finalStat.isFile() ||
      !sameFileIdentity(stat, openedStat) ||
      !sameFileIdentity(openedStat, finalStat)
    ) {
      return {
        valid: false,
        present: true,
        diagnostics: [{ code: "reply-changed", path: filePath }],
      };
    }
    return { valid: true, present: true, diagnostics: [] };
  } catch (error) {
    return {
      valid: false,
      present: true,
      diagnostics: [{ code: "reply-unreadable", path: filePath, message: error.message }],
    };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function appendFreshnessDiagnostics(diagnostics, lifecycle) {
  if (lifecycle.latestOccurrence?.settled === false) {
    diagnostics.push({
      code: "dispatch-mixed-state",
      latestStatus: lifecycle.latestOccurrence.status || "unavailable",
      latestTurnId: lifecycle.latestOccurrence.turnId || null,
    });
  }
  diagnostics.push({
    code: "dispatch-freshness-unsettled",
    status: lifecycle.freshness?.status || "unavailable",
    reason: lifecycle.freshness?.reason || "unavailable",
    boundaryLine: lifecycle.freshness?.boundaryLine ?? null,
  });
  diagnostics.push(...(lifecycle.freshness?.diagnostics || []));
}

function resolveCompletion(lifecycle, options) {
  if (lifecycle.status === "unavailable") {
    return { token: "unavailable", diagnostics: lifecycle.diagnostics };
  }

  const resolution = replyPathResolution(options);
  const diagnostics = [...lifecycle.diagnostics, ...(resolution.diagnostics || [])];
  const reply = resolution.status === "resolved"
    ? inspectReply(resolution.path)
    : { valid: false, present: (resolution.paths || []).length > 0, diagnostics: [] };
  diagnostics.push(...reply.diagnostics);

  if (lifecycle.duplicateCount > 1) {
    if (reply.present) {
      diagnostics.push({
        code: "reply-unverified",
        message: "reply exists but its dispatch id identifies multiple distinct occurrences",
      });
    }
    return { token: "unavailable", diagnostics };
  }

  if (lifecycle.status === "aborted") {
    if (reply.present) {
      diagnostics.push({
        code: "reply-unverified",
        message: "reply exists but the dispatch turn was aborted",
      });
    }
    return { token: "aborted", diagnostics };
  }
  if (lifecycle.status === "superseded") {
    return { token: "superseded", diagnostics };
  }
  if (lifecycle.status === "pending") {
    if (resolution.status === "ambiguous" || resolution.status === "unavailable") {
      return { token: "unavailable", diagnostics };
    }
    return { token: "pending", diagnostics: lifecycle.diagnostics };
  }
  // lifecycle.status === "complete": the dispatch's own turn reached task_complete un-superseded.
  if (resolution.status === "ambiguous" || resolution.status === "unavailable") {
    return { token: "unavailable", diagnostics };
  }
  if (reply.valid) {
    // Reply-file selection cannot override a newer noncomplete exact occurrence or an opaque
    // post-occurrence schema tail. Preserve the historical reply as evidence, but keep the
    // machine token non-success while current-occurrence completion is unresolved.
    const latestStatus = lifecycle.latestOccurrence?.status || null;
    const status =
      latestStatus && latestStatus !== "complete"
        ? (WAIT_TOKENS.includes(latestStatus) ? latestStatus : "unavailable")
        : lifecycle.freshness?.reason === "post-occurrence-schema-unknown"
          ? "unavailable"
          : null;
    if (status) {
      appendFreshnessDiagnostics(diagnostics, lifecycle);
      diagnostics.push({
        code: "reply-unverified",
        message: "reply exists but the latest exact dispatch occurrence is unsettled",
      });
      return { token: status, diagnostics };
    }
    // In a settled lifecycle, a readable regular file (including a zero-byte one) is primary.
    return { token: "done", replySource: "reply-file", diagnostics };
  }
  // A present-but-invalid reply (symlink, non-regular, unreadable, changed) never falls through to
  // the rollout fallback; only a genuinely-absent reply is fallback-eligible.
  if (reply.present) {
    return { token: "reply-missing", diagnostics };
  }
  // Reply genuinely absent. Under the D2 opt-in, a same-snapshot verified body certifies done from
  // the rollout store; flagless v0.1.6 stays file-primary. Absent/empty/mismatched body stays
  // reply-missing. The recovered body is NEVER emitted.
  if (options.acceptRolloutFallback && lifecycle.certifiable) {
    if (lifecycle.freshness?.settled === false) {
      const status = lifecycle.freshness.status === "pending" ? "pending" : "unavailable";
      appendFreshnessDiagnostics(diagnostics, lifecycle);
      return { token: status, diagnostics };
    }
    return { token: "done", replySource: "rollout-fallback", diagnostics };
  }
  return { token: "reply-missing", diagnostics };
}

// The queue store is read through codex_ipc_queue.mjs, loaded on first use, so this module stays
// SQLite-free and an ordinary wait (no --queue-id) never opens the queue store.
async function loadQueueReader() {
  const { readQueuedItem } = await import(new URL("./codex_ipc_queue.mjs", import.meta.url));
  return readQueuedItem;
}

// The intended host kind the wake would use, resolved like the shared host policy (flag, then
// CODEX_IPC_INTENDED_HOST, then <transport root>/host-policy.json, then package). Only an alternate
// host may be woken; this pre-check keeps the helper from even starting for a package host, and
// the helper re-validates everything itself.
export function resolveWakeHostKind(options, env = process.env, fsImpl = fs) {
  const classify = (value, source) => {
    if (typeof value !== "string" || value.trim() === "") return { kind: "invalid", source };
    return { kind: value === "package" ? "package" : "alternate", source };
  };
  if (options.intendedHost) return classify(options.intendedHost, "flag");
  if (env.CODEX_IPC_INTENDED_HOST !== undefined) {
    return classify(env.CODEX_IPC_INTENDED_HOST, "environment");
  }
  let text;
  try {
    text = fsImpl.readFileSync(path.join(options.transportRoot, "host-policy.json"), "utf8");
  } catch (error) {
    return error?.code === "ENOENT"
      ? { kind: "package", source: "default" }
      : { kind: "invalid", source: "descriptor" };
  }
  let value;
  try {
    value = JSON.parse(text.replace(/^\uFEFF/u, ""));
  } catch {
    return { kind: "invalid", source: "descriptor" };
  }
  if (value?.intendedHost === undefined) return { kind: "package", source: "default" };
  const kind = value.intendedHost?.kind;
  return kind === "package" || kind === "alternate"
    ? { kind, source: "descriptor" }
    : { kind: "invalid", source: "descriptor" };
}

// The helper's one JSON line, reduced to tokens and PIDs; paths are never carried forward.
export function parseWakeOutput(stdout, exitStatus) {
  const lines = String(stdout || "").split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
  let value = null;
  try {
    value = JSON.parse(lines[lines.length - 1] || "");
  } catch {
    value = null;
  }
  const pid = (item) => (Number.isSafeInteger(item) && item > 0 ? item : null);
  if (value?.schemaVersion !== 1 || value?.tool !== "codex_ipc_wake" ||
      !WAKE_RESULTS.has(value?.result) || typeof value?.code !== "string" ||
      !WAKE_TOKEN_RE.test(value.code)) {
    return { result: null, wakeCode: "helper-output-invalid", launched: false, exitStatus };
  }
  return {
    result: value.result,
    wakeCode: value.code,
    reasons: Array.isArray(value.reasons)
      ? value.reasons.filter((item) => typeof item === "string" && WAKE_TOKEN_RE.test(item))
      : [],
    launched: value.launched === true,
    rootPid: pid(value.rootPid),
    rootPidAfter: pid(value.rootPidAfter),
    helperPid: pid(value.helperPid),
    helperExitCode: Number.isSafeInteger(value.helperExitCode) ? value.helperExitCode : null,
    exitStatus,
  };
}

// Runs codex_ipc_wake.ps1 once, the way the toolkit runs its other PowerShell helpers. It never
// kills the helper: past the timeout the waiter stops waiting and reports helper-timeout.
function runWakeHelper(request) {
  return new Promise((resolve) => {
    const helper = fileURLToPath(new URL("./codex_ipc_wake.ps1", import.meta.url));
    const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", helper,
      "-ThreadId", request.threadId, "-IpcRoot", request.ipcRoot];
    if (request.intendedHost) args.push("-IntendedHost", request.intendedHost);
    let child = null;
    let stdout = "";
    let finished = false;
    let timer = null;
    let exitTimer = null;
    const finish = (outcome) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      clearTimeout(exitTimer);
      child?.stdout?.destroy();
      child?.unref();
      resolve(outcome);
    };
    try {
      child = spawn("powershell.exe", args, { stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
    } catch {
      finish({ result: null, wakeCode: "helper-unavailable", launched: false, exitStatus: null });
      return;
    }
    timer = setTimeout(() => finish({
      result: null, wakeCode: "helper-timeout", launched: false, exitStatus: null,
    }), request.timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      if (stdout.length < 65536) stdout += chunk;
    });
    child.on("error", () => finish({
      result: null, wakeCode: "helper-unavailable", launched: false, exitStatus: null,
    }));
    child.on("close", (status) => finish(parseWakeOutput(stdout, status)));
    // A process the helper launched could hold the pipe open; the helper's own exit is enough.
    child.on("exit", (status) => {
      exitTimer = setTimeout(() => finish(parseWakeOutput(stdout, status)), 2000);
    });
  });
}

// --queue-id (opt-in): non-terminal diagnostics for a dispatch delivered with --deliver queue.
// They never change the determination token or exit code. Each is reported at most once:
//   queued-not-started       the item is still queued after the grace period and no rollout turn
//                            carries this dispatch (the thread may be busy, not loaded in the App,
//                            or its last turn was interrupted; the item runs when it next idles)
//   queue-check-unavailable  the queue store could not be read
//   queue-item-thread-mismatch  the queued item belongs to another thread
// With the wake on (options.wake, a polling wait), an item still queued QUEUE_WAKE_AFTER_MS after
// it was queued, with no turn carrying the dispatch, gets one wake: wake-skipped (not Windows, or
// not an alternate host: the helper never runs), or wake-attempted then wake-result with the
// helper's code. A launched wake whose item is still queued QUEUE_WAKE_NO_EFFECT_MS later reports
// wake-no-effect. An item that is gone was started (or removed in the App); the rollout decides
// the rest.
function createQueueCheck(options, injected, now, report, budgetMs) {
  if (!options.queueItemId) return null;
  const graceMs = Number.isSafeInteger(options.queueGraceMs) && options.queueGraceMs >= 0
    ? options.queueGraceMs
    : QUEUE_NOT_STARTED_GRACE_MS;
  const wakeAfterMs = Number.isSafeInteger(options.wakeAfterMs) && options.wakeAfterMs >= 0
    ? options.wakeAfterMs
    : QUEUE_WAKE_AFTER_MS;
  const noEffectMs = Number.isSafeInteger(options.wakeNoEffectMs) && options.wakeNoEffectMs >= 0
    ? options.wakeNoEffectMs
    : QUEUE_WAKE_NO_EFFECT_MS;
  const queueId = options.queueItemId;
  // A single-shot wait (budget 0) is a status read; it never wakes.
  let wakeState = options.wake === true && budgetMs > 0 ? "pending" : "off";
  let wakeLaunched = false;
  let wakeDoneAt = null;
  let noEffectReported = false;
  let notStartedReported = false;
  let settled = false;
  let firstSeenAt = null;
  const wake = async (ageMs) => {
    wakeState = "done";
    const platform = injected.platform || process.platform;
    if (platform !== "win32") {
      report({ code: "wake-skipped", queueId, reason: "not-windows" });
      return;
    }
    const host = resolveWakeHostKind(options, injected.env || process.env);
    if (host.kind !== "alternate") {
      report({
        code: "wake-skipped",
        queueId,
        reason: host.kind === "package" ? "host-package" : "host-policy-invalid",
        source: host.source,
      });
      return;
    }
    report({ code: "wake-attempted", queueId, threadId: options.threadId, ageMs });
    let outcome;
    try {
      outcome = await (injected.runWake || runWakeHelper)({
        threadId: options.threadId,
        ipcRoot: options.transportRoot,
        intendedHost: options.intendedHost || null,
        timeoutMs: QUEUE_WAKE_HELPER_TIMEOUT_MS,
      });
    } catch {
      outcome = { result: null, wakeCode: "helper-error", launched: false, exitStatus: null };
    }
    wakeDoneAt = now();
    wakeLaunched = outcome?.launched === true;
    report({ code: "wake-result", queueId, ...outcome });
  };
  return async (records) => {
    if (settled) return;
    let item;
    try {
      const read = injected.readQueuedItem || await loadQueueReader();
      item = await read({ dbPath: options.queueDbPath, queueId });
    } catch (error) {
      item = { status: "unavailable", reason: "queue-check-error", message: error?.message };
    }
    if (item?.status === "absent") {
      settled = true;
      return;
    }
    if (item?.status !== "present") {
      settled = true;
      report({ code: "queue-check-unavailable", queueId, reason: item?.reason || "unknown" });
      return;
    }
    if (item.threadId !== options.threadId) {
      settled = true;
      report({ code: "queue-item-thread-mismatch", queueId, threadId: item.threadId });
      return;
    }
    if (firstSeenAt === null) firstSeenAt = now();
    const since = Number.isSafeInteger(item.createdAtMs) ? item.createdAtMs : firstSeenAt;
    const ageMs = Math.max(0, now() - since);
    const wakeDue = wakeState === "pending" && ageMs >= wakeAfterMs;
    const noEffectDue = wakeState === "done" && wakeLaunched && !noEffectReported &&
      now() - wakeDoneAt >= noEffectMs;
    const notStartedDue = !notStartedReported && ageMs >= graceMs;
    if (!wakeDue && !noEffectDue && !notStartedDue) return;
    // Between the turn start and the item's deletion a turn may already carry the dispatch.
    if (dispatchLifecycle(records, [], options.dispatchId).duplicateCount > 0) return;
    if (wakeDue) {
      // Once: the state leaves "pending" before the helper runs. The next poll re-reads the item.
      await wake(ageMs);
      return;
    }
    if (noEffectDue) {
      noEffectReported = true;
      report({
        code: "wake-no-effect",
        queueId,
        threadId: options.threadId,
        sinceWakeMs: Math.max(0, now() - wakeDoneAt),
        possibleCauses: ["last-turn-interrupted", "thread-owned-by-another-writer", "app-not-ready"],
      });
    }
    if (notStartedDue) {
      notStartedReported = true;
      report({
        code: "queued-not-started",
        queueId,
        threadId: options.threadId,
        ageMs,
        possibleCauses: ["thread-busy", "thread-not-loaded", "last-turn-interrupted"],
      });
    }
    if (notStartedReported && wakeState !== "pending" && (noEffectReported || !wakeLaunched)) {
      settled = true;
    }
  };
}

export async function waitForCompletion(options, injected = {}) {
  const now = injected.now || Date.now;
  const sleep = injected.sleep || defaultSleep;
  const readRollout = injected.readRolloutFile || readRolloutFile;
  const inspectNoGrowth = injected.inspectRolloutNoGrowth || inspectRolloutNoGrowth;
  const assessPage = injected.assessRolloutPageSupersession || assessRolloutPageSupersession;
  const budgetMs = Number.isSafeInteger(options.budgetMs) && options.budgetMs >= 0
    ? options.budgetMs
    : DEFAULT_WAIT_BUDGET_MS;
  const intervalMs = Number.isSafeInteger(options.intervalMs) && options.intervalMs > 0
    ? options.intervalMs
    : DEFAULT_WAIT_INTERVAL_MS;
  const startedAt = now();
  const deadlineAt = budgetMs > 0 ? startedAt + budgetMs : Number.POSITIVE_INFINITY;
  const maxIterations = budgetMs > 0 ? Math.ceil(budgetMs / intervalMs) + 1 : 1;
  const records = [];
  const diagnostics = [];
  let candidatePath = null;
  let candidateIdentityKey = null;
  let cursor = null;
  let readableCandidate = false;
  let lastLocation = null;
  // A read that only ran out of budget is not an authority failure: the candidate exists and is
  // parseable, we simply did not finish observing it. That is `pending`, never `unavailable`.
  let deadlineOnlyReadFailure = false;
  let readerAtCompleteEof = false;
  let pageGuidanceRecorded = false;
  const queueCheck = createQueueCheck(options, injected, now, (item) => {
    diagnostics.push(item);
    if (typeof injected.onDiagnostic === "function") injected.onDiagnostic(item);
  }, budgetMs);

  let staleSnapshotRecorded = false;
  // "current" may certify; "stale" (the page grew after this read) keeps polling and never
  // certifies; anything else is terminal.
  const pageStatus = (lifecycle) => {
    if (!candidatePath || !cursor) return "unproven";
    const assessment = assessPage({
      threadId: options.threadId,
      rolloutPath: candidatePath,
      sessionsRoot: options.sessionsRoot,
      expectedIdentityKey: candidateIdentityKey,
      expectedSize: cursor.size,
      dispatchMarkerByteOffset: lifecycle?.latestOccurrence?.markerByteOffset ?? null,
      deadlineAt,
      now,
    });
    if (assessment.status === "stale") {
      if (!staleSnapshotRecorded) diagnostics.push(...(assessment.diagnostics || []));
      staleSnapshotRecorded = true;
      return "stale";
    }
    diagnostics.push(...(assessment.diagnostics || []));
    return assessment.status === "current" ? "current" : "unproven";
  };

  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    const iterationStartedAt = iteration === 0 ? startedAt : now();
    if (iteration > 0 && iterationStartedAt - startedAt >= budgetMs) break;
    if (!candidatePath) {
      lastLocation = locateRollout({
        threadId: options.threadId,
        rolloutPath: options.rolloutPath,
        sessionsRoot: options.sessionsRoot,
        deadlineAt,
        now,
      });
      diagnostics.push(...(lastLocation.diagnostics || []));
      if (!pageGuidanceRecorded) {
        diagnostics.push(...rolloutPageGuidance(lastLocation, options.rolloutPath));
        pageGuidanceRecorded = true;
      }
      if (lastLocation.status === "ambiguous") {
        return { token: "unavailable", diagnostics };
      }
      if (lastLocation.status === "found") {
        candidatePath = lastLocation.path;
        candidateIdentityKey = lastLocation.candidates?.[0]?.identityKey || null;
      }
    }

    if (candidatePath) {
      const forceCertifyingRead =
        !cursor ||
        budgetMs === 0 ||
        iteration + 1 >= maxIterations ||
        iterationStartedAt + intervalMs >= deadlineAt;
      const unchangedWithoutCertification =
        cursor &&
        !forceCertifyingRead &&
        inspectNoGrowth(candidatePath, cursor).unchanged;
      if (unchangedWithoutCertification) {
        const lifecycle = dispatchLifecycle(records, diagnostics, options.dispatchId);
        if (pageStatus(lifecycle) === "unproven") return { token: "unavailable", diagnostics };
      } else {
        const parsed = readRollout(candidatePath, {
          ...(cursor ? { cursor } : {}),
          rolloutThreadId: options.threadId,
          ...(candidateIdentityKey ? { expectedIdentityKey: candidateIdentityKey } : {}),
          maxRecordBytes: options.maxRecordBytes ?? DEFAULT_MAX_RECORD_BYTES,
          deadlineAt,
          now,
        });
        diagnostics.push(...(parsed.diagnostics || []));
        if (!parsed.ok) {
          readerAtCompleteEof = false;
          if (parsed.reason !== "deadline-exceeded") {
            return { token: "unavailable", diagnostics };
          }
          deadlineOnlyReadFailure = true;
          break;
        } else {
          records.push(...(parsed.records || []));
          readableCandidate = true;
          cursor = parsed.cursor;
          readerAtCompleteEof = isCompleteReaderCursor(parsed.cursor);
          if (!readerAtCompleteEof) {
            diagnostics.push({ code: "rollout-read-not-at-eof" });
          }
        }

        if (readerAtCompleteEof) {
          const lifecycle = dispatchLifecycle(records, diagnostics, options.dispatchId);
          const page = pageStatus(lifecycle);
          if (page === "unproven") return { token: "unavailable", diagnostics };
          const resolved = page === "current"
            ? resolveCompletion(lifecycle, options)
            : { token: "pending", diagnostics: [] };
          if (resolved.token !== "pending") {
            return {
              token: resolved.token,
              diagnostics: [...diagnostics, ...resolved.diagnostics],
              replySource: resolved.replySource,
            };
          }
        }
      }
    }

    if (queueCheck) await queueCheck(records);

    if (budgetMs === 0) break;
    const elapsed = now() - startedAt;
    if (elapsed >= budgetMs || iteration + 1 >= maxIterations) break;
    // A sleep opens a new observation interval. Do not combine the prior EOF-certified
    // lifecycle with a reply file that appears while sleeping if the clock overshoots the
    // next forced read; only a later full rollout read may restore certification.
    readerAtCompleteEof = false;
    await sleep(Math.min(intervalMs, Math.max(1, budgetMs - elapsed)));
  }

  if (!candidatePath) {
    return { token: "unavailable", diagnostics };
  }
  if (!readableCandidate && !deadlineOnlyReadFailure) {
    return { token: "unavailable", diagnostics };
  }
  // No remaining loop exit can certify completion. Do not repeat the completed
  // pending evaluation's page assessment or reply read at the budget edge.
  return { token: "pending", diagnostics };
}

function serializeDiagnostic(item) {
  return JSON.stringify(item).replace(
    /[\u0000-\u001f\u007f-\u009f]/gu,
    (character) => `\\u${character.codePointAt(0).toString(16).padStart(4, "0")}`,
  );
}

function usage() {
  return `Usage: node codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> [options]

Options:
  --reply-path <path>       Explicit reply file path (wins over derivation).
  --transport-root <path>   Default: CODEX_IPC_ROOT, else ~/.claude/ipc.
  --session <sid>           Derive <transport-root>/<sid>/<thread>/<dispatch>.reply.md.
  --rollout-path <path>     Explicit rollout path (wins over locator).
  --sessions-root <path>    Rollout locator root (default ~/.codex/sessions).
  --budget-ms <n>           0 (default) is single-shot; positive values poll to budget.
  --interval-ms <n>         Positive poll interval (default 250).
  --accept-rollout-fallback D2 opt-in: when the reply file is genuinely absent, a completed own
                            turn whose verified rollout body matches its terminal certifies done
                            (replySource=rollout-fallback). Flagless mode stays file-primary.
  --status-exit-codes       D4 opt-in: map the determination to an exit code (done=0, pending=2,
                            aborted=3, superseded=4, reply-missing=5, unavailable=6). Usage errors
                            stay exit 1 with no token. Flagless stays all-determinations-exit-0.
  --materialize-reply       Opt-in, with --accept-rollout-fallback and --reply-path or --session:
                            after done/rollout-fallback, keep the certified body beside the task
                            envelope as <dispatch>.reply.rollout.md (plus .reply.rollout.json),
                            via the harvester's --materialize rules. It never writes the primary
                            reply file; stdout and the exit code are unchanged.
  --queue-id <uuid>         Opt-in, for a --deliver queue dispatch: read the runtime queue store
                            read-only. If that item is still queued ${QUEUE_NOT_STARTED_GRACE_MS / 1000} s after it was queued
                            and no turn carries this dispatch, print one non-terminal
                            WAIT_DIAGNOSTIC queued-not-started as soon as it is seen (the thread
                            may be busy, not loaded in the App, or its last turn was interrupted).
                            The token and exit code are unchanged.
  --queue-db <path>         Queue store for --queue-id (default ~/.codex/queue_1.sqlite).
                            With --queue-id and a positive budget, the waiter also wakes the
                            thread once: if the item is still queued ${QUEUE_WAKE_AFTER_MS / 1000} s after it was queued
                            and no turn carries this dispatch, it runs codex_ipc_wake.ps1, which
                            asks the running alternate-host App to load the thread (Windows only;
                            never for a package host). WAIT_DIAGNOSTIC wake-attempted, wake-result,
                            wake-skipped and wake-no-effect report it; the token and exit code are
                            unchanged.
  --no-wake                 With --queue-id: never run the wake.
  --intended-host <value>   With --queue-id: the handoff's --intended-host (package or an
                            absolute executable), used only by the wake.

Environment:
  CODEX_IPC_ROLLOUT_PATH      same validation as --rollout-path; flag wins
  CODEX_IPC_SESSIONS_ROOT     same meaning as --sessions-root; flag wins
  CODEX_IPC_WAIT_BUDGET_MS    same validation as --budget-ms; flag wins
  CODEX_IPC_WAIT_INTERVAL_MS  same validation as --interval-ms; flag wins
  CODEX_IPC_QUEUE_DB          same meaning as --queue-db; flag wins`;
}

function takeValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function nonNegativeInteger(value, fallback, label) {
  if (value === undefined || value === null || value === "") return fallback;
  if (/^[0-9]+$/.test(String(value))) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isSafeInteger(parsed)) return parsed;
  }
  throw new Error(`${label} must be a non-negative integer`);
}

function positiveOrDefault(value, fallback, label, warnings) {
  if (value === undefined || value === null || value === "") return fallback;
  if (/^[0-9]+$/.test(String(value))) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isSafeInteger(parsed) && parsed > 0) return parsed;
  }
  warnings.push(`WARNING: ${label} must be a positive integer; using default ${fallback}.`);
  return fallback;
}

export function parseWaitArgs(argv, env = process.env) {
  const raw = {
    threadId: null,
    dispatchId: null,
    replyPath: null,
    transportRoot: null,
    sessionId: null,
    rolloutPath: null,
    sessionsRoot: null,
    budgetMs: undefined,
    intervalMs: undefined,
    acceptRolloutFallback: false,
    statusExitCodes: false,
    materializeReply: false,
    queueItemId: null,
    queueDbPath: null,
    noWake: false,
    intendedHost: null,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--accept-rollout-fallback":
        raw.acceptRolloutFallback = true;
        break;
      case "--materialize-reply":
        raw.materializeReply = true;
        break;
      case "--status-exit-codes":
        raw.statusExitCodes = true;
        break;
      case "--thread":
        raw.threadId = takeValue(argv, ++index, arg);
        break;
      case "--dispatch":
        raw.dispatchId = takeValue(argv, ++index, arg);
        break;
      case "--reply-path":
        raw.replyPath = takeValue(argv, ++index, arg);
        break;
      case "--transport-root":
        raw.transportRoot = takeValue(argv, ++index, arg);
        break;
      case "--session":
        raw.sessionId = takeValue(argv, ++index, arg);
        break;
      case "--rollout-path":
        raw.rolloutPath = takeValue(argv, ++index, arg);
        break;
      case "--sessions-root":
        raw.sessionsRoot = takeValue(argv, ++index, arg);
        break;
      case "--budget-ms":
        raw.budgetMs = takeValue(argv, ++index, arg);
        break;
      case "--interval-ms":
        raw.intervalMs = takeValue(argv, ++index, arg);
        break;
      case "--queue-id":
        raw.queueItemId = takeValue(argv, ++index, arg);
        break;
      case "--queue-db":
        raw.queueDbPath = takeValue(argv, ++index, arg);
        break;
      case "--no-wake":
        raw.noWake = true;
        break;
      case "--intended-host":
        raw.intendedHost = takeValue(argv, ++index, arg);
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!raw.threadId || !UUID_RE.test(raw.threadId)) throw new Error("--thread must be a UUID");
  if (!raw.dispatchId || !/^[A-Za-z0-9._-]+$/.test(raw.dispatchId)) {
    throw new Error("--dispatch must be a dispatch id");
  }
  if (
    raw.sessionId &&
    (raw.sessionId === "." || raw.sessionId === ".." || /[\\/\u0000]/.test(raw.sessionId))
  ) {
    throw new Error("--session must be one path segment");
  }
  if (raw.materializeReply && !raw.acceptRolloutFallback) {
    throw new Error("--materialize-reply requires --accept-rollout-fallback");
  }
  if (raw.materializeReply && !raw.replyPath && !raw.sessionId) {
    throw new Error("--materialize-reply requires --reply-path or --session");
  }
  if (raw.queueItemId !== null && !UUID_RE.test(raw.queueItemId)) {
    throw new Error("--queue-id must be a UUID");
  }
  if (raw.queueDbPath !== null && raw.queueItemId === null) {
    throw new Error("--queue-db requires --queue-id");
  }
  if (raw.noWake && raw.queueItemId === null) throw new Error("--no-wake requires --queue-id");
  if (raw.intendedHost !== null) {
    if (raw.queueItemId === null) throw new Error("--intended-host requires --queue-id");
    if (raw.intendedHost !== "package" &&
        (!/^(?:[A-Za-z]:[\\/]|\\\\)/u.test(raw.intendedHost) ||
          /[\u0000-\u001f\u007f]/u.test(raw.intendedHost))) {
      throw new Error("--intended-host must be package or an absolute executable path");
    }
  }

  const warnings = [];
  const budgetSource = raw.budgetMs ?? env.CODEX_IPC_WAIT_BUDGET_MS;
  const intervalSource = raw.intervalMs ?? env.CODEX_IPC_WAIT_INTERVAL_MS;
  const rolloutSource = raw.rolloutPath || env.CODEX_IPC_ROLLOUT_PATH || null;
  const transportRoot = raw.transportRoot || env.CODEX_IPC_ROOT ||
    path.join(os.homedir(), ".claude", "ipc");
  return {
    warnings,
    options: {
      threadId: raw.threadId.toLowerCase(),
      dispatchId: raw.dispatchId,
      replyPath: raw.replyPath,
      transportRoot,
      sessionId: raw.sessionId,
      rolloutPath: rolloutSource ? normalizeRolloutCliPath(rolloutSource) : null,
      sessionsRoot: raw.sessionsRoot || env.CODEX_IPC_SESSIONS_ROOT ||
        path.join(os.homedir(), ".codex", "sessions"),
      budgetMs: nonNegativeInteger(
        budgetSource,
        DEFAULT_WAIT_BUDGET_MS,
        "wait budget",
      ),
      intervalMs: positiveOrDefault(
        intervalSource,
        DEFAULT_WAIT_INTERVAL_MS,
        "wait interval",
        warnings,
      ),
      acceptRolloutFallback: raw.acceptRolloutFallback,
      statusExitCodes: raw.statusExitCodes,
      materializeReply: raw.materializeReply,
      maxRecordBytes: DEFAULT_MAX_RECORD_BYTES,
      queueItemId: raw.queueItemId ? raw.queueItemId.toLowerCase() : null,
      queueDbPath: raw.queueItemId
        ? raw.queueDbPath || env.CODEX_IPC_QUEUE_DB ||
          path.join(os.homedir(), ".codex", "queue_1.sqlite")
        : null,
      // The wake is on by default for a queue dispatch; --no-wake opts out.
      wake: raw.queueItemId !== null && !raw.noWake,
      intendedHost: raw.intendedHost,
    },
  };
}

async function main(argv) {
  let parsed;
  try {
    parsed = parseWaitArgs(argv);
  } catch (error) {
    console.error(`ERROR ${serializeDiagnostic({ code: "usage-error", message: error.message })}`);
    if (error?.code === "IPC_ROLLOUT_PATH_INVALID") console.error(ROLLOUT_PATH_GUIDANCE);
    console.error(usage());
    process.exitCode = 1;
    return;
  }

  for (const warning of parsed.warnings) console.error(warning);
  // Queue diagnostics print when they are seen, so a long wait reports a stuck item early; they
  // are not repeated with the end-of-wait diagnostics.
  const printedLive = new Set();
  const onDiagnostic = (item) => {
    printedLive.add(item);
    console.error(`WAIT_DIAGNOSTIC ${serializeDiagnostic(item)}`);
  };
  try {
    const result = await waitForCompletion(parsed.options, { onDiagnostic });
    for (const line of rolloutDiagnosticLines(result.diagnostics)) console.error(line);
    for (const item of result.diagnostics) {
      if (printedLive.has(item)) continue;
      console.error(`WAIT_DIAGNOSTIC ${serializeDiagnostic(item)}`);
    }
    // Opt-in provenance: in --accept-rollout-fallback mode, surface which source certified a done
    // (reply-file or rollout-fallback) as exactly one stderr diagnostic. The recovered body is
    // never emitted; stdout remains exactly the one determination token.
    if (parsed.options.acceptRolloutFallback && result.replySource) {
      console.error(
        `WAIT_DIAGNOSTIC ${serializeDiagnostic({ code: "reply-source", source: result.replySource })}`,
      );
    }
    // Opt-in only. The harvester re-certifies before writing anything; the outcome is one stderr
    // diagnostic, and stdout and the exit code still describe the wait alone.
    if (parsed.options.materializeReply && result.token === "done" &&
        result.replySource === "rollout-fallback") {
      const resolution = replyPathResolution(parsed.options);
      const outcome = resolution.status === "resolved"
        ? materializeDispatch({
            threadId: parsed.options.threadId,
            dispatchId: parsed.options.dispatchId,
            replyPath: resolution.path,
            rolloutPath: parsed.options.rolloutPath,
            sessionsRoot: parsed.options.sessionsRoot,
            maxRecordBytes: parsed.options.maxRecordBytes,
          })
        : { ok: false, reason: "reply-path-unresolved" };
      console.error(`WAIT_DIAGNOSTIC ${serializeDiagnostic(outcome.ok
        ? { code: "reply-materialized", bytes: outcome.bodyBytes, sha256: outcome.bodySha256 }
        : { code: "reply-materialize-refused", reason: outcome.reason })}`);
    }
    process.stdout.write(`${result.token}\n`);
    // A6: opt-in only. Flagless leaves process.exitCode unset (0), byte-identical to prior releases.
    if (parsed.options.statusExitCodes) {
      process.exitCode = STATUS_EXIT_CODES[result.token] ?? STATUS_EXIT_CODES.unavailable;
    }
  } catch (error) {
    console.error(
      `WAIT_DIAGNOSTIC ${serializeDiagnostic({ code: "wait-error", message: error.message })}`,
    );
    process.stdout.write("unavailable\n");
    // A caught runtime authority failure is an unavailable determination; map it under the flag.
    if (parsed.options.statusExitCodes) {
      process.exitCode = STATUS_EXIT_CODES.unavailable;
    }
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
  console.error('ERROR {"code":"entrypoint-resolution-failed"}');
  process.exitCode = 1;
}
if (runAsMain) {
  await main(process.argv.slice(2));
}
