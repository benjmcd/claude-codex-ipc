#!/usr/bin/env node
// Runtime-queue delivery helper for `handoff_to_codex.sh --ipc <uuid> --deliver queue`, and the
// read-only queue-item probe that codex_ipc_wait.mjs --queue-id uses.
//
// send: after read-only preflight, runs exactly
//     <runtime> queue --thread <uuid> --message <text>
// once, as an argv array (no shell, no --resume, --remote or -c), with a timeout, and prints one
// JSON document describing the outcome. The runtime path is the intended Desktop host's own proven
// app-server executable from the shared host policy; this helper never looks up `codex` on PATH.
// It never retries. Outcomes:
//   queued         the runtime printed exactly "Queued message <qid> for thread <uuid>." for the
//                  target thread and exited 0.
//   not-attempted  preflight refused, or the process could not be started at all (no pid), so the
//                  runtime never ran.
//   unknown        the runtime ran and anything else happened (nonzero exit, signal, timeout,
//                  unrecognized output, another thread): the item may have been queued.
//
// probe (library only): readQueuedItem() opens the queue store read-only and reports whether one
// queued item is still present. It never writes.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { realpathSync } from "node:fs";
import { spawnSync } from "node:child_process";

export const QUEUE_SEND_DEFAULT_TIMEOUT_MS = 30000;
export const QUEUE_STORE_FILE = "queue_1.sqlite";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const QUEUED_LINE_RE =
  /^Queued message ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) for thread ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.$/i;
const RUNTIME_NAMES = new Set(["codex.exe", "codex"]);
const OUTPUT_LIMIT_BYTES = 1024 * 1024;
const EXCERPT_BYTES = 600;
const EXCERPT_LINES = 6;

// The Codex home the inspector read (USERPROFILE, else HOME, plus .codex). The runtime writes the
// queue under CODEX_HOME when that is set, so a different CODEX_HOME would send the item to a
// store the preflight never checked.
export function inspectedCodexHome(env = process.env) {
  const home = env.USERPROFILE || env.HOME;
  if (!home) return null;
  return path.join(home, ".codex");
}

function samePath(left, right) {
  const normalize = (value) => {
    let result = path.resolve(value);
    if (result.length > path.parse(result).root.length) result = result.replace(/[\\/]+$/u, "");
    return process.platform === "win32" ? result.toLowerCase() : result;
  };
  return normalize(left) === normalize(right);
}

function regularFile(filePath) {
  try {
    return fs.statSync(filePath).isFile();
  } catch {
    return false;
  }
}

// Bounded, single-line-per-entry excerpt of runtime diagnostics: no ANSI or control characters.
export function excerpt(text) {
  if (typeof text !== "string" || text.length === 0) return [];
  const clean = text
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/gu, "")
    .replace(/\r\n?/gu, "\n")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/gu, "");
  const lines = clean.split("\n").map((line) => line.trimEnd()).filter((line) => line.length > 0);
  const kept = [];
  let bytes = 0;
  for (const line of lines.slice(0, EXCERPT_LINES)) {
    const room = EXCERPT_BYTES - bytes;
    if (room <= 0) break;
    const slice = Buffer.from(line, "utf8").subarray(0, room).toString("utf8").replace(/�$/u, "");
    kept.push(slice);
    bytes += Buffer.byteLength(slice, "utf8");
  }
  return kept;
}

// Exactly one line on stdout, matching the runtime's own success sentence. Anything more or less
// is unrecognized, so a future runtime that adds output cannot be misread as a success.
export function parseQueuedOutput(stdout) {
  if (typeof stdout !== "string") return null;
  const body = stdout.replace(/\r?\n$/u, "");
  if (body.length === 0 || /[\r\n]/u.test(body)) return null;
  const match = QUEUED_LINE_RE.exec(body);
  if (!match) return null;
  return { queueId: match[1].toLowerCase(), threadId: match[2].toLowerCase() };
}

