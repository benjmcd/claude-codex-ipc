#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  createDispatchCorrelator,
  isCompleteReaderCursor,
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

function supersessionAssessment(status, diagnostics = [], caution = false) {
  const uncertaintyCode =
    status === "pending" || status === "unavailable"
      ? `reply-supersession-${status}`
      : null;
  const annotatedDiagnostics = uncertaintyCode && !diagnostics.some(
    (item) => item.code === uncertaintyCode,
  )
    ? [...diagnostics, { code: uncertaintyCode }]
    : diagnostics;
  return {
    status,
    replySuperseded: status === "confirmed",
    caution,
    diagnostics: annotatedDiagnostics,
  };
}

function mixedOccurrenceDiagnostic(latestOccurrence) {
  return {
    code: "dispatch-mixed-state",
    latestStatus: latestOccurrence?.status || "unavailable",
    latestTurnId: latestOccurrence?.turnId || null,
  };
}

function freshnessDiagnostic(freshness) {
  return {
    code: "dispatch-freshness-unsettled",
    status: freshness?.status || "unavailable",
    reason: freshness?.reason || "unavailable",
    boundaryLine: freshness?.boundaryLine ?? null,
  };
}

function dispatchReuseDiagnostic(correlated) {
  return {
    code: "dispatch-id-reused",
    duplicateCount: correlated?.duplicateCount || 0,
    message: "distinct dispatch occurrences share one reply-file identity",
  };
}

function assessRolloutSupersession(options) {
  const threadId = String(options?.threadId || "").toLowerCase();
  if (!UUID_RE.test(threadId)) {
    return supersessionAssessment("unavailable", [
      { code: "rollout-authority-unavailable", threadId },
    ], true);
  }
  const located = locateRollout({
    threadId,
    rolloutPath: options?.rolloutPath,
    sessionsRoot: options?.sessionsRoot,
  });
  if (located.status !== "found") {
    const benignNoCandidate =
      located.status === "unavailable" &&
      located.reason === "no-candidate" &&
      (located.diagnostics || []).every(
        (item) => item.code === "sessions-root-missing",
      );
    return supersessionAssessment(
      "unavailable",
      located.diagnostics || [],
      Boolean(options?.rolloutPath) || located.status === "ambiguous" || !benignNoCandidate,
    );
  }
  const correlator = createDispatchCorrelator(String(options?.dispatchId || ""));
  const parsed = readRolloutFile(located.path, {
    rolloutThreadId: threadId,
    expectedIdentityKey: located.candidates?.[0]?.identityKey,
    maxRecordBytes: options?.maxRecordBytes,
    retainRecords: false,
    onRecord: correlator.push,
  });
  const readDiagnostics = [...(located.diagnostics || []), ...(parsed.diagnostics || [])];
  if (!parsed.ok) {
    return supersessionAssessment("unavailable", readDiagnostics, true);
  }
  if (!isCompleteReaderCursor(parsed.cursor)) {
    return supersessionAssessment("pending", [
      ...readDiagnostics,
      { code: "rollout-read-not-at-eof" },
    ], true);
  }
  const correlated = correlator.finish(parsed);
  const diagnostics = [...readDiagnostics, ...(correlated.diagnostics || [])];
  if ((correlated.duplicateCount || 0) > 1) {
    return supersessionAssessment(
      "unavailable",
      [...diagnostics, dispatchReuseDiagnostic(correlated)],
      true,
    );
  }
  const certifiableCompletion =
    correlated.status === "complete" &&
    correlated.lifecycle?.status === "complete" &&
    correlated.lifecycle.certifiable === true;
  if (certifiableCompletion && hasSupersessionMarker(correlated.text)) {
    const freshnessUnknown = correlated.freshness?.settled === false;
    const freshnessDiagnostics = freshnessUnknown
      ? [
          ...(correlated.latestOccurrence?.settled === false
            ? [mixedOccurrenceDiagnostic(correlated.latestOccurrence)]
            : []),
          freshnessDiagnostic(correlated.freshness),
        ]
      : [];
    return supersessionAssessment(
      "confirmed",
      [...diagnostics, ...freshnessDiagnostics],
      freshnessUnknown,
    );
  }
  if (certifiableCompletion && correlated.freshness?.settled === false) {
    const status = correlated.freshness.status === "pending" ? "pending" : "unavailable";
    const uncertainty = correlated.latestOccurrence?.settled === false
      ? mixedOccurrenceDiagnostic(correlated.latestOccurrence)
      : { code: "reply-supersession-schema-unknown" };
    return supersessionAssessment(
      status,
      [...diagnostics, uncertainty, freshnessDiagnostic(correlated.freshness)],
      true,
    );
  }
  if (certifiableCompletion) {
    return supersessionAssessment("not-seen", diagnostics);
  }
  if (correlated.reason === "pending" || correlated.lifecycle?.status === "pending") {
    return supersessionAssessment("pending", diagnostics, true);
  }
  return supersessionAssessment("unavailable", diagnostics, true);
}

