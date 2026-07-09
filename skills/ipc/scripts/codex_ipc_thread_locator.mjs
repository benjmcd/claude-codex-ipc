#!/usr/bin/env node
// Read-only Codex Desktop thread locator for /ipc new-session workflows.
//
// This helper reads the Codex Desktop SQLite thread index and reports candidate
// conversationIds for a workspace/project. It never connects to the IPC pipe,
// never sends a prompt, and never writes SQLite. A candidate is not send
// authority: inspect the chosen conversationId before using --ipc.

import path from "node:path";
import { existsSync, statSync } from "node:fs";

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

const DEFAULT_LIMIT = 10;
const THREAD_COLUMNS = [
  "id",
  "rollout_path",
  "created_at",
  "updated_at",
  "cwd",
  "title",
  "model",
  "reasoning_effort",
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
  node scripts/codex_ipc_thread_locator.mjs --cwd <workspace> [options]
  node scripts/codex_ipc_thread_locator.mjs --project <project-name> [options]
  node scripts/codex_ipc_thread_locator.mjs --list-projects

Options:
  --cwd <path>              Match normalized thread cwd.
  --project <name>          Match normalized basename of thread cwd.
  --title-contains <text>   Filter candidate title/preview. May be repeated.
  --since-iso <timestamp>   Include threads created/updated at or after this ISO timestamp.
  --since-ms <epoch-ms>     Include threads created/updated at or after this epoch ms.
  --include-archived        Include archived threads. Default: exclude archived.
  --limit <n>               Max candidates to return. Default: ${DEFAULT_LIMIT}
  --require-single          Exit non-zero unless exactly one candidate remains.
  --db <path>               State DB path. Default: %USERPROFILE%\\.codex\\state_5.sqlite
  --help                    Show this help.

Safety:
  Read-only only. Opens SQLite with readOnly:true, sends no IPC messages, and
  writes no files. Candidate discovery is not write authority; run
  codex_ipc_session_inspect.mjs on the selected conversationId before sending.`;
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
    cwd: null,
    project: null,
    titleContains: [],
    sinceMs: null,
    includeArchived: false,
    limit: DEFAULT_LIMIT,
    requireSingle: false,
    dbPath: defaultCodexPath("state_5.sqlite"),
    listProjects: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--cwd":
        opts.cwd = takeValue(argv, ++index, arg);
        break;
      case "--project":
        opts.project = takeValue(argv, ++index, arg);
        break;
      case "--title-contains":
        opts.titleContains.push(takeValue(argv, ++index, arg));
        break;
      case "--since-iso":
        opts.sinceMs = parseIsoMs(takeValue(argv, ++index, arg), arg);
        break;
      case "--since-ms":
        opts.sinceMs = parseEpochMs(takeValue(argv, ++index, arg), arg);
        break;
      case "--include-archived":
        opts.includeArchived = true;
        break;
      case "--limit":
        opts.limit = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--require-single":
        opts.requireSingle = true;
        break;
      case "--db":
        opts.dbPath = takeValue(argv, ++index, arg);
        break;
      case "--list-projects":
        opts.listProjects = true;
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!opts.help && !opts.listProjects && !opts.cwd && !opts.project) {
    throw new Error("Provide --cwd, --project, or --list-projects");
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
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}

function parseEpochMs(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive epoch-ms integer`);
  }
  return parsed;
}

