#!/usr/bin/env node
// Read-only snapshot helper for Codex Desktop IPC isolation checks.
//
// This script does not connect to the Desktop IPC pipe and does not write to
// SQLite. It captures the config and state DB evidence needed around a future
// controlled follower write.

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";
import path from "node:path";

// node:sqlite is optional at the repo level: file-drop handoff works without it.
// Loaded lazily so --compare mode (plain JSON diffing) needs no SQLite support.
async function requireNodeSqlite() {
  try {
    const { DatabaseSync } = await import("node:sqlite");
    return DatabaseSync;
  } catch (error) {
    throw new Error(
      "node:sqlite is unavailable in this Node.js runtime. This optional inspection " +
        "feature requires a Node.js version with node:sqlite support (>= 22.5; older 22.x/23.x lines may require --experimental-sqlite). " +
        `File-drop handoff (handoff_to_codex.sh) works without it. (${error.message})`,
    );
  }
}

const CONFIG_KEYS = [
  "model",
  "model_reasoning_effort",
  "sandbox_mode",
  "approval_policy",
];
const THREAD_COLUMNS = [
  "id",
  "rollout_path",
  "created_at",
  "updated_at",
  "source",
  "model_provider",
  "cwd",
  "title",
  "sandbox_policy",
  "approval_mode",
  "tokens_used",
  "has_user_event",
  "archived",
  "git_sha",
  "git_branch",
  "cli_version",
  "first_user_message",
  "agent_nickname",
  "agent_role",
  "memory_mode",
  "model",
  "reasoning_effort",
  "agent_path",
  "created_at_ms",
  "updated_at_ms",
  "thread_source",
  "preview",
];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function usage() {
  return `Usage:
  node scripts/codex_ipc_snapshot.mjs [--thread <uuid>] [options]
  node scripts/codex_ipc_snapshot.mjs --compare <before.json> <after.json>

Snapshot options:
  --thread <uuid>              Target conversation/thread id. Required in snapshot mode.
  --other-thread <uuid>        Non-target thread to track. May be repeated.
  --marker <text>              Count a unique marker in the DB bytes.
  --summary                    Omit the full per-thread hash map from snapshot output.
  --db <path>                  State DB path. Default: %USERPROFILE%\\.codex\\state_5.sqlite
  --config <path>              Config path. Default: %USERPROFILE%\\.codex\\config.toml

Compare options:
  --compare <before> <after>   Compare two JSON snapshots produced by this script.
  --allow-thread-change <uuid> Permit an expected non-target row change during compare.
                               May be repeated for operator/control threads.
  --expect-target-change       Require the target thread row hash to change.
  --expect-marker-increase     Require the marker count to increase.

Safety:
  This helper is read-only. It opens SQLite with readOnly:true, never connects to
  \\\\.\\pipe\\codex-ipc, and writes no files.`;
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
    otherThreadIds: [],
    marker: null,
    includeThreadHashes: true,
    dbPath: defaultCodexPath("state_5.sqlite"),
    configPath: defaultCodexPath("config.toml"),
    compare: null,
    allowThreadChangeIds: [],
    expectTargetChange: false,
    expectMarkerIncrease: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--other-thread":
        opts.otherThreadIds.push(takeValue(argv, ++index, arg));
        break;
      case "--marker":
        opts.marker = takeValue(argv, ++index, arg);
        break;
      case "--summary":
        opts.includeThreadHashes = false;
        break;
      case "--db":
        opts.dbPath = takeValue(argv, ++index, arg);
        break;
      case "--config":
        opts.configPath = takeValue(argv, ++index, arg);
        break;
      case "--compare":
        opts.compare = [
          takeValue(argv, ++index, arg),
          takeValue(argv, ++index, arg),
        ];
        break;
      case "--allow-thread-change":
        opts.allowThreadChangeIds.push(takeValue(argv, ++index, arg));
        break;
      case "--expect-target-change":
        opts.expectTargetChange = true;
        break;
      case "--expect-marker-increase":
        opts.expectMarkerIncrease = true;
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
    for (const allowedThreadId of opts.allowThreadChangeIds) {
      validateUuid(allowedThreadId, "--allow-thread-change");
    }
    opts.allowThreadChangeIds = opts.allowThreadChangeIds.map((value) => value.toLowerCase());
  }

  if (!opts.help && !opts.compare) {
    if (!opts.threadId) {
      throw new Error("--thread is required in snapshot mode (no default thread id is shipped)");
    }
    validateUuid(opts.threadId, "--thread");
    for (const otherThreadId of opts.otherThreadIds) {
      validateUuid(otherThreadId, "--other-thread");
    }
    opts.threadId = opts.threadId.toLowerCase();
    opts.otherThreadIds = opts.otherThreadIds.map((value) => value.toLowerCase());
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

function validateUuid(value, flag) {
  if (!UUID_RE.test(value)) {
    throw new Error(`${flag} must be a UUID`);
  }
}

function canonicalUuid(value) {
  return typeof value === "string" && UUID_RE.test(value) ? value.toLowerCase() : null;
}

async function snapshot(opts) {
  const config = await readConfigSnapshot(opts.configPath);
  const db = await readDbSnapshot(
    opts.dbPath,
    opts.threadId,
    opts.otherThreadIds,
    opts.marker,
    opts.includeThreadHashes,
  );
  const ok = config.exists && db.exists && db.readOnlyOpenOk && db.threads.target.exists;

  return {
    ok,
    mode: "snapshot",
    generatedAt: new Date().toISOString(),
    targetThreadId: opts.threadId,
    otherThreadIds: opts.otherThreadIds,
    config,
    db,
    warnings: [
      "Read-only evidence only: no IPC connection and no SQLite write were attempted.",
      "Thread row hashes prove row-level changes, not full GUI rendering by themselves.",
    ],
  };
}

async function readConfigSnapshot(configPath) {
  const info = fileInfo(configPath);
  if (!info.exists) {
    return { path: configPath, exists: false };
  }

  const bytes = await readFile(configPath);
  const afterInfo = fileInfo(configPath);
  const text = bytes.toString("utf8");
  return {
    path: configPath,
    exists: true,
    size: info.size,
    mtimeMs: info.mtimeMs,
    stableDuringRead: stableFileInfo(info, afterInfo),
    statAfterRead: afterInfo,
    sha256: sha256(bytes),
    keys: parseConfigKeys(text),
  };
}

function parseConfigKeys(text) {
  const parsed = {};
  for (const key of CONFIG_KEYS) {
    const pattern = new RegExp(
      `^\\s*${escapeRegExp(key)}\\s*=\\s*(.+?)\\s*$`,
      "m",
    );
    const match = text.match(pattern);
    parsed[key] = match ? stripTomlScalar(match[1]) : null;
  }
  return parsed;
}

function stripTomlScalar(value) {
  const trimmed = value.trim();
  const quoted = trimmed.match(/^"(.*)"$/);
  return quoted ? quoted[1] : trimmed;
}

async function readDbSnapshot(dbPath, threadId, otherThreadIds, marker, includeThreadHashes) {
  const info = fileInfo(dbPath);
  if (!info.exists) {
    return { path: dbPath, exists: false, readOnlyOpenOk: false };
  }

  const DatabaseSync = await requireNodeSqlite();
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const rows = db.prepare(`select ${THREAD_COLUMNS.join(", ")} from threads order by id`).all();
    const tableNames = db
      .prepare("select name from sqlite_master where type = 'table' order by name")
      .all()
      .map((row) => row.name);
    const pageCount = db.prepare("pragma page_count").get().page_count;
    const pageSize = db.prepare("pragma page_size").get().page_size;
    const quickCheck = db.prepare("pragma quick_check").get().quick_check;
    const target = summarizeThread(rows.find((row) => row.id === threadId) || null);
    const otherThreads = Object.fromEntries(
      otherThreadIds.map((otherThreadId) => [
        otherThreadId,
        summarizeThread(rows.find((row) => row.id === otherThreadId) || null),
      ]),
    );
    const threadRowHashById = includeThreadHashes
      ? Object.fromEntries(rows.map((row) => [row.id, hashJson(row)]))
      : null;
    const binary = await readFile(dbPath);
    const afterInfo = fileInfo(dbPath);

    return {
      path: dbPath,
      exists: true,
      readOnlyOpenOk: true,
      size: info.size,
      mtimeMs: info.mtimeMs,
      stableDuringRead: stableFileInfo(info, afterInfo),
      statAfterRead: afterInfo,
      sha256: sha256(binary),
      tableNames,
      pageCount,
      pageSize,
      quickCheck,
      marker: marker
        ? {
            textSha256: sha256(Buffer.from(marker, "utf8")),
            dbBinaryCount: countOccurrences(binary, Buffer.from(marker, "utf8")),
          }
        : null,
      threads: {
        total: rows.length,
        target,
        otherThreads,
        threadHashesIncluded: includeThreadHashes,
        threadRowHashById,
      },
    };
  } finally {
    if (db) {
      db.close();
    }
  }
}

