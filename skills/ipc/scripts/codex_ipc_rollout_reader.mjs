import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_MAX_RECORD_BYTES = 24 * 1024 * 1024;
const READ_CHUNK_BYTES = 256 * 1024;
const CONTENT_ANCHOR_BYTES = 4096;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const EVENT_TYPES = new Set([
  "agent_message",
  "agent_reasoning",
  "context_compacted",
  "mcp_tool_call_end",
  "patch_apply_end",
  "sub_agent_activity",
  "task_complete",
  "task_started",
  "thread_goal_updated",
  "thread_rolled_back",
  "thread_settings_applied",
  "token_count",
  "turn_aborted",
  "user_message",
  "web_search_end",
]);

const RESPONSE_TYPES = new Set([
  "agent_message",
  "custom_tool_call",
  "custom_tool_call_output",
  "function_call",
  "function_call_output",
  "message",
  "reasoning",
  "tool_search_call",
  "tool_search_output",
  "web_search_call",
]);

const TYPELESS_ENVELOPES = new Set([
  "compacted",
  "inter_agent_communication_metadata",
  "session_meta",
  "turn_context",
  "world_state",
]);
const RETAINED_EVENT_TYPES = new Set([
  "agent_message",
  "task_complete",
  "task_started",
  "turn_aborted",
  "user_message",
]);

function diagnostic(code, details = {}) {
  return { code, ...details };
}

function textFromAllowedFields(payload) {
  if (!payload || typeof payload !== "object") {
    return "";
  }
  if (typeof payload.message === "string") {
    return payload.message;
  }
  if (typeof payload.text === "string") {
    return payload.text;
  }
  if (!Array.isArray(payload.content)) {
    return "";
  }
  return payload.content
    .map((part) => {
      if (typeof part === "string") {
        return part;
      }
      if (part && typeof part.text === "string") {
        return part.text;
      }
      return "";
    })
    .filter(Boolean)
    .join(" ");
}

function knownPair(envelopeType, payloadType) {
  if (envelopeType === "event_msg") {
    return EVENT_TYPES.has(payloadType);
  }
  if (envelopeType === "response_item") {
    return RESPONSE_TYPES.has(payloadType);
  }
  return TYPELESS_ENVELOPES.has(envelopeType) && payloadType === null;
}

export function normalizeRolloutRecord(value, context = {}) {
  const payload = value && typeof value.payload === "object" ? value.payload : {};
  const item = payload.item && typeof payload.item === "object" ? payload.item : null;
  const body = item || payload;
  const envelopeType = typeof value?.type === "string" ? value.type : null;
  const payloadType = typeof body.type === "string" ? body.type : null;
  const role = typeof body.role === "string" ? body.role : null;
  const phase = typeof body.phase === "string" ? body.phase : null;
  const turnId = typeof body.turn_id === "string" ? body.turn_id : null;
  const interAgent = envelopeType === "response_item" && payloadType === "agent_message";
  const lastAgentMessage =
    typeof body.last_agent_message === "string" || body.last_agent_message === null
      ? body.last_agent_message
      : undefined;
  return {
    envelopeType,
    payloadType,
    role,
    phase,
    turnId,
    lastAgentMessage,
    text: interAgent ? "" : textFromAllowedFields(body),
    timestamp: typeof value?.timestamp === "string" ? value.timestamp : null,
    line: context.line ?? null,
    byteOffset: context.byteOffset ?? null,
    interAgent,
    knownPair: knownPair(envelopeType, payloadType),
  };
}

function retainForCorrelation(record) {
  if (record.envelopeType === "event_msg") {
    return RETAINED_EVENT_TYPES.has(record.payloadType);
  }
  return record.envelopeType === "response_item" && record.payloadType === "agent_message";
}

function canonicalPath(filePath) {
  let resolved;
  try {
    resolved = fs.realpathSync.native(filePath);
  } catch {
    resolved = path.resolve(filePath);
  }
  if (process.platform === "win32") {
    if (resolved.startsWith("\\\\?\\UNC\\")) {
      resolved = `\\\\${resolved.slice(8)}`;
    } else if (resolved.startsWith("\\\\?\\")) {
      resolved = resolved.slice(4);
    }
    resolved = resolved.toLowerCase();
  }
  return resolved;
}

