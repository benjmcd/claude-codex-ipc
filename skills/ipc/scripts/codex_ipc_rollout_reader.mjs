import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_MAX_RECORD_BYTES = 24 * 1024 * 1024;
const READ_CHUNK_BYTES = 256 * 1024;
const CONTENT_ANCHOR_BYTES = 4096;
const DEADLINE_ERROR_CODE = "IPC_ROLLOUT_DEADLINE_EXCEEDED";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID_SOURCE = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const ROLLOUT_BASENAME_RE = new RegExp(
  `^.+-(${UUID_SOURCE})(?:_(${UUID_SOURCE}))?\\.jsonl$`,
  "i",
);

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
  "compaction",
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
// Named item_completed classes. Pinned to a dated corpus census: re-derived over the retained
// ~/.codex/sessions corpus on 2026-09-03 (2026/08 + 2026/09 enumerated in full). The eleven
// original entries plus FunctionCallOutput (91 records across 12 files, produced whenever a
// thread uses Codex's own send_message_to_thread delegation tool) and Plan (2026/03-04 files).
// Re-derive this census at each release cut; classes outside it are governed by the unknown-class
// rule below, not by this set.
const COMPLETED_ITEM_TYPES = new Set([
  "AgentMessage",
  "CollabAgentToolCall",
  "CommandExecution",
  "ContextCompaction",
  "DynamicToolCall",
  "Extension",
  "FileChange",
  "FunctionCallOutput",
  "McpToolCall",
  "Plan",
  "Reasoning",
  "SubAgentActivity",
  "UserMessage",
]);
const COMPLETED_ITEM_SEMANTICS = new Map([
  ["AgentMessage", "agent_message"],
  ["UserMessage", "user_message"],
]);
// Owner ruling B-1 (2026-09-03): an item_completed wrapper whose item class is not named above is
// inert-but-logged rather than drift, UNLESS the item itself carries a body- or role-bearing field.
// Such a field means the record could hold a reply body or a speaker role this reader cannot read,
// which is the only condition under which an unrecognised class may poison its turn. The closed
// promotion set above is unchanged by this rule: an unknown class is never promoted, never exposes
// text, phase or role, and never reaches correlation retention.
const ITEM_BODY_BEARING_KEYS = ["content", "text", "phase", "role"];

function itemCarriesBodyOrRole(item) {
  if (!item || typeof item !== "object") return false;
  return ITEM_BODY_BEARING_KEYS.some((key) => Object.hasOwn(item, key));
}

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

function semanticEventRoleValid(envelopeType, payloadType, payload) {
  if (envelopeType !== "event_msg") return true;
  const expectedRole =
    payloadType === "agent_message"
      ? "assistant"
      : payloadType === "user_message"
        ? "user"
        : null;
  return (
    expectedRole === null ||
    !Object.hasOwn(payload, "role") ||
    payload.role === expectedRole
  );
}

export function recordThreadIdentity(value) {
  const payload =
    value && value.payload && typeof value.payload === "object" && !Array.isArray(value.payload)
      ? value.payload
      : null;
  if (!payload) return { status: "absent", threadId: null };
  const item =
    payload.item && typeof payload.item === "object" && !Array.isArray(payload.item)
      ? payload.item
      : null;
  const nestedIdentityCarrier =
    value?.type === "event_msg" &&
    item !== null &&
    (payload.type === "item_completed" || !Object.hasOwn(payload, "type"));
  const values = [];
  if (Object.hasOwn(payload, "thread_id")) values.push(payload.thread_id);
  if (nestedIdentityCarrier && Object.hasOwn(item, "thread_id")) values.push(item.thread_id);
  if (values.length === 0) return { status: "absent", threadId: null };
  if (
    values.some(
      (threadId) => typeof threadId !== "string" || !UUID_RE.test(threadId),
    )
  ) {
    return { status: "invalid", threadId: null };
  }
  const distinct = new Set(values.map((threadId) => threadId.toLowerCase()));
  if (distinct.size !== 1) return { status: "conflict", threadId: null };
  return { status: "valid", threadId: [...distinct][0] };
}

function normalizedUuid(value) {
  return typeof value === "string" && UUID_RE.test(value) ? value.toLowerCase() : null;
}

function normalizedTurnId(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  return UUID_RE.test(value) ? value.toLowerCase() : value;
}

export function advanceRolloutOwnerLineage(value, state = {}) {
  if (value?.type !== "session_meta") {
    return {
      status: "absent",
      rolloutThreadId: normalizedUuid(state.rolloutThreadId),
      lineageIds: [...new Set(state.lineageIds || [])].sort(),
    };
  }

  const declaredThreadId = normalizedUuid(value?.payload?.id);
  let rolloutThreadId = normalizedUuid(state.rolloutThreadId);
  const expectedThreadId = normalizedUuid(state.expectedThreadId);
  const lineageIds = new Set(
    Array.isArray(state.lineageIds)
      ? state.lineageIds.map(normalizedUuid).filter(Boolean)
      : [],
  );
  if (rolloutThreadId) lineageIds.add(rolloutThreadId);
  if (!declaredThreadId) {
    return { status: "invalid", rolloutThreadId, lineageIds: [...lineageIds].sort() };
  }

  const observedThreadIds = new Set(
    [...(state.observedThreadIds || [])].map(normalizedUuid).filter(Boolean),
  );
  if (!rolloutThreadId) {
    if (
      (expectedThreadId && declaredThreadId !== expectedThreadId) ||
      [...observedThreadIds].some((threadId) => threadId !== declaredThreadId)
    ) {
      return { status: "mismatch", rolloutThreadId, lineageIds: [...lineageIds].sort() };
    }
    rolloutThreadId = declaredThreadId;
    lineageIds.add(rolloutThreadId);
  } else if (
    (expectedThreadId && rolloutThreadId !== expectedThreadId) ||
    !lineageIds.has(declaredThreadId) ||
    [...observedThreadIds].some((threadId) => threadId !== rolloutThreadId)
  ) {
    return { status: "mismatch", rolloutThreadId, lineageIds: [...lineageIds].sort() };
  }

  lineageIds.add(declaredThreadId);
  const forkedFromId = normalizedUuid(value?.payload?.forked_from_id);
  if (forkedFromId) lineageIds.add(forkedFromId);
  return {
    status: "accepted",
    rolloutThreadId,
    lineageIds: [...lineageIds].sort(),
  };
}

function forkHistoryStateValid(state, requireBoundary = false) {
  if (!state || typeof state !== "object" || Array.isArray(state)) return false;
  if (state.mode === "nonfork") {
    return (
      state.forkedFromId === null &&
      state.startOrdinal === null &&
      state.nextOrdinal === null &&
      state.boundarySeen === false
    );
  }
  if (state.mode !== "producer-ordinal") return false;
  if (
    !normalizedUuid(state.forkedFromId) ||
    !Number.isSafeInteger(state.startOrdinal) ||
    state.startOrdinal < 1 ||
    !Number.isSafeInteger(state.nextOrdinal) ||
    state.nextOrdinal < 1 ||
    typeof state.boundarySeen !== "boolean"
  ) {
    return false;
  }
  if (state.boundarySeen !== (state.nextOrdinal > state.startOrdinal)) return false;
  return !requireBoundary || state.boundarySeen;
}

function forkHistoryCursorStateValid(cursor) {
  if (cursor?.firstRecordSeen === false) return cursor.forkHistoryScope === null;
  return forkHistoryStateValid(cursor?.forkHistoryScope, true);
}

function forkHistoryStatesEqual(left, right) {
  return (
    forkHistoryStateValid(left, true) &&
    forkHistoryStateValid(right, true) &&
    left.mode === right.mode &&
    left.forkedFromId === right.forkedFromId &&
    left.startOrdinal === right.startOrdinal &&
    left.nextOrdinal === right.nextOrdinal &&
    left.boundarySeen === right.boundarySeen
  );
}

function canonicalRolloutLineageIds(values) {
  if (!Array.isArray(values)) return null;
  const normalized = values.map(normalizedUuid);
  if (normalized.some((value) => value === null)) return null;
  const distinct = [...new Set(normalized)].sort();
  return distinct.length === normalized.length ? distinct : null;
}

function rolloutOwnerStatesEqual(cursor, replayed) {
  const cursorThreadId = normalizedUuid(cursor?.rolloutThreadId);
  const replayedThreadId = normalizedUuid(replayed?.rolloutThreadId);
  const cursorLineageIds = canonicalRolloutLineageIds(cursor?.rolloutLineageIds);
  const replayedLineageIds = canonicalRolloutLineageIds(replayed?.rolloutLineageIds);
  return (
    cursorThreadId !== null &&
    cursorThreadId === replayedThreadId &&
    cursorLineageIds !== null &&
    replayedLineageIds !== null &&
    cursorLineageIds.length === replayedLineageIds.length &&
    cursorLineageIds.every((value, index) => value === replayedLineageIds[index])
  );
}

function cursorPartialBase64ShapeValid(value) {
  if (value === "") return true;
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return false;
  const paddingStart = value.indexOf("=");
  const contentLength = paddingStart === -1 ? value.length : paddingStart;
  if (contentLength % 4 === 1) return false;
  if (paddingStart === -1) return true;
  if (value.length % 4 !== 0) return false;
  const paddingLength = value.length - contentLength;
  return (
    (paddingLength === 1 && contentLength % 4 === 3) ||
    (paddingLength === 2 && contentLength % 4 === 2)
  );
}

function cursorPrefixStateMatches(cursor, replayed, maxRecordBytes) {
  const replayedPending = replayed?.pending;
  if (
    typeof cursor?.partialBase64 !== "string" ||
    !Number.isSafeInteger(cursor?.lineNumber) ||
    !Number.isSafeInteger(cursor?.partialStart) ||
    !Buffer.isBuffer(replayedPending) ||
    cursor.lineNumber !== replayed?.lineNumber ||
    cursor.partialStart !== replayed?.pendingStart ||
    !Object.is(cursor.lastTimestamp, replayed?.lastTimestamp) ||
    cursor.firstRecordSeen !== replayed?.firstRecordSeen ||
    cursor.firstRecordAnchorEndOffset !== replayed?.firstRecordAnchorEndOffset ||
    cursor.firstRecordAnchorSha256 !== replayed?.firstRecordAnchorSha256
  ) {
    return false;
  }

  // Cursors are untrusted input. Bound and validate the encoded representation before
  // asking Buffer.from to allocate; the decoded bytes must still equal the replayed prefix.
  const maxEncodedLength = Math.ceil(maxRecordBytes / 3) * 4;
  const expectedEncodedLength = Math.ceil(replayedPending.length / 3) * 4;
  if (
    cursor.partialBase64.length > maxEncodedLength ||
    cursor.partialBase64.length > expectedEncodedLength ||
    !cursorPartialBase64ShapeValid(cursor.partialBase64)
  ) {
    return false;
  }
  const cursorPending = Buffer.from(cursor.partialBase64, "base64");
  return cursorPending.length === replayedPending.length && cursorPending.equals(replayedPending);
}