function timeoutFromEnv(env, warnings) {
  const raw = env.CODEX_IPC_QUEUE_TIMEOUT_MS;
  if (raw === undefined || raw === "") return QUEUE_SEND_DEFAULT_TIMEOUT_MS;
  if (/^[1-9][0-9]{0,8}$/.test(raw)) return Number.parseInt(raw, 10);
  warnings.push(
    `CODEX_IPC_QUEUE_TIMEOUT_MS must be a positive integer; using default ${QUEUE_SEND_DEFAULT_TIMEOUT_MS}.`,
  );
  return QUEUE_SEND_DEFAULT_TIMEOUT_MS;
}

export function sendToQueue(request, injected = {}) {
  const env = injected.env || process.env;
  const spawn = injected.spawnSync || spawnSync;
  const warnings = [];
  const result = (outcome, reason, extra = {}) => ({
    schemaVersion: 1,
    outcome,
    reason,
    queueId: null,
    reportedThreadId: null,
    exitCode: null,
    signal: null,
    runtimeStderr: [],
    warnings,
    ...extra,
  });
  const { runtime, threadId, message, cwd } = request;

  // Preflight: everything here is read-only, and any refusal means the runtime never ran.
  if (typeof threadId !== "string" || !UUID_RE.test(threadId)) {
    return result("not-attempted", "invalid-request");
  }
  if (typeof message !== "string" || message.length === 0 || message.includes("\u0000")) {
    return result("not-attempted", "invalid-request");
  }
  if (typeof runtime !== "string" || !path.isAbsolute(runtime) || !regularFile(runtime)) {
    return result("not-attempted", "runtime-missing");
  }
  if (!RUNTIME_NAMES.has(path.basename(runtime).toLowerCase())) {
    return result("not-attempted", "runtime-unexpected-name");
  }
  const codexHome = inspectedCodexHome(env);
  if (!codexHome) return result("not-attempted", "codex-home-unresolved");
  if (env.CODEX_HOME && !samePath(env.CODEX_HOME, codexHome)) {
    return result("not-attempted", "codex-home-mismatch");
  }
  if (!regularFile(path.join(codexHome, QUEUE_STORE_FILE))) {
    return result("not-attempted", "queue-store-absent");
  }
  const timeoutMs = timeoutFromEnv(env, warnings);

  const child = spawn(runtime, ["queue", "--thread", threadId.toLowerCase(), "--message", message], {
    cwd: cwd || undefined,
    env,
    encoding: "utf8",
    windowsHide: true,
    timeout: timeoutMs,
    killSignal: "SIGTERM",
    maxBuffer: OUTPUT_LIMIT_BYTES,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const runtimeStderr = excerpt(child.stderr);
  const common = { exitCode: child.status ?? null, signal: child.signal ?? null, runtimeStderr };

  // A spawn failure has no pid: the process never existed, so nothing could have been queued.
  if (child.error && !child.pid) {
    return result("not-attempted", "runtime-launch-failed", {
      ...common,
      launchError: String(child.error.code || "spawn-error"),
    });
  }
  if (child.error?.code === "ETIMEDOUT") {
    return result("unknown", "queue-timeout", { ...common, timeoutMs });
  }
  if (child.error || child.signal || child.status !== 0) {
    return result("unknown", "queue-runtime-failed", {
      ...common,
      ...(child.error ? { runtimeError: String(child.error.code || "error") } : {}),
    });
  }
  const parsed = parseQueuedOutput(child.stdout);
  if (!parsed) {
    return result("unknown", "queue-output-unrecognized", {
      ...common,
      runtimeStdout: excerpt(child.stdout),
    });
  }
  if (parsed.threadId !== threadId.toLowerCase()) {
    return result("unknown", "queue-thread-mismatch", {
      ...common,
      queueId: parsed.queueId,
      reportedThreadId: parsed.threadId,
    });
  }
  return result("queued", "runtime-accepted", {
    ...common,
    queueId: parsed.queueId,
    reportedThreadId: parsed.threadId,
  });
}

// node:sqlite prints an ExperimentalWarning on import; that one warning is noise on a waiter's
// stderr. Every other warning still prints.
async function loadSqlite() {
  const original = process.emitWarning;
  process.emitWarning = function filtered(warning, ...rest) {
    const type = typeof rest[0] === "string" ? rest[0] : rest[0]?.type;
    const text = typeof warning === "string" ? warning : warning?.message;
    if (type === "ExperimentalWarning" && /\bSQLite\b/u.test(String(text))) return undefined;
    return original.call(process, warning, ...rest);
  };
  try {
    return await import("node:sqlite");
  } finally {
    process.emitWarning = original;
  }
}

// Read-only lookup of one ordinary queued item. Never writes: the store is opened read-only, and
// an explicitly selected Python SQLite reader (CODEX_IPC_SQLITE_READER) is honored by refusing,
// because that selection never falls back to node:sqlite.
export async function readQueuedItem({ dbPath, queueId }, env = process.env) {
  if (Object.hasOwn(env, "CODEX_IPC_SQLITE_READER")) {
    return { status: "unavailable", reason: "sqlite-reader-selected" };
  }
  if (typeof queueId !== "string" || !UUID_RE.test(queueId)) {
    return { status: "unavailable", reason: "invalid-queue-id" };
  }
  if (!regularFile(dbPath)) return { status: "unavailable", reason: "queue-store-absent" };
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await loadSqlite());
  } catch {
    return { status: "unavailable", reason: "node-sqlite-unavailable" };
  }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db
      .prepare("select id, thread_id, created_at_ms from queued_items where id = ?")
      .get(queueId.toLowerCase());
    if (!row) return { status: "absent" };
    const createdAtMs = Number(row.created_at_ms);
    return {
      status: "present",
      queueId: String(row.id),
      threadId: String(row.thread_id).toLowerCase(),
      createdAtMs: Number.isSafeInteger(createdAtMs) ? createdAtMs : null,
    };
  } catch (error) {
    return { status: "unavailable", reason: "queue-store-read-failed", message: error.message };
  } finally {
    if (db) {
      try { db.close(); } catch { /* read-only handle; nothing to flush */ }
    }
  }
}