function fileIdentity(filePath, stat, exactStat) {
  const inode = exactStat?.ino ?? BigInt(stat.ino || 0);
  const device = exactStat?.dev ?? BigInt(stat.dev || 0);
  const canonical = canonicalPath(filePath);
  return {
    canonicalPath: canonical,
    key: inode !== 0n ? `${device}:${inode}` : canonical,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function readContentAnchor(descriptor, endOffset) {
  const length = Math.min(CONTENT_ANCHOR_BYTES, endOffset);
  const offset = endOffset - length;
  const buffer = Buffer.allocUnsafe(length);
  let total = 0;
  while (total < length) {
    const bytesRead = fs.readSync(descriptor, buffer, total, length - total, offset + total);
    if (bytesRead === 0) throw new Error("content anchor became unreadable");
    total += bytesRead;
  }
  return {
    endOffset,
    sha256: createHash("sha256").update(buffer).digest("hex"),
  };
}

function failure(filePath, reason, diagnostics = [], extra = {}) {
  return {
    ok: false,
    integrityValidated: false,
    path: filePath,
    reason,
    records: extra.records || [],
    diagnostics,
    parseErrorCount: extra.parseErrorCount || 0,
    partialTail: false,
    cursor: extra.cursor || null,
  };
}

export function readRolloutFile(filePath, options = {}) {
  const maxRecordBytes = options.maxRecordBytes ?? DEFAULT_MAX_RECORD_BYTES;
  const now = options.now || Date.now;
  const deadlineAt = options.deadlineAt ?? Number.POSITIVE_INFINITY;
  if (!Number.isSafeInteger(maxRecordBytes) || maxRecordBytes <= 0) {
    return failure(filePath, "invalid-record-cap", [
      diagnostic("invalid-record-cap", { path: filePath, maxRecordBytes }),
    ]);
  }

  let descriptor;
  let initialStat;
  let exactInitialStat;
  try {
    descriptor = fs.openSync(filePath, "r");
    initialStat = fs.fstatSync(descriptor);
    exactInitialStat = fs.fstatSync(descriptor, { bigint: true });
  } catch (error) {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    return failure(filePath, error?.code === "ENOENT" ? "missing" : "unreadable", [
      diagnostic("read-error", { path: filePath, message: error.message }),
    ]);
  }

  if (!initialStat.isFile()) {
    fs.closeSync(descriptor);
    return failure(filePath, "unreadable", [diagnostic("not-regular-file", { path: filePath })]);
  }

  const identity = fileIdentity(filePath, initialStat, exactInitialStat);
  const previous = options.cursor || null;
  if (previous?.identityKey && previous.identityKey !== identity.key) {
    fs.closeSync(descriptor);
    return failure(filePath, "file-replaced", [
      diagnostic("file-replaced", {
        path: filePath,
        previousIdentity: previous.identityKey,
        identity: identity.key,
      }),
    ]);
  }
  if (previous && initialStat.size < previous.size) {
    fs.closeSync(descriptor);
    return failure(filePath, "file-truncated", [
      diagnostic("file-truncated", {
        path: filePath,
        previousSize: previous.size,
        size: initialStat.size,
      }),
    ]);
  }

  let initialAnchor;
  try {
    initialAnchor = readContentAnchor(descriptor, initialStat.size);
    if (previous?.anchorSha256) {
      const previousAnchor = readContentAnchor(descriptor, previous.anchorEndOffset);
      if (previousAnchor.sha256 !== previous.anchorSha256) {
        fs.closeSync(descriptor);
        return failure(filePath, "file-replaced", [
          diagnostic("content-anchor-changed", {
            path: filePath,
            anchorEndOffset: previous.anchorEndOffset,
          }),
        ]);
      }
    }
  } catch (error) {
    fs.closeSync(descriptor);
    return failure(filePath, "unreadable", [
      diagnostic("anchor-read-error", { path: filePath, message: error.message }),
    ]);
  }

  const records = [];
  const diagnostics = [];
  const retainRecords = options.retainRecords !== false;
  const onRecord = typeof options.onRecord === "function" ? options.onRecord : null;
  let parseErrorCount = 0;
  let lineNumber = previous?.lineNumber || 0;
  let position = previous?.offset || 0;
  let pending = previous?.partialBase64
    ? Buffer.from(previous.partialBase64, "base64")
    : Buffer.alloc(0);
  let pendingStart = previous?.partialStart ?? position;
  let previousTimestamp = previous?.lastTimestamp || null;
  let firstRecordSeen = Boolean(previous?.firstRecordSeen);
  const decoder = new TextDecoder("utf-8", { fatal: true });

  const emitRecord = (item) => {
    try {
      if (onRecord) onRecord(item);
      if (retainRecords) records.push(item);
      return null;
    } catch (error) {
      return failure(filePath, "record-handler-error", [
        ...diagnostics,
        diagnostic("record-handler-error", {
          path: filePath,
          line: item.line,
          byteOffset: item.byteOffset,
          message: error.message,
        }),
      ], { records, parseErrorCount });
    }
  };

  const parseLine = (input, byteOffset) => {
    lineNumber += 1;
    let bytes = input;
    if (bytes.length > 0 && bytes.at(-1) === 13) {
      bytes = bytes.subarray(0, bytes.length - 1);
      diagnostics.push(diagnostic("crlf", { path: filePath, line: lineNumber, byteOffset }));
    }
    if (bytes.length === 0) {
      diagnostics.push(diagnostic("blank-line", { path: filePath, line: lineNumber, byteOffset }));
      return null;
    }
    if (bytes.length > maxRecordBytes) {
      return failure(filePath, "record-too-large", [
        ...diagnostics,
        diagnostic("record-too-large", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          bytes: bytes.length,
          maxRecordBytes,
        }),
      ], { records, parseErrorCount });
    }
    if (!firstRecordSeen && bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      bytes = bytes.subarray(3);
      diagnostics.push(diagnostic("utf8-bom", { path: filePath, line: lineNumber, byteOffset }));
    }
    firstRecordSeen = true;
    let text;
    try {
      text = decoder.decode(bytes);
    } catch (error) {
      return failure(filePath, "invalid-utf8", [
        ...diagnostics,
        diagnostic("invalid-utf8", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          message: error.message,
        }),
      ], { records, parseErrorCount });
    }
    let value;
    try {
      value = JSON.parse(text);
    } catch (error) {
      parseErrorCount += 1;
      const item = {
        parseError: true,
        line: lineNumber,
        byteOffset,
        path: filePath,
        message: error.message,
      };
      const handlerFailure = emitRecord(item);
      diagnostics.push(diagnostic("malformed-json", item));
      return handlerFailure;
    }
    const normalized = normalizeRolloutRecord(value, { line: lineNumber, byteOffset });
    if (retainForCorrelation(normalized)) {
      const handlerFailure = emitRecord(normalized);
      if (handlerFailure) return handlerFailure;
    }
    if (!normalized.knownPair) {
      diagnostics.push(
        diagnostic("schema-drift", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          envelopeType: normalized.envelopeType,
          payloadType: normalized.payloadType,
        }),
      );
    }
    if (normalized.timestamp) {
      const timestamp = Date.parse(normalized.timestamp);
      if (!Number.isNaN(timestamp)) {
        if (previousTimestamp !== null && timestamp < previousTimestamp) {
          diagnostics.push(diagnostic("timestamp-regression", { path: filePath, line: lineNumber }));
        }
        previousTimestamp = timestamp;
      }
    }
    return null;
  };

  const chunk = Buffer.allocUnsafe(READ_CHUNK_BYTES);
  let fatalResult = null;
  let finalDescriptorStat = null;
  let finalInitialAnchor = null;
  let cursorAnchor = null;
  try {
    while (fatalResult === null) {
      if (now() >= deadlineAt) {
        fatalResult = failure(filePath, "deadline-exceeded", [
          ...diagnostics,
          diagnostic("deadline-exceeded", { path: filePath, byteOffset: position, deadlineAt }),
        ], { records, parseErrorCount });
        break;
      }
      const bytesRead = fs.readSync(descriptor, chunk, 0, chunk.length, position);
      if (bytesRead === 0) break;
      const current = chunk.subarray(0, bytesRead);
      let start = 0;
      while (start < current.length) {
        const newline = current.indexOf(10, start);
        if (newline === -1) {
          const tail = current.subarray(start);
          if (pending.length === 0) pendingStart = position + start;
          pending = pending.length === 0 ? Buffer.from(tail) : Buffer.concat([pending, tail]);
          if (pending.length > maxRecordBytes) {
            fatalResult = failure(filePath, "record-too-large", [
              ...diagnostics,
              diagnostic("record-too-large", {
                path: filePath,
                line: lineNumber + 1,
                byteOffset: pendingStart,
                bytes: pending.length,
                maxRecordBytes,
              }),
            ], { records, parseErrorCount });
          }
          break;
        }
        const fragment = current.subarray(start, newline);
        const line = pending.length === 0 ? fragment : Buffer.concat([pending, fragment]);
        const lineStart = pending.length === 0 ? position + start : pendingStart;
        pending = Buffer.alloc(0);
        fatalResult = parseLine(line, lineStart);
        start = newline + 1;
        pendingStart = position + start;
        if (fatalResult) break;
      }
      position += bytesRead;
    }
  } catch (error) {
    fatalResult = failure(filePath, "unreadable", [
      ...diagnostics,
      diagnostic("read-error", { path: filePath, byteOffset: position, message: error.message }),
    ], { records, parseErrorCount });
  } finally {
    try {
      finalDescriptorStat = fs.fstatSync(descriptor);
      if (finalDescriptorStat.size >= initialStat.size && finalDescriptorStat.size >= position) {
        finalInitialAnchor = readContentAnchor(descriptor, initialStat.size);
        cursorAnchor = readContentAnchor(descriptor, position);
      }
    } catch {
      finalDescriptorStat = null;
    }
    fs.closeSync(descriptor);
  }
  if (fatalResult && fatalResult.reason !== "deadline-exceeded") return fatalResult;
  if (!finalDescriptorStat) {
    return failure(filePath, "unreadable", [
      ...diagnostics,
      diagnostic("descriptor-revalidation-failed", { path: filePath }),
    ], { records, parseErrorCount });
  }
  if (finalDescriptorStat.size < initialStat.size || finalDescriptorStat.size < position) {
    return failure(filePath, "file-truncated", [
      ...diagnostics,
      diagnostic("file-truncated", {
        path: filePath,
        initialSize: initialStat.size,
        finalSize: finalDescriptorStat.size,
        byteOffset: position,
      }),
    ], { records, parseErrorCount });
  }
  if (!finalInitialAnchor || finalInitialAnchor.sha256 !== initialAnchor.sha256) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("content-anchor-changed", {
        path: filePath,
        anchorEndOffset: initialAnchor.endOffset,
      }),
    ], { records, parseErrorCount });
  }

  let pathIdentity;
  try {
    const pathStat = fs.statSync(filePath);
    const exactPathStat = fs.statSync(filePath, { bigint: true });
    pathIdentity = fileIdentity(filePath, pathStat, exactPathStat);
  } catch (error) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("path-revalidation-failed", { path: filePath, message: error.message }),
    ], { records, parseErrorCount });
  }
  if (pathIdentity.key !== identity.key) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("file-replaced", {
        path: filePath,
        previousIdentity: identity.key,
        identity: pathIdentity.key,
      }),
    ], { records, parseErrorCount });
  }
  if (fatalResult) {
    return { ...fatalResult, integrityValidated: true };
  }
  const cursor = {
    identityKey: identity.key,
    canonicalPath: identity.canonicalPath,
    offset: position,
    size: finalDescriptorStat.size,
    lineNumber,
    partialBase64: pending.length > 0 ? pending.toString("base64") : "",
    partialStart: pendingStart,
    lastTimestamp: previousTimestamp,
    firstRecordSeen,
    anchorEndOffset: cursorAnchor.endOffset,
    anchorSha256: cursorAnchor.sha256,
  };
  return {
    ok: true,
    integrityValidated: true,
    path: filePath,
    records,
    diagnostics,
    parseErrorCount,
    partialTail: pending.length > 0,
    cursor,
  };
}

