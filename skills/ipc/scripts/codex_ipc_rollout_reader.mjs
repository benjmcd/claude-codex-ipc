import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_MAX_RECORD_BYTES = 24 * 1024 * 1024;
const READ_CHUNK_BYTES = 256 * 1024;
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

function failure(filePath, reason, diagnostics = [], extra = {}) {
  return {
    ok: false,
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
    } catch {
      finalDescriptorStat = null;
    }
    fs.closeSync(descriptor);
  }
  if (fatalResult) return fatalResult;
  if (!finalDescriptorStat) {
    return failure(filePath, "unreadable", [
      ...diagnostics,
      diagnostic("descriptor-revalidation-failed", { path: filePath }),
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
  };
  return {
    ok: true,
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

function makeTurn(record, sequence) {
  return {
    sequence,
    turnId: record.turnId,
    boundaryMode: record.turnId ? "turn-id" : "ordered-fallback",
    startLine: record.line,
    terminal: null,
    userMessages: [],
    agentMessages: [],
    parseErrors: [],
    boundaryErrors: [],
    superseded: false,
  };
}

function correlateDispatchWindow(parsed, dispatchId) {
  const basename = dispatchId.endsWith(".task.md") ? dispatchId : `${dispatchId}.task.md`;
  const turns = [];
  const explicit = new Map();
  let current = null;
  let sequence = 0;

  for (const record of parsed.records || []) {
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
      if (current && !current.terminal) current.userMessages.push(record);
      continue;
    }
    if (record.payloadType === "agent_message") {
      if (current && !current.terminal) current.agentMessages.push(record);
      continue;
    }
    if (record.payloadType === "task_complete" || record.payloadType === "turn_aborted") {
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
        continue;
      } else {
        turn = current;
      }
      if (!turn || turn.terminal) continue;
      turn.terminal = record;
      if (current === turn) current = null;
    }
  }

  const occurrences = [];
  for (const turn of turns) {
    const markers = turn.userMessages.filter((item) => exactTaskBasename(item.text, basename));
    for (const marker of markers) {
      const diagnostics = [];
      const laterUsers = turn.userMessages.filter((item) => item.line > marker.line);
      const inWindowErrors = turn.parseErrors.filter(
        (item) => item.line > marker.line && (!turn.terminal || item.line < turn.terminal.line),
      );
      let outcome;
      if (turn.superseded) {
        diagnostics.push(diagnostic("turn-superseded", { line: turn.startLine, turnId: turn.turnId }));
        outcome = { status: "none", reason: "unavailable" };
      } else if (turn.boundaryErrors.length > 0) {
        diagnostics.push(...turn.boundaryErrors);
        outcome = { status: "none", reason: "unparseable" };
      } else if (inWindowErrors.length > 0) {
        diagnostics.push(...inWindowErrors.map((item) => diagnostic("malformed-json", item)));
        outcome = { status: "none", reason: "unparseable" };
      } else if (laterUsers.length > 0) {
        diagnostics.push(diagnostic("intervening-user-message", { line: laterUsers[0].line }));
        outcome = { status: "none", reason: "ambiguous" };
      } else if (!turn.terminal) {
        outcome = { status: "none", reason: "pending" };
      } else if (turn.terminal.payloadType === "turn_aborted") {
        outcome = { status: "none", reason: "unavailable" };
      } else {
        let finals = turn.agentMessages.filter((item) => item.phase === "final_answer");
        if (finals.length === 0 && typeof turn.terminal.lastAgentMessage === "string") {
          finals = turn.agentMessages.filter((item) => item.text === turn.terminal.lastAgentMessage);
        }
        const selected = finals.at(-1) || null;
        if (!selected) {
          outcome = { status: "none", reason: "unavailable" };
        } else {
          if (
            typeof turn.terminal.lastAgentMessage === "string" &&
            turn.terminal.lastAgentMessage !== selected.text
          ) {
            diagnostics.push(
              diagnostic("completion-message-mismatch", {
                line: turn.terminal.line,
                turnId: turn.turnId,
              }),
            );
          }
          outcome = {
            status: "complete",
            text: selected.text,
            finalMessageCount: finals.length,
          };
        }
      }
      occurrences.push({
        ...outcome,
        diagnostics,
        markerLine: marker.line,
        terminalLine: turn.terminal?.line || null,
        turnId: turn.turnId,
        boundaryMode: turn.boundaryMode,
      });
    }
  }

  const completed = occurrences
    .filter((item) => item.status === "complete")
    .sort((left, right) => (left.terminalLine || 0) - (right.terminalLine || 0));
  if (completed.length > 0) {
    return { ...completed.at(-1), duplicateCount: occurrences.length };
  }
  const reasonOrder = ["unparseable", "ambiguous", "pending", "unavailable"];
  const reason = reasonOrder.find((item) => occurrences.some((entry) => entry.reason === item));
  const matching = occurrences.find((item) => item.reason === reason) || null;
  return {
    status: "none",
    reason: reason || (parsed.ok ? "pending" : "unparseable"),
    duplicateCount: occurrences.length,
    diagnostics: matching?.diagnostics || parsed.diagnostics || [],
    turnId: matching?.turnId || null,
    boundaryMode: matching?.boundaryMode || null,
  };
}

export function createDispatchCorrelator(dispatchId) {
  let currentRecords = [];
  let currentTurnId = null;
  let bestCompleted = null;
  let duplicateCount = 0;
  const reasonDiagnostics = new Map();

  const consumeWindow = () => {
    if (currentRecords.length === 0) return;
    const result = correlateDispatchWindow({ ok: true, records: currentRecords }, dispatchId);
    currentRecords = [];
    currentTurnId = null;
    if (!result.duplicateCount) return;
    duplicateCount += result.duplicateCount;
    if (result.status === "complete") {
      bestCompleted = result;
    } else if (!reasonDiagnostics.has(result.reason)) {
      reasonDiagnostics.set(result.reason, result);
    }
  };

  return {
    push(record) {
      if (record.parseError) {
        if (currentRecords.length > 0) currentRecords.push(record);
        return;
      }
      if (record.envelopeType !== "event_msg") return;
      if (record.payloadType === "task_started") {
        if (currentRecords.length > 0) {
          currentRecords.push(record);
          consumeWindow();
        }
        currentRecords = [record];
        currentTurnId = record.turnId;
        return;
      }
      if (currentRecords.length === 0) return;
      currentRecords.push(record);
      if (record.payloadType !== "task_complete" && record.payloadType !== "turn_aborted") return;
      const matchingTerminal = currentTurnId
        ? record.turnId === currentTurnId
        : record.turnId === null;
      if (matchingTerminal) consumeWindow();
    },
    finish(parsed = { ok: true, diagnostics: [] }) {
      consumeWindow();
      if (bestCompleted) return { ...bestCompleted, duplicateCount };
      const reasonOrder = ["unparseable", "ambiguous", "pending", "unavailable"];
      const reason = reasonOrder.find((item) => reasonDiagnostics.has(item));
      const selected = reason ? reasonDiagnostics.get(reason) : null;
      return {
        status: "none",
        reason: reason || (parsed.ok ? "pending" : "unparseable"),
        duplicateCount,
        diagnostics: selected?.diagnostics || parsed.diagnostics || [],
        turnId: selected?.turnId || null,
        boundaryMode: selected?.boundaryMode || null,
      };
    },
  };
}

export function correlateDispatch(parsed, dispatchId) {
  const correlator = createDispatchCorrelator(dispatchId);
  for (const record of parsed.records || []) correlator.push(record);
  return correlator.finish(parsed);
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

function applyMarkerRecord(state, item, marker) {
  if (item.parseError) return;
  if (
    item.text.includes(marker) &&
    item.envelopeType === "event_msg" &&
    item.payloadType === "user_message"
  ) {
    state.lastUserMarkerLine = item.line;
  }
  if (
    item.text.includes(marker) &&
    !item.interAgent &&
    item.envelopeType === "event_msg" &&
    item.payloadType === "agent_message"
  ) {
    state.lastAgentMarkerLine = item.line;
  }
  if (item.envelopeType === "event_msg" && item.payloadType === "task_complete") {
    state.lastTaskCompleteLine = item.line;
  }
}

function updateMarkerState(state, parsed, marker) {
  for (const item of parsed.records || []) applyMarkerRecord(state, item, marker);
  state.exists ||= parsed.reason !== "missing";
  state.lineCount = Math.max(
    state.lineCount,
    parsed.cursor?.lineNumber || parsed.records?.at(-1)?.line || 0,
  );
  state.parseErrorCount += parsed.parseErrorCount || 0;
  state.partialTail = parsed.partialTail || false;
  state.error = parsed.ok ? null : parsed.reason;
  return {
    ...state,
    agentMarkerSeen: state.lastAgentMarkerLine !== null,
    taskCompleteAfterAgentMarker:
      state.lastAgentMarkerLine !== null &&
      state.lastTaskCompleteLine !== null &&
      state.lastTaskCompleteLine > state.lastAgentMarkerLine,
  };
}

function emptyMarkerState() {
  return {
    exists: false,
    lineCount: 0,
    parseErrorCount: 0,
    lastUserMarkerLine: null,
    lastAgentMarkerLine: null,
    lastTaskCompleteLine: null,
    partialTail: false,
    error: null,
  };
}

export function inspectRolloutMarker(rolloutPath, marker) {
  return updateMarkerState(emptyMarkerState(), readRolloutFile(rolloutPath), marker);
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
  const markerState = emptyMarkerState();
  let lastObservation = null;
  let attemptsMade = 0;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    if (attempt > 1 && now() >= deadlineAt) break;
    const parsed = readRolloutFile(rolloutPath, {
      ...(cursor ? { cursor } : {}),
      deadlineAt,
      now,
      retainRecords: false,
      onRecord: (item) => applyMarkerRecord(markerState, item, marker),
    });
    attemptsMade = attempt;
    if (parsed.ok) cursor = parsed.cursor;
    lastObservation = updateMarkerState(markerState, parsed, marker);
    if (lastObservation.agentMarkerSeen && lastObservation.taskCompleteAfterAgentMarker) {
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