function parseIsoMs(value, flag) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${flag} must be a parseable ISO timestamp`);
  }
  return parsed;
}

function inspectDb(opts) {
  if (!existsSync(opts.dbPath)) {
    return {
      ok: false,
      path: opts.dbPath,
      exists: false,
      error: "State DB was not found.",
    };
  }

  let db;
  try {
    db = new DatabaseSync(opts.dbPath, { readOnly: true });
    const availableColumns = new Set(
      db.prepare("pragma table_info(threads)").all().map((row) => row.name),
    );
    const selectedColumns = THREAD_COLUMNS.filter((column) => availableColumns.has(column));
    const rows = db
      .prepare(`select ${selectedColumns.join(", ")} from threads`)
      .all()
      .map((row) => summarizeThread(row));

    if (opts.listProjects) {
      const projects = summarizeProjects(rows, opts.includeArchived).slice(0, opts.limit);
      return {
        ok: true,
        mode: "thread-locator",
        generatedAt: new Date().toISOString(),
        db: dbInfo(opts.dbPath),
        listProjects: true,
        projects,
        warnings: baseWarnings(),
      };
    }

    const candidates = rows
      .filter((row) => matchesFilters(row, opts))
      .sort(compareThreads)
      .slice(0, opts.limit);
    const ok = opts.requireSingle ? candidates.length === 1 : candidates.length > 0;

    return {
      ok,
      mode: "thread-locator",
      generatedAt: new Date().toISOString(),
      db: dbInfo(opts.dbPath),
      filters: {
        cwd: opts.cwd,
        project: opts.project,
        titleContains: opts.titleContains,
        sinceMs: opts.sinceMs,
        sinceIso: opts.sinceMs ? new Date(opts.sinceMs).toISOString() : null,
        includeArchived: opts.includeArchived,
        limit: opts.limit,
        requireSingle: opts.requireSingle,
      },
      candidateCount: candidates.length,
      candidates,
      nextStep:
        candidates.length === 1
          ? "Run codex_ipc_session_inspect.mjs on this conversationId before any --ipc send."
          : "Do not send. Narrow with --title-contains/--since-iso or ask the user to choose a conversationId.",
      warnings: baseWarnings(),
    };
  } finally {
    if (db) {
      db.close();
    }
  }
}

function dbInfo(dbPath) {
  const stat = statSync(dbPath);
  return {
    path: dbPath,
    exists: true,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function summarizeThread(row) {
  const cwd = row.cwd || "";
  const normalizedCwd = normalizePath(cwd);
  return {
    id: row.id,
    cwd,
    normalizedCwd,
    projectName: projectNameFromCwd(cwd),
    title: row.title || "",
    model: row.model || null,
    reasoningEffort: row.reasoning_effort || null,
    tokensUsed: row.tokens_used ?? null,
    archived: Boolean(row.archived),
    threadSource: row.thread_source || null,
    preview: truncate(row.preview || "", 300),
    firstUserMessage: truncate(row.first_user_message || "", 300),
    rolloutPath: row.rollout_path || null,
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
    createdAtMs: row.created_at_ms ?? null,
    updatedAtMs: row.updated_at_ms ?? null,
    createdAtIso: msToIso(row.created_at_ms),
    updatedAtIso: msToIso(row.updated_at_ms),
  };
}

function summarizeProjects(rows, includeArchived) {
  const byProject = new Map();
  for (const row of rows) {
    if (!includeArchived && row.archived) {
      continue;
    }
    const key = row.projectName || "(unknown)";
    const current = byProject.get(key) || {
      projectName: key,
      cwdSamples: new Set(),
      threadCount: 0,
      newestUpdatedAtMs: 0,
      newestUpdatedAtIso: null,
    };
    current.cwdSamples.add(row.cwd);
    current.threadCount += 1;
    if ((row.updatedAtMs || 0) > current.newestUpdatedAtMs) {
      current.newestUpdatedAtMs = row.updatedAtMs || 0;
      current.newestUpdatedAtIso = row.updatedAtIso;
    }
    byProject.set(key, current);
  }
  return [...byProject.values()]
    .map((item) => ({
      ...item,
      cwdSamples: [...item.cwdSamples].filter(Boolean).slice(0, 5),
    }))
    .sort((left, right) => right.newestUpdatedAtMs - left.newestUpdatedAtMs);
}

function matchesFilters(row, opts) {
  if (!opts.includeArchived && row.archived) {
    return false;
  }
  if (opts.cwd && normalizePath(opts.cwd) !== row.normalizedCwd) {
    return false;
  }
  if (opts.project && normalizeName(opts.project) !== normalizeName(row.projectName)) {
    return false;
  }
  if (opts.sinceMs) {
    const newestMs = Math.max(row.createdAtMs || 0, row.updatedAtMs || 0);
    if (newestMs < opts.sinceMs) {
      return false;
    }
  }
  for (const needle of opts.titleContains) {
    const normalizedNeedle = normalizeText(needle);
    const haystack = normalizeText(`${row.title}\n${row.preview}\n${row.firstUserMessage}`);
    if (!haystack.includes(normalizedNeedle)) {
      return false;
    }
  }
  return true;
}

function compareThreads(left, right) {
  return (
    (right.updatedAtMs || 0) - (left.updatedAtMs || 0) ||
    (right.createdAtMs || 0) - (left.createdAtMs || 0) ||
    String(left.id).localeCompare(String(right.id))
  );
}

function normalizePath(value) {
  return String(value || "")
    .replace(/^\\\\\?\\/, "")
    .replace(/^\/\/\?\//, "")
    .replace(/\//g, "\\")
    .replace(/\\+$/g, "")
    .toLowerCase();
}

function projectNameFromCwd(cwd) {
  const cleaned = String(cwd || "")
    .replace(/^\\\\\?\\/, "")
    .replace(/^\/\/\?\//, "")
    .replace(/[\\/]+$/g, "");
  return cleaned ? path.win32.basename(cleaned) : "";
}

function normalizeName(value) {
  return String(value || "").trim().toLowerCase();
}

function normalizeText(value) {
  return String(value || "").toLowerCase();
}

function msToIso(value) {
  if (!Number.isFinite(value)) {
    return null;
  }
  try {
    return new Date(value).toISOString();
  } catch {
    return null;
  }
}

function truncate(text, maxChars) {
  const normalized = String(text || "").replace(/\s+/g, " ").trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return `${normalized.slice(0, Math.max(0, maxChars - 14))}...[truncated]`;
}

function baseWarnings() {
  return [
    "Read-only evidence only: no IPC connection, no prompt send, and no SQLite write were attempted.",
    "Locator candidates are not write authority; inspect the selected conversationId before --ipc.",
    "If more than one candidate remains, do not choose by recency alone for a write.",
  ];
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

  const result = inspectDb(opts);
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) {
    process.exit(1);
  }
}

await main();
