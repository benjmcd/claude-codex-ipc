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
import {
  advanceRolloutHistoryScope,
  advanceRolloutOwnerLineage,
  createTurnBoundaryAccumulator,
  locateRollout,
  normalizeRolloutRecord,
  parseRolloutBasename,
  recordThreadIdentity,
  summarizeThreadActivity,
} from "./codex_ipc_rollout_reader.mjs";

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
// Raw recentItems remain an inspection/display surface. Activity projections use this private,
// non-serialized tail so copied fork history can never become child-local activity evidence.
const ADMITTED_ACTIVITY_ITEMS = Symbol("admittedActivityItems");
// --- `--summary` projection caps (O3) -------------------------------------------------------
// These bound the ONLY two open-ended arrays the projection carries. They are projection-time
// caps: they never reach parseArgs, inspectSession, parseRollout or inferActivitySignals, so
// they cannot shift a parsing parameter. See projectSummary() for the S1 invariant.
const SUMMARY_CANDIDATE_CAP = 5;
const SUMMARY_TAIL_ITEMS = 3;
const SUMMARY_TEXT_CHARS = 120;
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
  --summary              Print the preflight PROJECTION of the same computed object under the
                         same parsing parameters: the SKILL.md-mandated fields plus a bounded
                         ${SUMMARY_TAIL_ITEMS}-item rollout tail and a bounded ${SUMMARY_CANDIDATE_CAP}-element candidate list
                         (selection.candidateCount always states the true total). Re-run the
                         identical command without --summary for the full object.
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
    // S1 enforcement rule 1: `--summary` sets exactly ONE boolean and has no other parse-time
    // effect. It is deliberately NOT a value-bearing option and never rewrites another field.
    summary: false,
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
      case "--summary":
        opts.summary = true;
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
    opts.threadId = opts.threadId.toLowerCase();
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
    ? await parseRollout(primaryRollout.path, opts.tailEvents, opts.maxTextChars, opts.threadId)
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
        ...(rolloutSelection.reason === "candidate-set-unresolved"
          ? {
              rejectedCandidateCount: rolloutSelection.rejectedCandidateCount ?? 0,
              scanIssueCount: rolloutSelection.scanIssueCount ?? 0,
            }
          : {}),
      },
    },
    activitySignals: inferActivitySignals(dbThread.thread, rolloutSummary, rolloutSelection.status),
    warnings: [
      "Read-only evidence only: no IPC connection, no Desktop message send, and no SQLite write were attempted.",
      "DB row and rollout presence do not prove the owning Desktop renderer is currently open.",
      "Activity signals are heuristic; read the rollout context before interrupting or adding a new turn.",
      ...(rolloutSelection.reason === "multiple-candidates"
        ? ["Multiple distinct rollout candidates have equal authority; no primary rollout was selected."]
        : rolloutSelection.reason === "candidate-set-unresolved"
          ? [
              "Rollout discovery encountered rejected target candidates or unreadable scan state; no primary rollout was selected.",
            ]
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
    // reply-writability prediction. A blocked reply write is a non-event: the opt-in waiter
    // certifies named-dispatch completion and `replySource=rollout-fallback` but intentionally emits
    // no body; retrieval belongs to the read-only dual-source `codex_ipc_replies.sh` viewer, never a
    // policy gate. Completion-time
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
  let rejectedDbCandidate = null;
  const rejectedSessionsCandidates = [];
  const scanIssues = [];

  function addCandidate(filePath, source) {
    if (!filePath) {
      return;
    }
    const validated = locateRollout({ threadId, rolloutPath: filePath });
    if (validated.status !== "found") {
      if (source === "db.rollout_path") {
        rejectedDbCandidate = validated;
      } else {
        rejectedSessionsCandidates.push({ ...validated, path: filePath });
      }
      return;
    }
    const stat = statSync(filePath);
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

  // A present DB-designated path is authority, including when its identity is
  // invalid. Never recover from an identity-invalid DB path by selecting a
  // different sessions-root file.
  if (rejectedDbCandidate) {
    return {
      candidates: [],
      primaryCandidate: null,
      ambiguousCandidates: [],
      status: "unavailable",
      reason: rejectedDbCandidate.reason || "identity-mismatch",
      authority: "db.rollout_path",
      aliasCount: 0,
    };
  }

  if (existsSync(sessionsRoot)) {
    for (const filePath of walkFiles(sessionsRoot, (issue) => scanIssues.push(issue))) {
      const basename = path.basename(filePath);
      const filename = parseRolloutBasename(basename);
      if (filename?.rootThreadId === threadId.toLowerCase()) {
        addCandidate(filePath, "sessions-root-match");
      } else if (
        basename.toLowerCase().startsWith("rollout-") &&
        basename.toLowerCase().includes(threadId.toLowerCase()) &&
        !(filename?.paginated && filename.pageId === threadId.toLowerCase())
      ) {
        rejectedSessionsCandidates.push({
          status: "unavailable",
          reason: "rollout-name-unrecognized",
          path: filePath,
        });
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
  // otherwise exactly one physical sessions-root match may be selected only when
  // discovery itself is complete. A rejected target-named sibling or scan failure
  // makes the root-only candidate set unresolved rather than silently selecting an
  // older valid file. DB-designated parse validity remains visible as parsedOk and
  // never causes an implicit fallback to a different file than the DB named.
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
  if (rejectedSessionsCandidates.length > 0 || scanIssues.length > 0) {
    return {
      candidates,
      primaryCandidate: null,
      ambiguousCandidates: candidates,
      status: "ambiguous",
      reason: "candidate-set-unresolved",
      authority: "sessions-root-match",
      aliasCount,
      rejectedCandidateCount: rejectedSessionsCandidates.length,
      scanIssueCount: scanIssues.length,
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

function* walkFiles(root, onIssue = () => {}) {
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch (error) {
    onIssue({ reason: "directory-unreadable", path: root, message: error.message });
    return;
  }
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      yield* walkFiles(fullPath, onIssue);
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      yield fullPath;
    }
  }
}

async function parseRollout(filePath, tailEvents, maxTextChars, expectedThreadId) {
  const info = fileInfo(filePath);
  const recentItems = [];
  const admittedActivityItems = [];
  const countsByEnvelopeType = {};
  const countsByPayloadType = {};
  const parseErrors = [];
  let lineCount = 0;
  let parsedCount = 0;
  let sessionMeta = null;
  let rolloutThreadId = null;
  let rolloutLineageIds = [];
  let forkHistoryScope = null;
  let forkHistoryConflict = false;
  let sessionMetaSeen = false;
  // A4: feed the FULL parse stream (not the clipped display tail) into the ONE shared boundary
  // machine (createTurnBoundaryAccumulator). Its final emitted snapshot drives turnActivity via
  // the pure summarizeThreadActivity projection; the inspector keeps its own parse/count/display.
  const accumulator = createTurnBoundaryAccumulator();
  const boundarySnapshots = [];
  const boundaryDiagnostics = [];
  const ownerIntegrityDiagnostics = [];

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
      boundarySnapshots.push(...accumulator.push({ parseError: true, line: lineCount }).snapshots);
      continue;
    }

    parsedCount += 1;
    const isSessionMeta = parsed?.type === "session_meta";
    let ownerConflict = false;
    const ownerLineage = advanceRolloutOwnerLineage(parsed, {
      rolloutThreadId,
      lineageIds: rolloutLineageIds,
      expectedThreadId,
    });
    if (ownerLineage.status === "invalid" || ownerLineage.status === "mismatch") {
      ownerConflict = true;
      const item = {
        code: "schema-drift",
        line: lineCount,
        reason:
          ownerLineage.status === "invalid"
            ? "rollout-thread-id-invalid"
            : "rollout-thread-id-mismatch",
      };
      boundaryDiagnostics.push(item);
      ownerIntegrityDiagnostics.push(item);
    }
    if (ownerLineage.status === "accepted") {
      rolloutThreadId = ownerLineage.rolloutThreadId;
      rolloutLineageIds = ownerLineage.lineageIds;
    }
    const declaredSessionId =
      isSessionMeta && typeof parsed?.payload?.id === "string" && UUID_RE.test(parsed.payload.id)
        ? parsed.payload.id.toLowerCase()
        : null;
    const isCurrentOwnerSessionMeta =
      ownerLineage.status === "accepted" &&
      declaredSessionId !== null &&
      declaredSessionId === rolloutThreadId;
    if (isCurrentOwnerSessionMeta) sessionMetaSeen = true;
    const recordOwner = recordThreadIdentity(parsed);
    let inheritedHistory = false;
    let historyAdmitted = false;
    if (!forkHistoryConflict) {
      const historyScope = advanceRolloutHistoryScope(parsed, forkHistoryScope, {
        isFirstRecord: parsedCount === 1,
      });
      if (historyScope.status === "missing" || historyScope.status === "invalid") {
        forkHistoryConflict = true;
        const item = {
          code: "schema-drift",
          line: lineCount,
          reason: historyScope.reason,
        };
        boundaryDiagnostics.push(item);
        ownerIntegrityDiagnostics.push(item);
      } else {
        forkHistoryScope = historyScope.state;
        inheritedHistory = historyScope.status === "skip";
        historyAdmitted = historyScope.status === "admit";
      }
    }
    if (!ownerConflict && !forkHistoryConflict && !inheritedHistory && recordOwner.status !== "absent") {
      const ownerReason =
        recordOwner.status === "invalid"
          ? "rollout-thread-id-invalid"
          : "rollout-thread-id-mismatch";
      const recordOwnerMismatch =
        recordOwner.status === "conflict" ||
        recordOwner.status === "invalid" ||
        (recordOwner.status === "valid" &&
          expectedThreadId &&
          recordOwner.threadId !== expectedThreadId.toLowerCase()) ||
        (recordOwner.status === "valid" &&
          rolloutThreadId &&
          recordOwner.threadId !== rolloutThreadId.toLowerCase());
      if (recordOwnerMismatch) {
        ownerConflict = true;
        const item = {
          code: "schema-drift",
          line: lineCount,
          reason: ownerReason,
        };
        boundaryDiagnostics.push(item);
        ownerIntegrityDiagnostics.push(item);
      }
    }
    if (!forkHistoryConflict && !inheritedHistory) {
      const normalized = normalizeRolloutRecord(parsed, {
        line: lineCount,
        rolloutThreadId: rolloutThreadId || expectedThreadId,
      });
      const boundaryRecord = ownerConflict
        ? { ...normalized, knownPair: false, text: "", phase: null, role: null }
        : normalized;
      boundarySnapshots.push(...accumulator.push(boundaryRecord).snapshots);
      if (!normalized.knownPair) {
        boundaryDiagnostics.push({ code: "schema-drift", line: lineCount });
      }
    }
    const item = summarizeJsonlItem(parsed, lineCount, maxTextChars);
    increment(countsByEnvelopeType, item.envelopeType || "unknown");
    increment(countsByPayloadType, item.payloadType || "unknown");
    if (isCurrentOwnerSessionMeta && sessionMeta === null) {
      sessionMeta = item;
    }
    if (historyAdmitted && !ownerConflict) {
      admittedActivityItems.push(item);
      while (admittedActivityItems.length > tailEvents) {
        admittedActivityItems.shift();
      }
    }
    recentItems.push(item);
    while (recentItems.length > tailEvents) {
      recentItems.shift();
    }
  }
  if (!sessionMetaSeen) {
    const item = {
      code: "schema-drift",
      line: null,
      reason: "rollout-thread-id-missing",
    };
    boundaryDiagnostics.push(item);
    ownerIntegrityDiagnostics.push(item);
  }
  if (
    forkHistoryScope?.mode === "producer-ordinal" &&
    forkHistoryScope.boundarySeen !== true &&
    !forkHistoryConflict
  ) {
    const item = {
      code: "schema-drift",
      line: lineCount,
      reason: "fork-history-boundary-unseen",
    };
    boundaryDiagnostics.push(item);
    ownerIntegrityDiagnostics.push(item);
  }
  boundarySnapshots.push(...accumulator.finish(boundaryDiagnostics));
  const latestBoundarySnapshot = boundarySnapshots.reduce(
    (latest, snap) => (latest === null || snap.sequence > latest.sequence ? snap : latest),
    null,
  );
  const boundarySnapshot = ownerIntegrityDiagnostics.length > 0 && latestBoundarySnapshot
    ? Object.freeze({
        sequence: latestBoundarySnapshot?.sequence ?? 0,
        turnId: latestBoundarySnapshot?.turnId ?? null,
        boundaryMode: latestBoundarySnapshot?.boundaryMode ?? null,
        activity: "ambiguous",
        terminalType: latestBoundarySnapshot?.terminalType ?? null,
        terminalLine: latestBoundarySnapshot?.terminalLine ?? null,
        superseded: latestBoundarySnapshot?.superseded ?? false,
        diagnostics: Object.freeze([
          ...(latestBoundarySnapshot?.diagnostics || []),
          ...ownerIntegrityDiagnostics,
        ]),
      })
    : latestBoundarySnapshot;

  return {
    parsedOk: parsedCount > 0 && parsedCount === lineCount,
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
    [ADMITTED_ACTIVITY_ITEMS]:
      ownerIntegrityDiagnostics.length === 0 ? admittedActivityItems : [],
    boundarySnapshot,
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
  const turnId =
    typeof payload.turn_id === "string"
      ? payload.turn_id
      : typeof payload.item?.turn_id === "string"
        ? payload.item.turn_id
        : null;

  return {
    line,
    timestamp: item.timestamp || payload.timestamp || null,
    envelopeType,
    payloadType,
    role,
    turnId,
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

function inferActivitySignals(thread, rollout, rolloutStatus) {
  const recent = rollout?.[ADMITTED_ACTIVITY_ITEMS] || [];
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

  // A4: turnActivity is the authoritative open/closed/ambiguous signal from the shared boundary
  // machine over the FULL parse stream; maybeMidTurn is preserved byte-compatibly (historical
  // tail heuristic) and the conclusion now derives from turnActivity, not maybeMidTurn.
  const { turnActivity } = summarizeThreadActivity(
    rollout?.boundarySnapshot || null,
    rolloutStatus || "unavailable",
  );

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
    turnActivity,
    conclusion:
      turnActivity === "open"
        ? "latest turn boundary is open: a start/user turn has no matching terminal (mid-turn)"
        : turnActivity === "closed"
          ? "latest turn boundary is closed: the latest turn reached its terminal"
          : "latest turn boundary is ambiguous: turn activity could not be determined from the rollout",
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

// --- `--summary`: the preflight projection (O3) ----------------------------------------------
//
// INVARIANT S1 -- SUMMARY IS A PARAMETER-IDENTICAL FIELD-SUBSET. For any argv A, the output of
// `A --summary` is a projection of the SAME result object that A produces: every JSON path in
// the summary exists at the identical path in the default output, and every scalar leaf at a
// shared path carries the identical value, with exactly three declared bounded carve-outs:
//   C-a  rollout.primary.recentItems -> the LAST <= SUMMARY_TAIL_ITEMS elements, 5 of 7 keys
//        (envelopeType and turnId dropped; turn correlation is already projected as turnActivity).
//   C-b  rollout.candidates / rollout.ambiguousCandidates -> the first <= SUMMARY_CANDIDATE_CAP
//        elements, 3 of 6 keys (path/source/size). The TRUE total is never lost: it stays at
//        rollout.selection.candidateCount, and the omitted count is candidateCount - length,
//        so no new field is invented. There is deliberately no per-candidate `authority` key --
//        none exists in the full output, and emitting one would break the subset invariant.
//   C-c  recentItems[*].text -> re-truncated to SUMMARY_TEXT_CHARS. This is the ONLY value
//        deviation, and it is self-evident (the existing "...[truncated]" marker). It is also
//        provably parameter-free: truncate() normalizes whitespace and then slices the ORIGINAL
//        characters, so for any n < m, truncate(truncate(s, m), n) === truncate(s, n) -- the
//        outer slice can never read the inner marker, and the normalization is idempotent. The
//        mini-tail text therefore equals what `--max-text-chars 120` would emit WITHOUT
//        maxTextChars ever changing (which would also have altered sessionMeta and every
//        non-tail item, and is the forbidden parameter shift).
//
// S1 enforcement rule 2 (structural): this projection is a PURE FUNCTION THAT NEVER RECEIVES
// `opts`. It takes one argument, reads no fs/DB/env, and uses only module-level `truncate` plus
// the three SUMMARY_* caps. A function that cannot see `opts` is structurally incapable of
// shifting a parsing parameter, and inspectSession/readDbThread/findRolloutCandidates/
// parseRollout/inferActivitySignals receive no branch at all. `ok` and the exit code are
// computed upstream and are identical in both modes.
//
// The retained field set is mandated by SKILL.md's preflight paragraph (the "Use the inspector
// output to identify:" paragraph). Any change here must keep tests/test_session_inspect.sh
// scenario 25 green: it carries the mandated field list AND greps the mandating SKILL.md prose,
// so a SKILL.md rewrite turns it red rather than letting the two drift apart silently. Scenario
// 24 separately pins the DEFAULT emit byte-for-byte against the pre-flag inspector.
function projectSummaryCandidate(candidate) {
  return { path: candidate.path, source: candidate.source, size: candidate.size };
}

function projectSummaryItem(item) {
  return {
    line: item.line,
    timestamp: item.timestamp,
    payloadType: item.payloadType,
    role: item.role,
    text: truncate(item.text, SUMMARY_TEXT_CHARS),
  };
}

function projectSummary(result) {
  const db = result.dbThread || {};
  const thread = db.thread || {};
  const rollout = result.rollout || {};
  const selection = rollout.selection || {};
  const primary = rollout.primary || null;
  const signals = result.activitySignals || {};
  // Reads are unconditional and direct: a key absent from the source object projects to
  // `undefined`, which JSON.stringify omits, so an absent path stays absent (never `null`).
  return {
    ok: result.ok,
    mode: result.mode,
    generatedAt: result.generatedAt,
    threadId: result.threadId,
    dbThread: {
      exists: db.exists,
      readOnlyOpenOk: db.readOnlyOpenOk,
      thread: {
        exists: thread.exists,
        id: thread.id,
        rolloutPath: thread.rolloutPath,
        cwd: thread.cwd,
        title: thread.title,
        model: thread.model,
        reasoningEffort: thread.reasoningEffort,
        approvalMode: thread.approvalMode,
        sandboxPolicy: thread.sandboxPolicy,
        permissionProfileAdvisory: thread.permissionProfileAdvisory,
        archived: thread.archived,
      },
      warnings: db.warnings,
    },
    rollout: {
      candidates: (rollout.candidates || [])
        .slice(0, SUMMARY_CANDIDATE_CAP)
        .map(projectSummaryCandidate),
      primary: primary && {
        parsedOk: primary.parsedOk,
        path: primary.path,
        lineCount: primary.lineCount,
        parsedCount: primary.parsedCount,
        parseErrorCount: primary.parseErrorCount,
        recentItems: (primary.recentItems || [])
          .slice(-SUMMARY_TAIL_ITEMS)
          .map(projectSummaryItem),
      },
      candidatesAmbiguous: rollout.candidatesAmbiguous,
      ambiguousCandidates: (rollout.ambiguousCandidates || [])
        .slice(0, SUMMARY_CANDIDATE_CAP)
        .map(projectSummaryCandidate),
      selection: {
        status: selection.status,
        reason: selection.reason,
        authority: selection.authority,
        path: selection.path,
        candidateCount: selection.candidateCount,
        aliasCount: selection.aliasCount,
        ...(selection.reason === "candidate-set-unresolved"
          ? {
              rejectedCandidateCount: selection.rejectedCandidateCount,
              scanIssueCount: selection.scanIssueCount,
            }
          : {}),
      },
    },
    activitySignals: {
      lastTaskCompleteLine: signals.lastTaskCompleteLine,
      terminalState: signals.terminalState,
      lastUserMessageLine: signals.lastUserMessageLine,
      lastAgentMessageLine: signals.lastAgentMessageLine,
      maybeMidTurn: signals.maybeMidTurn,
      turnActivity: signals.turnActivity,
      conclusion: signals.conclusion,
    },
  };
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
  console.log(JSON.stringify(opts.summary ? projectSummary(result) : result, null, 2));
  if (!result.ok) {
    process.exit(1);
  }
}

await main();