export function advanceRolloutHistoryScope(value, state = null, context = {}) {
  const isFirstRecord = context.isFirstRecord === true;
  let current = state;
  if (isFirstRecord) {
    const payload =
      value?.payload && typeof value.payload === "object" && !Array.isArray(value.payload)
        ? value.payload
        : {};
    const hasFork = Object.hasOwn(payload, "forked_from_id");
    if (!hasFork) {
      current = {
        mode: "nonfork",
        forkedFromId: null,
        startOrdinal: null,
        nextOrdinal: null,
        boundarySeen: false,
      };
      return { status: "admit", reason: null, state: current };
    }

    const forkedFromId = normalizedUuid(payload.forked_from_id);
    const ownerId = normalizedUuid(payload.id);
    if (!forkedFromId || !ownerId || forkedFromId === ownerId) {
      return { status: "invalid", reason: "fork-history-parent-invalid", state: null };
    }
    if (!Object.hasOwn(payload, "subagent_history_start_ordinal")) {
      return { status: "missing", reason: "fork-history-boundary-missing", state: null };
    }
    const startOrdinal = payload.subagent_history_start_ordinal;
    if (!Number.isSafeInteger(startOrdinal) || startOrdinal < 1 || value?.ordinal !== 0) {
      return { status: "invalid", reason: "fork-history-boundary-invalid", state: null };
    }
    current = {
      mode: "producer-ordinal",
      forkedFromId,
      startOrdinal,
      nextOrdinal: 1,
      boundarySeen: false,
    };
    return { status: "skip", reason: "fork-history-inherited", state: current };
  }

  if (!forkHistoryStateValid(current)) {
    return { status: "invalid", reason: "fork-history-state-invalid", state: null };
  }
  if (current.mode === "nonfork") {
    return { status: "admit", reason: null, state: current };
  }
  if (!Number.isSafeInteger(value?.ordinal) || value.ordinal !== current.nextOrdinal) {
    return { status: "invalid", reason: "fork-history-ordinal-invalid", state: current };
  }

  const ordinal = value.ordinal;
  current = { ...current, nextOrdinal: ordinal + 1 };
  if (ordinal < current.startOrdinal) {
    return { status: "skip", reason: "fork-history-inherited", state: current };
  }
  if (ordinal === current.startOrdinal) {
    if (value?.type !== "event_msg" || value?.payload?.type !== "thread_settings_applied") {
      return { status: "invalid", reason: "fork-history-boundary-record-invalid", state: current };
    }
    current = { ...current, boundarySeen: true };
    return { status: "admit", reason: null, state: current };
  }
  if (!current.boundarySeen) {
    return { status: "invalid", reason: "fork-history-boundary-unseen", state: current };
  }
  return { status: "admit", reason: null, state: current };
}

function replayConsumedHistoryScope(
  descriptor,
  endOffset,
  maxRecordBytes,
  deadlineReached = null,
) {
  if (!Number.isSafeInteger(endOffset) || endOffset <= 0) {
    return { ok: false, reason: "fork-history-prefix-offset-invalid", state: null };
  }

  const decoder = new TextDecoder("utf-8", { fatal: true });
  const chunk = Buffer.allocUnsafe(Math.min(READ_CHUNK_BYTES, endOffset));
  let position = 0;
  let pending = Buffer.alloc(0);
  let pendingStart = 0;
  let lineNumber = 0;
  let firstRecordSeen = false;
  let firstRecordAnchorEndOffset = null;
  let firstRecordAnchorSha256 = null;
  let lastTimestamp = null;
  let state = null;
  let rolloutThreadId = null;
  let rolloutLineageIds = [];
  const observedThreadIds = new Set();

  const replayLine = (input, byteOffset) => {
    lineNumber += 1;
    const isFirstRecord = !firstRecordSeen;
    firstRecordSeen = true;
    if (isFirstRecord) {
      firstRecordAnchorEndOffset = byteOffset + input.length + 1;
      firstRecordAnchorSha256 = createHash("sha256")
        .update(input)
        .update("\n")
        .digest("hex");
    }
    let bytes = input;
    if (bytes.length > 0 && bytes.at(-1) === 13) {
      bytes = bytes.subarray(0, bytes.length - 1);
    }
    if (bytes.length === 0) {
      return isFirstRecord
        ? { ok: false, reason: "fork-history-first-record-invalid" }
        : { ok: true };
    }
    if (bytes.length > maxRecordBytes) {
      return { ok: false, reason: "fork-history-prefix-record-too-large" };
    }
    if (
      isFirstRecord &&
      bytes.length >= 3 &&
      bytes[0] === 0xef &&
      bytes[1] === 0xbb &&
      bytes[2] === 0xbf
    ) {
      bytes = bytes.subarray(3);
    }

    let value;
    try {
      value = JSON.parse(decoder.decode(bytes));
    } catch {
      return isFirstRecord
        ? { ok: false, reason: "fork-history-first-record-invalid" }
        : { ok: true };
    }
    if (isFirstRecord && value?.type !== "session_meta") {
      return { ok: false, reason: "fork-history-first-record-invalid" };
    }
    const ownerLineage = advanceRolloutOwnerLineage(value, {
      rolloutThreadId,
      lineageIds: rolloutLineageIds,
      observedThreadIds,
    });
    if (ownerLineage.status === "invalid" || ownerLineage.status === "mismatch") {
      return {
        ok: false,
        reason:
          ownerLineage.status === "invalid"
            ? "rollout-owner-prefix-invalid"
            : "rollout-owner-prefix-mismatch",
      };
    }
    if (ownerLineage.status === "accepted") {
      rolloutThreadId = ownerLineage.rolloutThreadId;
      rolloutLineageIds = ownerLineage.lineageIds;
    }
    const recordOwner = recordThreadIdentity(value);
    const advanced = advanceRolloutHistoryScope(value, state, { isFirstRecord });
    if (advanced.status === "missing" || advanced.status === "invalid") {
      return { ok: false, reason: advanced.reason };
    }
    state = advanced.state;
    if (advanced.status === "skip") return { ok: true };
    if (recordOwner.status === "invalid" || recordOwner.status === "conflict") {
      return { ok: false, reason: "rollout-owner-prefix-invalid" };
    }
    if (recordOwner.status === "valid") {
      observedThreadIds.add(recordOwner.threadId);
      if (rolloutThreadId && rolloutThreadId !== recordOwner.threadId) {
        return { ok: false, reason: "rollout-owner-prefix-mismatch" };
      }
    }
    if (typeof value?.timestamp === "string") {
      const timestamp = Date.parse(value.timestamp);
      if (!Number.isNaN(timestamp)) lastTimestamp = timestamp;
    }
    return { ok: true };
  };

  while (position < endOffset) {
    assertDeadlineOpen(deadlineReached);
    const length = Math.min(chunk.length, endOffset - position);
    const bytesRead = fs.readSync(descriptor, chunk, 0, length, position);
    if (bytesRead === 0) throw new Error("history prefix became unreadable");
    const current = chunk.subarray(0, bytesRead);
    let start = 0;
    while (start < current.length) {
      const newline = current.indexOf(10, start);
      if (newline === -1) {
        const tail = current.subarray(start);
        if (pending.length === 0) pendingStart = position + start;
        pending = pending.length === 0 ? Buffer.from(tail) : Buffer.concat([pending, tail]);
        if (pending.length > maxRecordBytes) {
          return { ok: false, reason: "fork-history-prefix-record-too-large", state: null };
        }
        break;
      }
      const fragment = current.subarray(start, newline);
      const line = pending.length === 0 ? fragment : Buffer.concat([pending, fragment]);
      const lineStart = pending.length === 0 ? position + start : pendingStart;
      pending = Buffer.alloc(0);
      const replayed = replayLine(line, lineStart);
      if (!replayed.ok) return { ...replayed, state: null };
      start = newline + 1;
      pendingStart = position + start;
    }
    position += bytesRead;
  }
  assertDeadlineOpen(deadlineReached);
  if (
    firstRecordSeen &&
    (!forkHistoryStateValid(state, true) ||
      !normalizedUuid(rolloutThreadId) ||
      !canonicalRolloutLineageIds(rolloutLineageIds)?.includes(rolloutThreadId))
  ) {
    return { ok: false, reason: "fork-history-prefix-incomplete", state: null };
  }
  return {
    ok: true,
    reason: null,
    state,
    lineNumber,
    pending,
    pendingStart,
    lastTimestamp,
    firstRecordSeen,
    firstRecordAnchorEndOffset,
    firstRecordAnchorSha256,
    rolloutThreadId,
    rolloutLineageIds: canonicalRolloutLineageIds(rolloutLineageIds) || [],
  };
}

