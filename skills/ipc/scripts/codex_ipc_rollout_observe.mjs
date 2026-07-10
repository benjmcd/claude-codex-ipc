#!/usr/bin/env node
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  DEFAULT_MAX_RECORD_BYTES,
  locateRollout,
  readRolloutFile,
} from "./codex_ipc_rollout_reader.mjs";

// Retained-envelope census p90 was 17.78 s on 2026-07-10; keep bounded headroom above it.
export const DEFAULT_OBSERVE_BUDGET_MS = 20000;
export const DEFAULT_OBSERVE_INTERVAL_MS = 250;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function serializeDiagnostic(item) {
  return JSON.stringify(item).replace(
    /[\u0000-\u001f\u007f-\u009f]/gu,
    (character) => `\\u${character.codePointAt(0).toString(16).padStart(4, "0")}`,
  );
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

function admissionSeen(records, dispatchId) {
  const basename = dispatchId.endsWith(".task.md") ? dispatchId : `${dispatchId}.task.md`;
  return records.some(
    (item) =>
      !item.parseError &&
      item.envelopeType === "event_msg" &&
      item.payloadType === "user_message" &&
      exactTaskBasename(item.text, basename),
  );
}

export async function observeRollout(options, injected = {}) {
  const now = injected.now || Date.now;
  const sleep = injected.sleep || defaultSleep;
  const budgetMs = options.budgetMs;
  const intervalMs = options.intervalMs;
  const maxIterations = Math.ceil(budgetMs / intervalMs) + 1;
  const startedAt = now();
  let candidatePath = null;
  let cursor = null;
  let readableCandidate = false;
  let schemaFailure = false;
  const diagnostics = [];

  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    if (iteration > 0 && now() - startedAt >= budgetMs) break;
    if (!candidatePath) {
      const located = locateRollout({
        threadId: options.threadId,
        rolloutPath: options.rolloutPath,
        sessionsRoot: options.sessionsRoot,
        deadlineAt: startedAt + budgetMs,
        now,
      });
      diagnostics.push(...(located.diagnostics || []));
      if (located.status === "ambiguous") {
        return { token: "rollout-unavailable", diagnostics };
      }
      if (located.status === "found") {
        candidatePath = located.path;
        readableCandidate = true;
      }
    }

    if (candidatePath) {
      let admission = false;
      const parsed = readRolloutFile(candidatePath, {
        ...(cursor ? { cursor } : {}),
        maxRecordBytes: options.maxRecordBytes,
        deadlineAt: startedAt + budgetMs,
        now,
        retainRecords: false,
        onRecord: (item) => {
          if (admissionSeen([item], options.dispatchId)) admission = true;
        },
      });
      diagnostics.push(...(parsed.diagnostics || []));
      const trustedRead = parsed.ok || (
        parsed.reason === "deadline-exceeded" && parsed.integrityValidated
      );
      if (trustedRead && admission) {
        return { token: "rollout-hit", diagnostics };
      }
      if (parsed.ok) {
        readableCandidate = true;
        cursor = parsed.cursor;
        if (parsed.parseErrorCount > 0) schemaFailure = true;
      } else if (parsed.reason === "deadline-exceeded") {
        if (readableCandidate) break;
        return { token: "rollout-unavailable", diagnostics };
      } else if (parsed.reason !== "missing") {
        schemaFailure = true;
      }
    }

    const elapsed = now() - startedAt;
    if (elapsed >= budgetMs || iteration + 1 >= maxIterations) break;
    await sleep(Math.min(intervalMs, Math.max(1, budgetMs - elapsed)));
  }

  if (schemaFailure || !readableCandidate) {
    return { token: "rollout-unavailable", diagnostics };
  }
  return { token: "rollout-pending", diagnostics };
}

function usage() {
  return `Usage: node codex_ipc_rollout_observe.mjs --thread <uuid> --dispatch <dispatchId>
       [--rollout-path <explicit>] [--budget-ms <n>] [--interval-ms <n>]

Environment:
  CODEX_IPC_OBSERVE_BUDGET_MS    bounded observation budget (default 20000, measurement-informed)
  CODEX_IPC_OBSERVE_INTERVAL_MS  positive poll interval (default 250)`;
}

function takeValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function positiveOrDefault(value, fallback, label, warnings) {
  if (value === undefined || value === null || value === "") return fallback;
  if (/^[1-9][0-9]*$/.test(String(value))) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isSafeInteger(parsed)) return parsed;
  }
  warnings.push(`WARNING: ${label} must be a positive integer; using default ${fallback}.`);
  return fallback;
}

function parseArgs(argv) {
  const raw = {
    threadId: null,
    dispatchId: null,
    rolloutPath: null,
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
      case "--rollout-path":
        raw.rolloutPath = takeValue(argv, ++index, arg);
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
  const warnings = [];
  const budgetSource = raw.budgetMs ?? process.env.CODEX_IPC_OBSERVE_BUDGET_MS;
  const intervalSource = raw.intervalMs ?? process.env.CODEX_IPC_OBSERVE_INTERVAL_MS;
  const maxRecordSource = process.env.CODEX_IPC_ROLLOUT_MAX_RECORD_BYTES;
  return {
    warnings,
    options: {
      threadId: raw.threadId.toLowerCase(),
      dispatchId: raw.dispatchId,
      rolloutPath: raw.rolloutPath || null,
      sessionsRoot: process.env.CODEX_IPC_SESSIONS_ROOT || undefined,
      budgetMs: positiveOrDefault(
        budgetSource,
        DEFAULT_OBSERVE_BUDGET_MS,
        "observation budget",
        warnings,
      ),
      intervalMs: positiveOrDefault(
        intervalSource,
        DEFAULT_OBSERVE_INTERVAL_MS,
        "observation interval",
        warnings,
      ),
      maxRecordBytes: positiveOrDefault(
        maxRecordSource,
        DEFAULT_MAX_RECORD_BYTES,
        "rollout record cap",
        warnings,
      ),
    },
  };
}

async function main(argv) {
  let parsed;
  try {
    parsed = parseArgs(argv);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    console.error(usage());
    process.exitCode = 1;
    return;
  }
  for (const warning of parsed.warnings) console.error(warning);
  try {
    const result = await observeRollout(parsed.options);
    for (const item of result.diagnostics) {
      console.error(`ROLLOUT_DIAGNOSTIC ${serializeDiagnostic(item)}`);
    }
    process.stdout.write(`${result.token}\n`);
  } catch (error) {
    console.error(`ROLLOUT_DIAGNOSTIC ${serializeDiagnostic({ code: "observer-error", message: error.message })}`);
    process.stdout.write("rollout-unavailable\n");
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main(process.argv.slice(2));
}
