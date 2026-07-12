#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  createDispatchCorrelator,
  DEFAULT_MAX_RECORD_BYTES,
  locateRollout,
  readRolloutFile,
} from "./codex_ipc_rollout_reader.mjs";

export const DEFAULT_WAIT_BUDGET_MS = 0;
export const DEFAULT_WAIT_INTERVAL_MS = 250;
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
  return correlator.finish({ ok: true, diagnostics: parserDiagnostics }).lifecycle;
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
    // Reply file is primary. A readable regular file (including a zero-byte one) certifies done.
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
    return { token: "done", replySource: "rollout-fallback", diagnostics };
  }
  return { token: "reply-missing", diagnostics };
}

export async function waitForCompletion(options, injected = {}) {
  const now = injected.now || Date.now;
  const sleep = injected.sleep || defaultSleep;
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
  let cursor = null;
  let readableCandidate = false;
  let lastLocation = null;
  // A read that only ran out of budget is not an authority failure: the candidate exists and is
  // parseable, we simply did not finish observing it. That is `pending`, never `unavailable`.
  let deadlineOnlyReadFailure = false;

  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    if (iteration > 0 && now() - startedAt >= budgetMs) break;
    if (!candidatePath) {
      lastLocation = locateRollout({
        threadId: options.threadId,
        rolloutPath: options.rolloutPath,
        sessionsRoot: options.sessionsRoot,
        deadlineAt,
        now,
      });
      diagnostics.push(...(lastLocation.diagnostics || []));
      if (lastLocation.status === "ambiguous") {
        return { token: "unavailable", diagnostics };
      }
      if (lastLocation.status === "found") candidatePath = lastLocation.path;
    }

    if (candidatePath) {
      const parsed = readRolloutFile(candidatePath, {
        ...(cursor ? { cursor } : {}),
        maxRecordBytes: options.maxRecordBytes ?? DEFAULT_MAX_RECORD_BYTES,
        deadlineAt,
        now,
      });
      records.push(...(parsed.records || []));
      diagnostics.push(...(parsed.diagnostics || []));
      if (!parsed.ok) {
        if (parsed.reason !== "deadline-exceeded") {
          return { token: "unavailable", diagnostics };
        }
        deadlineOnlyReadFailure = true;
      } else {
        readableCandidate = true;
        cursor = parsed.cursor;
      }

      const lifecycle = dispatchLifecycle(records, diagnostics, options.dispatchId);
      const resolved = resolveCompletion(lifecycle, options);
      if (lifecycle.status !== "pending" || resolved.token === "unavailable") {
        return {
          token: resolved.token,
          diagnostics: [...diagnostics, ...resolved.diagnostics],
          replySource: resolved.replySource,
        };
      }
      if (!parsed.ok) break;
    }

    if (budgetMs === 0) break;
    const elapsed = now() - startedAt;
    if (elapsed >= budgetMs || iteration + 1 >= maxIterations) break;
    await sleep(Math.min(intervalMs, Math.max(1, budgetMs - elapsed)));
  }

  if (!candidatePath) {
    return { token: "unavailable", diagnostics };
  }
  if (!readableCandidate && !deadlineOnlyReadFailure) {
    return { token: "unavailable", diagnostics };
  }
  const lifecycle = dispatchLifecycle(records, diagnostics, options.dispatchId);
  const resolved = resolveCompletion(lifecycle, options);
  return {
    token: resolved.token,
    diagnostics: [...diagnostics, ...resolved.diagnostics],
    replySource: resolved.replySource,
  };
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

Environment:
  CODEX_IPC_WAIT_BUDGET_MS    same validation as --budget-ms; flag wins
  CODEX_IPC_WAIT_INTERVAL_MS  same validation as --interval-ms; flag wins`;
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
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--accept-rollout-fallback":
        raw.acceptRolloutFallback = true;
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

  const warnings = [];
  const budgetSource = raw.budgetMs ?? env.CODEX_IPC_WAIT_BUDGET_MS;
  const intervalSource = raw.intervalMs ?? env.CODEX_IPC_WAIT_INTERVAL_MS;
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
      rolloutPath: raw.rolloutPath,
      sessionsRoot: raw.sessionsRoot || path.join(os.homedir(), ".codex", "sessions"),
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
      maxRecordBytes: DEFAULT_MAX_RECORD_BYTES,
    },
  };
}

async function main(argv) {
  let parsed;
  try {
    parsed = parseWaitArgs(argv);
  } catch (error) {
    console.error(`ERROR ${serializeDiagnostic({ code: "usage-error", message: error.message })}`);
    console.error(usage());
    process.exitCode = 1;
    return;
  }

  for (const warning of parsed.warnings) console.error(warning);
  try {
    const result = await waitForCompletion(parsed.options);
    for (const item of result.diagnostics) {
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

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main(process.argv.slice(2));
}