export function normalizeRolloutRecord(value, context = {}) {
  const envelopeType = typeof value?.type === "string" ? value.type : null;
  const payload =
    value && value.payload && typeof value.payload === "object" && !Array.isArray(value.payload)
      ? value.payload
      : {};
  const item =
    payload.item && typeof payload.item === "object" && !Array.isArray(payload.item)
      ? payload.item
      : null;
  const completedWrapper = envelopeType === "event_msg" && payload.type === "item_completed";
  const legacyItem =
    envelopeType === "event_msg" && !Object.hasOwn(payload, "type") && item !== null;

  if (completedWrapper) {
    const itemType = typeof item?.type === "string" ? item.type : null;
    const outerTurnId = normalizedTurnId(payload.turn_id);
    const outerThreadId =
      typeof payload.thread_id === "string" && payload.thread_id.length > 0
        ? payload.thread_id
        : null;
    const innerTurnPresent = Boolean(item && Object.hasOwn(item, "turn_id"));
    const innerThreadPresent = Boolean(item && Object.hasOwn(item, "thread_id"));
    const innerTurnId = innerTurnPresent ? normalizedTurnId(item.turn_id) : null;
    const expectedThreadId =
      typeof context.rolloutThreadId === "string" && context.rolloutThreadId.length > 0
        ? context.rolloutThreadId
        : null;
    const identityValid =
      outerTurnId !== null &&
      (!Object.hasOwn(payload, "turn_id") || typeof payload.turn_id === "string") &&
      (!Object.hasOwn(payload, "thread_id") || outerThreadId !== null) &&
      (!innerTurnPresent || (innerTurnId !== null && innerTurnId === outerTurnId)) &&
      (!innerThreadPresent ||
        (typeof item.thread_id === "string" &&
          outerThreadId !== null &&
          item.thread_id.toLowerCase() === outerThreadId.toLowerCase())) &&
      (!expectedThreadId ||
        !outerThreadId ||
        expectedThreadId.toLowerCase() === outerThreadId.toLowerCase());
    const namedClass = Boolean(item && itemType !== null && COMPLETED_ITEM_TYPES.has(itemType));
    const accepted = Boolean(namedClass && identityValid);
    // Unknown-but-inert: an unnamed class with valid outer identity and no body/role-bearing field.
    const inertUnknown = Boolean(
      item && !namedClass && identityValid && !itemCarriesBodyOrRole(item),
    );
    const semanticType = accepted ? COMPLETED_ITEM_SEMANTICS.get(itemType) || null : null;
    const semanticRoleValid =
      semanticType === null || semanticEventRoleValid(envelopeType, semanticType, item);
    return {
      envelopeType,
      payloadType: semanticType || "item_completed",
      itemType,
      itemId: accepted && semanticRoleValid && typeof item.id === "string" ? item.id : null,
      role:
        semanticType && semanticRoleValid && typeof item.role === "string" ? item.role : null,
      phase:
        semanticType && semanticRoleValid && typeof item.phase === "string" ? item.phase : null,
      turnId: outerTurnId,
      threadId: outerThreadId,
      lastAgentMessage: undefined,
      text: semanticType && semanticRoleValid ? textFromAllowedFields(item) : "",
      timestamp: typeof value?.timestamp === "string" ? value.timestamp : null,
      line: context.line ?? null,
      byteOffset: context.byteOffset ?? null,
      interAgent: false,
      unknownItemClass: inertUnknown ? itemType : null,
      knownPair: (accepted || inertUnknown) && semanticRoleValid,
    };
  }

  const body = legacyItem ? item : payload;
  const payloadType = typeof body.type === "string" ? body.type : null;
  const innerTurnPresent = legacyItem && Object.hasOwn(body, "turn_id");
  const innerThreadPresent = legacyItem && Object.hasOwn(body, "thread_id");
  const innerTurnId = normalizedTurnId(body.turn_id);
  const innerThreadId =
    typeof body.thread_id === "string" && body.thread_id.length > 0 ? body.thread_id : null;
  const outerTurnPresent = legacyItem && Object.hasOwn(payload, "turn_id");
  const outerThreadPresent = legacyItem && Object.hasOwn(payload, "thread_id");
  const outerTurnId = legacyItem ? normalizedTurnId(payload.turn_id) : null;
  const outerThreadId =
    legacyItem && typeof payload.thread_id === "string" && payload.thread_id.length > 0
      ? payload.thread_id
      : null;
  const expectedThreadId =
    typeof context.rolloutThreadId === "string" && context.rolloutThreadId.length > 0
      ? context.rolloutThreadId
      : null;
  const selectedThreadId = outerThreadId || innerThreadId;
  const legacyIdentityValid =
    !legacyItem ||
    ((!outerTurnPresent || outerTurnId !== null) &&
      (!outerThreadPresent || outerThreadId !== null) &&
      (!innerTurnPresent || innerTurnId !== null) &&
      (!innerThreadPresent || innerThreadId !== null) &&
      (!outerTurnId || !innerTurnId || outerTurnId === innerTurnId) &&
      (!outerThreadId ||
        !innerThreadId ||
        outerThreadId.toLowerCase() === innerThreadId.toLowerCase()) &&
      (!expectedThreadId ||
        !selectedThreadId ||
        expectedThreadId.toLowerCase() === selectedThreadId.toLowerCase()));
  const directIdentityValid =
    legacyItem ||
    ((!Object.hasOwn(body, "turn_id") || innerTurnId !== null) &&
      (!Object.hasOwn(body, "thread_id") || innerThreadId !== null) &&
      (!expectedThreadId ||
        !innerThreadId ||
        expectedThreadId.toLowerCase() === innerThreadId.toLowerCase()));
  const identityValid = legacyIdentityValid && directIdentityValid;
  const turnId = legacyItem ? outerTurnId || innerTurnId : innerTurnId;
  const threadId = legacyItem ? selectedThreadId : innerThreadId;
  const semanticRoleValid = semanticEventRoleValid(envelopeType, payloadType, body);
  const role =
    identityValid && semanticRoleValid && typeof body.role === "string" ? body.role : null;
  const phase =
    identityValid && semanticRoleValid && typeof body.phase === "string" ? body.phase : null;
  const interAgent = envelopeType === "response_item" && payloadType === "agent_message";
  const inertResponseItem = envelopeType === "response_item" && payloadType === "compaction";
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
    threadId,
    itemType: null,
    itemId: null,
    unknownItemClass: null,
    lastAgentMessage,
    text:
      interAgent || inertResponseItem || !identityValid || !semanticRoleValid
        ? ""
        : textFromAllowedFields(body),
    timestamp: typeof value?.timestamp === "string" ? value.timestamp : null,
    line: context.line ?? null,
    byteOffset: context.byteOffset ?? null,
    interAgent,
    knownPair: identityValid && semanticRoleValid && knownPair(envelopeType, payloadType),
  };
}

