#!/usr/bin/env node
// Read-only Codex Desktop session inspector for Claude /ipc workflows.
//
// This helper does not connect to the Desktop IPC pipe and does not write to
// SQLite. It summarizes the target thread row plus the matching rollout JSONL
// tail so a caller can inspect current state before sending a handoff.

import { createReadStream } from "node:fs";
import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";

// node:sqlite is optional at the repo level: file-drop handoff works without it.
let DatabaseSync;
try {
  ({ DatabaseSync } = await import("node:sqlite"));
} catch (error) {
  console.error(
    "ERROR: node:sqlite is unavailable in this Node.js runtime. This optional inspection " +
      "feature requires a Node.js version with node:sqlite support (>= 22.5; older 22.x/23.x lines may require --experimental-sqlite). " +
      `File-drop handoff (handoff_to_codex.sh) works without it. (${error.message})`,
  );
  process.exit(1);
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEFAULT_TAIL_EVENTS = 20;
const DEFAULT_MAX_TEXT_CHARS = 600;
const THREAD_COLUMNS = [
  "id",
  "rollout_path",
  "created_at",
  "updated_at",
  "cwd",
  "title",
  "model",
  "reasoning_effort",
  "sandbox_policy",
  "approval_mode",
  "tokens_used",
  "archived",
  "thread_source",
  "preview",
  "first_user_message",
  "created_at_ms",
  "updated_at_ms",
];

function usage() {
  return `Usage:
  node scripts/codex_ipc_session_inspect.mjs --thread <uuid> [options]

Options:
  --thread <uuid>        Codex conversation/thread id to inspect. Required.
  --tail-events <n>      Number of recent JSONL events to include. Default: ${DEFAULT_TAIL_EVENTS}
  --max-text-chars <n>   Max extracted text chars per recent item. Default: ${DEFAULT_MAX_TEXT_CHARS}
  --db <path>            State DB path. Default: %USERPROFILE%\\.codex\\state_5.sqlite
  --sessions-root <path> Sessions root. Default: %USERPROFILE%\\.codex\\sessions
  --help                 Show this help.

Safety:
  Read-only only. Opens SQLite with readOnly:true, reads rollout JSONL files,
  sends no IPC messages, and writes no files. Activity/finished signals are
  heuristics; inspect the rollout directly before interrupting or sending.`;
}

function defaultCodexPath(...parts) {
  const home = process.env.USERPROFILE || process.env.HOME;
  if (!home) {
    throw new Error("Cannot resolve user home directory from USERPROFILE or HOME");
  }
  return path.join(home, ".codex", ...parts);
}

function parseArgs(argv) {
  const opts = {
    threadId: null,
    tailEvents: DEFAULT_TAIL_EVENTS,
    maxTextChars: DEFAULT_MAX_TEXT_CHARS,
    dbPath: defaultCodexPath("state_5.sqlite"),
    sessionsRoot: defaultCodexPath("sessions"),
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--tail-events":
        opts.tailEvents = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--max-text-chars":
        opts.maxTextChars = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--db":
        opts.dbPath = takeValue(argv, ++index, arg);
        break;
      case "--sessions-root":
        opts.sessionsRoot = takeValue(argv, ++index, arg);
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!opts.help) {
    if (!opts.threadId) {
      throw new Error("--thread is required");
    }
    validateUuid(opts.threadId, "--thread");
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

function validateUuid(value, flag) {
  if (!UUID_RE.test(value)) {
    throw new Error(`${flag} must be a UUID`);
  }
}

async function inspectSession(opts) {
  const dbThread = readDbThread(opts.dbPath, opts.threadId);
  const rolloutSelection = findRolloutCandidates(
    opts.sessionsRoot,
    opts.threadId,
    dbThread.thread?.rolloutPath || null,
  );
  const primaryRollout = rolloutSelection.primaryCandidate;
  const rolloutSummary = primaryRollout
    ? await parseRollout(primaryRollout.path, opts.tailEvents, opts.maxTextChars)
    : null;

  const ok = Boolean(dbThread.thread?.exists || rolloutSummary?.parsedOk);
  return {
    ok,
    mode: "session-inspect",
    generatedAt: new Date().toISOString(),
    threadId: opts.threadId,
    dbThread,
    rollout: {
      candidates: rolloutSelection.candidates,
      primary: rolloutSummary,
      candidatesAmbiguous: rolloutSelection.status === "ambiguous",
      ambiguousCandidates: rolloutSelection.ambiguousCandidates,
      selection: {
        status: rolloutSelection.status,
        reason: rolloutSelection.reason,
        authority: rolloutSelection.authority,
        path: primaryRollout?.path || null,
        candidateCount: rolloutSelection.candidates.length,
        aliasCount: rolloutSelection.aliasCount,
      },
    },
    activitySignals: inferActivitySignals(dbThread.thread, rolloutSummary),
    warnings: [
      "Read-only evidence only: no IPC connection, no Desktop message send, and no SQLite write were attempted.",
      "DB row and rollout presence do not prove the owning Desktop renderer is currently open.",
      "Activity signals are heuristic; read the rollout context before interrupting or adding a new turn.",
      ...(rolloutSelection.status === "ambiguous"
        ? ["Multiple distinct rollout candidates have equal authority; no primary rollout was selected."]
        : []),
    ],
  };
}

function readDbThread(dbPath, threadId) {
  const info = fileInfo(dbPath);
  if (!info.exists) {
    return {
      path: dbPath,
      exists: false,
      readOnlyOpenOk: false,
      thread: { exists: false },
      warnings: ["State DB was not found."],
    };
  }

  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const availableColumns = new Set(
      db.prepare("pragma table_info(threads)").all().map((row) => row.name),
    );
    const selectedColumns = THREAD_COLUMNS.filter((column) => availableColumns.has(column));
    if (!selectedColumns.includes("id")) {
      throw new Error("threads table does not expose an id column");
    }
    const row = db
      .prepare(`select ${selectedColumns.join(", ")} from threads where id = ?`)
      .get(threadId);

    return {
      path: dbPath,
      exists: true,
      readOnlyOpenOk: true,
      stat: info,
      selectedColumns,
      thread: summarizeThread(row || null),
      warnings: [],
    };
  } catch (error) {
    return {
      path: dbPath,
      exists: true,
      readOnlyOpenOk: false,
      stat: info,
      thread: { exists: false },
      warnings: [`Failed to read state DB: ${error.message}`],
    };
  } finally {
    if (db) {
      db.close();
    }
  }
}

function parseJsonColumn(value) {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  try {
    return JSON.parse(value);
  } catch {
    // Fail-visible: surface the raw column text rather than hiding a schema drift.
    return { unparsed: String(value) };
  }
}

function summarizeThread(row) {
  if (!row) {
    return { exists: false };
  }
  return {
    exists: true,
    id: row.id,
    rolloutPath: row.rollout_path || null,
    cwd: row.cwd || null,
    title: row.title || null,
    model: row.model || null,
    reasoningEffort: row.reasoning_effort || null,
    // `approvalMode`/`sandboxPolicy` are the parsed snapshot of the stored `threads.approval_mode`
    // / `threads.sandbox_policy` columns (permission-profile-shaped: observed `disabled`/`managed`).
    // They are the stored thread row, NOT the effective next-turn `turn_context.sandbox_policy`, so
    // they may differ from the turn that actually runs and MUST NOT gate a dispatch or be read as a
    // reply-writability prediction. A blocked reply write is a non-event recovered via
    // `codex_ipc_wait --accept-rollout-fallback` (A1), never a policy gate. Completion-time
    // re-stamping was observed evidence, not a stable timing contract.
    approvalMode: row.approval_mode || null,
    sandboxPolicy: parseJsonColumn(row.sandbox_policy),
    permissionProfileAdvisory: {
      source: "stored-thread-row",
      mayDifferFromEffectiveTurn: true,
      mustNotGateDispatch: true,
      predictsReplyWritability: false,
    },
    tokensUsed: row.tokens_used ?? null,
    archived: row.archived ?? null,
    threadSource: row.thread_source || null,
    preview: truncate(row.preview || "", 300),
    firstUserMessage: truncate(row.first_user_message || "", 300),
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
    createdAtMs: row.created_at_ms ?? null,
    updatedAtMs: row.updated_at_ms ?? null,
  };
}

function findRolloutCandidates(sessionsRoot, threadId, dbRolloutPath) {
  const candidates = [];
  const candidatesByIdentity = new Map();

  function addCandidate(filePath, source) {
    if (!filePath || !existsSync(filePath)) {
      return;
    }
    const stat = statSync(filePath);
    if (!stat.isFile()) {
      return;
    }
    const canonical = canonicalPath(filePath);
    const identity = fileIdentity(filePath, canonical);
    const existing = candidatesByIdentity.get(identity);
    if (existing) {
      if (!existing.aliases.includes(filePath)) {
        existing.aliases.push(filePath);
      }
      if (source === "db.rollout_path") {
        existing.path = filePath;
        existing.source = source;
      }
      return;
    }
    const candidate = {
      path: filePath,
      source,
      size: stat.size,
      mtimeMs: stat.mtimeMs,
      canonicalPath: canonical,
      aliases: [filePath],
    };
    candidatesByIdentity.set(identity, candidate);
    candidates.push(candidate);
  }

  addCandidate(dbRolloutPath, "db.rollout_path");

  if (existsSync(sessionsRoot)) {
    for (const filePath of walkFiles(sessionsRoot)) {
      if (path.basename(filePath).includes(threadId) && filePath.endsWith(".jsonl")) {
        addCandidate(filePath, "sessions-root-match");
      }
    }
  }

  candidates.sort((left, right) => {
    if (left.source === "db.rollout_path" && right.source !== "db.rollout_path") {
      return -1;
    }
    if (right.source === "db.rollout_path" && left.source !== "db.rollout_path") {
      return 1;
    }
    return right.mtimeMs - left.mtimeMs || left.canonicalPath.localeCompare(right.canonicalPath);
  });

  // Authority order: an existing DB-designated rollout wins over broad scanning;
  // otherwise exactly one physical sessions-root match may be selected. Parse
  // validity is reported by rollout.primary.parsedOk and never causes an implicit
  // fallback to a different file than the DB named.
  const dbCandidate = candidates.find((candidate) => candidate.source === "db.rollout_path");
  const aliasCount = candidates.reduce((count, candidate) => count + candidate.aliases.length, 0);
  if (dbCandidate) {
    return {
      candidates,
      primaryCandidate: dbCandidate,
      ambiguousCandidates: [],
      status: "found",
      reason: "db-rollout-path",
      authority: "db.rollout_path",
      aliasCount,
    };
  }
  if (candidates.length === 1) {
    return {
      candidates,
      primaryCandidate: candidates[0],
      ambiguousCandidates: [],
      status: "found",
      reason: "single-candidate",
      authority: "sessions-root-match",
      aliasCount,
    };
  }
  if (candidates.length > 1) {
    return {
      candidates,
      primaryCandidate: null,
      ambiguousCandidates: candidates,
      status: "ambiguous",
      reason: "multiple-candidates",
      authority: "sessions-root-match",
      aliasCount,
    };
  }
  return {
    candidates,
    primaryCandidate: null,
    ambiguousCandidates: [],
    status: "unavailable",
    reason: "no-candidate",
    authority: "none",
    aliasCount,
  };
}

function canonicalPath(filePath) {
  let resolved;
  try {
    resolved = realpathSync.native(filePath);
  } catch {
    resolved = path.resolve(filePath);
  }
  if (process.platform === "win32") {
    if (resolved.startsWith("\\\\?\\UNC\\")) {
      resolved = `\\\\${resolved.slice(8)}`;
    } else if (resolved.startsWith("\\\\?\\")) {
      resolved = resolved.slice(4);
    }
    return resolved.toLowerCase();
  }
  return resolved;
}

function fileIdentity(filePath, canonical) {
  try {
    const stat = statSync(filePath, { bigint: true });
    if (stat.ino !== 0n) {
      return `${stat.dev}:${stat.ino}`;
    }
  } catch {
    // Canonical path identity remains available when bigint stat is unsupported.
  }
  return canonical;
}

function* walkFiles(root) {
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      yield* walkFiles(fullPath);
    } else if (entry.isFile()) {
      yield fullPath;
    }
  }
}

