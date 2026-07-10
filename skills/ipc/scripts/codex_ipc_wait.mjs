#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function exactTaskBasename(text, basename) {
  if (typeof text !== "string" || !text.includes(basename)) return false;
  let offset = text.indexOf(basename);
  while (offset !== -1) {
    const before = offset === 0 ? "" : text[offset - 1];
    const after = text[offset + basename.length] || "";
    if ((before === "" || /[\\/"'\s]/.test(before)) && (after === "" || /["'\s]/.test(after))) {
      return true;
    }
    offset = text.indexOf(basename, offset + 1);
  }
  return false;
}

function makeTurn(record, sequence) {
  return {
    sequence,
    turnId: record.turnId,
    startLine: record.line,
    terminal: null,
    userMessages: [],
    parseErrors: [],
    boundaryErrors: [],
    superseded: false,
  };
}

function classifyDispatch(records, parserDiagnostics, dispatchId) {
  const basename = dispatchId.endsWith(".task.md") ? dispatchId : `${dispatchId}.task.md`;
  const turns = [];
  const explicit = new Map();
  let current = null;
  let sequence = 0;

  for (const record of records) {
    if (record.parseError) {
      if (current && !current.terminal) current.parseErrors.push(record);
      continue;
    }
    if (record.envelopeType !== "event_msg") continue;
    if (record.payloadType === "task_started") {
      if (current && !current.terminal) current.superseded = true;
      const turn = makeTurn(record, sequence++);
      turns.push(turn);
      current = turn;
      if (turn.turnId) explicit.set(turn.turnId, turn);
      continue;
    }
    if (record.payloadType === "user_message") {
      if (current && !current.terminal) {
        if (current.turnId && record.turnId && current.turnId !== record.turnId) {
          current.boundaryErrors.push({
            code: "user-message-turn-id-mismatch",
            line: record.line,
            expectedTurnId: current.turnId,
            messageTurnId: record.turnId,
          });
        }
        current.userMessages.push(record);
      }
      continue;
    }
    if (record.payloadType !== "task_complete" && record.payloadType !== "turn_aborted") {
      continue;
    }

    let turn;
    if (record.turnId) {
      turn = explicit.get(record.turnId);
      if (!turn && current?.turnId) {
        current.boundaryErrors.push({
          code: "terminal-turn-id-mismatch",
          line: record.line,
          expectedTurnId: current.turnId,
          terminalTurnId: record.turnId,
        });
      } else if (!turn && current) {
        current.boundaryErrors.push({
          code: "terminal-turn-id-unexpected",
          line: record.line,
          terminalTurnId: record.turnId,
        });
      }
    } else if (current?.turnId) {
      current.boundaryErrors.push({
        code: "terminal-turn-id-missing",
        line: record.line,
        expectedTurnId: current.turnId,
      });
      continue;
    } else {
      turn = current;
    }
    if (!turn || turn.terminal) continue;
    turn.terminal = record;
    if (current === turn) current = null;
  }

  const occurrences = [];
  for (const turn of turns) {
    const markers = turn.userMessages.filter((item) => exactTaskBasename(item.text, basename));
    for (const marker of markers) {
      const laterUsers = turn.userMessages.filter((item) => item.line > marker.line);
      const inWindowErrors = turn.parseErrors.filter(
        (item) => item.line > marker.line && (!turn.terminal || item.line < turn.terminal.line),
      );
      const inWindowSchemaDrift = parserDiagnostics.filter(
        (item) =>
          item.code === "schema-drift" &&
          item.line > turn.startLine &&
          (!turn.terminal || item.line < turn.terminal.line),
      );
      let outcome;
      if (turn.superseded) {
        outcome = {
          status: "superseded",
          diagnostics: [{ code: "turn-superseded", line: turn.startLine, turnId: turn.turnId }],
        };
      } else if (turn.boundaryErrors.length > 0) {
        outcome = { status: "unavailable", diagnostics: turn.boundaryErrors };
      } else if (inWindowErrors.length > 0) {
        outcome = {
          status: "unavailable",
          diagnostics: inWindowErrors.map((item) => ({ code: "malformed-json", ...item })),
        };
      } else if (!turn.turnId && laterUsers.length > 0) {
        // Ambiguity rule of the ORDERED-EVENT FALLBACK only. When the turn carries a turn_id,
        // its boundaries are already unambiguous, so a later user message inside the same turn
        // (e.g. the operator typing into the thread while the lane works) is not ambiguity.
        outcome = {
          status: "unavailable",
          diagnostics: [{ code: "intervening-user-message", line: laterUsers[0].line }],
        };
      } else if (inWindowSchemaDrift.length > 0) {
        outcome = { status: "unavailable", diagnostics: inWindowSchemaDrift };
      } else if (!turn.terminal) {
        outcome = { status: "pending", diagnostics: [] };
      } else if (turn.terminal.payloadType === "turn_aborted") {
        outcome = { status: "aborted", diagnostics: [] };
      } else {
        outcome = { status: "complete", diagnostics: [] };
      }
      occurrences.push({
        ...outcome,
        markerLine: marker.line,
        terminalLine: turn.terminal?.line || null,
      });
    }
  }

  const completed = occurrences
    .filter((item) => item.status === "complete")
    .sort((left, right) => (left.terminalLine || 0) - (right.terminalLine || 0));
  if (completed.length > 0) return completed.at(-1);

  const unavailable = occurrences.find((item) => item.status === "unavailable");
  if (unavailable) return unavailable;
  const pending = occurrences.find((item) => item.status === "pending");
  if (pending) return pending;
  if (occurrences.length > 0) {
    return occurrences.sort((left, right) => left.markerLine - right.markerLine).at(-1);
  }

  const schemaFailure = records.some((item) => item.parseError) ||
    parserDiagnostics.some((item) => item.code === "schema-drift");
  return {
    status: schemaFailure ? "unavailable" : "pending",
    diagnostics: schemaFailure
      ? parserDiagnostics.filter((item) => item.code === "schema-drift" || item.code === "malformed-json")
      : [],
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
  if (resolution.status === "ambiguous" || resolution.status === "unavailable") {
    return { token: "unavailable", diagnostics };
  }
  return { token: reply.valid ? "done" : "reply-missing", diagnostics };
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

      const lifecycle = classifyDispatch(records, diagnostics, options.dispatchId);
      const resolved = resolveCompletion(lifecycle, options);
      if (lifecycle.status !== "pending" || resolved.token === "unavailable") {
        return { token: resolved.token, diagnostics: [...diagnostics, ...resolved.diagnostics] };
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
  const lifecycle = classifyDispatch(records, diagnostics, options.dispatchId);
  const resolved = resolveCompletion(lifecycle, options);
  return { token: resolved.token, diagnostics: [...diagnostics, ...resolved.diagnostics] };
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
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
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
    process.stdout.write(`${result.token}\n`);
  } catch (error) {
    console.error(
      `WAIT_DIAGNOSTIC ${serializeDiagnostic({ code: "wait-error", message: error.message })}`,
    );
    process.stdout.write("unavailable\n");
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main(process.argv.slice(2));
}