function summarizeThread(row) {
  if (!row) {
    return { exists: false };
  }
  return {
    exists: true,
    id: row.id,
    rowHash: hashJson(row),
    rolloutPath: row.rollout_path,
    cwd: row.cwd,
    title: row.title,
    model: row.model,
    reasoningEffort: row.reasoning_effort,
    sandboxPolicyHash: sha256(Buffer.from(row.sandbox_policy || "", "utf8")),
    sandboxPolicyLength: (row.sandbox_policy || "").length,
    approvalMode: row.approval_mode,
    updatedAt: row.updated_at,
    updatedAtMs: row.updated_at_ms,
    tokensUsed: row.tokens_used,
    archived: row.archived,
    threadSource: row.thread_source,
    previewHash: sha256(Buffer.from(row.preview || "", "utf8")),
    firstUserMessageHash: sha256(Buffer.from(row.first_user_message || "", "utf8")),
  };
}

async function compareSnapshots(beforePath, afterPath, compareOpts) {
  const before = await readSnapshotJson(beforePath);
  const after = await readSnapshotJson(afterPath);
  const beforeTargetThreadId = canonicalUuid(before.targetThreadId);
  const afterTargetThreadId = canonicalUuid(after.targetThreadId);
  const beforeTargetRowId = canonicalUuid(before.db?.threads?.target?.id);
  const afterTargetRowId = canonicalUuid(after.db?.threads?.target?.id);
  const targetThreadId = afterTargetThreadId || beforeTargetThreadId;
  const targetIdentityBound = Boolean(
    beforeTargetThreadId &&
    afterTargetThreadId &&
    beforeTargetThreadId === afterTargetThreadId &&
    beforeTargetRowId === beforeTargetThreadId &&
    afterTargetRowId === afterTargetThreadId,
  );
  const threadDiff = diffThreadHashes(
    before.db?.threads?.threadRowHashById || {},
    after.db?.threads?.threadRowHashById || {},
    targetThreadId,
    compareOpts.allowThreadChangeIds,
  );
  const hashMapsPresent =
    before.db?.threads?.threadRowHashById &&
    after.db?.threads?.threadRowHashById;
  const configShaEqual = before.config?.sha256 === after.config?.sha256;
  const configKeysEqual =
    hashJson(before.config?.keys || {}) === hashJson(after.config?.keys || {});
  const stableEvidence =
    before.config?.stableDuringRead === true &&
    after.config?.stableDuringRead === true &&
    before.db?.stableDuringRead === true &&
    after.db?.stableDuringRead === true;
  const marker = compareMarker(before.db?.marker, after.db?.marker);
  const markerIncreased = typeof marker?.delta === "number" && marker.delta > 0;
  const targetExistsBefore = Boolean(before.db?.threads?.target?.exists);
  const targetExistsAfter = Boolean(after.db?.threads?.target?.exists);
  const ok =
    configShaEqual &&
    configKeysEqual &&
    targetIdentityBound &&
    targetExistsBefore &&
    targetExistsAfter &&
    hashMapsPresent &&
    threadDiff.identitiesValid &&
    threadDiff.unexpectedNonTargetChangedIds.length === 0 &&
    threadDiff.removedIds.length === 0 &&
    threadDiff.addedIds.length === 0 &&
    (!compareOpts.expectTargetChange || threadDiff.targetChanged) &&
    (!compareOpts.expectMarkerIncrease || markerIncreased) &&
    stableEvidence;

  return {
    ok,
    mode: "compare",
    generatedAt: new Date().toISOString(),
    beforePath,
    afterPath,
    targetThreadId,
    allowThreadChangeIds: compareOpts.allowThreadChangeIds,
    expectations: {
      targetChangeRequired: compareOpts.expectTargetChange,
      markerIncreaseRequired: compareOpts.expectMarkerIncrease,
    },
    config: {
      sha256Unchanged: configShaEqual,
      selectedKeysUnchanged: configKeysEqual,
      stableDuringReads:
        before.config?.stableDuringRead === true &&
        after.config?.stableDuringRead === true,
      beforeKeys: before.config?.keys || null,
      afterKeys: after.config?.keys || null,
    },
    db: {
      stableDuringReads:
        before.db?.stableDuringRead === true &&
        after.db?.stableDuringRead === true,
      targetExistsBefore,
      targetExistsAfter,
      targetIdentityBound,
      beforeTargetThreadId,
      afterTargetThreadId,
      beforeTargetRowId,
      afterTargetRowId,
      threadHashMapsPresent: Boolean(hashMapsPresent),
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
      "Compare mode proves thread-row and config invariants only for the supplied snapshots.",
      "A successful compare is not GUI proof; it must be paired with the observed Desktop result.",
    ],
  };
}