async function parseRollout(filePath, tailEvents, maxTextChars) {
  const info = fileInfo(filePath);
  const recentItems = [];
  const countsByEnvelopeType = {};
  const countsByPayloadType = {};
  const parseErrors = [];
  let lineCount = 0;
  let parsedCount = 0;
  let sessionMeta = null;

  const rl = readline.createInterface({
    input: createReadStream(filePath, { encoding: "utf8" }),
    crlfDelay: Infinity,
  });

  for await (const rawLine of rl) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }
    lineCount += 1;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      if (parseErrors.length < 5) {
        parseErrors.push({ line: lineCount, error: error.message });
      }
      continue;
    }

    parsedCount += 1;
    const item = summarizeJsonlItem(parsed, lineCount, maxTextChars);
    increment(countsByEnvelopeType, item.envelopeType || "unknown");
    increment(countsByPayloadType, item.payloadType || "unknown");
    if (item.payloadType === "session_meta") {
      sessionMeta = item;
    }
    recentItems.push(item);
    while (recentItems.length > tailEvents) {
      recentItems.shift();
    }
  }

  return {
    parsedOk: parsedCount > 0,
    path: filePath,
    stat: info,
    lineCount,
    parsedCount,
    parseErrorCount: lineCount - parsedCount,
    parseErrors,
    countsByEnvelopeType,
    countsByPayloadType,
    sessionMeta,
    recentItems,
  };
}