export function defaultQueueDbPath() {
  return path.join(os.homedir(), ".codex", QUEUE_STORE_FILE);
}

function usage() {
  return `Usage: node codex_ipc_queue.mjs send --runtime <absolute codex.exe> --thread <uuid> --message <text> [--cwd <dir>]

Runs <runtime> queue --thread <uuid> --message <text> exactly once and prints one JSON document
(outcome queued | not-attempted | unknown). Used by handoff_to_codex.sh --deliver queue; the
runtime must be the intended Desktop host's own proven runtime from the shared host policy.

Environment:
  CODEX_IPC_QUEUE_TIMEOUT_MS  runtime timeout (default ${QUEUE_SEND_DEFAULT_TIMEOUT_MS}); a timeout reports unknown`;
}

function parseSendArgs(argv) {
  const request = { runtime: null, threadId: null, message: null, cwd: null };
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const key = { "--runtime": "runtime", "--thread": "threadId", "--message": "message", "--cwd": "cwd" }[arg];
    if (!key) throw new Error(`unknown argument: ${arg}`);
    if (seen.has(key)) throw new Error(`${arg} may be supplied only once`);
    seen.add(key);
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${arg} requires a value`);
    request[key] = value;
    index += 1;
  }
  for (const [flag, key] of [["--runtime", "runtime"], ["--thread", "threadId"], ["--message", "message"]]) {
    if (request[key] === null) throw new Error(`${flag} is required`);
  }
  return request;
}

function main(argv) {
  if (argv[0] === "-h" || argv[0] === "--help") {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  let request;
  try {
    if (argv[0] !== "send") throw new Error(`unknown argument: ${argv[0] ?? "(none)"}`);
    request = parseSendArgs(argv.slice(1));
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    console.error(usage());
    process.exitCode = 2;
    return;
  }
  const outcome = sendToQueue(request);
  process.stdout.write(`${JSON.stringify(outcome)}\n`);
  process.exitCode = outcome.outcome === "queued" ? 0 : 1;
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
  main(process.argv.slice(2));
}