function retainForCorrelation(record) {
  if (record.knownPair !== true) return false;
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

function assertDeadlineOpen(deadlineReached) {
  if (deadlineReached?.()) {
    const error = new Error("rollout read deadline exceeded");
    error.code = DEADLINE_ERROR_CODE;
    throw error;
  }
}

function readContentAnchor(descriptor, endOffset, deadlineReached = null) {
  assertDeadlineOpen(deadlineReached);
  const length = Math.min(CONTENT_ANCHOR_BYTES, endOffset);
  const offset = endOffset - length;
  const buffer = Buffer.allocUnsafe(length);
  let total = 0;
  while (total < length) {
    assertDeadlineOpen(deadlineReached);
    const bytesRead = fs.readSync(descriptor, buffer, total, length - total, offset + total);
    if (bytesRead === 0) throw new Error("content anchor became unreadable");
    total += bytesRead;
  }
  assertDeadlineOpen(deadlineReached);
  return {
    endOffset,
    sha256: createHash("sha256").update(buffer).digest("hex"),
  };
}

function updatePrefixHash(descriptor, endOffset, hash, deadlineReached = null) {
  if (!Number.isSafeInteger(endOffset) || endOffset <= 0) {
    throw new Error("prefix anchor offset is invalid");
  }
  const buffer = Buffer.allocUnsafe(Math.min(READ_CHUNK_BYTES, endOffset));
  let position = 0;
  while (position < endOffset) {
    assertDeadlineOpen(deadlineReached);
    const length = Math.min(buffer.length, endOffset - position);
    const bytesRead = fs.readSync(descriptor, buffer, 0, length, position);
    if (bytesRead === 0) throw new Error("prefix anchor became unreadable");
    hash.update(buffer.subarray(0, bytesRead));
    position += bytesRead;
  }
  assertDeadlineOpen(deadlineReached);
  return hash;
}

function readPrefixAnchor(descriptor, endOffset, deadlineReached = null) {
  const hash = updatePrefixHash(
    descriptor,
    endOffset,
    createHash("sha256"),
    deadlineReached,
  );
  return { endOffset, sha256: hash.digest("hex") };
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

function deadlineFailure(filePath, deadlineAt, byteOffset, extra = {}) {
  return failure(filePath, "deadline-exceeded", [
    ...(extra.diagnostics || []),
    diagnostic("deadline-exceeded", { path: filePath, byteOffset, deadlineAt }),
  ], extra);
}

export function readRolloutFile(filePath, options = {}) {
  const maxRecordBytes = options.maxRecordBytes ?? DEFAULT_MAX_RECORD_BYTES;
  const now = options.now || Date.now;
  const deadlineAt = options.deadlineAt ?? Number.POSITIVE_INFINITY;
  const deadlineReached = Number.isFinite(deadlineAt)
    ? () => now() >= deadlineAt
    : null;
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
  if (previous && !forkHistoryCursorStateValid(previous)) {
    fs.closeSync(descriptor);
    return failure(filePath, "invalid-cursor", [
      diagnostic("fork-history-cursor-invalid", { path: filePath }),
    ]);
  }
  if (
    typeof options.expectedIdentityKey === "string" &&
    options.expectedIdentityKey.length > 0 &&
    options.expectedIdentityKey !== identity.key
  ) {
    fs.closeSync(descriptor);
    return failure(filePath, "file-replaced", [
      diagnostic("file-replaced", {
        path: filePath,
        expectedIdentity: options.expectedIdentityKey,
        identity: identity.key,
      }),
    ]);
  }
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
  if (
    previous &&
    (typeof previous.canonicalPath !== "string" ||
      previous.canonicalPath.length === 0 ||
      previous.canonicalPath !== identity.canonicalPath)
  ) {
    fs.closeSync(descriptor);
    return failure(filePath, "file-replaced", [
      diagnostic("canonical-path-changed", {
        path: filePath,
        previousCanonicalPath: previous.canonicalPath || null,
        canonicalPath: identity.canonicalPath,
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
  const expectedRolloutThreadId =
    typeof options.rolloutThreadId === "string"
      ? normalizedUuid(options.rolloutThreadId)
      : null;
  if (typeof options.rolloutThreadId === "string" && !expectedRolloutThreadId) {
    fs.closeSync(descriptor);
    return failure(filePath, "rollout-owner-invalid", [
      diagnostic("schema-drift", {
        path: filePath,
        line: null,
        byteOffset: 0,
        envelopeType: "session_meta",
        payloadType: null,
        reason: "rollout-thread-id-invalid",
      }),
    ]);
  }
  const previousRolloutThreadId = normalizedUuid(previous?.rolloutThreadId);
  if (
    previous &&
    expectedRolloutThreadId &&
    previousRolloutThreadId !== expectedRolloutThreadId
  ) {
    fs.closeSync(descriptor);
    return failure(filePath, "rollout-owner-mismatch", [
      diagnostic("schema-drift", {
        path: filePath,
        line: null,
        byteOffset: 0,
        envelopeType: "session_meta",
        payloadType: null,
        reason: "rollout-thread-id-mismatch",
      }),
    ]);
  }

  let initialAnchor;
  let revalidatedForkHistoryScope = previous?.forkHistoryScope || null;
  let revalidatedRolloutThreadId = previousRolloutThreadId;
  let revalidatedRolloutLineageIds = Array.isArray(previous?.rolloutLineageIds)
    ? [...previous.rolloutLineageIds]
    : previousRolloutThreadId
      ? [previousRolloutThreadId]
      : [];
  let revalidatedPrefixState = null;
  const observedPrefixHash = createHash("sha256");
  try {
    initialAnchor = readContentAnchor(descriptor, initialStat.size, deadlineReached);
    if (previous) {
      if (
        !Number.isSafeInteger(previous.prefixEndOffset) ||
        previous.prefixEndOffset <= 0 ||
        previous.prefixEndOffset !== previous.offset ||
        previous.prefixEndOffset > initialStat.size ||
        typeof previous.prefixSha256 !== "string" ||
        !/^[0-9a-f]{64}$/i.test(previous.prefixSha256)
      ) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("consumed-prefix-anchor-missing", { path: filePath }),
        ]);
      }
      updatePrefixHash(
        descriptor,
        previous.prefixEndOffset,
        observedPrefixHash,
        deadlineReached,
      );
      if (observedPrefixHash.copy().digest("hex") !== previous.prefixSha256) {
        fs.closeSync(descriptor);
        return failure(filePath, "file-replaced", [
          diagnostic("consumed-prefix-changed", {
            path: filePath,
            anchorEndOffset: previous.prefixEndOffset,
          }),
        ]);
      }
    }
    if (previous?.anchorSha256) {
      const previousAnchor = readContentAnchor(
        descriptor,
        previous.anchorEndOffset,
        deadlineReached,
      );
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
    if (previous?.firstRecordSeen === true) {
      if (
        !Number.isSafeInteger(previous.firstRecordAnchorEndOffset) ||
        previous.firstRecordAnchorEndOffset <= 0 ||
        typeof previous.firstRecordAnchorSha256 !== "string" ||
        !/^[0-9a-f]{64}$/i.test(previous.firstRecordAnchorSha256)
      ) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("first-record-anchor-missing", { path: filePath }),
        ]);
      }
      const previousFirstRecordAnchor = readPrefixAnchor(
        descriptor,
        previous.firstRecordAnchorEndOffset,
        deadlineReached,
      );
      if (previousFirstRecordAnchor.sha256 !== previous.firstRecordAnchorSha256) {
        fs.closeSync(descriptor);
        return failure(filePath, "file-replaced", [
          diagnostic("first-record-changed", {
            path: filePath,
            anchorEndOffset: previous.firstRecordAnchorEndOffset,
          }),
        ]);
      }
    } else if (
      previous &&
      (previous.firstRecordSeen !== false ||
        previous.firstRecordAnchorEndOffset !== null ||
        previous.firstRecordAnchorSha256 !== null)
    ) {
      fs.closeSync(descriptor);
      return failure(filePath, "invalid-cursor", [
        diagnostic("first-record-anchor-missing", { path: filePath }),
      ]);
    }
    if (previous) {
      if (
        typeof previous.partialBase64 !== "string" ||
        !Number.isSafeInteger(previous.partialStart) ||
        previous.partialStart < 0 ||
        previous.partialStart > previous.offset ||
        (previous.firstRecordSeen === true &&
          previous.partialStart < previous.firstRecordAnchorEndOffset) ||
        (previous.partialBase64 === "" && previous.partialStart !== previous.offset)
      ) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("fork-history-prefix-offset-invalid", { path: filePath }),
        ]);
      }
      const replayedHistory = replayConsumedHistoryScope(
        descriptor,
        previous.offset,
        maxRecordBytes,
        deadlineReached,
      );
      if (
        !replayedHistory.ok ||
        !cursorPrefixStateMatches(previous, replayedHistory, maxRecordBytes)
      ) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("rollout-prefix-cursor-mismatch", {
            path: filePath,
            reason: replayedHistory.reason || "rollout-prefix-state-mismatch",
          }),
        ]);
      }
      const replayedCursorState = replayedHistory.firstRecordSeen
        ? replayedHistory
        : {
            ...replayedHistory,
            rolloutThreadId: expectedRolloutThreadId,
            rolloutLineageIds: expectedRolloutThreadId ? [expectedRolloutThreadId] : [],
          };
      if (
        replayedHistory.firstRecordSeen
          ? !forkHistoryStatesEqual(previous.forkHistoryScope, replayedHistory.state)
          : previous.forkHistoryScope !== null || replayedHistory.state !== null
      ) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("fork-history-cursor-mismatch", {
            path: filePath,
            reason: replayedHistory.reason || "fork-history-state-mismatch",
          }),
        ]);
      }
      if (!rolloutOwnerStatesEqual(previous, replayedCursorState)) {
        fs.closeSync(descriptor);
        return failure(filePath, "invalid-cursor", [
          diagnostic("rollout-owner-cursor-mismatch", {
            path: filePath,
            reason: "rollout-owner-state-mismatch",
          }),
        ]);
      }
      revalidatedForkHistoryScope = replayedHistory.state;
      revalidatedRolloutThreadId = replayedCursorState.rolloutThreadId;
      revalidatedRolloutLineageIds = replayedCursorState.rolloutLineageIds;
      revalidatedPrefixState = replayedHistory;
    }
  } catch (error) {
    fs.closeSync(descriptor);
    if (error?.code === DEADLINE_ERROR_CODE) {
      return deadlineFailure(filePath, deadlineAt, previous?.offset || 0);
    }
    return failure(filePath, "unreadable", [
      diagnostic("anchor-read-error", { path: filePath, message: error.message }),
    ]);
  }

  const records = [];
  const diagnostics = [];
  const retainRecords = options.retainRecords !== false;
  const onRecord = typeof options.onRecord === "function" ? options.onRecord : null;
  const onObservedRecord =
    typeof options.onObservedRecord === "function" ? options.onObservedRecord : null;
  let parseErrorCount = 0;
  let lineNumber = revalidatedPrefixState?.lineNumber ?? 0;
  let position = previous?.offset || 0;
  let pending = revalidatedPrefixState
    ? Buffer.from(revalidatedPrefixState.pending)
    : Buffer.alloc(0);
  let pendingStart = revalidatedPrefixState?.pendingStart ?? position;
  let previousTimestamp = revalidatedPrefixState?.lastTimestamp ?? null;
  let firstRecordSeen = revalidatedPrefixState?.firstRecordSeen ?? false;
  let firstRecordAnchorEndOffset =
    revalidatedPrefixState?.firstRecordAnchorEndOffset ?? null;
  let firstRecordAnchorSha256 =
    revalidatedPrefixState?.firstRecordAnchorSha256 ?? null;
  let rolloutThreadId =
    revalidatedRolloutThreadId || expectedRolloutThreadId || null;
  let rolloutLineageIds = revalidatedRolloutLineageIds.length > 0
    ? [...revalidatedRolloutLineageIds]
    : rolloutThreadId
      ? [rolloutThreadId]
      : [];
  let forkHistoryScope = revalidatedForkHistoryScope;
  const observedThreadIds = new Set();
  const decoder = new TextDecoder("utf-8", { fatal: true });

  const callRecordHandler = (handler, item) => {
    try {
      if (handler) handler(item);
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

  const observeRecord = (item) => callRecordHandler(onObservedRecord, item);
  const emitRecord = (item) => {
    const handlerFailure = callRecordHandler(onRecord, item);
    if (handlerFailure) return handlerFailure;
    if (retainRecords) records.push(item);
    return null;
  };

  const parseLine = (input, byteOffset) => {
    lineNumber += 1;
    const isFirstPhysicalRecord = !firstRecordSeen;
    firstRecordSeen = true;
    if (isFirstPhysicalRecord) {
      firstRecordAnchorEndOffset = byteOffset + input.length + 1;
      firstRecordAnchorSha256 = createHash("sha256")
        .update(input)
        .update("\n")
        .digest("hex");
    }
    let bytes = input;
    if (bytes.length > 0 && bytes.at(-1) === 13) {
      bytes = bytes.subarray(0, bytes.length - 1);
      diagnostics.push(diagnostic("crlf", { path: filePath, line: lineNumber, byteOffset }));
    }
    if (bytes.length === 0) {
      if (isFirstPhysicalRecord) {
        return failure(filePath, "rollout-owner-missing", [
          ...diagnostics,
          diagnostic("schema-drift", {
            path: filePath,
            line: lineNumber,
            byteOffset,
            envelopeType: null,
            payloadType: null,
            reason: "rollout-thread-id-missing",
          }),
        ], { records, parseErrorCount });
      }
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
    if (isFirstPhysicalRecord && bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      bytes = bytes.subarray(3);
      diagnostics.push(diagnostic("utf8-bom", { path: filePath, line: lineNumber, byteOffset }));
    }
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
      const observerFailure = observeRecord(item);
      const handlerFailure = observerFailure || emitRecord(item);
      diagnostics.push(diagnostic("malformed-json", item));
      if (isFirstPhysicalRecord) {
        return failure(filePath, "rollout-owner-missing", [
          ...diagnostics,
          diagnostic("schema-drift", {
            path: filePath,
            line: lineNumber,
            byteOffset,
            envelopeType: null,
            payloadType: null,
            reason: "rollout-thread-id-missing",
          }),
        ], { records, parseErrorCount });
      }
      return handlerFailure;
    }
    if (isFirstPhysicalRecord && value?.type !== "session_meta") {
      return failure(filePath, "rollout-owner-missing", [
        ...diagnostics,
        diagnostic("schema-drift", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          envelopeType: typeof value?.type === "string" ? value.type : null,
          payloadType: typeof value?.payload?.type === "string" ? value.payload.type : null,
          reason: "rollout-thread-id-missing",
        }),
      ], { records, parseErrorCount });
    }
    const ownerLineage = advanceRolloutOwnerLineage(value, {
      rolloutThreadId,
      lineageIds: rolloutLineageIds,
      observedThreadIds,
    });
    if (ownerLineage.status === "invalid" || ownerLineage.status === "mismatch") {
      const invalid = ownerLineage.status === "invalid";
      return failure(filePath, invalid ? "rollout-owner-invalid" : "rollout-owner-mismatch", [
        ...diagnostics,
        diagnostic("schema-drift", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          envelopeType: "session_meta",
          payloadType: null,
          reason: invalid ? "rollout-thread-id-invalid" : "rollout-thread-id-mismatch",
        }),
      ], { records, parseErrorCount });
    }
    if (ownerLineage.status === "accepted") {
      rolloutThreadId = ownerLineage.rolloutThreadId;
      rolloutLineageIds = ownerLineage.lineageIds;
    }
    const recordOwner = recordThreadIdentity(value);
    const historyScope = advanceRolloutHistoryScope(value, forkHistoryScope, {
      isFirstRecord: isFirstPhysicalRecord,
    });
    if (historyScope.status === "missing" || historyScope.status === "invalid") {
      const missing = historyScope.status === "missing";
      return failure(
        filePath,
        missing ? "rollout-history-boundary-missing" : "rollout-history-boundary-invalid",
        [
          ...diagnostics,
          diagnostic("schema-drift", {
            path: filePath,
            line: lineNumber,
            byteOffset,
            envelopeType: typeof value?.type === "string" ? value.type : null,
            payloadType: typeof value?.payload?.type === "string" ? value.payload.type : null,
            reason: historyScope.reason,
          }),
        ],
        { records, parseErrorCount },
      );
    }
    forkHistoryScope = historyScope.state;
    if (historyScope.status === "skip") return null;
    if (recordOwner.status === "invalid" || recordOwner.status === "conflict") {
      const ownerReason =
        recordOwner.status === "invalid"
          ? "rollout-thread-id-invalid"
          : "rollout-thread-id-mismatch";
      return failure(
        filePath,
        recordOwner.status === "invalid" ? "rollout-owner-invalid" : "rollout-owner-mismatch",
        [
          ...diagnostics,
          diagnostic("schema-drift", {
            path: filePath,
            line: lineNumber,
            byteOffset,
            envelopeType: typeof value?.type === "string" ? value.type : null,
            payloadType: typeof value?.payload?.type === "string" ? value.payload.type : null,
            reason: ownerReason,
          }),
        ],
        { records, parseErrorCount },
      );
    }
    if (recordOwner.status === "valid") {
      observedThreadIds.add(recordOwner.threadId);
      if (
        rolloutThreadId &&
        rolloutThreadId.toLowerCase() !== recordOwner.threadId
      ) {
        return failure(filePath, "rollout-owner-mismatch", [
          ...diagnostics,
          diagnostic("schema-drift", {
            path: filePath,
            line: lineNumber,
            byteOffset,
            envelopeType: typeof value?.type === "string" ? value.type : null,
            payloadType: typeof value?.payload?.type === "string" ? value.payload.type : null,
            reason: "rollout-thread-id-mismatch",
          }),
        ], { records, parseErrorCount });
      }
    }
    const normalized = normalizeRolloutRecord(value, {
      line: lineNumber,
      byteOffset,
      rolloutThreadId,
    });
    // Activity and other integrity projections need the complete parsed stream, including
    // unknown schema pairs that are deliberately excluded from correlation retention.
    const observerFailure = observeRecord(normalized);
    if (observerFailure) return observerFailure;
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
          itemType: normalized.itemType ?? null,
        }),
      );
    } else if (normalized.unknownItemClass !== null && normalized.unknownItemClass !== undefined) {
      // Inert-but-logged (owner ruling B-1): recorded so an unrecognised class is visible and
      // datable, but deliberately NOT a 'schema-drift' code, because it must not poison its turn.
      diagnostics.push(
        diagnostic("unknown-item-class", {
          path: filePath,
          line: lineNumber,
          byteOffset,
          envelopeType: normalized.envelopeType,
          payloadType: normalized.payloadType,
          itemType: normalized.unknownItemClass,
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
  let finalFirstRecordAnchor = null;
  let finalConsumedPrefixAnchor = null;
  let observedPrefixSha256 = null;
  let cursorAnchor = null;
  let finalDeadlineExceeded = false;
  try {
    while (fatalResult === null) {
      if (deadlineReached?.()) {
        fatalResult = deadlineFailure(filePath, deadlineAt, position, {
          records,
          diagnostics,
          parseErrorCount,
        });
        break;
      }
      const bytesRead = fs.readSync(descriptor, chunk, 0, chunk.length, position);
      if (bytesRead === 0) break;
      const current = chunk.subarray(0, bytesRead);
      observedPrefixHash.update(current);
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
      observedPrefixSha256 = observedPrefixHash.digest("hex");
      finalDescriptorStat = fs.fstatSync(descriptor);
      if (finalDescriptorStat.size >= initialStat.size && finalDescriptorStat.size >= position) {
        finalInitialAnchor = readContentAnchor(
          descriptor,
          initialStat.size,
          deadlineReached,
        );
        cursorAnchor = readContentAnchor(descriptor, position, deadlineReached);
        if (position > 0) {
          finalConsumedPrefixAnchor = readPrefixAnchor(
            descriptor,
            position,
            deadlineReached,
          );
        }
        if (
          Number.isSafeInteger(firstRecordAnchorEndOffset) &&
          firstRecordAnchorEndOffset > 0
        ) {
          finalFirstRecordAnchor = readPrefixAnchor(
            descriptor,
            firstRecordAnchorEndOffset,
            deadlineReached,
          );
        }
      }
    } catch (error) {
      if (error?.code === DEADLINE_ERROR_CODE) {
        finalDeadlineExceeded = true;
      } else {
        finalDescriptorStat = null;
      }
    }
    fs.closeSync(descriptor);
  }
  if (fatalResult && fatalResult.reason !== "deadline-exceeded") return fatalResult;
  if (finalDeadlineExceeded) {
    return deadlineFailure(filePath, deadlineAt, position, {
      records,
      diagnostics,
      parseErrorCount,
    });
  }
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
  if (
    firstRecordAnchorEndOffset !== null &&
    (!finalFirstRecordAnchor ||
      finalFirstRecordAnchor.sha256 !== firstRecordAnchorSha256)
  ) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("first-record-changed", {
        path: filePath,
        anchorEndOffset: firstRecordAnchorEndOffset,
      }),
    ], { records, parseErrorCount });
  }
  if (
    position > 0 &&
    (!finalConsumedPrefixAnchor ||
      finalConsumedPrefixAnchor.sha256 !== observedPrefixSha256)
  ) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("consumed-prefix-changed", {
        path: filePath,
        anchorEndOffset: position,
      }),
    ], { records, parseErrorCount });
  }

  if (deadlineReached?.()) {
    return deadlineFailure(filePath, deadlineAt, position, {
      records,
      diagnostics,
      parseErrorCount,
    });
  }

  let pathIdentity;
  let pathObservedSize;
  let pathMinimumSize;
  try {
    const pathStat = fs.statSync(filePath);
    const exactPathStat = fs.statSync(filePath, { bigint: true });
    pathIdentity = fileIdentity(filePath, pathStat, exactPathStat);
    const exactPathSize = Number(exactPathStat.size);
    pathObservedSize = Math.max(pathStat.size, exactPathSize);
    pathMinimumSize = Math.min(pathStat.size, exactPathSize);
  } catch (error) {
    return failure(filePath, "file-replaced", [
      ...diagnostics,
      diagnostic("path-revalidation-failed", { path: filePath, message: error.message }),
    ], { records, parseErrorCount });
  }
  if (deadlineReached?.()) {
    return deadlineFailure(filePath, deadlineAt, position, {
      records,
      diagnostics,
      parseErrorCount,
    });
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
  if (pathMinimumSize < finalDescriptorStat.size || pathMinimumSize < position) {
    return failure(filePath, "file-truncated", [
      ...diagnostics,
      diagnostic("file-truncated", {
        path: filePath,
        descriptorSize: finalDescriptorStat.size,
        pathSize: pathMinimumSize,
        byteOffset: position,
      }),
    ], { records, parseErrorCount });
  }
  if (pathObservedSize > finalDescriptorStat.size) {
    diagnostics.push(diagnostic("file-grew-after-read", {
      path: filePath,
      descriptorSize: finalDescriptorStat.size,
      pathSize: pathObservedSize,
      byteOffset: position,
    }));
  }
  if (deadlineReached?.()) {
    return deadlineFailure(filePath, deadlineAt, position, {
      records,
      diagnostics,
      parseErrorCount,
    });
  }
  if (fatalResult) {
    return { ...fatalResult, integrityValidated: true };
  }
  if (
    position > 0 &&
    !(firstRecordSeen === false && pending.length > 0 && forkHistoryScope === null) &&
    !forkHistoryStateValid(forkHistoryScope, true)
  ) {
    return failure(filePath, "rollout-history-boundary-invalid", [
      ...diagnostics,
      diagnostic("schema-drift", {
        path: filePath,
        line: lineNumber,
        byteOffset: position,
        envelopeType: "session_meta",
        payloadType: null,
        reason: "fork-history-boundary-unseen",
      }),
    ], { records, parseErrorCount, integrityValidated: true });
  }
  if (
    !rolloutThreadId ||
    position === 0 ||
    !finalConsumedPrefixAnchor ||
    !cursorAnchor
  ) {
    return failure(filePath, "rollout-owner-missing", [
      ...diagnostics,
      diagnostic("schema-drift", {
        path: filePath,
        line: null,
        byteOffset: 0,
        envelopeType: "session_meta",
        payloadType: null,
        reason: "rollout-thread-id-missing",
      }),
    ], { records, parseErrorCount, integrityValidated: true });
  }
  const cursor = {
    identityKey: identity.key,
    canonicalPath: identity.canonicalPath,
    offset: position,
    size: pathObservedSize,
    lineNumber,
    partialBase64: pending.length > 0 ? pending.toString("base64") : "",
    partialStart: pendingStart,
    lastTimestamp: previousTimestamp,
    firstRecordSeen,
    firstRecordAnchorEndOffset,
    firstRecordAnchorSha256,
    rolloutThreadId,
    rolloutLineageIds,
    forkHistoryScope,
    prefixEndOffset: finalConsumedPrefixAnchor.endOffset,
    prefixSha256: finalConsumedPrefixAnchor.sha256,
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
// binding, terminal binding, and supersession, and it carries the primary
// parser/schema-gap attribution (push-time for full-stream consumers,
// finish()-time windows for retained-only consumers); the dispatch lifecycle
// adapter additionally enforces the same in-window schema-gap rule over the
// same parser diagnostics in its own projection (see the finish() comment) --
// one rule, one signal, so the two attributions cannot disagree.
// Both consumers are thin projections over its snapshots: createDispatchCorrelator
// (A1 dispatch correlation) and summarizeThreadActivity (A4 thread activity).
// ---------------------------------------------------------------------------

const BOUNDARY_ERROR_CODES = new Set([
  "orphan-user-message",
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

  const startUnboundTurn = (record, kind) => {
    const turn = {
      sequence: sequence++,
      turnId: null,
      boundaryMode: "unbound",
      startLine: record.line,
      terminalType: null,
      terminalLine: null,
      superseded: false,
      boundaryErrors: [],
      parseErrorLines: [],
      schemaGap: false,
      emitted: false,
    };
    if (kind === "parse-error") turn.parseErrorLines.push(record.line);
    if (kind === "schema-gap") turn.schemaGap = true;
    if (kind === "orphan-user-message") {
      turn.boundaryErrors.push(
        diagnostic("orphan-user-message", { line: record.line }),
      );
    }
    openTurns.push(turn);
    current = turn;
    return turn;
  };

  return {
    push(record) {
      if (record.parseError) {
        if (current && !current.terminalType) {
          current.parseErrorLines.push(record.line);
          return { sequence: current.sequence, snapshots: [] };
        }
        const turn = startUnboundTurn(record, "parse-error");
        return { sequence: turn.sequence, snapshots: [] };
      }
      // Schema-drift attribution at push time (A1/F1): an unknown envelope/payload pair arriving
      // while a turn is open poisons THAT turn before it can finalize, so a later terminal still
      // yields a fail-closed 'ambiguous' snapshot instead of 'closed'. This is the same drift
      // signal (knownPair === false) from which the parser emits its 'schema-drift' diagnostics,
      // and the arrival-while-open condition is exactly the lifecycle adapter's in-window rule
      // (startLine < line < terminalLine) applied in stream order — the two cannot disagree.
      // Consumers that push only retained records never hit this branch; their still-open turns
      // keep the finish()-time window attribution below.
      if (record.knownPair === false) {
        if (current && !current.terminalType) {
          current.schemaGap = true;
          return { sequence: current.sequence, snapshots: [] };
        }
        const turn = startUnboundTurn(record, "schema-gap");
        return { sequence: turn.sequence, snapshots: [] };
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
        const turn = startUnboundTurn(record, "orphan-user-message");
        return { sequence: turn.sequence, snapshots: [] };
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
      // Attribute schema gaps to every still-open turn's window before finalizing it. This covers
      // consumers that feed only RETAINED records plus parser diagnostics (drift records never
      // reach push there). Consumers that feed the FULL observation stream (the activity helper)
      // get push-time attribution above, which also covers turns finalized during push; the
      // dispatch adapter additionally enforces schema-gap integrity over the same parser
      // diagnostics in its lifecycle projection. All three apply the same in-window rule to the
      // same signal.
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

function completionBodyDecision(agentMessages, lastAgentMessage, options = {}) {
  const explicitFinals = agentMessages.filter(
    (item) => item.phase === "final_answer" && item.text.length > 0,
  );
  const legacyFinals =
    options.allowLegacyPhaseLess !== false &&
    explicitFinals.length === 0 &&
    typeof lastAgentMessage === "string" &&
    lastAgentMessage.length > 0
      ? agentMessages.filter(
          (item) =>
            item.itemType === null &&
            item.phase === null &&
            item.text.length > 0 &&
            item.text === lastAgentMessage,
        )
      : [];
  const logicalFinals = [];
  const seenBodies = new Set();
  for (const item of explicitFinals.length > 0 ? explicitFinals : legacyFinals) {
    if (seenBodies.has(item.text)) continue;
    seenBodies.add(item.text);
    logicalFinals.push(item);
  }
  let selected = logicalFinals[0] || null;
  if (!selected) return { status: "missing", selected: null, count: 0 };
  const hasTerminalCopy =
    typeof lastAgentMessage === "string" && lastAgentMessage.length > 0;
  if (logicalFinals.length > 1) {
    if (!hasTerminalCopy) {
      return {
        status: options.requireTerminalCopy === true ? "terminal-missing" : "conflict",
        selected: null,
        count: logicalFinals.length,
      };
    }
    const terminalMatches = logicalFinals.filter(
      (item) => item.text === lastAgentMessage,
    );
    if (terminalMatches.length !== 1) {
      return {
        status: "mismatch",
        selected: null,
        count: logicalFinals.length,
      };
    }
    [selected] = terminalMatches;
  }
  if (
    options.requireTerminalCopy === true &&
    !hasTerminalCopy
  ) {
    return { status: "terminal-missing", selected: null, count: 1 };
  }
  if (typeof lastAgentMessage === "string" && lastAgentMessage !== selected.text) {
    return { status: "mismatch", selected: null, count: 1 };
  }
  return { status: "ok", selected, count: 1 };
}

function sameLogicalUserDelivery(left, right) {
  if (!left || !right || left.text !== right.text) return false;
  const sharedItemId =
    typeof left.itemId === "string" &&
    left.itemId.length > 0 &&
    left.itemId === right.itemId;
  return sharedItemId;
}

function computeOccurrence(snapshot, bucket, marker) {
  const laterUsers = bucket.userMessages.filter((u) => u.line > marker.line);
  const disqualifying = laterUsers.find((item) => !sameLogicalUserDelivery(marker, item));
  const integrityWindowStart = bucket.startLine === null ? marker.line : bucket.startLine;
  const inWindowErrors = bucket.parseErrors.filter(
    (item) =>
      item.line > integrityWindowStart &&
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

  // task_complete: presentation and certification share one exact logical body decision.
  const lam = bucket.terminal ? bucket.terminal.lastAgentMessage : undefined;
  const agentMessages = bucket.agentMessages.filter(
    (item) =>
      item.line > marker.line &&
      (snapshot.terminalLine === null || item.line < snapshot.terminalLine),
  );
  const bodyDecision = completionBodyDecision(agentMessages, lam, {
    requireTerminalCopy: true,
  });
  if (bodyDecision.status === "conflict") {
    return {
      ...base,
      waitStatus: "unavailable",
      harvestStatus: "none",
      harvestReason: "unavailable",
      diagnostics: [
        diagnostic("multiple-final-message-bodies", {
          line: snapshot.terminalLine,
          turnId: snapshot.turnId,
          count: bodyDecision.count,
        }),
      ],
    };
  }
  if (bodyDecision.status === "mismatch" || bodyDecision.status === "terminal-missing") {
    return {
      ...base,
      waitStatus: "unavailable",
      harvestStatus: "none",
      harvestReason: "unavailable",
      diagnostics: [
        diagnostic("completion-message-mismatch", {
          line: snapshot.terminalLine,
          turnId: snapshot.turnId,
        }),
      ],
    };
  }
  const selected = bodyDecision.status === "ok" ? bodyDecision.selected : null;
  return {
    ...base,
    waitStatus: "complete",
    harvestStatus: selected ? "complete" : "none",
    harvestReason: selected ? null : "unavailable",
    certifiable: Boolean(selected),
    text: selected ? selected.text : null,
    finalMessageCount: bodyDecision.count,
    diagnostics: [],
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
  const schemaFailure = (parsed.diagnostics || []).some(
    (item) => item.code === "schema-drift" || item.code === "malformed-json",
  );
  return {
    status: "none",
    reason: reason || (parsed.ok && !schemaFailure ? "pending" : "unparseable"),
    text: null,
    finalMessageCount: 0,
    duplicateCount,
    turnId: matching?.turnId || null,
    boundaryMode: matching?.boundaryMode || null,
    diagnostics: matching?.diagnostics || parsed.diagnostics || [],
  };
}

function applySchemaIntegrity(occurrences, parserDiagnostics) {
  const ownerIntegrity = (parserDiagnostics || []).filter(
    (item) =>
      item.code === "schema-drift" &&
      (item.reason === "rollout-thread-id-invalid" ||
        item.reason === "rollout-thread-id-mismatch" ||
        item.reason === "rollout-thread-id-missing"),
  );
  if (ownerIntegrity.length > 0) {
    return occurrences.map((occ) => ({
      ...occ,
      waitStatus: "unavailable",
      harvestStatus: "none",
      harvestReason: "unparseable",
      certifiable: false,
      text: null,
      finalMessageCount: 0,
      diagnostics: ownerIntegrity,
      waitDiagnostics: ownerIntegrity,
    }));
  }
  return occurrences.map((occ) => {
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
        return {
          ...occ,
          waitStatus: "unavailable",
          harvestStatus: "none",
          harvestReason: "unparseable",
          certifiable: false,
          text: null,
          finalMessageCount: 0,
          diagnostics: drift,
          waitDiagnostics: drift,
        };
      }
    }
    return occ;
  });
}

function projectLifecycle(occurrences, parserDiagnostics, sawParseError, parsed) {
  const completed = occurrences
    .filter((o) => o.waitStatus === "complete")
    .sort((left, right) => (left.terminalLine || 0) - (right.terminalLine || 0));
  if (completed.length > 0) {
    const win = completed.at(-1);
    return { status: "complete", diagnostics: win.diagnostics, certifiable: win.certifiable };
  }
  const unavailable = occurrences.find((o) => o.waitStatus === "unavailable");
  if (unavailable) {
    return { status: "unavailable", diagnostics: unavailable.waitDiagnostics || unavailable.diagnostics, certifiable: false };
  }
  const pending = occurrences.find((o) => o.waitStatus === "pending");
  if (pending) {
    return { status: "pending", diagnostics: pending.diagnostics, certifiable: false };
  }
  if (occurrences.length > 0) {
    const last = [...occurrences].sort((left, right) => left.markerLine - right.markerLine).at(-1);
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

function projectLatestOccurrence(occurrences) {
  if (occurrences.length === 0) return null;
  const latest = [...occurrences]
    .sort((left, right) => left.markerLine - right.markerLine)
    .at(-1);
  return {
    status: latest.waitStatus,
    harvestStatus: latest.harvestStatus,
    reason: latest.harvestReason,
    certifiable: latest.certifiable === true,
    settled: latest.waitStatus === "complete" && latest.certifiable === true,
    markerLine: latest.markerLine,
    terminalLine: latest.terminalLine,
    turnId: latest.turnId,
  };
}

function projectDispatchFreshness(occurrences, parserDiagnostics) {
  if (occurrences.length === 0) {
    return {
      status: "not-seen",
      settled: false,
      reason: "not-seen",
      boundaryLine: null,
      diagnostics: [],
    };
  }
  const latest = [...occurrences]
    .sort((left, right) => left.markerLine - right.markerLine)
    .at(-1);
  const boundaryLine = Number.isSafeInteger(latest.terminalLine)
    ? latest.terminalLine
    : latest.markerLine;
  if (latest.waitStatus !== "complete" || latest.certifiable !== true) {
    return {
      status: latest.waitStatus === "pending" ? "pending" : "unavailable",
      settled: false,
      reason: latest.harvestReason || latest.waitStatus || "unavailable",
      boundaryLine,
      diagnostics: latest.waitDiagnostics || latest.diagnostics || [],
    };
  }
  const opaqueSuffix = (parserDiagnostics || []).filter(
    (item) =>
      (item.code === "schema-drift" || item.code === "malformed-json") &&
      Number.isSafeInteger(item.line) &&
      item.line > boundaryLine,
  );
  if (opaqueSuffix.length > 0) {
    return {
      status: "unavailable",
      settled: false,
      reason: "post-occurrence-schema-unknown",
      boundaryLine,
      diagnostics: opaqueSuffix,
    };
  }
  return {
    status: "complete",
    settled: true,
    reason: null,
    boundaryLine,
    diagnostics: [],
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
      bucket = {
        startLine: null,
        userMessages: [],
        agentMessages: [],
        parseErrors: [],
        terminal: null,
        agentKeys: new Set(),
      };
      buckets.set(seq, bucket);
    }
    return bucket;
  };

  const appendSemanticOnce = (items, keys, record) => {
    const key = JSON.stringify([
      record.payloadType,
      record.itemType,
      record.role,
      record.phase,
      record.text,
    ]);
    if (keys.has(key)) return;
    keys.add(key);
    items.push(record);
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
      // Every user event remains observable: equal text can be a real later input.
      bucket.userMessages.push(record);
    } else if (record.payloadType === "agent_message") {
      appendSemanticOnce(bucket.agentMessages, bucket.agentKeys, record);
    } else if (record.payloadType === "task_complete" || record.payloadType === "turn_aborted") {
      bucket.terminal = record;
    }
  };

  const processSnapshot = (snapshot) => {
    const bucket = buckets.get(snapshot.sequence);
    buckets.delete(snapshot.sequence);
    if (!bucket) return;
    // One turn can certify at most its earliest dispatch occurrence. Later matching
    // user events remain in the bucket so they can invalidate that occurrence.
    const marker = bucket.userMessages.find((item) => exactTaskBasename(item.text, basename));
    if (marker) occurrences.push(computeOccurrence(snapshot, bucket, marker));
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
      if (parsed?.ok !== true) {
        const readerDiagnostics = parserDiagnostics.length > 0
          ? parserDiagnostics
          : [diagnostic(parsed?.reason || "rollout-read-failed", { path: parsed?.path || null })];
        return {
          status: "none",
          reason: "unparseable",
          text: null,
          finalMessageCount: 0,
          duplicateCount: occurrences.length,
          turnId: null,
          boundaryMode: null,
          diagnostics: readerDiagnostics,
          lifecycle: {
            status: "unavailable",
            diagnostics: readerDiagnostics,
            certifiable: false,
          },
        };
      }
      if (parsed.cursor && !isCompleteReaderCursor(parsed.cursor)) {
        const readerDiagnostics = [
          ...parserDiagnostics,
          ...(parserDiagnostics.some((item) => item.code === "rollout-read-not-at-eof")
            ? []
            : [diagnostic("rollout-read-not-at-eof", { path: parsed?.path || null })]),
        ];
        return {
          status: "none",
          reason: "pending",
          text: null,
          finalMessageCount: 0,
          duplicateCount: occurrences.length,
          turnId: null,
          boundaryMode: null,
          diagnostics: readerDiagnostics,
          lifecycle: {
            status: "pending",
            diagnostics: readerDiagnostics,
            certifiable: false,
          },
        };
      }
      const integrityChecked = applySchemaIntegrity(occurrences, parserDiagnostics);
      const harvest = projectHarvest(integrityChecked, parsed);
      const lifecycle = projectLifecycle(
        integrityChecked,
        parserDiagnostics,
        sawParseError,
        parsed,
      );
      const latestOccurrence = projectLatestOccurrence(integrityChecked);
      const freshness = projectDispatchFreshness(integrityChecked, parserDiagnostics);
      return { ...harvest, lifecycle, latestOccurrence, freshness };
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

export function readRolloutActivity(filePath, options = {}) {
  const accumulator = createTurnBoundaryAccumulator();
  let boundarySnapshot = null;
  const retainLatest = (snapshots) => {
    for (const snapshot of snapshots || []) {
      if (boundarySnapshot === null || snapshot.sequence > boundarySnapshot.sequence) {
        boundarySnapshot = snapshot;
      }
    }
  };
  const parsed = readRolloutFile(filePath, {
    ...options,
    retainRecords: false,
    onObservedRecord: (item) => retainLatest(accumulator.push(item).snapshots),
  });
  retainLatest(accumulator.finish(parsed.diagnostics || []));
  const certified =
    parsed.ok &&
    parsed.integrityValidated &&
    !parsed.partialTail &&
    isCompleteReaderCursor(parsed.cursor);
  return {
    parsed,
    boundarySnapshot: certified ? boundarySnapshot : null,
    turnActivity: summarizeThreadActivity(
      certified ? boundarySnapshot : null,
      certified ? "found" : "unavailable",
    ).turnActivity,
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

export function parseRolloutBasename(filePath) {
  const match = path.basename(filePath).match(ROLLOUT_BASENAME_RE);
  if (!match) return null;
  const rootThreadId = match[1].toLowerCase();
  const pageId = match[2]?.toLowerCase() || null;
  return {
    rootThreadId,
    pageId,
    paginated: pageId !== null,
  };
}

function validateCandidate(filePath, threadId) {
  try {
    const stat = fs.statSync(filePath);
    const exactStat = fs.statSync(filePath, { bigint: true });
    if (!stat.isFile()) {
      return { ok: false, reason: "unreadable", path: filePath };
    }
    const filename = parseRolloutBasename(filePath);
    const first = readFirstRecord(filePath);
    const payload =
      first.ok &&
      first.value?.type === "session_meta" &&
      first.value.payload &&
      typeof first.value.payload === "object" &&
      !Array.isArray(first.value.payload)
        ? first.value.payload
        : null;
    const ownerId =
      typeof payload?.id === "string" ? normalizedUuid(payload.id) : null;
    const sessionId =
      typeof payload?.session_id === "string" ? normalizedUuid(payload.session_id) : null;
    const historyBaseThreadId = normalizedUuid(payload?.history_base?.thread_id);
    const paginationValid =
      filename?.paginated !== true ||
      (sessionId === threadId &&
        payload?.history_mode === "paginated" &&
        historyBaseThreadId !== null);
    if (
      !first.ok ||
      filename?.rootThreadId !== threadId ||
      ownerId !== threadId ||
      !paginationValid
    ) {
      return {
        ok: false,
        reason: "identity-mismatch",
        path: filePath,
        filenameId: filename?.rootThreadId || null,
        pageId: filename?.pageId || null,
        ownerId,
        sessionId,
        historyMode: payload?.history_mode || null,
        historyBaseThreadId,
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
      pageId: filename.pageId,
      paginated: filename.paginated,
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
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        const filename = parseRolloutBasename(entry.name);
        if (filename?.rootThreadId === threadId) {
          matches.push(candidate);
        } else if (
          entry.name.toLowerCase().startsWith("rollout-") &&
          entry.name.toLowerCase().includes(threadId) &&
          !(filename?.paginated && filename.pageId === threadId)
        ) {
          diagnostics.push(diagnostic("rollout-name-unrecognized", { path: candidate }));
        }
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
  if (invalid.length > 0 || discovered.diagnostics.length > 0) {
    return {
      status: "ambiguous",
      reason: "candidate-set-unresolved",
      authority: "sessions-root",
      candidates,
      aliasCount: valid.length,
      diagnostics: [
        ...diagnostics,
        diagnostic("candidate-set-unresolved", {
          validPaths: candidates.map((item) => item.path),
          rejectedPaths: invalid.map((item) => item.path),
        }),
      ],
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
function createMarkerProofConsumer(marker, options = {}) {
  const accumulator = createTurnBoundaryAccumulator();
  const strict = typeof options.expectedTurnId === "string";
  const expectedTurnId = strict ? normalizedTurnId(options.expectedTurnId) : null;
  const buckets = new Map();
  let looseAgentMessages = [];
  let candidate = null;
  const integrityDiagnostics = [];
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

  const bucketFor = (sequence) => {
    let bucket = buckets.get(sequence);
    if (!bucket) {
      bucket = { startLine: null, userMessages: [], agentMessages: [], terminal: null };
      buckets.set(sequence, bucket);
    }
    return bucket;
  };

  const appendAgentOnce = (items, item) => {
    if (items.some((current) => current.phase === item.phase && current.text === item.text)) return;
    items.push(item);
  };

  const ingest = (item, sequence) => {
    if (sequence === null || sequence === undefined || item.parseError) return;
    if (item.envelopeType !== "event_msg") return;
    const bucket = bucketFor(sequence);
    if (item.payloadType === "task_started") {
      bucket.startLine = item.line;
    } else if (item.payloadType === "user_message") {
      bucket.userMessages.push(item);
    } else if (item.payloadType === "agent_message") {
      appendAgentOnce(bucket.agentMessages, item);
    } else if (item.payloadType === "task_complete" || item.payloadType === "turn_aborted") {
      bucket.terminal = item;
    }
  };

  const processSnapshot = (snapshot) => {
    const bucket = buckets.get(snapshot.sequence);
    buckets.delete(snapshot.sequence);
    if (!bucket || snapshot.activity !== "closed" || snapshot.terminalType !== "task_complete") {
      return;
    }
    if (strict && (snapshot.boundaryMode !== "turn-id" || snapshot.turnId !== expectedTurnId)) {
      return;
    }
    const body = completionBodyDecision(
      bucket.agentMessages,
      bucket.terminal?.lastAgentMessage,
      { allowLegacyPhaseLess: false, requireTerminalCopy: true },
    );
    if (body.status !== "ok" || !body.selected.text.includes(marker)) return;
    const userMarker = bucket.userMessages.find(
      (item) => item.text.includes(marker) && item.line < body.selected.line,
    );
    const interveningUser = userMarker
      ? bucket.userMessages.find(
          (item) =>
            item.line > userMarker.line &&
            item.line < snapshot.terminalLine &&
            !sameLogicalUserDelivery(userMarker, item),
        )
      : null;
    if (strict && (!userMarker || interveningUser)) return;
    if (body.selected.line >= snapshot.terminalLine) return;
    candidate = {
      startLine: bucket.startLine,
      agentLine: body.selected.line,
      terminalLine: snapshot.terminalLine,
      turnId: snapshot.turnId,
    };
  };

  return {
    push(item) {
      if (item.parseError) {
        const { snapshots } = accumulator.push(item);
        for (const snapshot of snapshots) processSnapshot(snapshot);
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
        item.payloadType === "agent_message" &&
        item.phase === "final_answer";
      const isTaskComplete =
        item.envelopeType === "event_msg" && item.payloadType === "task_complete";
      if (item.envelopeType === "event_msg" && item.payloadType === "task_started") {
        looseAgentMessages = [];
      }
      const { sequence, snapshots } = accumulator.push(item);
      ingest(item, sequence);
      if (isAgentMarker) {
        state.lastAgentMarkerLine = item.line;
      }
      if (!strict && sequence === null && item.envelopeType === "event_msg" && item.payloadType === "agent_message") {
        appendAgentOnce(looseAgentMessages, item);
      }
      if (isTaskComplete) {
        state.lastTaskCompleteLine = item.line;
        if (!strict && (sequence === null || sequence === undefined)) {
          const body = completionBodyDecision(looseAgentMessages, item.lastAgentMessage, {
            allowLegacyPhaseLess: false,
            requireTerminalCopy: true,
          });
          if (body.status === "ok" && body.selected.text.includes(marker)) {
            candidate = {
              startLine: null,
              agentLine: body.selected.line,
              terminalLine: item.line,
              turnId: null,
            };
          }
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
        for (const item of parsed.diagnostics || []) {
          if (
            (item.code === "schema-drift" || item.code === "malformed-json") &&
            typeof item.line === "number"
          ) {
            integrityDiagnostics.push(item);
          }
        }
      }
      const integrityViolation = Boolean(
        candidate &&
          integrityDiagnostics.some(
            (item) =>
              (candidate.startLine === null || item.line > candidate.startLine) &&
              item.line < candidate.terminalLine,
          ),
      );
      return {
        ...state,
        agentMarkerSeen: state.lastAgentMarkerLine !== null,
        taskCompleteAfterAgentMarker: Boolean(
          candidate && !integrityViolation && state.error === null,
        ),
        expectedTurnId,
        proofTurnId: candidate?.turnId || null,
      };
    },
  };
}

export function inspectRolloutMarker(rolloutPath, marker) {
  const consumer = createMarkerProofConsumer(marker);
  const parsed = readRolloutFile(rolloutPath);
  for (const item of parsed.records || []) consumer.push(item);
  consumer.finish(parsed);
  const observed = consumer.observe(parsed);
  if (parsed.ok && !isCompleteReaderCursor(parsed.cursor)) {
    return {
      ...observed,
      error: "rollout-read-not-at-eof",
      taskCompleteAfterAgentMarker: false,
    };
  }
  return observed;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function isCompleteReaderCursor(cursor) {
  return Boolean(
    cursor &&
      typeof cursor.identityKey === "string" &&
      cursor.identityKey.length > 0 &&
      typeof cursor.canonicalPath === "string" &&
      cursor.canonicalPath.length > 0 &&
      Number.isSafeInteger(cursor.offset) &&
      cursor.offset > 0 &&
      Number.isSafeInteger(cursor.size) &&
      cursor.size === cursor.offset &&
      Number.isSafeInteger(cursor.lineNumber) &&
      cursor.lineNumber > 0 &&
      cursor.partialBase64 === "" &&
      Number.isSafeInteger(cursor.partialStart) &&
      cursor.partialStart === cursor.offset &&
      cursor.firstRecordSeen === true &&
      Number.isSafeInteger(cursor.firstRecordAnchorEndOffset) &&
      cursor.firstRecordAnchorEndOffset > 0 &&
      cursor.firstRecordAnchorEndOffset <= cursor.offset &&
      typeof cursor.firstRecordAnchorSha256 === "string" &&
      /^[0-9a-f]{64}$/i.test(cursor.firstRecordAnchorSha256) &&
      UUID_RE.test(cursor.rolloutThreadId || "") &&
      Number.isSafeInteger(cursor.prefixEndOffset) &&
      cursor.prefixEndOffset === cursor.offset &&
      typeof cursor.prefixSha256 === "string" &&
      /^[0-9a-f]{64}$/i.test(cursor.prefixSha256) &&
      forkHistoryStateValid(cursor.forkHistoryScope, true) &&
      Number.isSafeInteger(cursor.anchorEndOffset) &&
      cursor.anchorEndOffset === cursor.size &&
      typeof cursor.anchorSha256 === "string" &&
      /^[0-9a-f]{64}$/i.test(cursor.anchorSha256)
  );
}

// Polling callers may use this metadata-only check to avoid re-hashing an unchanged rollout.
// It never certifies content: any growth, path rebinding, physical replacement, invalid cursor,
// or stat failure requires the caller to run the full reader and accept its fail-closed result.
export function inspectRolloutNoGrowth(filePath, cursor) {
  if (!isCompleteReaderCursor(cursor)) {
    return { unchanged: false, reason: "invalid-cursor" };
  }
  try {
    const stat = fs.statSync(filePath);
    const exactStat = fs.statSync(filePath, { bigint: true });
    if (!stat.isFile()) return { unchanged: false, reason: "not-regular-file" };
    const identity = fileIdentity(filePath, stat, exactStat);
    const unchanged =
      identity.canonicalPath === cursor.canonicalPath &&
      identity.key === cursor.identityKey &&
      identity.size === cursor.size;
    return {
      unchanged,
      reason: unchanged ? "unchanged" : "changed",
      canonicalPath: identity.canonicalPath,
      identityKey: identity.key,
      size: identity.size,
    };
  } catch (error) {
    return {
      unchanged: false,
      reason: error?.code === "ENOENT" ? "missing" : "unreadable",
    };
  }
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
  const readRollout = injected.readRolloutFile || readRolloutFile;
  const inspectNoGrowth = injected.inspectRolloutNoGrowth || inspectRolloutNoGrowth;
  const startedAtMs = now();
  const startedAt = new Date(startedAtMs).toISOString();
  const attempts = Number.isSafeInteger(pollAttempts) && pollAttempts > 0 ? pollAttempts : 1;
  const interval = Number.isFinite(pollMs) && pollMs > 0 ? pollMs : 1;
  const deadlineAt = startedAtMs + interval * attempts;
  const strictRequested =
    Object.hasOwn(injected, "cursor") ||
    Object.hasOwn(injected, "expectedTurnId") ||
    Object.hasOwn(injected, "expectedThreadId");
  const expectedTurnId =
    typeof injected.expectedTurnId === "string"
      ? normalizedTurnId(injected.expectedTurnId)
      : null;
  const expectedThreadId =
    typeof injected.expectedThreadId === "string" ? injected.expectedThreadId : null;
  const initialCursor = injected.cursor || null;
  const strictErrors = [];
  if (strictRequested) {
    if (!UUID_RE.test(expectedTurnId || "")) strictErrors.push("invalid-expected-turn-id");
    if (!isCompleteReaderCursor(initialCursor)) strictErrors.push("invalid-initial-cursor");
    if (!UUID_RE.test(expectedThreadId || "")) {
      strictErrors.push("invalid-expected-thread-id");
    }
    if (
      expectedThreadId &&
      (!UUID_RE.test(initialCursor?.rolloutThreadId || "") ||
        initialCursor.rolloutThreadId.toLowerCase() !== expectedThreadId.toLowerCase())
    ) {
      strictErrors.push("cursor-thread-id-mismatch");
    }
  }
  if (!rolloutPath || !marker || strictErrors.length > 0) {
    return {
      ok: false,
      startedAt,
      finishedAt: new Date(now()).toISOString(),
      attempts: 0,
      rolloutPath,
      markerSha256: sha256(marker || ""),
      lastObservation: null,
      diagnostics: strictErrors,
      warnings: ["Marker proof prerequisites were not satisfied; rollout polling was not attempted."],
    };
  }
  let cursor = strictRequested ? initialCursor : null;
  const consumer = createMarkerProofConsumer(marker, { expectedTurnId });
  let lastObservation = null;
  let lastParsed = null;
  let attemptsMade = 0;
  const pollDiagnostics = [];

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const attemptStartedAt = attempt === 1 ? startedAtMs : now();
    if (attempt > 1 && attemptStartedAt >= deadlineAt) break;
    const forceCertifyingRead =
      attempt === attempts || attemptStartedAt + interval >= deadlineAt;
    if (cursor && !forceCertifyingRead && inspectNoGrowth(rolloutPath, cursor).unchanged) {
      // This is only a pending/wait optimization. It deliberately does not observe records,
      // advance the proof machine, or return success. A final scheduled attempt or a budget-edge
      // attempt that begins before the deadline runs the full reader. If the deadline elapses
      // during sleep, the poll returns unverified rather than performing a post-deadline read.
      attemptsMade = attempt;
      if (attempt < attempts) {
        const remaining = deadlineAt - now();
        if (remaining <= 0) break;
        await sleep(Math.min(interval, remaining));
      }
      continue;
    }
    // Collect this attempt's streamed records, but only feed them into the shared turn-scoped
    // accumulator once the read is trusted, so an integrity-failed read never advances the
    // boundary machine and a re-read from the retained cursor cannot double-push records.
    const attemptRecords = [];
    const parsed = readRollout(rolloutPath, {
      ...(cursor ? { cursor } : {}),
      ...(expectedThreadId ? { rolloutThreadId: expectedThreadId } : {}),
      deadlineAt,
      now,
      retainRecords: false,
      onRecord: (item) => attemptRecords.push(item),
    });
    lastParsed = parsed;
    attemptsMade = attempt;
    const deadlineExpired = parsed.reason === "deadline-exceeded";
    const missingRead = parsed.reason === "missing";
    const parsedThreadId =
      parsed.cursor?.rolloutThreadId ||
      (deadlineExpired || missingRead ? cursor?.rolloutThreadId : null) ||
      null;
    const ownerConflict = (parsed.diagnostics || []).some(
      (item) => item.reason === "rollout-thread-id-mismatch",
    );
    const threadBindingValid =
      !ownerConflict &&
      (!expectedThreadId ||
        (UUID_RE.test(parsedThreadId || "") &&
          parsedThreadId.toLowerCase() === expectedThreadId.toLowerCase()));
    if (deadlineExpired) pollDiagnostics.push("deadline-exceeded");
    if (!threadBindingValid) pollDiagnostics.push("rollout-thread-id-changed");
    const completeRead = parsed.ok && isCompleteReaderCursor(parsed.cursor);
    if (parsed.ok && !completeRead) pollDiagnostics.push("rollout-read-not-at-eof");
    const trustedRead =
      threadBindingValid &&
      (parsed.ok || (parsed.reason === "deadline-exceeded" && parsed.integrityValidated));
    if (trustedRead) {
      if (parsed.ok) cursor = parsed.cursor;
      for (const item of attemptRecords) consumer.push(item);
    }
    lastObservation = consumer.observe(parsed);
    if (
      trustedRead &&
      completeRead &&
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
    if (!threadBindingValid || (!parsed.ok && parsed.reason !== "missing")) break;
    if (attempt < attempts) {
      const remaining = deadlineAt - now();
      if (remaining <= 0) break;
      await sleep(Math.min(interval, remaining));
    }
  }
  if (lastParsed) {
    consumer.finish(lastParsed);
    lastObservation = consumer.observe();
  }
  return {
    ok: false,
    startedAt,
    finishedAt: new Date(now()).toISOString(),
    attempts: attemptsMade,
    rolloutPath,
    markerSha256: sha256(marker),
    lastObservation,
    diagnostics: pollDiagnostics,
    warnings: [
      "Marker proof did not reach agent response plus later task_complete within the poll window.",
      "The turn may still be running. Negative bounded inspection cannot authorize a retry; require exact full-history non-admission or an explicit owner decision acknowledging duplicate-send risk.",
    ],
  };
}