function summarizeJsonlItem(item, line, maxTextChars) {
  const envelopeType = typeof item.type === "string" ? item.type : null;
  const payload = item.payload && typeof item.payload === "object" ? item.payload : item;
  const payloadType =
    typeof payload.type === "string"
      ? payload.type
      : typeof payload.item?.type === "string"
        ? payload.item.type
        : envelopeType;
  const role =
    payload.role ||
    payload.item?.role ||
    payload.message?.role ||
    payload.output?.role ||
    null;
  const text = truncate(extractText(payload), maxTextChars);

  return {
    line,
    timestamp: item.timestamp || payload.timestamp || null,
    envelopeType,
    payloadType,
    role,
    text,
  };
}

function extractText(value) {
  const found = [];
  collectText(value, found, 0);
  return found.join("\n");
}

function collectText(value, found, depth) {
  if (!value || depth > 5 || found.length >= 8) {
    return;
  }
  if (typeof value === "string") {
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      collectText(item, found, depth + 1);
    }
    return;
  }
  if (typeof value !== "object") {
    return;
  }

  for (const key of ["message", "text", "input_text", "output_text", "content"]) {
    const item = value[key];
    if (typeof item === "string" && item.trim()) {
      found.push(item.trim());
    } else if (Array.isArray(item) || (item && typeof item === "object")) {
      collectText(item, found, depth + 1);
    }
  }

  for (const key of ["payload", "item", "response", "output", "input"]) {
    collectText(value[key], found, depth + 1);
  }
}