function exactTaskBasename(text, basename) {
  if (typeof text !== "string" || !text.includes(basename)) return false;
  let offset = text.indexOf(basename);
  while (offset !== -1) {
    const before = offset === 0 ? "" : text[offset - 1];
    const after = text[offset + basename.length] || "";
    const beforeOk = before === "" || /[\\/"'\s]/.test(before);
    const afterOk = after === "" || /["'\s]/.test(after);
    if (beforeOk && afterOk) return true;
    offset = text.indexOf(basename, offset + 1);
  }
  return false;
}

// ---------------------------------------------------------------------------
// Single shared turn-boundary state machine (A1).
//
// createTurnBoundaryAccumulator() is the ONLY boundary machine in the tooling.
// It is I/O-free and text-free: it consumes normalized records and emits
// immutable per-turn snapshots carrying EXACTLY the eight boundary fields below
// and no marker/text/lastAgentMessage/body/reply/source/verdict material. It
// alone owns start/current-turn selection, explicit-id and ordered-fallback
// binding, terminal binding, supersession, and parser/schema-gap attribution.
// Both consumers are thin projections over its snapshots: createDispatchCorrelator
// (A1 dispatch correlation) and summarizeThreadActivity (A4 thread activity).
// ---------------------------------------------------------------------------

const BOUNDARY_ERROR_CODES = new Set([
  "user-message-turn-id-mismatch",
  "agent-message-turn-id-mismatch",
  "terminal-turn-id-mismatch",
  "terminal-turn-id-unexpected",
  "terminal-turn-id-missing",
]);

function buildTurnSnapshot(turn) {
  const diagnostics = [...turn.boundaryErrors];
  if (turn.superseded) {
    diagnostics.push(diagnostic("turn-superseded", { line: turn.startLine, turnId: turn.turnId }));
  }
  for (const line of turn.parseErrorLines) {
    diagnostics.push(diagnostic("malformed-json", { line }));
  }
  if (turn.schemaGap) {
    diagnostics.push(diagnostic("schema-drift", { turnId: turn.turnId }));
  }
  const parseGap = turn.parseErrorLines.length > 0 || turn.schemaGap;
  let activity;
  if (turn.superseded || turn.boundaryErrors.length > 0 || parseGap) {
    activity = "ambiguous";
  } else if (turn.terminalType) {
    activity = "closed";
  } else {
    activity = "open";
  }
  return Object.freeze({
    sequence: turn.sequence,
    turnId: turn.turnId,
    boundaryMode: turn.boundaryMode,
    activity,
    terminalType: turn.terminalType,
    terminalLine: turn.terminalLine,
    superseded: turn.superseded,
    diagnostics: Object.freeze(diagnostics),
  });
}

export function createTurnBoundaryAccumulator() {
  const explicit = new Map();
  const openTurns = [];
  let current = null;
  let sequence = 0;

  const finalize = (turn) => {
    if (turn.emitted) return null;
    turn.emitted = true;
    const index = openTurns.indexOf(turn);
    if (index !== -1) openTurns.splice(index, 1);
    return buildTurnSnapshot(turn);
  };

  const startTurn = (record) => {
    const turn = {
      sequence: sequence++,
      turnId: record.turnId,
      boundaryMode: record.turnId ? "turn-id" : "ordered-fallback",
      startLine: record.line,
      terminalType: null,
      terminalLine: null,
      superseded: false,
      boundaryErrors: [],
      parseErrorLines: [],
      schemaGap: false,
      emitted: false,
    };
    openTurns.push(turn);
    if (turn.turnId) explicit.set(turn.turnId, turn);
    return turn;
  };

  return {
    push(record) {
      if (record.parseError) {
        if (current && !current.terminalType) {
          current.parseErrorLines.push(record.line);
          return { sequence: current.sequence, snapshots: [] };
        }
        return { sequence: null, snapshots: [] };
      }
      if (record.envelopeType !== "event_msg") {
        return { sequence: null, snapshots: [] };
      }
      if (record.payloadType === "task_started") {
        const snapshots = [];
        if (current && !current.terminalType) {
          current.superseded = true;
          const snap = finalize(current);
          if (snap) snapshots.push(snap);
        }
        current = startTurn(record);
        return { sequence: current.sequence, snapshots };
      }
      if (record.payloadType === "user_message") {
        if (current && !current.terminalType) {
          // A user message whose turn id disagrees with its enclosing turn breaks correlation
          // authority: the marker would be attributed to a turn that never carried it, and that
          // turn's final answer would be served as this dispatch's reply. Fail closed.
          if (current.turnId && record.turnId && current.turnId !== record.turnId) {
            current.boundaryErrors.push(
              diagnostic("user-message-turn-id-mismatch", {
                line: record.line,
                expectedTurnId: current.turnId,
                messageTurnId: record.turnId,
              }),
            );
          }
          return { sequence: current.sequence, snapshots: [] };
        }
        return { sequence: null, snapshots: [] };
      }
      if (record.payloadType === "agent_message") {
        if (current && !current.terminalType) {
          // A non-null agent-message turn id that disagrees with its enclosing turn is the same
          // fail-closed class as the user-message guard: refuse rather than certify a body whose
          // own turn attribution contradicts the turn it appears in.
          if (current.turnId && record.turnId && current.turnId !== record.turnId) {
            current.boundaryErrors.push(
              diagnostic("agent-message-turn-id-mismatch", {
                line: record.line,
                expectedTurnId: current.turnId,
                messageTurnId: record.turnId,
              }),
            );
          }
          return { sequence: current.sequence, snapshots: [] };
        }
        return { sequence: null, snapshots: [] };
      }
      if (record.payloadType !== "task_complete" && record.payloadType !== "turn_aborted") {
        return { sequence: null, snapshots: [] };
      }

      let turn;
      if (record.turnId) {
        turn = explicit.get(record.turnId);
        if (!turn && current?.turnId) {
          current.boundaryErrors.push(
            diagnostic("terminal-turn-id-mismatch", {
              line: record.line,
              expectedTurnId: current.turnId,
              terminalTurnId: record.turnId,
            }),
          );
        } else if (!turn && current) {
          current.boundaryErrors.push(
            diagnostic("terminal-turn-id-unexpected", {
              line: record.line,
              terminalTurnId: record.turnId,
            }),
          );
        }
      } else if (current?.turnId) {
        current.boundaryErrors.push(
          diagnostic("terminal-turn-id-missing", {
            line: record.line,
            expectedTurnId: current.turnId,
          }),
        );
        return { sequence: current.sequence, snapshots: [] };
      } else {
        turn = current;
      }
      if (!turn || turn.terminalType || turn.emitted) {
        return { sequence: turn && !turn.emitted ? turn.sequence : null, snapshots: [] };
      }
      turn.terminalType = record.payloadType;
      turn.terminalLine = record.line;
      if (current === turn) current = null;
      const snap = finalize(turn);
      return { sequence: turn.sequence, snapshots: snap ? [snap] : [] };
    },
    finish(parserDiagnostics = []) {
      const drift = [];
      for (const item of parserDiagnostics || []) {
        if (item && item.code === "schema-drift" && typeof item.line === "number") {
          drift.push(item.line);
        }
      }
      // Attribute schema gaps to every still-open turn's window before finalizing it. Turns
      // already finalized during push are emitted; the dispatch adapter enforces their schema-gap
      // integrity separately over the same parser diagnostics.
      for (const turn of openTurns) {
        for (const line of drift) {
          if (line > turn.startLine && (turn.terminalLine === null || line < turn.terminalLine)) {
            turn.schemaGap = true;
            break;
          }
        }
      }
      const snapshots = [];
      for (const turn of [...openTurns]) {
        const snap = finalize(turn);
        if (snap) snapshots.push(snap);
      }
      current = null;
      return snapshots;
    },
  };
}

function computeOccurrence(snapshot, bucket, marker) {
  const laterUsers = bucket.userMessages.filter((u) => u.line > marker.line);
  const disqualifying = laterUsers.find(
    (u) => !(snapshot.turnId && u.turnId && u.turnId === snapshot.turnId),
  );
  const inWindowErrors = bucket.parseErrors.filter(
    (item) =>
      item.line > marker.line &&
      (snapshot.terminalLine === null || item.line < snapshot.terminalLine),
  );
  const boundaryErrors = snapshot.diagnostics.filter((d) => BOUNDARY_ERROR_CODES.has(d.code));

  const base = {
    markerLine: marker.line,
    startLine: bucket.startLine,
    terminalLine: snapshot.terminalLine,
    turnId: snapshot.turnId,
    boundaryMode: snapshot.boundaryMode,
    certifiable: false,
    text: null,
    finalMessageCount: 0,
  };

  if (snapshot.superseded) {
    return {
      ...base,
      waitStatus: "superseded",
      harvestStatus: "none",
      harvestReason: "unavailable",
      diagnostics: [diagnostic("turn-superseded", { line: bucket.startLine, turnId: snapshot.turnId })],
    };
  }
  if (boundaryErrors.length > 0) {
    return { ...base, waitStatus: "unavailable", harvestStatus: "none", harvestReason: "unparseable", diagnostics: boundaryErrors };
  }
  if (inWindowErrors.length > 0) {
    return {
      ...base,
      waitStatus: "unavailable",
      harvestStatus: "none",
      harvestReason: "unparseable",
      diagnostics: inWindowErrors.map((item) => diagnostic("malformed-json", item)),
    };
  }
  if (disqualifying) {
    return {
      ...base,
      waitStatus: "unavailable",
      harvestStatus: "none",
      harvestReason: "ambiguous",
      diagnostics: [diagnostic("intervening-user-message", { line: disqualifying.line })],
    };
  }
  if (!snapshot.terminalType) {
    return { ...base, waitStatus: "pending", harvestStatus: "none", harvestReason: "pending", diagnostics: [] };
  }
  if (snapshot.terminalType === "turn_aborted") {
    return { ...base, waitStatus: "aborted", harvestStatus: "none", harvestReason: "unavailable", diagnostics: [] };
  }

  // task_complete: select the presentation body (harvester) and the wait-verified body (certification).
  const lam = bucket.terminal ? bucket.terminal.lastAgentMessage : undefined;
  const finalAnswers = bucket.agentMessages.filter((a) => a.phase === "final_answer");
  let presentationFinals = finalAnswers;
  if (presentationFinals.length === 0 && typeof lam === "string") {
    presentationFinals = bucket.agentMessages.filter((a) => a.text === lam);
  }
  const selected = presentationFinals.at(-1) || null;
  let certifiable = false;
  if (typeof lam === "string" && lam.length > 0) {
    // An exact, non-empty terminal copy among the same-turn candidates certifies the body.
    certifiable = bucket.agentMessages.some((a) => a.text === lam);
  } else if (lam === null || lam === undefined) {
    // No terminal copy: the latest non-empty explicit final answer remains eligible.
    const latestFinal = finalAnswers.at(-1) || null;
    certifiable = Boolean(latestFinal && latestFinal.text.length > 0);
  }
  const diagnostics = [];
  if (selected && typeof lam === "string" && lam !== selected.text) {
    diagnostics.push(diagnostic("completion-message-mismatch", { line: snapshot.terminalLine, turnId: snapshot.turnId }));
  }
  return {
    ...base,
    waitStatus: "complete",
    harvestStatus: selected ? "complete" : "none",
    harvestReason: selected ? null : "unavailable",
    certifiable,
    text: selected ? selected.text : null,
    finalMessageCount: presentationFinals.length,
    diagnostics,
  };
}

function projectHarvest(occurrences, parsed) {
  const duplicateCount = occurrences.length;
  const completed = occurrences
    .filter((o) => o.harvestStatus === "complete")
    .sort((left, right) => (left.terminalLine || 0) - (right.terminalLine || 0));
  if (completed.length > 0) {
    const win = completed.at(-1);
    return {
      status: "complete",
      reason: null,
      text: win.text,
      finalMessageCount: win.finalMessageCount,
      duplicateCount,
      turnId: win.turnId,
      boundaryMode: win.boundaryMode,
      diagnostics: win.diagnostics,
    };
  }
  const reasonOrder = ["unparseable", "ambiguous", "pending", "unavailable"];
  const reason = reasonOrder.find((item) => occurrences.some((o) => o.harvestReason === item));
  const matching = occurrences.find((o) => o.harvestReason === reason) || null;
  return {
    status: "none",
    reason: reason || (parsed.ok ? "pending" : "unparseable"),
    text: null,
    finalMessageCount: 0,
    duplicateCount,
    turnId: matching?.turnId || null,
    boundaryMode: matching?.boundaryMode || null,
    diagnostics: matching?.diagnostics || parsed.diagnostics || [],
  };
}

function projectLifecycle(occurrences, parserDiagnostics, sawParseError, parsed) {
  // The wait lifecycle applies schema-drift-in-window as a certification integrity gate: a
  // schema gap inside a would-be complete / pending / aborted turn window forces `unavailable`.
  const withSchema = occurrences.map((occ) => {
    if (
      (occ.waitStatus === "complete" || occ.waitStatus === "pending" || occ.waitStatus === "aborted") &&
      occ.startLine !== null
    ) {
      const drift = (parserDiagnostics || []).filter(
        (d) =>
          d.code === "schema-drift" &&
          typeof d.line === "number" &&
          d.line > occ.startLine &&
          (occ.terminalLine === null || d.line < occ.terminalLine),
      );
      if (drift.length > 0) {
        return { ...occ, waitStatus: "unavailable", waitDiagnostics: drift };
      }
    }
    return occ;
  });

  const completed = withSchema
    .filter((o) => o.waitStatus === "complete")
    .sort((left, right) => (left.terminalLine || 0) - (right.terminalLine || 0));
  if (completed.length > 0) {
    const win = completed.at(-1);
    return { status: "complete", diagnostics: win.diagnostics, certifiable: win.certifiable };
  }
  const unavailable = withSchema.find((o) => o.waitStatus === "unavailable");
  if (unavailable) {
    return { status: "unavailable", diagnostics: unavailable.waitDiagnostics || unavailable.diagnostics, certifiable: false };
  }
  const pending = withSchema.find((o) => o.waitStatus === "pending");
  if (pending) {
    return { status: "pending", diagnostics: pending.diagnostics, certifiable: false };
  }
  if (withSchema.length > 0) {
    const last = [...withSchema].sort((left, right) => left.markerLine - right.markerLine).at(-1);
    return { status: last.waitStatus, diagnostics: last.diagnostics, certifiable: last.certifiable };
  }
  const schemaFailure =
    sawParseError || (parserDiagnostics || []).some((d) => d.code === "schema-drift");
  return {
    status: schemaFailure ? "unavailable" : "pending",
    diagnostics: schemaFailure
      ? (parserDiagnostics || []).filter((d) => d.code === "schema-drift" || d.code === "malformed-json")
      : [],
    certifiable: false,
  };
}

// A1 dispatch adapter: the ONLY dispatch correlation surface. It pairs each normalized record with
// the snapshots emitted by the same createTurnBoundaryAccumulator() call, owns marker selection and
// presentation / wait-body integrity, and projects BOTH the harvester public shape (top level) and
// the wait lifecycle (`.lifecycle`). It reimplements no start/terminal/id/supersession rule.
export function createDispatchCorrelator(dispatchId) {
  const basename = String(dispatchId).endsWith(".task.md")
    ? String(dispatchId)
    : `${dispatchId}.task.md`;
  const accumulator = createTurnBoundaryAccumulator();
  const buckets = new Map();
  const occurrences = [];
  let sawParseError = false;

  const bucketFor = (seq) => {
    let bucket = buckets.get(seq);
    if (!bucket) {
      bucket = { startLine: null, userMessages: [], agentMessages: [], parseErrors: [], terminal: null };
      buckets.set(seq, bucket);
    }
    return bucket;
  };

  const ingest = (record, seq) => {
    if (seq === null || seq === undefined) return;
    const bucket = bucketFor(seq);
    if (record.parseError) {
      bucket.parseErrors.push(record);
      return;
    }
    if (record.envelopeType !== "event_msg") return;
    if (record.payloadType === "task_started") {
      bucket.startLine = record.line;
    } else if (record.payloadType === "user_message") {
      bucket.userMessages.push(record);
    } else if (record.payloadType === "agent_message") {
      bucket.agentMessages.push(record);
    } else if (record.payloadType === "task_complete" || record.payloadType === "turn_aborted") {
      bucket.terminal = record;
    }
  };

  const processSnapshot = (snapshot) => {
    const bucket = buckets.get(snapshot.sequence);
    buckets.delete(snapshot.sequence);
    if (!bucket) return;
    const markers = bucket.userMessages.filter((item) => exactTaskBasename(item.text, basename));
    for (const marker of markers) {
      occurrences.push(computeOccurrence(snapshot, bucket, marker));
    }
  };

  return {
    push(record) {
      if (record.parseError) sawParseError = true;
      const { sequence, snapshots } = accumulator.push(record);
      ingest(record, sequence);
      for (const snapshot of snapshots) processSnapshot(snapshot);
    },
    finish(parsed = { ok: true, diagnostics: [] }) {
      const parserDiagnostics = parsed?.diagnostics || [];
      const snapshots = accumulator.finish(parserDiagnostics);
      for (const snapshot of snapshots) processSnapshot(snapshot);
      const harvest = projectHarvest(occurrences, parsed);
      const lifecycle = projectLifecycle(occurrences, parserDiagnostics, sawParseError, parsed);
      return { ...harvest, lifecycle };
    },
  };
}

export function correlateDispatch(parsed, dispatchId) {
  const correlator = createDispatchCorrelator(dispatchId);
  for (const record of parsed.records || []) correlator.push(record);
  return correlator.finish(parsed);
}

// A4 thread-activity projection (pure). Consumed in Phase 3; built here so both adapters remain
// thin projections over the one boundary machine. Returns ONLY turnActivity.
export function summarizeThreadActivity(boundarySnapshot, rolloutStatus) {
  return {
    turnActivity:
      rolloutStatus === "found" && boundarySnapshot ? boundarySnapshot.activity : "ambiguous",
  };
}

function readFirstRecord(filePath, maxRecordBytes = DEFAULT_MAX_RECORD_BYTES) {
  let descriptor;
  try {
    descriptor = fs.openSync(filePath, "r");
    const chunks = [];
    let bytes = 0;
    let position = 0;
    const chunk = Buffer.allocUnsafe(4096);
    while (bytes <= maxRecordBytes) {
      const bytesRead = fs.readSync(descriptor, chunk, 0, chunk.length, position);
      if (bytesRead === 0) break;
      const current = chunk.subarray(0, bytesRead);
      const newline = current.indexOf(10);
      if (newline === -1) {
        chunks.push(Buffer.from(current));
        bytes += current.length;
        position += current.length;
        continue;
      }
      chunks.push(Buffer.from(current.subarray(0, newline)));
      bytes += newline;
      break;
    }
    if (bytes > maxRecordBytes) {
      return { ok: false, reason: "record-too-large" };
    }
    let first = Buffer.concat(chunks);
    if (first.at(-1) === 13) first = first.subarray(0, first.length - 1);
    if (first.length >= 3 && first[0] === 0xef && first[1] === 0xbb && first[2] === 0xbf) {
      first = first.subarray(3);
    }
    const text = new TextDecoder("utf-8", { fatal: true }).decode(first);
    return { ok: true, value: JSON.parse(text) };
  } catch (error) {
    return { ok: false, reason: "unreadable", error };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function filenameOwnerId(filePath) {
  const match = path.basename(filePath).match(
    /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i,
  );
  return match?.[1]?.toLowerCase() || null;
}

function validateCandidate(filePath, threadId) {
  try {
    const stat = fs.statSync(filePath);
    const exactStat = fs.statSync(filePath, { bigint: true });
    if (!stat.isFile()) {
      return { ok: false, reason: "unreadable", path: filePath };
    }
    const filenameId = filenameOwnerId(filePath);
    const first = readFirstRecord(filePath);
    const ownerId =
      first.ok &&
      first.value?.type === "session_meta" &&
      typeof first.value?.payload?.id === "string"
        ? first.value.payload.id.toLowerCase()
        : null;
    if (!first.ok || filenameId !== threadId || ownerId !== threadId) {
      return {
        ok: false,
        reason: "identity-mismatch",
        path: filePath,
        filenameId,
        ownerId,
      };
    }
    const identity = fileIdentity(filePath, stat, exactStat);
    return {
      ok: true,
      path: filePath,
      canonicalPath: identity.canonicalPath,
      identityKey: identity.key,
      size: stat.size,
      mtimeMs: stat.mtimeMs,
      ownerId,
    };
  } catch (error) {
    return { ok: false, reason: "unreadable", path: filePath, message: error.message };
  }
}

function findUuidCandidates(root, threadId, options = {}) {
  const matches = [];
  const diagnostics = [];
  const stack = [root];
  while (stack.length > 0) {
    if (options.now() >= options.deadlineAt) {
      diagnostics.push(diagnostic("deadline-exceeded", { path: root }));
      return { matches, diagnostics, deadlineExceeded: true };
    }
    const directory = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
        a.name.localeCompare(b.name),
      );
    } catch (error) {
      diagnostics.push(diagnostic("directory-unreadable", { path: directory, message: error.message }));
      continue;
    }
    for (const entry of entries) {
      if (options.now() >= options.deadlineAt) {
        diagnostics.push(diagnostic("deadline-exceeded", { path: directory }));
        return { matches, diagnostics, deadlineExceeded: true };
      }
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory() && !entry.isSymbolicLink()) {
        stack.push(candidate);
      } else if (
        (entry.isFile() || entry.isSymbolicLink()) &&
        entry.name.toLowerCase().endsWith(`${threadId}.jsonl`)
      ) {
        matches.push(candidate);
      }
    }
  }
  return { matches, diagnostics, deadlineExceeded: false };
}

export function locateRollout(options) {
  const threadId = String(options?.threadId || "").toLowerCase();
  const now = options?.now || Date.now;
  const deadlineAt = options?.deadlineAt ?? Number.POSITIVE_INFINITY;
  if (!UUID_RE.test(threadId)) {
    return {
      status: "unavailable",
      reason: "invalid-thread",
      candidates: [],
      diagnostics: [diagnostic("invalid-thread", { threadId })],
    };
  }

  if (options?.rolloutPath) {
    if (now() >= deadlineAt) {
      return {
        status: "unavailable",
        reason: "deadline-exceeded",
        authority: "explicit",
        candidates: [],
        diagnostics: [diagnostic("deadline-exceeded", { path: options.rolloutPath })],
      };
    }
    const candidate = validateCandidate(options.rolloutPath, threadId);
    if (!candidate.ok) {
      return {
        status: "unavailable",
        reason: candidate.reason,
        authority: "explicit",
        candidates: [],
        diagnostics: [diagnostic(candidate.reason, candidate)],
      };
    }
    return {
      status: "found",
      authority: "explicit",
      path: candidate.path,
      candidates: [candidate],
      aliasCount: 1,
      diagnostics: [],
    };
  }

  const sessionsRoot = options?.sessionsRoot || path.join(os.homedir(), ".codex", "sessions");
  if (!fs.existsSync(sessionsRoot)) {
    return {
      status: "unavailable",
      reason: "no-candidate",
      authority: "sessions-root",
      candidates: [],
      diagnostics: [diagnostic("sessions-root-missing", { path: sessionsRoot })],
    };
  }
  const discovered = findUuidCandidates(sessionsRoot, threadId, { now, deadlineAt });
  if (discovered.deadlineExceeded) {
    return {
      status: "unavailable",
      reason: "deadline-exceeded",
      authority: "sessions-root",
      candidates: [],
      diagnostics: discovered.diagnostics,
    };
  }
  const checked = [];
  for (const item of discovered.matches) {
    if (now() >= deadlineAt) {
      return {
        status: "unavailable",
        reason: "deadline-exceeded",
        authority: "sessions-root",
        candidates: [],
        diagnostics: [...discovered.diagnostics, diagnostic("deadline-exceeded", { path: item })],
      };
    }
    checked.push(validateCandidate(item, threadId));
  }
  const valid = checked.filter((item) => item.ok);
  const invalid = checked.filter((item) => !item.ok);
  const byIdentity = new Map();
  for (const candidate of valid) {
    const existing = byIdentity.get(candidate.identityKey);
    if (existing) {
      existing.aliases.push(candidate.path);
    } else {
      byIdentity.set(candidate.identityKey, { ...candidate, aliases: [candidate.path] });
    }
  }
  const candidates = [...byIdentity.values()].sort((a, b) => a.path.localeCompare(b.path));
  const diagnostics = [
    ...discovered.diagnostics,
    ...invalid.map((item) => diagnostic(item.reason, item)),
  ];
  if (candidates.length === 0) {
    return {
      status: "unavailable",
      reason: invalid[0]?.reason || "no-candidate",
      authority: "sessions-root",
      candidates,
      aliasCount: valid.length,
      diagnostics,
    };
  }
  if (candidates.length > 1) {
    return {
      status: "ambiguous",
      reason: "multiple-candidates",
      authority: "sessions-root",
      candidates,
      aliasCount: valid.length,
      diagnostics: [
        ...diagnostics,
        diagnostic("multiple-candidates", { paths: candidates.map((item) => item.path) }),
      ],
    };
  }
  return {
    status: "found",
    authority: "sessions-root",
    path: candidates[0].path,
    candidates,
    aliasCount: valid.length,
    diagnostics,
  };
}

// A4 marker-proof consumer: a NAMED consumer over the ONE shared createTurnBoundaryAccumulator (no
// third boundary machine). Completion is turn-scoped / turnId-bound: a task_complete certifies the
// agent marker only when it CLOSES the SAME turn that carried that marker. This replaces the old
// pure line-order `lastTaskCompleteLine > lastAgentMarkerLine` relation, whose cross-turn blind spot
// returned a false-positive proof (agent marker in turn 1, task_complete in turn 2 → wrongly ok).
function createMarkerProofConsumer(marker) {
  const accumulator = createTurnBoundaryAccumulator();
  const markerTurnSequences = new Set();
  // A marker seen with no enclosing task_started-opened turn (ordered / degenerate rollout tail)
  // stays certifiable by a following same-region task_complete until a new task_started ends it.
  let looseAgentMarkerPending = false;
  let completedAfterAgentMarker = false;
  const state = {
    exists: false,
    lineCount: 0,
    parseErrorCount: 0,
    lastUserMarkerLine: null,
    lastAgentMarkerLine: null,
    lastTaskCompleteLine: null,
    partialTail: false,
    error: null,
  };

  const processSnapshot = (snapshot) => {
    if (
      markerTurnSequences.has(snapshot.sequence) &&
      snapshot.activity === "closed" &&
      snapshot.terminalType === "task_complete"
    ) {
      completedAfterAgentMarker = true;
    }
    markerTurnSequences.delete(snapshot.sequence);
  };

  return {
    push(item) {
      if (item.parseError) {
        accumulator.push(item);
        return;
      }
      const hasMarker = typeof item.text === "string" && item.text.includes(marker);
      if (
        hasMarker &&
        item.envelopeType === "event_msg" &&
        item.payloadType === "user_message"
      ) {
        state.lastUserMarkerLine = item.line;
      }
      const isAgentMarker =
        hasMarker &&
        !item.interAgent &&
        item.envelopeType === "event_msg" &&
        item.payloadType === "agent_message";
      const isTaskComplete =
        item.envelopeType === "event_msg" && item.payloadType === "task_complete";
      if (item.envelopeType === "event_msg" && item.payloadType === "task_started") {
        looseAgentMarkerPending = false;
      }
      const { sequence, snapshots } = accumulator.push(item);
      if (isAgentMarker) {
        state.lastAgentMarkerLine = item.line;
        if (sequence !== null && sequence !== undefined) {
          markerTurnSequences.add(sequence);
        } else {
          looseAgentMarkerPending = true;
        }
      }
      if (isTaskComplete) {
        state.lastTaskCompleteLine = item.line;
        if ((sequence === null || sequence === undefined) && looseAgentMarkerPending) {
          completedAfterAgentMarker = true;
        }
      }
      for (const snapshot of snapshots) processSnapshot(snapshot);
    },
    finish(parsed) {
      const snapshots = accumulator.finish(parsed?.diagnostics || []);
      for (const snapshot of snapshots) processSnapshot(snapshot);
    },
    observe(parsed) {
      if (parsed) {
        state.exists ||= parsed.reason !== "missing";
        state.lineCount = Math.max(
          state.lineCount,
          parsed.cursor?.lineNumber || parsed.records?.at(-1)?.line || 0,
        );
        state.parseErrorCount += parsed.parseErrorCount || 0;
        state.partialTail = parsed.partialTail || false;
        state.error = parsed.ok ? null : parsed.reason;
      }
      return {
        ...state,
        agentMarkerSeen: state.lastAgentMarkerLine !== null,
        taskCompleteAfterAgentMarker: completedAfterAgentMarker,
      };
    },
  };
}

export function inspectRolloutMarker(rolloutPath, marker) {
  const consumer = createMarkerProofConsumer(marker);
  const parsed = readRolloutFile(rolloutPath);
  for (const item of parsed.records || []) consumer.push(item);
  consumer.finish(parsed);
  return consumer.observe(parsed);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function pollRolloutForMarker(
  rolloutPath,
  marker,
  pollMs,
  pollAttempts,
  injected = {},
) {
  const now = injected.now || Date.now;
  const sleep = injected.sleep || defaultSleep;
  const startedAtMs = now();
  const startedAt = new Date(startedAtMs).toISOString();
  const attempts = Number.isSafeInteger(pollAttempts) && pollAttempts > 0 ? pollAttempts : 1;
  const interval = Number.isFinite(pollMs) && pollMs > 0 ? pollMs : 1;
  const deadlineAt = startedAtMs + interval * attempts;
  let cursor = null;
  const consumer = createMarkerProofConsumer(marker);
  let lastObservation = null;
  let attemptsMade = 0;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    if (attempt > 1 && now() >= deadlineAt) break;
    // Collect this attempt's streamed records, but only feed them into the shared turn-scoped
    // accumulator once the read is trusted, so an integrity-failed read never advances the
    // boundary machine and a re-read from the retained cursor cannot double-push records.
    const attemptRecords = [];
    const parsed = readRolloutFile(rolloutPath, {
      ...(cursor ? { cursor } : {}),
      deadlineAt,
      now,
      retainRecords: false,
      onRecord: (item) => attemptRecords.push(item),
    });
    attemptsMade = attempt;
    const trustedRead = parsed.ok || (
      parsed.reason === "deadline-exceeded" && parsed.integrityValidated
    );
    if (trustedRead) {
      if (parsed.ok) cursor = parsed.cursor;
      for (const item of attemptRecords) consumer.push(item);
    }
    lastObservation = consumer.observe(parsed);
    if (
      trustedRead &&
      lastObservation.agentMarkerSeen &&
      lastObservation.taskCompleteAfterAgentMarker
    ) {
      return {
        ok: true,
        startedAt,
        finishedAt: new Date(now()).toISOString(),
        attempts: attempt,
        rolloutPath,
        markerSha256: sha256(marker),
        lastObservation,
      };
    }
    if (!parsed.ok && parsed.reason !== "missing") break;
    if (attempt < attempts) {
      const remaining = deadlineAt - now();
      if (remaining <= 0) break;
      await sleep(Math.min(interval, remaining));
    }
  }
  return {
    ok: false,
    startedAt,
    finishedAt: new Date(now()).toISOString(),
    attempts: attemptsMade,
    rolloutPath,
    markerSha256: sha256(marker),
    lastObservation,
    warnings: [
      "Marker proof did not reach agent response plus later task_complete within the poll window.",
      "The turn may still be running; inspect the target rollout before deciding whether to retry.",
    ],
  };
}