async function readSnapshotJson(snapshotPath) {
  const bytes = await readFile(snapshotPath);
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return JSON.parse(bytes.subarray(2).toString("utf16le"));
  }
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return JSON.parse(bytes.subarray(3).toString("utf8"));
  }
  return JSON.parse(bytes.toString("utf8"));
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
    const id = canonicalUuid(rawId);
    if (!id) {
      invalidIds.push(rawId);
      continue;
    }
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
      typeof beforeMarker?.dbBinaryCount === "number" && typeof afterMarker?.dbBinaryCount === "number"
        ? afterMarker.dbBinaryCount - beforeMarker.dbBinaryCount
        : null,
    textSha256: beforeMarker?.textSha256 || afterMarker?.textSha256 || null,
  };
}

function fileInfo(filePath) {
  if (!existsSync(filePath)) {
    return { exists: false };
  }
  const stat = statSync(filePath);
  return {
    exists: true,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function stableFileInfo(before, after) {
  return (
    before.exists === true &&
    after.exists === true &&
    before.size === after.size &&
    before.mtimeMs === after.mtimeMs
  );
}

function countOccurrences(buffer, needle) {
  if (needle.length === 0) {
    return 0;
  }
  let count = 0;
  let offset = 0;
  while (offset < buffer.length) {
    const found = buffer.indexOf(needle, offset);
    if (found === -1) {
      break;
    }
    count += 1;
    offset = found + needle.length;
  }
  return count;
}

function hashJson(value) {
  return sha256(Buffer.from(JSON.stringify(sortValue(value)), "utf8"));
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

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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

  const result = opts.compare
    ? await compareSnapshots(opts.compare[0], opts.compare[1], opts)
    : await snapshot(opts);
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) {
    process.exit(1);
  }
}

await main();