function inferActivitySignals(thread, rollout) {
  const recent = rollout?.recentItems || [];
  const lastItem = recent.at(-1) || null;
  const lastTaskComplete = lastOfType(recent, ["task_complete"]);
  const lastTurnAborted = lastOfType(recent, ["turn_aborted"]);
  const lastTerminal = lastOfType(recent, ["task_complete", "turn_aborted"]);
  const lastAgentMessage = lastOfType(recent, ["agent_message", "assistant_message", "message"]);
  const lastUserMessage = lastOfType(recent, ["user_message"]);
  const lastLine = lastItem?.line ?? null;
  const lastTaskCompleteLine = lastTaskComplete?.line ?? null;
  const lastTurnAbortedLine = lastTurnAborted?.line ?? null;
  const lastTerminalLine = lastTerminal?.line ?? null;
  const lastUserLine = lastUserMessage?.line ?? null;
  const maybeMidTurn =
    typeof lastUserLine === "number" &&
    (typeof lastTerminalLine !== "number" || lastUserLine > lastTerminalLine) &&
    (!lastAgentMessage || lastAgentMessage.line < lastUserLine);

  return {
    dbUpdatedAt: thread?.updatedAt || null,
    dbUpdatedAtMs: thread?.updatedAtMs ?? null,
    newestRolloutLine: lastLine,
    newestRolloutType: lastItem?.payloadType || null,
    lastTaskCompleteLine,
    lastTurnAbortedLine,
    lastTerminalLine,
    lastTerminalType: lastTerminal?.payloadType || null,
    terminalState:
      lastTerminal?.payloadType === "turn_aborted"
        ? "aborted"
        : lastTerminal?.payloadType === "task_complete"
          ? "completed"
          : "none",
    lastUserMessageLine: lastUserLine,
    lastAgentMessageLine: lastAgentMessage?.line ?? null,
    hasTaskCompleteInTail: Boolean(lastTaskComplete),
    hasTurnAbortedInTail: Boolean(lastTurnAborted),
    hasTerminalInTail: Boolean(lastTerminal),
    maybeMidTurn,
    conclusion:
      maybeMidTurn
        ? "tail suggests a user turn may not yet have a following agent message/terminal event"
        : "no mid-turn condition inferred from the requested tail",
  };
}

function lastOfType(items, types) {
  const wanted = new Set(types);
  for (let index = items.length - 1; index >= 0; index -= 1) {
    if (wanted.has(items[index].payloadType)) {
      return items[index];
    }
  }
  return null;
}

function fileInfo(filePath) {
  if (!filePath || !existsSync(filePath)) {
    return { exists: false };
  }
  const stat = statSync(filePath);
  return {
    exists: true,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function truncate(text, maxChars) {
  if (!text) {
    return "";
  }
  const normalized = String(text).replace(/\s+/g, " ").trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return `${normalized.slice(0, Math.max(0, maxChars - 14))}...[truncated]`;
}

function increment(counts, key) {
  counts[key] = (counts[key] || 0) + 1;
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
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

  const result = await inspectSession(opts);
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) {
    process.exit(1);
  }
}

await main();