export function harvestDispatch(options) {
  const maxBytes = options?.maxBytes ?? DEFAULT_MAX_BYTES;
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0) {
    return none("unparseable", [{ code: "invalid-max-bytes", maxBytes }]);
  }

  const primary = primaryReply(options?.replyPath, maxBytes);
  if (primary) {
    const supersession = assessRolloutSupersession(options);
    return {
      ...primary,
      replySuperseded: supersession.replySuperseded,
      replySupersessionStatus: supersession.status,
      replySupersessionCaution: supersession.caution,
      diagnostics: supersession.diagnostics,
    };
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
    rolloutThreadId: threadId,
    expectedIdentityKey: located.candidates?.[0]?.identityKey,
    maxRecordBytes: options?.maxRecordBytes,
    retainRecords: false,
    onRecord: correlator.push,
  });
  if (!parsed.ok) {
    return none("unparseable", [...located.diagnostics, ...parsed.diagnostics]);
  }
  if (!isCompleteReaderCursor(parsed.cursor)) {
    return none("pending", [
      ...located.diagnostics,
      ...parsed.diagnostics,
      { code: "rollout-read-not-at-eof" },
    ]);
  }
  const correlated = correlator.finish(parsed);
  if ((correlated.duplicateCount || 0) > 1) {
    return {
      ...none("unavailable", [
        ...located.diagnostics,
        ...parsed.diagnostics,
        ...(correlated.diagnostics || []),
        dispatchReuseDiagnostic(correlated),
      ]),
      duplicateCount: correlated.duplicateCount,
      boundaryMode: correlated.boundaryMode || null,
    };
  }
  if (
    correlated.status === "complete" &&
    correlated.lifecycle?.status === "complete" &&
    correlated.lifecycle.certifiable === true &&
    correlated.freshness?.settled === false
  ) {
    const reason = correlated.freshness.status === "pending" ? "pending" : "unavailable";
    const uncertainty = correlated.latestOccurrence?.settled === false
      ? mixedOccurrenceDiagnostic(correlated.latestOccurrence)
      : freshnessDiagnostic(correlated.freshness);
    return {
      ...none(reason, [
        ...located.diagnostics,
        ...parsed.diagnostics,
        ...(correlated.diagnostics || []),
        uncertainty,
      ]),
      duplicateCount: correlated.duplicateCount || 0,
      boundaryMode: correlated.boundaryMode || null,
    };
  }
  if (
    correlated.status !== "complete" ||
    correlated.lifecycle?.status !== "complete" ||
    correlated.lifecycle.certifiable !== true
  ) {
    return {
      ...none(correlated.reason || "unavailable", [
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
  } else if (result.replySupersessionCaution) {
    console.error(
      `REPLY_SUPERSESSION_UNCERTAIN\t${result.replySupersessionStatus}\tselected primary may be stale; freshness and supersession could not be certified.`,
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
