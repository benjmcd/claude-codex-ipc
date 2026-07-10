#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  createDispatchCorrelator,
  locateRollout,
  readRolloutFile,
} from "./codex_ipc_rollout_reader.mjs";

const DEFAULT_MAX_BYTES = 4096;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function serializeDiagnostic(item) {
  return JSON.stringify(item).replace(
    /[\u0000-\u001f\u007f-\u009f]/gu,
    (character) => `\\u${character.codePointAt(0).toString(16).padStart(4, "0")}`,
  );
}

function primaryReply(replyPath, maxBytes) {
  if (!replyPath) return null;
  let descriptor;
  try {
    const stat = fs.lstatSync(replyPath);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    descriptor = fs.openSync(replyPath, "r");
    fs.closeSync(descriptor);
    descriptor = undefined;
    return {
      source: "reply-file",
      reason: null,
      replyPath,
      sourceBytes: stat.size,
      returnedBytes: Math.min(stat.size, maxBytes),
      bodyBase64: null,
      duplicateCount: 0,
      boundaryMode: null,
      diagnostics: [],
    };
  } catch {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    return null;
  }
}

function none(reason, diagnostics = []) {
  return {
    source: "none",
    reason,
    replyPath: null,
    sourceBytes: 0,
    returnedBytes: 0,
    bodyBase64: "",
    duplicateCount: 0,
    boundaryMode: null,
    diagnostics,
  };
}

function hasSupersessionMarker(text) {
  if (typeof text !== "string") return false;
  const firstLine = text.split("\n", 1)[0];
  const withoutCr = firstLine.endsWith("\r") ? firstLine.slice(0, -1) : firstLine;
  return withoutCr.replace(/^[ \t]+|[ \t]+$/gu, "") === "REPLY-SUPERSEDED";
}

function rolloutSupersedesReply(options) {
  const threadId = String(options?.threadId || "").toLowerCase();
  if (!UUID_RE.test(threadId)) return false;
  const located = locateRollout({
    threadId,
    rolloutPath: options?.rolloutPath,
    sessionsRoot: options?.sessionsRoot,
  });
  if (located.status !== "found") return false;
  const correlator = createDispatchCorrelator(String(options?.dispatchId || ""));
  const parsed = readRolloutFile(located.path, {
    maxRecordBytes: options?.maxRecordBytes,
    retainRecords: false,
    onRecord: correlator.push,
  });
  if (!parsed.ok) return false;
  const correlated = correlator.finish(parsed);
  return correlated.status === "complete" && hasSupersessionMarker(correlated.text);
}

export function harvestDispatch(options) {
  const maxBytes = options?.maxBytes ?? DEFAULT_MAX_BYTES;
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
    return none("unparseable", [{ code: "invalid-max-bytes", maxBytes }]);
  }

  const primary = primaryReply(options?.replyPath, maxBytes);
  if (primary) {
    return { ...primary, replySuperseded: rolloutSupersedesReply(options) };
  }

  const threadId = String(options?.threadId || "").toLowerCase();
  if (!UUID_RE.test(threadId)) {
    return none("unavailable", [{ code: "rollout-authority-unavailable", threadId }]);
  }
  const located = locateRollout({
    threadId,
    rolloutPath: options?.rolloutPath,
    sessionsRoot: options?.sessionsRoot,
  });
  if (located.status === "ambiguous") {
    return none("ambiguous", located.diagnostics);
  }
  if (located.status !== "found") {
    return none("unavailable", located.diagnostics);
  }

  const correlator = createDispatchCorrelator(String(options?.dispatchId || ""));
  const parsed = readRolloutFile(located.path, {
    maxRecordBytes: options?.maxRecordBytes,
    retainRecords: false,
    onRecord: correlator.push,
  });
  if (!parsed.ok) {
    return none("unparseable", [...located.diagnostics, ...parsed.diagnostics]);
  }
  const correlated = correlator.finish(parsed);
  if (correlated.status !== "complete") {
    return {
      ...none(correlated.reason, [
        ...located.diagnostics,
        ...parsed.diagnostics,
        ...(correlated.diagnostics || []),
      ]),
      duplicateCount: correlated.duplicateCount || 0,
      boundaryMode: correlated.boundaryMode || null,
    };
  }

  const body = Buffer.from(correlated.text, "utf8");
  const limited = body.subarray(0, maxBytes);
  return {
    source: "rollout-fallback",
    reason: null,
    replyPath: null,
    sourceBytes: body.length,
    returnedBytes: limited.length,
    bodyBase64: limited.toString("base64"),
    duplicateCount: correlated.duplicateCount || 0,
    boundaryMode: correlated.boundaryMode || null,
    diagnostics: [
      ...located.diagnostics,
      ...parsed.diagnostics,
      ...(correlated.diagnostics || []),
    ],
  };
}

function usage() {
  return `Usage: node codex_ipc_reply_harvest.mjs --thread <uuid|filedrop> --dispatch <id>
       [--reply-path <path>] [--rollout-path <path>] [--max-bytes <n>]`;
}

function takeValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function parsePositive(value, flag) {
  if (!/^[1-9][0-9]*$/.test(String(value))) throw new Error(`${flag} must be positive`);
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${flag} is too large`);
  return parsed;
}

function parseArgs(argv) {
  const options = {
    threadId: null,
    dispatchId: null,
    replyPath: null,
    rolloutPath: process.env.CODEX_IPC_ROLLOUT_PATH || null,
    sessionsRoot: process.env.CODEX_IPC_SESSIONS_ROOT || undefined,
    maxBytes: DEFAULT_MAX_BYTES,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
        options.threadId = takeValue(argv, ++index, arg);
        break;
      case "--dispatch":
        options.dispatchId = takeValue(argv, ++index, arg);
        break;
      case "--reply-path":
        options.replyPath = takeValue(argv, ++index, arg);
        break;
      case "--rollout-path":
        options.rolloutPath = takeValue(argv, ++index, arg);
        break;
      case "--max-bytes":
        options.maxBytes = parsePositive(takeValue(argv, ++index, arg), arg);
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!options.threadId || !options.dispatchId) throw new Error("--thread and --dispatch are required");
  if (!/^[A-Za-z0-9._-]+$/.test(options.dispatchId)) throw new Error("invalid --dispatch");
  return options;
}

function emitDiagnostics(items) {
  for (const item of items || []) {
    console.error(`ROLLOUT_DIAGNOSTIC ${serializeDiagnostic(item)}`);
  }
}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    console.error(usage());
    process.exitCode = 1;
    return;
  }
  const result = harvestDispatch(options);
  if (result.replySuperseded) {
    console.error(
      "REPLY_SUPERSEDED_WARNING\tprimary reply may be superseded; inspect the dispatch thread before relying on it.",
    );
  }
  emitDiagnostics(result.diagnostics);
  const fields = [
    result.source,
    result.reason || "-",
    result.sourceBytes,
    result.returnedBytes,
    result.duplicateCount,
    result.boundaryMode || "-",
    result.bodyBase64 || "",
  ];
  process.stdout.write(`${fields.join("\t")}\n`);
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main(process.argv.slice(2));
}
