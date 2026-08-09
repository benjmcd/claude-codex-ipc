#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { constants as BUFFER_CONSTANTS } from "node:buffer";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const BINARY_ALLOWLIST = Object.freeze([]);
const MOJIBAKE_EXCEPTIONS = Object.freeze([]);
const SELF_TEST_TEMP_REGISTRY = [];

const MOJIBAKE_SIGNATURES = Object.freeze([
  { id: "MJ001", text: String.fromCodePoint(0x00e2, 0x20ac, 0x201d) },
  { id: "MJ002", text: String.fromCodePoint(0x00e2, 0x20ac, 0x201c) },
  { id: "MJ003", text: String.fromCodePoint(0x00e2, 0x2020, 0x2019) },
  { id: "MJ004", text: String.fromCodePoint(0x00e2, 0x2030, 0x00a5) },
  { id: "MJ005", text: String.fromCodePoint(0x00c2, 0x00b7) },
  { id: "MJ006", text: String.fromCodePoint(0x00c2, 0x00a7) },
  { id: "MJ007", text: String.fromCodePoint(0x00ef, 0x00bb, 0x00bf) },
]);

const FORBIDDEN_RANGES = Object.freeze([
  [0x0000, 0x0008],
  [0x000b, 0x001f],
  [0x007f, 0x009f],
  [0x061c, 0x061c],
  [0x200b, 0x200d],
  [0x200e, 0x200f],
  [0x202a, 0x202e],
  [0x2060, 0x2060],
  [0x2066, 0x2069],
  [0xfff9, 0xfffb],
  [0xfdd0, 0xfdef],
]);

// Frozen self-test oracles. Keep independent from production policy tables/helpers.
const SELF_TEST_FORBIDDEN_FIXTURES = Object.freeze([
  [0x0000, "forbidden-U+0000"],
  [0x0008, "forbidden-U+0008"],
  [0x000b, "forbidden-U+000B"],
  [0x001f, "forbidden-U+001F"],
  [0x007f, "forbidden-U+007F"],
  [0x009f, "forbidden-U+009F"],
  [0x061c, "forbidden-U+061C"],
  [0x200b, "forbidden-U+200B"],
  [0x200d, "forbidden-U+200D"],
  [0x200e, "forbidden-U+200E"],
  [0x200f, "forbidden-U+200F"],
  [0x202a, "forbidden-U+202A"],
  [0x202e, "forbidden-U+202E"],
  [0x2060, "forbidden-U+2060"],
  [0x2066, "forbidden-U+2066"],
  [0x2069, "forbidden-U+2069"],
  [0xfff9, "forbidden-U+FFF9"],
  [0xfffb, "forbidden-U+FFFB"],
  [0xfdd0, "forbidden-U+FDD0"],
  [0xfdef, "forbidden-U+FDEF"],
  [0xfffd, "forbidden-U+FFFD"],
  [0xfffe, "forbidden-U+FFFE"],
  [0xffff, "forbidden-U+FFFF"],
  [0x1fffe, "forbidden-U+1FFFE"],
  [0x1ffff, "forbidden-U+1FFFF"],
  [0x10fffe, "forbidden-U+10FFFE"],
  [0x10ffff, "forbidden-U+10FFFF"],
]);

const SELF_TEST_MOJIBAKE_FIXTURES = Object.freeze([
  { signatureId: "MJ001", codePoints: [0x00e2, 0x20ac, 0x201d], reason: "mojibake-MJ001" },
  { signatureId: "MJ002", codePoints: [0x00e2, 0x20ac, 0x201c], reason: "mojibake-MJ002" },
  { signatureId: "MJ003", codePoints: [0x00e2, 0x2020, 0x2019], reason: "mojibake-MJ003" },
  { signatureId: "MJ004", codePoints: [0x00e2, 0x2030, 0x00a5], reason: "mojibake-MJ004" },
  { signatureId: "MJ005", codePoints: [0x00c2, 0x00b7], reason: "mojibake-MJ005" },
  { signatureId: "MJ006", codePoints: [0x00c2, 0x00a7], reason: "mojibake-MJ006" },
  { signatureId: "MJ007", codePoints: [0x00ef, 0x00bb, 0x00bf], reason: "mojibake-MJ007" },
]);

const SELF_TEST_MJ001_LINE_SHA256 = "be1baf7cfce2ee1fa4c6e521a270f9c6c3e6418c1917d7db1674fac3d116e11a";
const SELF_TEST_SHA256_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function asciiEscape(value) {
  let output = "";
  for (const character of String(value)) {
    const codePoint = character.codePointAt(0);
    if (character === "\\") output += "\\\\";
    else if (codePoint >= 0x20 && codePoint <= 0x7e) output += character;
    else if (codePoint <= 0xffff) output += `\\u${codePoint.toString(16).padStart(4, "0")}`;
    else output += `\\u{${codePoint.toString(16)}}`;
  }
  return output;
}

function formatFinding(finding) {
  return `${finding.id} source=${asciiEscape(finding.source)} path=${asciiEscape(finding.path)} byte=${finding.byteOffset} codepoint=${finding.codePointOffset} reason=${asciiEscape(finding.reason)}`;
}

function sortFindings(findings) {
  return findings.sort((left, right) =>
    (left.path < right.path ? -1 : left.path > right.path ? 1 : 0)
    || left.byteOffset - right.byteOffset
    || left.codePointOffset - right.codePointOffset
    || (left.id < right.id ? -1 : left.id > right.id ? 1 : 0)
    || (left.reason < right.reason ? -1 : left.reason > right.reason ? 1 : 0));
}

function finding(context, id, byteOffset, codePointOffset, reason, extra = {}) {
  return {
    id,
    source: typeof context.source === "string" ? context.source : "buffer",
    path: typeof context.path === "string" ? context.path : "<buffer>",
    byteOffset,
    codePointOffset,
    reason,
    ...extra,
  };
}

function firstInvalidUtf8Offset(bytes) {
  for (let index = 0; index < bytes.length;) {
    const first = bytes[index];
    if (first <= 0x7f) {
      index += 1;
      continue;
    }
    let length;
    let secondMin = 0x80;
    let secondMax = 0xbf;
    if (first >= 0xc2 && first <= 0xdf) length = 2;
    else if (first === 0xe0) { length = 3; secondMin = 0xa0; }
    else if (first >= 0xe1 && first <= 0xec) length = 3;
    else if (first === 0xed) { length = 3; secondMax = 0x9f; }
    else if (first >= 0xee && first <= 0xef) length = 3;
    else if (first === 0xf0) { length = 4; secondMin = 0x90; }
    else if (first >= 0xf1 && first <= 0xf3) length = 4;
    else if (first === 0xf4) { length = 4; secondMax = 0x8f; }
    else return index;
    if (index + length > bytes.length) return index;
    if (bytes[index + 1] < secondMin || bytes[index + 1] > secondMax) return index;
    for (let offset = 2; offset < length; offset += 1) {
      if (bytes[index + offset] < 0x80 || bytes[index + offset] > 0xbf) return index;
    }
    index += length;
  }
  return -1;
}

function validUtf8PrefixScalarCount(bytes, startOffset, endOffset) {
  const prefix = bytes.subarray(startOffset, endOffset);
  if (firstInvalidUtf8Offset(prefix) !== -1) throw new Error("invalid UTF-8 prefix invariant");
  let count = 0;
  for (let index = 0; index < prefix.length; count += 1) {
    const first = prefix[index];
    if (first <= 0x7f) index += 1;
    else if (first <= 0xdf) index += 2;
    else if (first <= 0xef) index += 3;
    else index += 4;
  }
  return count;
}

function forbiddenCodePoint(codePoint) {
  if (codePoint === 0xfffd) return true;
  if (codePoint >= 0xfdd0 && codePoint <= 0xfdef) return true;
  if ((codePoint & 0xffff) === 0xfffe || (codePoint & 0xffff) === 0xffff) return true;
  return FORBIDDEN_RANGES.some(([start, end]) => codePoint >= start && codePoint <= end);
}

function codePointLabel(codePoint) {
  return `U+${codePoint.toString(16).toUpperCase().padStart(4, "0")}`;
}

function exceptionShapeReason(exception) {
  if (!exception || typeof exception !== "object" || Array.isArray(exception)) return "malformed-exception";
  const expectedFields = ["line", "lineSha256", "occurrence", "path", "rationale", "signatureId"];
  const actualFields = Object.keys(exception).sort();
  if (actualFields.length !== expectedFields.length
      || actualFields.some((field, index) => field !== expectedFields[index])) return "unexpected-fields";
  if (!MOJIBAKE_SIGNATURES.some((item) => item.id === exception.signatureId)) return "wrong-signature";
  if (typeof exception.path !== "string" || exception.path.length === 0) return "malformed-path";
  if (exception.path.startsWith("/") || /^[A-Za-z]:/.test(exception.path)
      || exception.path.includes("\\") || exception.path.split("/").some((part) =>
        part.length === 0 || part === "." || part === "..")) return "noncanonical-path";
  if (!Number.isInteger(exception.line) || exception.line < 1) return "invalid-line";
  if (!Number.isInteger(exception.occurrence) || exception.occurrence < 1) return "invalid-occurrence";
  if (typeof exception.lineSha256 !== "string" || !/^[0-9a-f]{64}$/.test(exception.lineSha256)) {
    return "malformed-line-hash";
  }
  if (typeof exception.rationale !== "string" || exception.rationale.trim().length === 0) {
    return "missing-rationale";
  }
  return null;
}

function exceptionKey(exception) {
  return [exception.signatureId, exception.path, exception.line, exception.occurrence].join("\0");
}

function resolveSignatureOffsets(text, byteBase, occurrences, stats) {
  const ordered = occurrences.map((occurrence, order) => ({ occurrence, order }))
    .sort((left, right) => left.occurrence.utf16Index - right.occurrence.utf16Index || left.order - right.order);
  let target = 0;
  let utf16Offset = 0;
  let byteOffset = byteBase;
  let codePointOffset = 0;
  if (stats) stats.scalarTraversals = (stats.scalarTraversals || 0) + 1;
  const resolveCurrent = () => {
    while (target < ordered.length && ordered[target].occurrence.utf16Index === utf16Offset) {
      ordered[target].occurrence.byteOffset = byteOffset;
      ordered[target].occurrence.codePointOffset = codePointOffset;
      target += 1;
      if (stats) stats.resolved = (stats.resolved || 0) + 1;
    }
  };
  for (const character of text) {
    resolveCurrent();
    utf16Offset += character.length;
    byteOffset += Buffer.byteLength(character, "utf8");
    codePointOffset += 1;
  }
  resolveCurrent();
  if (target !== ordered.length) throw new Error("unresolved-signature-offset");
}

function scanTextBufferWithPolicy(input, context, exceptions, offsetMetrics = null) {
  const bytes = Buffer.isBuffer(input)
    ? input
    : input instanceof Uint8Array
      ? Buffer.from(input.buffer, input.byteOffset, input.byteLength)
      : null;
  if (bytes === null) return [finding(context, "TXT900", 0, 0, "input-is-not-a-byte-buffer")];

  const findings = [];
  const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  const missingFinalLf = bytes.length > 0 && bytes.at(-1) !== 0x0a;
  if (hasBom) findings.push(finding(context, "TXT002", 0, 0, "utf8-bom"));

  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    const byteOffset = firstInvalidUtf8Offset(bytes);
    const safeByteOffset = byteOffset < 0 ? 0 : byteOffset;
    const prefixStart = hasBom && safeByteOffset >= 3 ? 3 : 0;
    const prefixCodePoints = validUtf8PrefixScalarCount(bytes, prefixStart, safeByteOffset);
    findings.push(finding(context, "TXT001", safeByteOffset, prefixCodePoints, "invalid-utf8"));
    if (missingFinalLf) findings.push(finding(context, "TXT005", bytes.length, 0, "missing-final-LF"));
    return context.deferSort ? findings : sortFindings(findings);
  }

  if (missingFinalLf) {
    findings.push(finding(context, "TXT005", bytes.length, [...text].length, "missing-final-LF"));
  }

  const byteBase = hasBom ? 3 : 0;
  let byteOffset = byteBase;
  let codePointOffset = 0;
  for (const character of text) {
    const codePoint = character.codePointAt(0);
    if (codePoint === 0xfeff) {
      findings.push(finding(context, "TXT002", byteOffset, codePointOffset, "embedded-U+FEFF"));
    } else if (codePoint === 0x000d) {
      findings.push(finding(context, "TXT003", byteOffset, codePointOffset, "carriage-return-U+000D"));
    } else if (forbiddenCodePoint(codePoint)) {
      findings.push(finding(context, "TXT004", byteOffset, codePointOffset,
        `forbidden-${codePointLabel(codePoint)}`));
    }
    byteOffset += Buffer.byteLength(character, "utf8");
    codePointOffset += 1;
  }

  const signatureOccurrences = [];
  let lineStart = 0;
  let lineNumber = 1;
  while (lineStart <= text.length) {
    const newline = text.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? text.length : newline;
    const lineText = text.slice(lineStart, lineEnd);
    const lineBytes = Buffer.from(lineText, "utf8");
    const lineHash = sha256(lineBytes);
    for (const signature of MOJIBAKE_SIGNATURES) {
      let searchFrom = 0;
      let occurrence = 0;
      while (searchFrom <= lineText.length) {
        const localIndex = lineText.indexOf(signature.text, searchFrom);
        if (localIndex === -1) break;
        occurrence += 1;
        const globalIndex = lineStart + localIndex;
        const signatureOccurrence = {
          signatureId: signature.id,
          line: lineNumber,
          occurrence,
          lineSha256: lineHash,
        };
        Object.defineProperty(signatureOccurrence, "utf16Index", { value: globalIndex });
        signatureOccurrences.push(signatureOccurrence);
        searchFrom = localIndex + signature.text.length;
      }
    }
    if (newline === -1) break;
    lineStart = newline + 1;
    lineNumber += 1;
  }
  resolveSignatureOffsets(text, byteBase, signatureOccurrences, offsetMetrics);

  if (context.globalExceptionState) {
    const suppressed = new Set();
    for (const indexed of exceptions) {
      const { exception, index } = indexed;
      const sameSignature = signatureOccurrences.filter((item) => item.signatureId === exception.signatureId);
      const sameLine = sameSignature.filter((item) => item.line === exception.line);
      const sameOccurrence = sameLine.find((item) => item.occurrence === exception.occurrence);
      let reason = null;
      if (sameSignature.length === 0) {
        const differentSignature = signatureOccurrences.some((item) =>
          item.line === exception.line && item.occurrence === exception.occurrence);
        reason = differentSignature ? "wrong-signature" : "no-matching-finding";
      } else if (sameLine.length === 0) reason = "wrong-line";
      else if (!sameOccurrence) reason = "wrong-occurrence";
      else if (sameOccurrence.lineSha256 !== exception.lineSha256) reason = "stale-line-hash";
      else {
        suppressed.add(sameOccurrence);
        context.globalExceptionState.used.add(index);
      }
      if (reason) context.globalExceptionState.failures.set(index, reason);
    }
    for (const occurrence of signatureOccurrences) {
      if (!suppressed.has(occurrence)) {
        findings.push(finding(context, "TXT006", occurrence.byteOffset, occurrence.codePointOffset,
          `mojibake-${occurrence.signatureId}`, occurrence));
      }
    }
    return context.deferSort ? findings : sortFindings(findings);
  }

  const invalidExceptions = new Set();
  const seenExceptionKeys = new Map();
  const knownPaths = Array.isArray(context.knownPaths) ? new Set(context.knownPaths) : null;
  exceptions.forEach((exception, index) => {
    const shapeReason = exceptionShapeReason(exception);
    if (shapeReason) {
      invalidExceptions.add(index);
      findings.push(finding(context, "TXT007", 0, 0, shapeReason));
      return;
    }
    const key = exceptionKey(exception);
    if (seenExceptionKeys.has(key)) {
      invalidExceptions.add(seenExceptionKeys.get(key));
      invalidExceptions.add(index);
      findings.push(finding(context, "TXT007", 0, 0, "duplicate-exception"));
    } else {
      seenExceptionKeys.set(key, index);
    }
    if (knownPaths && !knownPaths.has(exception.path)) {
      invalidExceptions.add(index);
      findings.push(finding(context, "TXT007", 0, 0, "nonexistent-path"));
    }
  });

  const suppressed = new Set();
  exceptions.forEach((exception, index) => {
    if (invalidExceptions.has(index) || !exception || exception.path !== context.path) return;
    const sameSignature = signatureOccurrences.filter((item) => item.signatureId === exception.signatureId);
    const sameLine = sameSignature.filter((item) => item.line === exception.line);
    const sameOccurrence = sameLine.find((item) => item.occurrence === exception.occurrence);
    let reason = null;
    if (sameSignature.length === 0) {
      const differentSignature = signatureOccurrences.some((item) =>
        item.line === exception.line && item.occurrence === exception.occurrence);
      reason = differentSignature ? "wrong-signature" : "no-matching-finding";
    }
    else if (sameLine.length === 0) reason = "wrong-line";
    else if (!sameOccurrence) reason = "wrong-occurrence";
    else if (sameOccurrence.lineSha256 !== exception.lineSha256) reason = "stale-line-hash";
    else suppressed.add(sameOccurrence);
    if (reason) findings.push(finding(context, "TXT007", 0, 0, reason));
  });

  for (const occurrence of signatureOccurrences) {
    if (!suppressed.has(occurrence)) {
      findings.push(finding(context, "TXT006", occurrence.byteOffset, occurrence.codePointOffset,
        `mojibake-${occurrence.signatureId}`, occurrence));
    }
  }
  return context.deferSort ? findings : sortFindings(findings);
}

export function scanTextBuffer(bytes, context = {}) {
  return scanTextBufferWithPolicy(bytes, context, MOJIBAKE_EXCEPTIONS);
}

function parseArgs(argv) {
  if (argv.length === 1 && argv[0] === "--self-test") return { mode: "self-test" };
  if (argv.length === 2 && argv[0] === "--source" && ["index", "worktree"].includes(argv[1])) {
    return { mode: "source", source: argv[1] };
  }
  throw new Error("usage: exactly --self-test or --source <index|worktree> is required");
}

class InfrastructureError extends Error {}

function failInfrastructure(reason) {
  throw new InfrastructureError(reason);
}

function decodeUtf8Strict(bytes, reason) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    failInfrastructure(reason);
  }
}

function decodeAsciiStrict(bytes, reason) {
  if ([...bytes].some((byte) => byte > 0x7f)) failInfrastructure(reason);
  return bytes.toString("latin1");
}

function gitChildEnvironment() {
  const env = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (!/^GIT_/i.test(name)) env[name] = value;
  }
  env.GIT_OPTIONAL_LOCKS = "0";
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_CONFIG_GLOBAL = process.platform === "win32" ? "NUL" : "/dev/null";
  env.GIT_PAGER = "cat";
  env.GIT_NO_REPLACE_OBJECTS = "1";
  env.GIT_NO_LAZY_FETCH = "1";
  env.GIT_ATTR_NOSYSTEM = "1";
  env.GIT_TERMINAL_PROMPT = "0";
  return env;
}

function runGitRaw(cwd, args, input, seams, operation, maxBuffer = undefined) {
  if (seams.gitFailure === operation) failInfrastructure(`git-child-error-${operation}`);
  if (typeof seams.onGitOperation === "function") {
    seams.onGitOperation({ operation, args: [...args], input, maxBuffer });
  }
  const overrideName = {
    "ls-files": "lsFilesBuffer",
    "ita-invisible": "itaInvisibleBuffer",
    "ita-visible": "itaVisibleBuffer",
    "check-attr": "attributeBuffer",
    "cat-file-batch-check": "batchCheckBuffer",
    "cat-file": "catFileBuffer",
    "show-toplevel": "rootBuffer",
  }[operation];
  if (overrideName && Object.hasOwn(seams, overrideName)) {
    const override = seams[overrideName];
    return typeof override === "function"
      ? override({ operation, args: [...args], input, maxBuffer }) : override;
  }
  const options = {
    cwd,
    input,
    encoding: null,
    shell: false,
    windowsHide: true,
    env: gitChildEnvironment(),
  };
  if (maxBuffer !== undefined) options.maxBuffer = maxBuffer;
  const result = spawnSync("git", args, options);
  if (result.error || result.signal || result.status !== 0 || !Buffer.isBuffer(result.stdout)) {
    failInfrastructure(`git-child-error-${operation}`);
  }
  return result.stdout;
}

function parseNulRecords(bytes, label, allowEmpty = false) {
  if (!Buffer.isBuffer(bytes)) failInfrastructure(`malformed-${label}-framing`);
  if (bytes.length === 0) {
    if (allowEmpty) return [];
    failInfrastructure(`malformed-${label}-framing`);
  }
  if (bytes.at(-1) !== 0) failInfrastructure(`malformed-${label}-framing`);
  const records = [];
  let start = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] !== 0) continue;
    if (index === start) failInfrastructure(`malformed-${label}-framing`);
    records.push(bytes.subarray(start, index));
    start = index + 1;
  }
  if (start !== bytes.length) failInfrastructure(`malformed-${label}-framing`);
  return records;
}

function validateGitPath(value, reason = "malformed-index-path") {
  if (value.length === 0 || value.startsWith("/") || /^[A-Za-z]:/.test(value)
      || value.split("/").some((part) => part.length === 0 || part === "." || part === "..")) {
    failInfrastructure(reason);
  }
  return value;
}

function parseIndexEntries(bytes) {
  const records = parseNulRecords(bytes, "index", true);
  if (records.length === 0) failInfrastructure("empty-tracked-selection");
  const entries = [];
  const paths = new Set();
  for (const record of records) {
    const tab = record.indexOf(0x09);
    if (tab <= 0 || tab === record.length - 1) failInfrastructure("malformed-index-record");
    const header = decodeAsciiStrict(record.subarray(0, tab), "non-ascii-index-header");
    const match = /^(\d{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])$/.exec(header);
    if (!match) failInfrastructure("malformed-index-record");
    const relativePath = validateGitPath(decodeUtf8Strict(record.subarray(tab + 1), "invalid-utf8-index-path"));
    if (paths.has(relativePath)) failInfrastructure("duplicate-index-path");
    paths.add(relativePath);
    const [, mode, oid, stageText] = match;
    if (Number(stageText) !== 0) failInfrastructure("non-stage-zero");
    if (/^0+$/.test(oid)) failInfrastructure("zero-object-identity");
    if (!new Set(["100644", "100755"]).has(mode)) failInfrastructure(`unsupported-mode-${mode}`);
    entries.push({ mode, oid, path: relativePath });
  }
  entries.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
  return entries;
}

function parsePathSet(bytes, label) {
  if (bytes.length === 0) return new Set();
  const paths = new Set();
  for (const record of parseNulRecords(bytes, label)) {
    const relativePath = validateGitPath(decodeUtf8Strict(record, `invalid-utf8-${label}-path`));
    if (paths.has(relativePath)) failInfrastructure(`duplicate-${label}-path`);
    paths.add(relativePath);
  }
  return paths;
}

function assertNoIntentToAdd(cwd, seams) {
  const invisible = parsePathSet(runGitRaw(cwd, ["diff", "--cached", "--name-only", "-z",
    "--ita-invisible-in-index"], undefined, seams, "ita-invisible"), "ita-invisible");
  const visible = parsePathSet(runGitRaw(cwd, ["diff", "--cached", "--name-only", "-z",
    "--ita-visible-in-index"], undefined, seams, "ita-visible"), "ita-visible");
  if (invisible.size !== visible.size || [...invisible].some((item) => !visible.has(item))) {
    failInfrastructure("intent-to-add");
  }
}

function checkedBatchBytes(total, amount) {
  if (!Number.isSafeInteger(total) || total < 0 || !Number.isSafeInteger(amount) || amount < 0
      || total > Number.MAX_SAFE_INTEGER - amount) failInfrastructure("cat-file-batch-size-overflow");
  const next = total + amount;
  if (next > BUFFER_CONSTANTS.MAX_LENGTH) failInfrastructure("cat-file-batch-size-overflow");
  return next;
}

function batchCheckMaxBuffer(entries) {
  const decimalWidth = String(Number.MAX_SAFE_INTEGER).length;
  let maximum = 0;
  for (const entry of entries) {
    maximum = checkedBatchBytes(maximum, entry.oid.length + " blob ".length + decimalWidth + 1);
  }
  return maximum;
}

function parseBatchCheck(bytes, entries) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0) failInfrastructure("malformed-cat-file-batch-check-framing");
  let lineFeeds = 0;
  for (const byte of bytes) if (byte === 0x0a) lineFeeds += 1;
  if (lineFeeds < entries.length) failInfrastructure("malformed-cat-file-batch-check-framing");
  if (lineFeeds > entries.length || bytes.at(-1) !== 0x0a) {
    failInfrastructure("malformed-cat-file-batch-check-trailing-data");
  }
  const sizes = [];
  let cursor = 0;
  for (const entry of entries) {
    const newline = bytes.indexOf(0x0a, cursor);
    if (newline < 0) failInfrastructure("malformed-cat-file-batch-check-framing");
    const header = decodeAsciiStrict(bytes.subarray(cursor, newline), "non-ascii-cat-file-batch-check-header");
    const match = /^([0-9a-f]{40}|[0-9a-f]{64}) blob (0|[1-9]\d*)$/.exec(header);
    if (!match || match[1] !== entry.oid) failInfrastructure("malformed-cat-file-batch-check-header");
    const size = Number(match[2]);
    if (!Number.isSafeInteger(size)) failInfrastructure("malformed-cat-file-batch-check-size");
    sizes.push(size);
    cursor = newline + 1;
  }
  if (cursor !== bytes.length) failInfrastructure("malformed-cat-file-batch-check-trailing-data");
  return sizes;
}

function prepareIndexBlobReader(cwd, entries, seams) {
  const input = Buffer.from(`${entries.map((entry) => entry.oid).join("\n")}\n`, "ascii");
  const checkedOutput = runGitRaw(cwd, ["cat-file", "--batch-check"], input, seams,
    "cat-file-batch-check", batchCheckMaxBuffer(entries));
  const sizes = parseBatchCheck(checkedOutput, entries);
  const sizeByPath = new Map(entries.map((entry, index) => [entry.path, sizes[index]]));
  return (entry) => {
    const size = sizeByPath.get(entry.path);
    if (!Number.isSafeInteger(size)) failInfrastructure("malformed-cat-file-batch-check-size");
    let maxBuffer = checkedBatchBytes(0, Buffer.byteLength(`${entry.oid} blob ${size}\n`, "ascii"));
    maxBuffer = checkedBatchBytes(maxBuffer, size);
    maxBuffer = checkedBatchBytes(maxBuffer, 1);
    const bodyInput = Buffer.from(`${entry.oid}\n`, "ascii");
    const output = runGitRaw(cwd, ["cat-file", "--batch"], bodyInput, seams, "cat-file", maxBuffer);
    const newline = output.indexOf(0x0a);
    if (newline < 0) failInfrastructure("malformed-cat-file-framing");
    const header = decodeAsciiStrict(output.subarray(0, newline), "non-ascii-cat-file-header");
    const match = /^([0-9a-f]{40}|[0-9a-f]{64}) blob (0|[1-9]\d*)$/.exec(header);
    if (!match || match[1] !== entry.oid) failInfrastructure("malformed-cat-file-header");
    const bodySize = Number(match[2]);
    if (!Number.isSafeInteger(bodySize)) failInfrastructure("malformed-cat-file-size");
    if (bodySize !== size) failInfrastructure("cat-file-size-mismatch");
    const start = newline + 1;
    const end = start + bodySize;
    if (end >= output.length || output[end] !== 0x0a) failInfrastructure("malformed-cat-file-framing");
    if (end + 1 !== output.length) failInfrastructure("malformed-cat-file-trailing-data");
    return Buffer.from(output.subarray(start, end));
  };
}

function parseAttributes(bytes, requestedPaths) {
  const records = parseNulRecords(bytes, "attribute", requestedPaths.length === 0);
  if (records.length !== requestedPaths.length * 6) failInfrastructure("malformed-attribute-response");
  const result = new Map();
  for (let pathIndex = 0; pathIndex < requestedPaths.length; pathIndex += 1) {
    const base = pathIndex * 6;
    const firstPath = decodeUtf8Strict(records[base], "invalid-utf8-attribute-path");
    const firstName = decodeUtf8Strict(records[base + 1], "invalid-utf8-attribute-name");
    const firstValue = decodeUtf8Strict(records[base + 2], "invalid-utf8-attribute-value");
    const secondPath = decodeUtf8Strict(records[base + 3], "invalid-utf8-attribute-path");
    const secondName = decodeUtf8Strict(records[base + 4], "invalid-utf8-attribute-name");
    const secondValue = decodeUtf8Strict(records[base + 5], "invalid-utf8-attribute-value");
    const requested = requestedPaths[pathIndex];
    if (firstPath !== requested || secondPath !== requested || firstName !== "text" || secondName !== "eol") {
      failInfrastructure("malformed-attribute-response");
    }
    if (result.has(requested)) failInfrastructure("duplicate-attribute-path");
    result.set(requested, { text: firstValue, eol: secondValue });
  }
  return result;
}

function readAttributes(cwd, entries, source, seams) {
  const paths = entries.map((entry) => entry.path);
  const input = Buffer.from(`${paths.join("\0")}\0`, "utf8");
  const args = ["check-attr"];
  if (source === "index") args.push("--cached");
  args.push("-z", "text", "eol", "--stdin");
  return parseAttributes(runGitRaw(cwd, args, input, seams, "check-attr"), paths);
}

function repositoryRoot(cwd, seams) {
  const raw = runGitRaw(cwd, ["rev-parse", "--show-toplevel"], undefined, seams, "show-toplevel");
  const text = decodeUtf8Strict(raw, "invalid-utf8-worktree-root");
  if (!text.endsWith("\n") || text.slice(0, -1).includes("\n")) failInfrastructure("malformed-worktree-root");
  return path.resolve(text.slice(0, -1).replace(/\r$/, ""));
}

function ensureContained(root, candidate) {
  const relative = path.relative(root, candidate);
  if (relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative))) return;
  failInfrastructure("worktree-realpath-escape");
}

function exactNonRedirectedDirent(parent, expectedName, seamKey, seams, missingReason) {
  let entries;
  try {
    entries = readdirSync(parent, { encoding: "utf8", withFileTypes: true });
  } catch {
    failInfrastructure(missingReason);
  }
  const match = entries.find((entry) => entry.name === expectedName);
  if (!match) {
    if (entries.some((entry) => entry.name.toLowerCase() === expectedName.toLowerCase())) {
      failInfrastructure("worktree-case-mismatch");
    }
    failInfrastructure(missingReason);
  }
  const selected = seams.direntKind?.[seamKey] === "reparse"
    ? Object.create(match, { isSymbolicLink: { value: () => true } })
    : match;
  if (selected.isSymbolicLink()) failInfrastructure("redirected-segment");
  return selected;
}

function readWorktreeFile(root, relativePath, seams) {
  const injectedKinds = seams.pathKind || {};
  const rootParent = path.dirname(root);
  const rootLeaf = path.basename(root);
  if (root === path.parse(root).root || rootParent === root || rootLeaf === "") {
    failInfrastructure("unsupported-worktree-root-anchor");
  }
  exactNonRedirectedDirent(rootParent, rootLeaf, "<root>", seams, "missing-worktree-root");
  let rootStat;
  try {
    rootStat = lstatSync(root);
  } catch {
    failInfrastructure("missing-worktree-root");
  }
  if (rootStat.isSymbolicLink()) failInfrastructure("redirected-segment");
  if (injectedKinds["<root>"] === "file" || !rootStat.isDirectory()) {
    failInfrastructure("nonregular-worktree-root");
  }
  let rootReal;
  if (seams.realpathFailure === "<root>") failInfrastructure("worktree-root-realpath-failure");
  try {
    rootReal = seams.realpath?.["<root>"] || realpathSync.native(root);
  } catch {
    failInfrastructure("worktree-root-realpath-failure");
  }
  const segments = relativePath.split("/");
  let parent = root;
  let relativeSoFar = "";
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    relativeSoFar = relativeSoFar ? `${relativeSoFar}/${segment}` : segment;
    exactNonRedirectedDirent(parent, segment, relativeSoFar, seams, "missing-segment");
    const candidate = path.join(parent, segment);
    let stat;
    try {
      stat = lstatSync(candidate);
    } catch {
      failInfrastructure("missing-segment");
    }
    const injected = injectedKinds[relativeSoFar];
    if (stat.isSymbolicLink()) failInfrastructure("redirected-segment");
    let candidateReal;
    if (seams.realpathFailure === relativeSoFar) failInfrastructure("worktree-realpath-failure");
    try {
      candidateReal = seams.realpath?.[relativeSoFar] || realpathSync.native(candidate);
    } catch {
      failInfrastructure("worktree-realpath-failure");
    }
    ensureContained(rootReal, candidateReal);
    const terminal = index === segments.length - 1;
    if (!terminal && (injected === "file" || !stat.isDirectory())) failInfrastructure("nonregular-intermediate");
    if (terminal && (injected === "directory" || !stat.isFile())) failInfrastructure("nonregular-terminal");
    parent = candidate;
  }
  try {
    const bytes = readFileSync(parent);
    if (typeof seams.onWorktreeRead === "function") seams.onWorktreeRead(relativePath);
    return bytes;
  } catch {
    failInfrastructure("worktree-read-error");
  }
}

function validateBinaryPolicy(entries, attributes) {
  const selected = new Map(entries.map((entry) => [entry.path, entry]));
  const binary = new Set();
  for (const relativePath of BINARY_ALLOWLIST) {
    if (typeof relativePath !== "string") failInfrastructure("binary-allowlist-malformed");
    try {
      validateGitPath(relativePath, "binary-allowlist-malformed");
    } catch (error) {
      if (error instanceof InfrastructureError) throw error;
      failInfrastructure("binary-allowlist-malformed");
    }
    if (binary.has(relativePath)) failInfrastructure("binary-allowlist-duplicate");
    binary.add(relativePath);
    if (!selected.has(relativePath)) failInfrastructure("binary-allowlist-nonexistent");
    const attribute = attributes.get(relativePath);
    if (!attribute) failInfrastructure("binary-attribute-missing");
    if (attribute.text !== "unset") failInfrastructure(`binary-attribute-${attribute.text}`);
  }
  return binary;
}

function prepareGlobalExceptions(source, selectedPaths, binaryPaths) {
  const findings = [];
  const invalid = new Set();
  const firstByKey = new Map();
  MOJIBAKE_EXCEPTIONS.forEach((exception, index) => {
    const shapeReason = exceptionShapeReason(exception);
    const context = { source, path: typeof exception?.path === "string" ? exception.path : "<policy>" };
    if (shapeReason) {
      invalid.add(index);
      findings.push(finding(context, "TXT007", 0, 0, shapeReason));
      return;
    }
    const key = exceptionKey(exception);
    if (firstByKey.has(key)) {
      invalid.add(firstByKey.get(key));
      invalid.add(index);
      findings.push(finding(context, "TXT007", 0, 0, "duplicate-exception"));
    } else {
      firstByKey.set(key, index);
    }
    if (!selectedPaths.has(exception.path)) {
      invalid.add(index);
      findings.push(finding(context, "TXT007", 0, 0, "nonexistent-path"));
    } else if (binaryPaths.has(exception.path)) {
      invalid.add(index);
      findings.push(finding(context, "TXT007", 0, 0, "binary-exception-target"));
    }
  });
  const byPath = new Map();
  const valid = [];
  MOJIBAKE_EXCEPTIONS.forEach((exception, index) => {
    if (invalid.has(index)) return;
    const list = byPath.get(exception.path) || [];
    const indexed = { exception, index };
    list.push(indexed);
    byPath.set(exception.path, list);
    valid.push(indexed);
  });
  return { findings, byPath, valid };
}

function scanRepository(source, seams = {}) {
  const cwd = seams.cwd || process.cwd();
  const root = repositoryRoot(cwd, seams);
  const indexBytes = runGitRaw(cwd, ["ls-files", "--stage", "-z"], undefined, seams, "ls-files");
  const entries = parseIndexEntries(indexBytes);
  assertNoIntentToAdd(cwd, seams);
  const attributes = readAttributes(cwd, entries, source, seams);
  let readIndexBlob = null;
  let moduleEntry = null;
  let indexedModuleBytes = null;
  if (source === "index") {
    readIndexBlob = prepareIndexBlobReader(cwd, entries, seams);
    const modulePath = path.resolve(seams.modulePath || fileURLToPath(import.meta.url));
    const moduleRelative = path.relative(root, modulePath).split(path.sep).join("/");
    if (moduleRelative !== "tests/check_text_integrity.mjs") failInfrastructure("validator-path-mismatch");
    moduleEntry = entries.find((entry) => entry.path === moduleRelative) || null;
    if (moduleEntry === null) failInfrastructure("validator-not-tracked");
    indexedModuleBytes = readIndexBlob(moduleEntry);
    if (!readFileSync(modulePath).equals(indexedModuleBytes)) failInfrastructure("validator-index-divergence");
  }
  const binaryPaths = validateBinaryPolicy(entries, attributes);
  const selectedPaths = new Set(entries.map((entry) => entry.path));
  const global = prepareGlobalExceptions(source, selectedPaths, binaryPaths);
  const globalExceptionState = { used: new Set(), failures: new Map() };
  const findings = [...global.findings];
  for (const entry of entries) {
    const binary = binaryPaths.has(entry.path);
    const exceptions = global.byPath.get(entry.path) || [];
    let bytes;
    if (source === "index") {
      if (binary) continue;
      if (entry === moduleEntry && indexedModuleBytes !== null) {
        bytes = indexedModuleBytes;
        indexedModuleBytes = null;
      } else {
        bytes = readIndexBlob(entry);
      }
    } else {
      bytes = readWorktreeFile(root, entry.path, seams);
      if (binary) continue;
    }
    if (typeof seams.onScanBuffer === "function") seams.onScanBuffer(source, entry.path);
    findings.push(...scanTextBufferWithPolicy(bytes, {
      source,
      path: entry.path,
      deferSort: true,
      globalExceptionState,
    }, exceptions));
  }
  for (const indexed of global.valid) {
    if (globalExceptionState.used.has(indexed.index)) continue;
    findings.push(finding({ source, path: indexed.exception.path }, "TXT007", 0, 0,
      globalExceptionState.failures.get(indexed.index) || "no-matching-finding"));
  }
  return { tracked: entries.length, findings: sortFindings(findings) };
}

function runRepositoryGate(source, seams = {}) {
  try {
    const result = scanRepository(source, seams);
    for (const item of result.findings) console.error(formatFinding(item));
    if (result.findings.length > 0) return 1;
    console.log(`TEXT-INTEGRITY PASS source=${source} tracked=${result.tracked}`);
    return 0;
  } catch (error) {
    const reason = error instanceof InfrastructureError ? error.message : "internal-error";
    console.error(`TXT900 source=${source} path=<none> byte=0 codepoint=0 reason=${asciiEscape(reason)}`);
    return 2;
  }
}

function bytesForCodePoints(...codePoints) {
  return Buffer.from(`${String.fromCodePoint(...codePoints)}\n`, "utf8");
}

function expectedIds(findings) {
  return findings.map((finding) => finding.id).sort().join(",") || "none";
}

function selfTestGit(repo, args, input = undefined, expectedStatus = 0) {
  const result = spawnSync("git", args, {
    cwd: repo,
    input,
    encoding: null,
    windowsHide: true,
    env: {
      ...process.env,
      GIT_OPTIONAL_LOCKS: "0",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: path.join(path.dirname(repo), "empty-gitconfig"),
      HOME: path.join(path.dirname(repo), "isolated-home"),
      USERPROFILE: path.join(path.dirname(repo), "isolated-home"),
      CODEX_IPC_ROOT: path.join(path.dirname(repo), "isolated-ipc-root"),
    },
  });
  if (result.error || result.status !== expectedStatus) {
    throw new Error(`git-${args[0]} status=${result.status} error=${result.error?.message || "none"} stderr=${asciiEscape(result.stderr || Buffer.alloc(0))}`);
  }
  return result.stdout;
}

function selfTestReplacePolicy(moduleBytes, binaryAllowlist = [], exceptions = []) {
  let source = moduleBytes.toString("utf8");
  source = source.replace(
    "const BINARY_ALLOWLIST = Object.freeze([]);",
    `const BINARY_ALLOWLIST = Object.freeze(${JSON.stringify(binaryAllowlist)});`,
  );
  source = source.replace(
    "const MOJIBAKE_EXCEPTIONS = Object.freeze([]);",
    `const MOJIBAKE_EXCEPTIONS = Object.freeze(${JSON.stringify(exceptions)});`,
  );
  return Buffer.from(source, "utf8");
}

function selfTestCreateRepo(parent, name, options = {}) {
  const repo = path.join(parent, name);
  mkdirSync(repo);
  SELF_TEST_TEMP_REGISTRY.push(repo);
  mkdirSync(path.join(repo, "tests"));
  selfTestGit(repo, ["init", "-q"]);
  const moduleBytes = readFileSync(fileURLToPath(import.meta.url));
  writeFileSync(
    path.join(repo, "tests", "check_text_integrity.mjs"),
    selfTestReplacePolicy(moduleBytes, options.binaryAllowlist, options.exceptions),
  );
  writeFileSync(path.join(repo, ".gitattributes"), options.attributes || "* text eol=lf\n");
  const files = options.files || { "plain.txt": Buffer.from("plain\n") };
  for (const [relativePath, bytes] of Object.entries(files)) {
    const destination = path.join(repo, ...relativePath.split("/"));
    mkdirSync(path.dirname(destination), { recursive: true });
    writeFileSync(destination, bytes);
  }
  const staged = [".gitattributes", "tests/check_text_integrity.mjs", ...Object.keys(files)];
  selfTestGit(repo, ["add", "--", ...staged]);
  return repo;
}

function selfTestInvokeMain(repo, source, seams = {}) {
  if (Object.keys(seams).length === 0) {
    const result = spawnSync(process.execPath, [path.join(repo, "tests", "check_text_integrity.mjs"), "--source", source], {
      cwd: repo,
      encoding: "utf8",
      windowsHide: true,
      env: {
        ...process.env,
        GIT_OPTIONAL_LOCKS: "0",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: path.join(path.dirname(repo), "empty-gitconfig"),
        HOME: path.join(path.dirname(repo), "isolated-home"),
        USERPROFILE: path.join(path.dirname(repo), "isolated-home"),
        CODEX_IPC_ROOT: path.join(path.dirname(repo), "isolated-ipc-root"),
      },
    });
    if (result.error) throw result.error;
    const lines = (value) => value.length === 0 ? [] : value.replace(/\n$/, "").split("\n");
    return { status: result.status, stdout: lines(result.stdout), stderr: lines(result.stderr) };
  }
  const previousCwd = process.cwd();
  const stdout = [];
  const stderr = [];
  const previousLog = console.log;
  const previousError = console.error;
  try {
    process.chdir(repo);
    console.log = (...items) => stdout.push(items.join(" "));
    console.error = (...items) => stderr.push(items.join(" "));
    const status = main(["--source", source], {
      modulePath: path.join(repo, "tests", "check_text_integrity.mjs"),
      ...seams,
    });
    return { status, stdout, stderr };
  } finally {
    console.log = previousLog;
    console.error = previousError;
    process.chdir(previousCwd);
  }
}

function selfTestExpectGate(repo, source, expectedStatus, reason = null, seams = {}) {
  const result = selfTestInvokeMain(repo, source, seams);
  if (result.status !== expectedStatus) {
    throw new Error(`source=${source} expected-status=${expectedStatus} actual-status=${result.status} stderr=${asciiEscape(result.stderr.join("|"))}`);
  }
  if (reason !== null && !result.stderr.some((line) => line.includes(reason))) {
    throw new Error(`source=${source} missing-reason=${reason} stderr=${asciiEscape(result.stderr.join("|"))}`);
  }
  if (expectedStatus === 0) {
    if (result.stderr.length !== 0 || result.stdout.length !== 1
        || !result.stdout[0].includes(`source=${source}`) || !result.stdout[0].includes("tracked=")) {
      throw new Error(`bad-success-output stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  } else if (result.stdout.length !== 0) {
    throw new Error(`failure-had-summary stdout=${asciiEscape(result.stdout.join("|"))}`);
  }
  return result;
}

function runSelfTests() {
  const tests = [];
  const add = (name, run) => tests.push({ name, run });
  const tempParent = mkdtempSync(path.join(tmpdir(), "ipc-text-self-"));
  const tempInventoryBefore = readdirSync(tempParent).sort();
  const context = { source: "self-test", path: "fixture.txt", knownPaths: ["fixture.txt"] };
  const scan = (bytes, extra = {}) => scanTextBuffer(bytes, { ...context, ...extra });
  const scanWithExceptions = (bytes, exceptions, extra = {}) =>
    scanTextBufferWithPolicy(bytes, { ...context, ...extra }, exceptions);
  const scanWithPrivateMetrics = (bytes, exceptions, metrics, extra = {}) =>
    scanTextBufferWithPolicy(bytes, { ...context, ...extra }, exceptions, metrics);
  const expectIds = (bytes, ids, extra = {}) => {
    const findings = scan(bytes, extra);
    const actual = expectedIds(findings);
    const expected = [...ids].sort().join(",") || "none";
    if (actual !== expected) throw new Error(`expected=${expected} actual=${actual}`);
    return findings;
  };
  const expectHas = (findings, id, reasonPart = null) => {
    const match = findings.find((finding) => finding.id === id
      && (reasonPart === null || finding.reason.includes(reasonPart)));
    if (!match) throw new Error(`expected=${id}${reasonPart ? `:${reasonPart}` : ""} actual=${expectedIds(findings)}`);
    return match;
  };
  const expectInfrastructure = (run, expectedReason) => {
    try {
      run();
    } catch (error) {
      if (error instanceof InfrastructureError && error.message === expectedReason) return;
      throw new Error(`expected=${expectedReason} actual=${error.message}`);
    }
    throw new Error(`expected=${expectedReason} actual=no-error`);
  };

  add("CLI accepts exact modes", () => {
    if (parseArgs(["--self-test"]).mode !== "self-test") throw new Error("self-test rejected");
    if (parseArgs(["--source", "index"]).source !== "index") throw new Error("index rejected");
    if (parseArgs(["--source", "worktree"]).source !== "worktree") throw new Error("worktree rejected");
  });
  add("CLI rejects missing duplicate conflicting and unknown arguments", () => {
    for (const argv of [[], ["--self-test", "--self-test"], ["--self-test", "--source", "index"],
      ["--source"], ["--source", "head"], ["--unknown"]]) {
      let rejected = false;
      try { parseArgs(argv); } catch { rejected = true; }
      if (!rejected) throw new Error(`accepted=${argv.join(" ")}`);
    }
  });
  add("CLI subprocess rejects invalid argv with exact rc and silent stdout", () => {
    const modulePath = fileURLToPath(import.meta.url);
    const cases = [[], ["--self-test", "--self-test"], ["--self-test", "--source", "index"],
      ["--source"], ["--source", "head"], ["--unknown"]];
    for (const argv of cases) {
      const result = spawnSync(process.execPath, [modulePath, ...argv], { encoding: "utf8", windowsHide: true });
      if (result.error || result.status !== 2 || result.stdout !== ""
          || !/^TXT900 source=cli path=<none> byte=0 codepoint=0 reason=[\x20-\x7e]+\n$/.test(result.stderr)) {
        throw new Error(`argv=${argv.join(",")} status=${result.status} stdout=${asciiEscape(result.stdout)} stderr=${asciiEscape(result.stderr)}`);
      }
    }
  });
  add("module import is silent and side-effect free", () => {
    const href = pathToFileURL(fileURLToPath(import.meta.url)).href;
    const result = spawnSync(process.execPath, ["--input-type=module", "--eval", `await import(${JSON.stringify(href)})`], {
      encoding: "utf8", windowsHide: true,
    });
    if (result.error || result.status !== 0 || result.stdout !== "" || result.stderr !== "") {
      throw new Error(`status=${result.status} stdout=${asciiEscape(result.stdout)} stderr=${asciiEscape(result.stderr)}`);
    }
  });
  add("valid ASCII and empty files pass", () => {
    expectIds(Buffer.from("plain text\n"), []);
    expectIds(Buffer.alloc(0), []);
  });
  add("intended Unicode and standalone Latin lead characters pass", () => {
    const intended = [0x2014, 0x2013, 0x2192, 0x2265, 0x00b7, 0x00a7, 0x00c3, 0x00c2, 0x00e2];
    expectIds(bytesForCodePoints(...intended), []);
  });
  add("accented multilingual and astral UTF-8 passes", () => {
    expectIds(bytesForCodePoints(0x0063, 0x0061, 0x0066, 0x00e9, 0x0020, 0x65e5, 0x672c, 0x8a9e, 0x0020, 0x1f642), []);
  });
  add("allowed values adjacent to forbidden ranges pass", () => {
    const adjacent = [0x0009, 0x000a, 0x0020, 0x007e, 0x00a0, 0x061b, 0x061d,
      0x200a, 0x2010, 0x2029, 0x202f, 0x205f, 0x2061, 0x2065, 0x206a,
      0xfdd0 - 1, 0xfdef + 1, 0xfff8, 0xfffc, 0x10000, 0x1fffd, 0x20000, 0x10fffd];
    expectIds(bytesForCodePoints(...adjacent), []);
  });
  add("invalid UTF-8 is TXT001", () => expectIds(Buffer.from([0xff, 0x0a]), ["TXT001"]));
  add("UTF-8 BOM is TXT002", () => expectIds(Buffer.concat([
    Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("text\n"),
  ]), ["TXT002"]));
  add("embedded U+FEFF is TXT002", () => expectIds(bytesForCodePoints(0x0061, 0xfeff), ["TXT002"]));
  add("CRLF and lone CR are TXT003", () => {
    expectIds(Buffer.from("a\r\n"), ["TXT003"]);
    expectIds(Buffer.from("a\rb\n"), ["TXT003"]);
  });
  add("NUL is TXT004", () => expectIds(bytesForCodePoints(0x0000), ["TXT004"]));

  for (const [codePoint, reason] of SELF_TEST_FORBIDDEN_FIXTURES) {
    add(`frozen forbidden fixture U+${codePoint.toString(16).toUpperCase()} is exact TXT004`, () => {
      const findings = expectIds(bytesForCodePoints(codePoint), ["TXT004"]);
      const item = findings[0];
      if (item.reason !== reason || item.byteOffset !== 0 || item.codePointOffset !== 0) {
        throw new Error(`reason=${item.reason} byte=${item.byteOffset} codepoint=${item.codePointOffset}`);
      }
    });
  }
  add("byte and code-point offsets survive preceding astral scalar", () => {
    const finding = expectIds(bytesForCodePoints(0x1f642, 0x0000), ["TXT004"])[0];
    if (finding.byteOffset !== 4 || finding.codePointOffset !== 1) {
      throw new Error(`byte=${finding.byteOffset} codepoint=${finding.codePointOffset}`);
    }
  });
  add("missing final LF is TXT005", () => expectIds(Buffer.from("text"), ["TXT005"]));
  add("missing final LF reports EOF byte and code-point offsets", () => {
    const bytes = Buffer.from(`${String.fromCodePoint(0x1f642)}x`, "utf8");
    const item = expectIds(bytes, ["TXT005"])[0];
    if (item.byteOffset !== 5 || item.codePointOffset !== 2) {
      throw new Error(`byte=${item.byteOffset} codepoint=${item.codePointOffset}`);
    }
  });
  add("SHA-256 helper matches fixed abc vector", () => {
    const actual = sha256(Buffer.from("abc", "ascii"));
    if (actual !== SELF_TEST_SHA256_ABC) throw new Error(`expected=${SELF_TEST_SHA256_ABC} actual=${actual}`);
  });
  SELF_TEST_MOJIBAKE_FIXTURES.forEach((fixture) => {
    add(`${fixture.signatureId} frozen tuple is exact TXT006`, () => {
      const text = String.fromCodePoint(...fixture.codePoints);
      const item = expectIds(Buffer.from(`${text}\n`, "utf8"), ["TXT006"])[0];
      if (item.signatureId !== fixture.signatureId || item.reason !== fixture.reason
          || item.byteOffset !== 0 || item.codePointOffset !== 0) {
        throw new Error(`signature=${item.signatureId} reason=${item.reason} byte=${item.byteOffset} codepoint=${item.codePointOffset}`);
      }
    });
  });

  const signatureId = "MJ001";
  const signatureLine = String.fromCodePoint(0x00e2, 0x20ac, 0x201d);
  const signatureBytes = Buffer.from(`${signatureLine}\n`, "utf8");
  const exactException = {
    signatureId,
    path: context.path,
    line: 1,
    occurrence: 1,
    lineSha256: SELF_TEST_MJ001_LINE_SHA256,
    rationale: "test-only exact exception",
  };
  add("exported scanner preserves frozen caller inputs and deterministic output", () => {
    const bytes = Buffer.from(signatureBytes);
    const bytesBefore = Buffer.from(bytes);
    const nestedUnknown = Object.freeze({ counters: Object.freeze({ scans: 9 }) });
    const frozenContext = Object.freeze({
      source: "self-test",
      path: "fixture.txt",
      knownPaths: Object.freeze(["fixture.txt"]),
      offsetStats: Object.freeze({ scalarTraversals: 0, resolved: 0 }),
      unknownMetrics: nestedUnknown,
    });
    const contextBefore = JSON.stringify(frozenContext);
    let first;
    let second;
    try {
      first = scanTextBuffer(bytes, frozenContext);
      second = scanTextBuffer(bytes, frozenContext);
    } catch (error) {
      throw new Error(`public-scan-threw=${error.name}:${error.message}`);
    }
    if (!bytes.equals(bytesBefore)) throw new Error("public-scan-mutated-buffer");
    if (JSON.stringify(frozenContext) !== contextBefore || frozenContext.unknownMetrics !== nestedUnknown
        || frozenContext.unknownMetrics.counters.scans !== 9) {
      throw new Error(`public-scan-mutated-context=${JSON.stringify(frozenContext)}`);
    }
    if (JSON.stringify(first) !== JSON.stringify(second)) {
      throw new Error(`nondeterministic-output first=${JSON.stringify(first)} second=${JSON.stringify(second)}`);
    }
  });
  add("exact exception suppresses exactly one finding", () => {
    const findings = scanWithExceptions(signatureBytes, [exactException]);
    if (findings.length !== 0) throw new Error(`actual=${expectedIds(findings)}`);
  });
  add("exception occurrence is one-based and single-use", () => {
    const line = `${signatureLine}${signatureLine}`;
    const exception = {
      ...exactException,
      lineSha256: "65757594ae2c2c6b887119833b6f4f0cd351178334401bcd4912ac6d1c672cd2",
    };
    const findings = scanWithExceptions(Buffer.from(`${line}\n`, "utf8"), [exception]);
    if (findings.filter((item) => item.id === "TXT006").length !== 1) {
      throw new Error(`actual=${expectedIds(findings)}`);
    }
  });
  const misuseCases = [
    ["malformed exception", [null], null],
    ["duplicate exception", [exactException, { ...exactException }], "duplicate"],
    ["duplicate exception target with different rationale", [
      exactException, { ...exactException, rationale: "different rationale" },
    ], "duplicate"],
    ["duplicate exception target with different hash", [
      exactException, { ...exactException, lineSha256: "2".repeat(64) },
    ], "duplicate"],
    ["nonexistent exception path", [{ ...exactException, path: "absent.txt" }], "nonexistent-path"],
    ["dot-relative exception path", [{ ...exactException, path: "./fixture.txt" }], "noncanonical-path"],
    ["parent-segment exception path", [{ ...exactException, path: "dir/../fixture.txt" }], "noncanonical-path"],
    ["POSIX absolute exception path", [{ ...exactException, path: "/absolute" }], "noncanonical-path"],
    ["drive absolute exception path", [{ ...exactException, path: "C:/absolute" }], "noncanonical-path"],
    ["drive-relative exception path", [{ ...exactException, path: "C:fixture.txt" }], "noncanonical-path"],
    ["backslash exception path", [{ ...exactException, path: "dir\\fixture.txt" }], "noncanonical-path"],
    ["duplicate-separator exception path", [{ ...exactException, path: "dir//fixture.txt" }], "noncanonical-path"],
    ["unknown signature", [{ ...exactException, signatureId: "MJ999" }], "wrong-signature"],
    ["valid but wrong signature", [{ ...exactException, signatureId: "MJ002" }], "wrong-signature"],
    ["wrong line", [{ ...exactException, line: 2 }], "wrong-line"],
    ["invalid occurrence", [{ ...exactException, occurrence: 0 }], "invalid-occurrence"],
    ["wrong occurrence", [{ ...exactException, occurrence: 2 }], "wrong-occurrence"],
    ["stale line hash", [{ ...exactException, lineSha256: "0".repeat(64) }], "stale-line-hash"],
    ["missing rationale", [{ ...exactException, rationale: "" }], "missing-rationale"],
    ["extra exception field", [{ ...exactException, extra: true }], "unexpected-fields"],
  ];
  for (const [name, exceptions, reason] of misuseCases) {
    add(name, () => expectHas(scanWithExceptions(signatureBytes, exceptions), "TXT007", reason));
  }
  add("exception with no matching finding is stale", () => {
    const findings = scanWithExceptions(Buffer.from("clean\n"), [exactException]);
    expectHas(findings, "TXT007", "no-matching-finding");
  });
  add("deterministic sort is path then byte then code-point then ID", () => {
    const unordered = [
      finding({ source: "sort", path: "b.txt" }, "TXT004", 0, 0, "b"),
      finding({ source: "sort", path: "a.txt" }, "TXT007", 1, 1, "id-late"),
      finding({ source: "sort", path: "a.txt" }, "TXT006", 1, 1, "id-early"),
      finding({ source: "sort", path: "a.txt" }, "TXT005", 1, 2, "codepoint-late"),
      finding({ source: "sort", path: "a.txt" }, "TXT004", 2, 0, "byte-late"),
    ];
    const actual = sortFindings(unordered).map((item) =>
      `${item.path}:${item.byteOffset}:${item.codePointOffset}:${item.id}`);
    const expected = [
      "a.txt:1:1:TXT006",
      "a.txt:1:1:TXT007",
      "a.txt:1:2:TXT005",
      "a.txt:2:0:TXT004",
      "b.txt:0:0:TXT004",
    ];
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(`expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}`);
    }
  });
  add("diagnostic rendering matches fixed ASCII escape contract", () => {
    const accented = String.fromCodePoint(0x00e9);
    const rendered = formatFinding({
      id: "TXT004",
      source: `src${accented}\tline\nslash\\source`,
      path: `caf${accented}\tline\nslash\\name`,
      byteOffset: 7,
      codePointOffset: 3,
      reason: `bad-${accented}\tline\nslash\\reason`,
    });
    const expected = "TXT004 source=src\\u00e9\\u0009line\\u000aslash\\\\source path=caf\\u00e9\\u0009line\\u000aslash\\\\name byte=7 codepoint=3 reason=bad-\\u00e9\\u0009line\\u000aslash\\\\reason";
    if (rendered !== expected || !/^[\x20-\x7e]+$/.test(rendered)
        || rendered.includes("\n") || rendered.includes("\r")) {
      throw new Error(`expected=${expected} actual=${JSON.stringify(rendered)}`);
    }
  });

  const invalidUtf8Fixtures = [
    ["after ASCII", Buffer.from([0x61, 0xff, 0x0a]), 1, 1],
    ["after astral scalar", Buffer.from([0xf0, 0x9f, 0x99, 0x82, 0xff, 0x0a]), 4, 1],
    ["truncated sequence", Buffer.from([0x61, 0xe2, 0x82, 0x0a]), 1, 1],
    ["overlong sequence", Buffer.from([0x61, 0xc0, 0xaf, 0x0a]), 1, 1],
    ["surrogate sequence", Buffer.from([0x61, 0xed, 0xa0, 0x80, 0x0a]), 1, 1],
    ["above U+10FFFF", Buffer.from([0x61, 0xf4, 0x90, 0x80, 0x80, 0x0a]), 1, 1],
  ];
  for (const [name, bytes, expectedByte, expectedCodePoint] of invalidUtf8Fixtures) {
    add(`invalid UTF-8 ${name} has exact offsets`, () => {
      const item = expectIds(bytes, ["TXT001"])[0];
      if (item.byteOffset !== expectedByte || item.codePointOffset !== expectedCodePoint) {
        throw new Error(`byte=${item.byteOffset} codepoint=${item.codePointOffset}`);
      }
    });
  }
  add("dense mojibake offsets use one bounded scalar traversal", () => {
    const repeat = 64;
    const astral = String.fromCodePoint(0x1f642);
    const text = `${astral}${signatureLine}`.repeat(repeat);
    const bytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(`${text}\n`, "utf8")]);
    const stats = {};
    const originalByteLength = Buffer.byteLength;
    let weightedStringUnits = 0;
    Buffer.byteLength = function measuredByteLength(value, ...args) {
      if (typeof value === "string") weightedStringUnits += value.length;
      return originalByteLength.call(Buffer, value, ...args);
    };
    let findings;
    try {
      findings = scanWithPrivateMetrics(bytes, MOJIBAKE_EXCEPTIONS, stats);
    } finally {
      Buffer.byteLength = originalByteLength;
    }
    const hits = findings.filter((item) => item.id === "TXT006");
    const first = hits[0];
    const last = hits.at(-1);
    if (hits.length !== repeat || first.byteOffset !== 7 || first.codePointOffset !== 1
        || last.byteOffset !== 7 + 12 * (repeat - 1) || last.codePointOffset !== 1 + 4 * (repeat - 1)) {
      throw new Error(`hits=${hits.length} first=${first?.byteOffset}:${first?.codePointOffset} last=${last?.byteOffset}:${last?.codePointOffset}`);
    }
    if (weightedStringUnits > text.length * 3) {
      throw new Error(`quadratic-offset-work units=${weightedStringUnits} bound=${text.length * 3}`);
    }
    if (stats.resolved !== repeat || stats.scalarTraversals !== 1) {
      throw new Error(`resolved=${stats.resolved} traversals=${stats.scalarTraversals}`);
    }
  });
  add("mixed BOM astral multiline offsets preserve occurrence-two suppression", () => {
    const astral = String.fromCodePoint(0x1f642);
    const firstLine = `${astral}${signatureLine}`;
    const secondLine = `x${astral}${signatureLine}${signatureLine}`;
    const bytes = Buffer.concat([
      Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(`${firstLine}\n${secondLine}\n`, "utf8"),
    ]);
    const stats = {};
    const exception = {
      ...exactException,
      line: 2,
      occurrence: 2,
      lineSha256: sha256(Buffer.from(secondLine, "utf8")),
    };
    const findings = scanWithPrivateMetrics(bytes, [exception], stats);
    const hits = findings.filter((item) => item.id === "TXT006");
    const offsets = hits.map((item) => `${item.byteOffset}:${item.codePointOffset}`);
    if (JSON.stringify(offsets) !== JSON.stringify(["7:1", "21:7"])
        || stats.resolved !== 3 || stats.scalarTraversals !== 1) {
      throw new Error(`offsets=${JSON.stringify(offsets)} resolved=${stats.resolved} traversals=${stats.scalarTraversals}`);
    }
  });

  add("index stage-0 regular blob success", () => {
    const repo = selfTestCreateRepo(tempParent, "index-ok");
    selfTestExpectGate(repo, "index", 0);
  });
  add("repository acquisition ignores ambient Git redirects without trace writes", () => {
    const repo = selfTestCreateRepo(tempParent, "ambient-git-env");
    const tracePath = path.join(tempParent, "ambient-git-trace.log");
    const bogusIndex = path.join(tempParent, "ambient-bogus.index");
    const prior = new Map(["GIT_TRACE", "GIT_INDEX_FILE"].map((name) =>
      [name, Object.hasOwn(process.env, name) ? process.env[name] : undefined]));
    try {
      process.env.GIT_TRACE = tracePath;
      process.env.GIT_INDEX_FILE = bogusIndex;
      const result = selfTestExpectGate(repo, "index", 0);
      if (JSON.stringify(result.stdout) !== JSON.stringify(["TEXT-INTEGRITY PASS source=index tracked=3"])) {
        throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))}`);
      }
      if (existsSync(tracePath)) throw new Error("ambient-git-trace-was-written");
    } finally {
      for (const [name, value] of prior) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
      if (existsSync(tracePath)) unlinkSync(tracePath);
      if (existsSync(bogusIndex)) unlinkSync(bogusIndex);
    }
  });
  add("index acquisition ignores Git replacement objects", () => {
    const repo = selfTestCreateRepo(tempParent, "replace-object");
    const originalOid = selfTestGit(repo, ["rev-parse", ":plain.txt"]).toString("ascii").trim();
    const replacementOid = selfTestGit(repo, ["hash-object", "-w", "--stdin"], Buffer.from([0xff, 0x0a]))
      .toString("ascii").trim();
    selfTestGit(repo, ["replace", originalOid, replacementOid]);
    const result = selfTestExpectGate(repo, "index", 0);
    if (JSON.stringify(result.stdout) !== JSON.stringify(["TEXT-INTEGRITY PASS source=index tracked=3"])) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))}`);
    }
  });
  add("Git child sanitizer overrides hostile mixed-case values", () => {
    const hostile = new Map([
      ["gIt_No_RePlAcE_ObJeCtS", "0"],
      ["gIt_No_LaZy_FeTcH", "0"],
      ["GiT_AtTr_NoSyStEm", "0"],
      ["git_terminal_prompt", "1"],
      ["gIt_PaGeR", "hostile"],
    ]);
    const hostileNames = new Set([...hostile.keys()].map((name) => name.toLowerCase()));
    const prior = new Map(Object.entries(process.env).filter(([name]) => hostileNames.has(name.toLowerCase())));
    try {
      for (const [name, value] of hostile) process.env[name] = value;
      const env = gitChildEnvironment();
      const expected = new Map([
        ["GIT_NO_REPLACE_OBJECTS", "1"],
        ["GIT_NO_LAZY_FETCH", "1"],
        ["GIT_ATTR_NOSYSTEM", "1"],
        ["GIT_TERMINAL_PROMPT", "0"],
        ["GIT_OPTIONAL_LOCKS", "0"],
        ["GIT_CONFIG_NOSYSTEM", "1"],
        ["GIT_CONFIG_GLOBAL", process.platform === "win32" ? "NUL" : "/dev/null"],
        ["GIT_PAGER", "cat"],
      ]);
      for (const [name, value] of expected) {
        if (env[name] !== value) throw new Error(`${name}=${env[name] || "missing"}`);
      }
      for (const name of Object.keys(env)) {
        if (/^git_/i.test(name) && !expected.has(name)) throw new Error(`unexpected-git-env=${name}`);
      }
    } finally {
      for (const name of Object.keys(process.env)) if (hostileNames.has(name.toLowerCase())) delete process.env[name];
      for (const [name, value] of prior) process.env[name] = value;
    }
  });
  add("index cat-file aggregate above one MiB succeeds with exact tracked count", () => {
    const largeText = (size) => {
      const bytes = Buffer.alloc(size, 0x61);
      bytes[bytes.length - 1] = 0x0a;
      return bytes;
    };
    const repo = selfTestCreateRepo(tempParent, "index-large-batch", {
      files: {
        "large-a.txt": largeText(700 * 1024),
        "large-b.txt": largeText(400 * 1024),
      },
    });
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const input = Buffer.from(`${entries.map((entry) => entry.oid).join("\n")}\n`, "ascii");
    const checked = selfTestGit(repo, ["cat-file", "--batch-check"], input).toString("ascii").trimEnd().split("\n");
    const framedBytes = checked.reduce((total, header) => {
      const match = /^([0-9a-f]{40}|[0-9a-f]{64}) blob (0|[1-9]\d*)$/.exec(header);
      if (!match) throw new Error(`bad-precondition-header=${header}`);
      return total + Buffer.byteLength(header, "ascii") + 1 + Number(match[2]) + 1;
    }, 0);
    if (framedBytes <= 1_048_576) throw new Error(`precondition-framed-bytes=${framedBytes}`);
    const result = selfTestExpectGate(repo, "index", 0);
    if (JSON.stringify(result.stdout) !== JSON.stringify(["TEXT-INTEGRITY PASS source=index tracked=4"])) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))}`);
    }
  });
  add("index single text blob above one MiB succeeds", () => {
    const bytes = Buffer.alloc(1_100_000, 0x62);
    bytes[bytes.length - 1] = 0x0a;
    const repo = selfTestCreateRepo(tempParent, "index-large-single", { files: { "large.txt": bytes } });
    const result = selfTestExpectGate(repo, "index", 0);
    if (JSON.stringify(result.stdout) !== JSON.stringify(["TEXT-INTEGRITY PASS source=index tracked=3"])) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))}`);
    }
  });
  add("index body acquisition uses exactly one OID per call", () => {
    const repo = selfTestCreateRepo(tempParent, "index-one-oid", {
      files: { "a.txt": Buffer.from("a\n"), "b.txt": Buffer.from("b\n") },
    });
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const moduleEntry = entries.find((entry) => entry.path === "tests/check_text_integrity.mjs");
    const expectedBodyOrder = [moduleEntry, ...entries.filter((entry) => entry !== moduleEntry)].map((entry) => `${entry.oid}\n`);
    const bodyInputs = [];
    const batchCheckInputs = [];
    selfTestExpectGate(repo, "index", 0, null, {
      onGitOperation: ({ operation, input }) => {
        if (operation === "cat-file") bodyInputs.push(input.toString("ascii"));
        if (operation === "cat-file-batch-check") batchCheckInputs.push(input.toString("ascii"));
      },
    });
    if (JSON.stringify(bodyInputs) !== JSON.stringify(expectedBodyOrder)) {
      throw new Error(`body-inputs=${JSON.stringify(bodyInputs)}`);
    }
    const expectedBatchCheck = `${entries.map((entry) => entry.oid).join("\n")}\n`;
    if (JSON.stringify(batchCheckInputs) !== JSON.stringify([expectedBatchCheck])) {
      throw new Error(`batch-check-inputs=${JSON.stringify(batchCheckInputs)}`);
    }
  });
  add("duplicate OID paths are each fetched and scanned", () => {
    const bytes = Buffer.from(`${String.fromCodePoint(0x00e2, 0x20ac, 0x201d)}\n`, "utf8");
    const repo = selfTestCreateRepo(tempParent, "duplicate-oid-paths", {
      files: { "a.txt": bytes, "b.txt": bytes },
    });
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const duplicateOid = entries.find((entry) => entry.path === "a.txt").oid;
    const bodyInputs = [];
    const result = selfTestExpectGate(repo, "index", 1, "TXT006", {
      onGitOperation: ({ operation, input }) => {
        if (operation === "cat-file") bodyInputs.push(input.toString("ascii").trim());
      },
    });
    if (bodyInputs.filter((oid) => oid === duplicateOid).length !== 2) {
      throw new Error(`duplicate-oid-fetches=${JSON.stringify(bodyInputs)}`);
    }
    const findingPaths = result.stderr.filter((line) => line.startsWith("TXT006 ")).map((line) =>
      line.match(/ path=([^ ]+)/)?.[1]);
    if (JSON.stringify(findingPaths) !== JSON.stringify(["a.txt", "b.txt"])) {
      throw new Error(`finding-paths=${JSON.stringify(findingPaths)}`);
    }
  });
  add("worktree acquisition reads and scans each path sequentially", () => {
    const repo = selfTestCreateRepo(tempParent, "worktree-sequential", {
      files: { "b.txt": Buffer.from("b\r\n"), "a.txt": Buffer.from("a\r\n") },
    });
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const events = [];
    const result = selfTestExpectGate(repo, "worktree", 1, "TXT003", {
      onWorktreeRead: (relativePath) => events.push(`read:${relativePath}`),
      onScanBuffer: (_source, relativePath) => events.push(`scan:${relativePath}`),
    });
    const expectedEvents = entries.flatMap((entry) => [`read:${entry.path}`, `scan:${entry.path}`]);
    if (JSON.stringify(events) !== JSON.stringify(expectedEvents)) throw new Error(`events=${JSON.stringify(events)}`);
    const findingPaths = result.stderr.filter((line) => line.startsWith("TXT003 ")).map((line) =>
      line.match(/ path=([^ ]+)/)?.[1]);
    if (JSON.stringify([...new Set(findingPaths)]) !== JSON.stringify(["a.txt", "b.txt"])) {
      throw new Error(`finding-paths=${JSON.stringify(findingPaths)}`);
    }
  });
  const addBatchCheckMutant = (name, mutate, reason) => add(`batch-check ${name} fails closed`, () => {
    const repo = selfTestCreateRepo(tempParent, `batch-check-${name.replace(/[^a-z0-9]+/gi, "-")}`);
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const input = Buffer.from(`${entries.map((entry) => entry.oid).join("\n")}\n`, "ascii");
    const canonical = selfTestGit(repo, ["cat-file", "--batch-check"], input);
    selfTestExpectGate(repo, "index", 2, reason, { batchCheckBuffer: mutate(Buffer.from(canonical)) });
  });
  const rewriteBatchCheckLine = (bytes, lineIndex, rewrite) => {
    const lines = bytes.toString("ascii").slice(0, -1).split("\n");
    lines[lineIndex] = rewrite(lines[lineIndex]);
    return Buffer.from(`${lines.join("\n")}\n`, "ascii");
  };
  addBatchCheckMutant("wrong-oid", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) =>
    `${line[0] === "0" ? "1" : "0"}${line.slice(1)}`), "malformed-cat-file-batch-check-header");
  addBatchCheckMutant("missing-record", (bytes) => Buffer.from(`${bytes.toString("ascii").split("\n").slice(1, -1).join("\n")}\n`, "ascii"),
    "malformed-cat-file-batch-check-framing");
  addBatchCheckMutant("extra-record", (bytes) => Buffer.concat([bytes, bytes.subarray(0, bytes.indexOf(0x0a) + 1)]),
    "malformed-cat-file-batch-check-trailing-data");
  addBatchCheckMutant("reordered-oid", (bytes) => {
    const lines = bytes.toString("ascii").slice(0, -1).split("\n");
    [lines[0], lines[1]] = [lines[1], lines[0]];
    return Buffer.from(`${lines.join("\n")}\n`, "ascii");
  }, "malformed-cat-file-batch-check-header");
  addBatchCheckMutant("non-blob", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) => line.replace(" blob ", " tree ")),
    "malformed-cat-file-batch-check-header");
  addBatchCheckMutant("leading-zero-size", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) => line.replace(/ (\d+)$/, " 0$1")),
    "malformed-cat-file-batch-check-header");
  addBatchCheckMutant("negative-size", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) => line.replace(/ (\d+)$/, " -$1")),
    "malformed-cat-file-batch-check-header");
  addBatchCheckMutant("unsafe-size", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) => line.replace(/ (\d+)$/, " 9007199254740992")),
    "malformed-cat-file-batch-check-size");
  addBatchCheckMutant("missing-final-lf", (bytes) => bytes.subarray(0, bytes.length - 1),
    "malformed-cat-file-batch-check-framing");
  addBatchCheckMutant("trailing-data", (bytes) => Buffer.concat([bytes, Buffer.from("x")]),
    "malformed-cat-file-batch-check-trailing-data");
  addBatchCheckMutant("high-bit-header", (bytes) => {
    bytes[0] |= 0x80;
    return bytes;
  }, "non-ascii-cat-file-batch-check-header");
  addBatchCheckMutant("body-size-mismatch", (bytes) => rewriteBatchCheckLine(bytes, 0, (line) =>
    line.replace(/ (\d+)$/, (_match, size) => ` ${Number(size) + 1}`)), "cat-file-size-mismatch");
  addBatchCheckMutant("safe-arithmetic-overflow", (bytes) => {
    const lines = bytes.toString("ascii").slice(0, -1).split("\n").map((line) =>
      line.replace(/ (\d+)$/, ` ${Number.MAX_SAFE_INTEGER}`));
    return Buffer.from(`${lines.join("\n")}\n`, "ascii");
  }, "cat-file-batch-size-overflow");
  add("batch-check child failure is distinct", () => {
    const repo = selfTestCreateRepo(tempParent, "batch-check-child-error");
    selfTestExpectGate(repo, "index", 2, "git-child-error-cat-file-batch-check", { gitFailure: "cat-file-batch-check" });
  });
  add("body cat-file child failure remains distinct", () => {
    const repo = selfTestCreateRepo(tempParent, "batch-body-child-error");
    selfTestExpectGate(repo, "index", 2, "git-child-error-cat-file", { gitFailure: "cat-file" });
  });
  add("native Unicode Git filename succeeds in both modes", () => {
    const unicodePath = `caf${String.fromCodePoint(0x00e9)}.txt`;
    const repo = selfTestCreateRepo(tempParent, "unicode-name", {
      files: { [unicodePath]: Buffer.from("unicode path\n") },
    });
    selfTestExpectGate(repo, "index", 0);
    selfTestExpectGate(repo, "worktree", 0);
  });
  add("source subprocess output has exact rc stdout stderr and LF bytes", () => {
    const repo = selfTestCreateRepo(tempParent, "source-output");
    const modulePath = path.join(repo, "tests", "check_text_integrity.mjs");
    const invoke = (source) => spawnSync(process.execPath, [modulePath, "--source", source], {
      cwd: repo,
      encoding: "utf8",
      windowsHide: true,
      env: {
        ...process.env,
        GIT_OPTIONAL_LOCKS: "0",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: path.join(tempParent, "empty-gitconfig"),
        HOME: path.join(tempParent, "isolated-home"),
        USERPROFILE: path.join(tempParent, "isolated-home"),
        CODEX_IPC_ROOT: path.join(tempParent, "isolated-ipc-root"),
      },
    });
    const success = invoke("index");
    if (success.error || success.status !== 0
        || success.stdout !== "TEXT-INTEGRITY PASS source=index tracked=3\n" || success.stderr !== ""
        || !/^[\x20-\x7e]+\n$/.test(success.stdout)) {
      throw new Error(`success-status=${success.status} stdout=${asciiEscape(success.stdout)} stderr=${asciiEscape(success.stderr)}`);
    }
    writeFileSync(path.join(repo, "plain.txt"), "plain\r\n");
    const policy = invoke("worktree");
    if (policy.error || policy.status !== 1 || policy.stdout !== "" || policy.stderr.includes("\r")
        || !/^(?:[\x20-\x7e]+\n)+$/.test(policy.stderr)) {
      throw new Error(`policy-status=${policy.status} stdout=${asciiEscape(policy.stdout)} stderr=${asciiEscape(policy.stderr)}`);
    }
  });
  add("unmerged index stages fail closed", () => {
    const repo = selfTestCreateRepo(tempParent, "unmerged", { files: { "conflict.txt": Buffer.from("base\n") } });
    selfTestGit(repo, ["-c", "user.name=Self Test", "-c", "user.email=self@test.invalid", "commit", "-qm", "base"]);
    selfTestGit(repo, ["checkout", "-qb", "other"]);
    writeFileSync(path.join(repo, "conflict.txt"), "other\n");
    selfTestGit(repo, ["add", "--", "conflict.txt"]);
    selfTestGit(repo, ["-c", "user.name=Self Test", "-c", "user.email=self@test.invalid", "commit", "-qm", "other"]);
    selfTestGit(repo, ["checkout", "-q", "master"]);
    writeFileSync(path.join(repo, "conflict.txt"), "master\n");
    selfTestGit(repo, ["add", "--", "conflict.txt"]);
    selfTestGit(repo, ["-c", "user.name=Self Test", "-c", "user.email=self@test.invalid", "commit", "-qm", "master"]);
    selfTestGit(repo, ["-c", "user.name=Self Test", "-c", "user.email=self@test.invalid", "merge", "other"], undefined, 1);
    selfTestExpectGate(repo, "index", 2, "non-stage-zero");
  });
  add("intent-to-add fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "ita");
    writeFileSync(path.join(repo, "intent.txt"), "intent\n");
    selfTestGit(repo, ["add", "-N", "--", "intent.txt"]);
    selfTestExpectGate(repo, "index", 2, "intent-to-add");
  });
  add("unstaged validator policy divergence fails before index authority", () => {
    const repo = selfTestCreateRepo(tempParent, "policy-drift");
    const modulePath = path.join(repo, "tests", "check_text_integrity.mjs");
    const original = readFileSync(modulePath, "utf8");
    const mutated = original.replace(
      "const BINARY_ALLOWLIST = Object.freeze([]);",
      "const BINARY_ALLOWLIST = Object.freeze([\"plain.txt\"]);",
    );
    if (mutated === original) throw new Error("policy mutation did not apply");
    writeFileSync(modulePath, mutated);
    let scans = 0;
    const result = selfTestExpectGate(repo, "index", 2, "validator-index-divergence", {
      onScanBuffer: () => { scans += 1; },
    });
    const expected = "TXT900 source=index path=<none> byte=0 codepoint=0 reason=validator-index-divergence";
    if (result.stdout.length !== 0 || JSON.stringify(result.stderr) !== JSON.stringify([expected])) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
    if (scans !== 0) throw new Error(`scans-before-validator-identity=${scans}`);
  });
  add("zero object identity parser seam fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "zero-oid");
    const record = Buffer.from(`100644 ${"0".repeat(40)} 0\tzero.txt\0`);
    selfTestExpectGate(repo, "index", 2, "zero-object-identity", { lsFilesBuffer: record });
  });
  add("index symlink mode 120000 fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "index-link");
    const oid = selfTestGit(repo, ["hash-object", "-w", "--stdin"], Buffer.from("target\n")).toString("ascii").trim();
    selfTestGit(repo, ["update-index", "--add", "--cacheinfo", `120000,${oid},link.txt`]);
    selfTestExpectGate(repo, "index", 2, "unsupported-mode-120000");
  });
  add("index submodule mode 160000 fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "index-submodule");
    selfTestGit(repo, ["-c", "user.name=Self Test", "-c", "user.email=self@test.invalid", "commit", "-qm", "base"]);
    const oid = selfTestGit(repo, ["rev-parse", "HEAD"]).toString("ascii").trim();
    selfTestGit(repo, ["update-index", "--add", "--cacheinfo", `160000,${oid},submodule`]);
    selfTestExpectGate(repo, "index", 2, "unsupported-mode-160000");
  });
  add("staged and worktree attribute authority remain distinct", () => {
    const repo = selfTestCreateRepo(tempParent, "attr-sources", {
      binaryAllowlist: ["blob.bin"],
      attributes: "* text eol=lf\nblob.bin -text\n",
      files: { "blob.bin": Buffer.from([0xff, 0x00]) },
    });
    writeFileSync(path.join(repo, ".gitattributes"), "* text eol=lf\nblob.bin text\n");
    selfTestExpectGate(repo, "index", 0);
    selfTestExpectGate(repo, "worktree", 2, "binary-attribute-set");
  });
  add("index and worktree byte authority remain distinct", () => {
    const repo = selfTestCreateRepo(tempParent, "byte-sources");
    writeFileSync(path.join(repo, "plain.txt"), "plain\r\n");
    selfTestExpectGate(repo, "index", 0);
    selfTestExpectGate(repo, "worktree", 1, "TXT003");
  });
  add("missing tracked worktree path fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "missing-file");
    unlinkSync(path.join(repo, "plain.txt"));
    selfTestExpectGate(repo, "worktree", 2, "missing-segment");
  });
  add("directory terminal injected lstat seam fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "directory-seam");
    selfTestExpectGate(repo, "worktree", 2, "nonregular-terminal", { pathKind: { "plain.txt": "directory" } });
  });
  add("native intermediate link or junction fails closed when constructible", () => {
    const repo = selfTestCreateRepo(tempParent, "native-link", { files: { "linked/file.txt": Buffer.from("linked\n") } });
    const linked = path.join(repo, "linked");
    const target = path.join(repo, "target");
    renameSync(linked, target);
    let nativeCreated = false;
    try {
      symlinkSync(target, linked, process.platform === "win32" ? "junction" : "dir");
      nativeCreated = true;
    } catch (error) {
      if (!["EPERM", "EACCES", "ENOTSUP"].includes(error.code)) throw error;
    }
    if (nativeCreated) selfTestExpectGate(repo, "worktree", 2, "redirected-segment");
  });
  for (const segment of ["<root>", "linked", "plain.txt"]) {
    add(`injected ${segment} Dirent reparse classifier fails closed`, () => {
      const options = segment === "linked" ? { files: { "linked/file.txt": Buffer.from("linked\n") } } : {};
      const repo = selfTestCreateRepo(tempParent, `reparse-${segment.replace(/[^a-z]/gi, "root")}`, options);
      selfTestExpectGate(repo, "worktree", 2, "redirected-segment", { direntKind: { [segment]: "reparse" } });
    });
  }
  add("worktree volume root anchor fails closed before acquisition", () => {
    const anchor = path.parse(tempParent).root;
    expectInfrastructure(
      () => readWorktreeFile(anchor, "plain.txt", {}),
      "unsupported-worktree-root-anchor",
    );
  });
  add("worktree exact-case mismatch fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "case-mismatch", { files: { "Case.txt": Buffer.from("case\n") } });
    renameSync(path.join(repo, "Case.txt"), path.join(repo, "case-hop.txt"));
    renameSync(path.join(repo, "case-hop.txt"), path.join(repo, "case.txt"));
    selfTestExpectGate(repo, "worktree", 2, "worktree-case-mismatch");
  });
  add("index acquisition rejects parent and absolute paths", () => {
    const repo = selfTestCreateRepo(tempParent, "path-escapes");
    const oid = "1".repeat(40);
    for (const badPath of ["../escape.txt", "/absolute.txt", "C:drive.txt"]) {
      selfTestExpectGate(repo, "index", 2, "malformed-index-path", {
        lsFilesBuffer: Buffer.from(`100644 ${oid} 0\t${badPath}\0`),
      });
    }
  });
  add("worktree sibling-prefix realpath escape seam fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "realpath-escape");
    const sibling = `${repo}-sibling`;
    selfTestExpectGate(repo, "worktree", 2, "worktree-realpath-escape", {
      realpath: { "plain.txt": path.join(sibling, "plain.txt") },
    });
  });
  add("worktree nonregular root and intermediate seams fail closed", () => {
    const rootRepo = selfTestCreateRepo(tempParent, "root-nonregular");
    selfTestExpectGate(rootRepo, "worktree", 2, "nonregular-worktree-root", {
      pathKind: { "<root>": "file" },
    });
    const intermediateRepo = selfTestCreateRepo(tempParent, "intermediate-nonregular", {
      files: { "linked/file.txt": Buffer.from("linked\n") },
    });
    selfTestExpectGate(intermediateRepo, "worktree", 2, "nonregular-intermediate", {
      pathKind: { linked: "file" },
    });
  });
  add("worktree realpath failure seam fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "realpath-failure");
    selfTestExpectGate(repo, "worktree", 2, "worktree-realpath-failure", {
      realpathFailure: "plain.txt",
    });
  });
  add("acquired special-character path renders one ASCII physical line", () => {
    const repo = selfTestCreateRepo(tempParent, "special-path");
    const specialPath = `caf${String.fromCodePoint(0x00e9)}\tline\nslash\\name.txt`;
    const records = [
      { mode: "100644", oid: "1".repeat(40), path: specialPath },
      { mode: "100644", oid: "2".repeat(40), path: "tests/check_text_integrity.mjs" },
    ];
    const indexBuffer = Buffer.concat(records.map((entry) => Buffer.concat([
      Buffer.from(`${entry.mode} ${entry.oid} 0\t`, "ascii"), Buffer.from(entry.path, "utf8"), Buffer.from([0]),
    ])));
    const sorted = parseIndexEntries(indexBuffer);
    const moduleBytes = readFileSync(path.join(repo, "tests", "check_text_integrity.mjs"));
    const bytesByOid = new Map(sorted.map((entry) => [
      entry.oid, entry.path === specialPath ? Buffer.from("bad\r\n") : moduleBytes,
    ]));
    const catFileBuffer = ({ input }) => {
      const oid = input.toString("ascii").trim();
      const bytes = bytesByOid.get(oid);
      if (!bytes) throw new Error(`unexpected-oid=${oid}`);
      return Buffer.concat([
        Buffer.from(`${oid} blob ${bytes.length}\n`, "ascii"), bytes, Buffer.from("\n"),
      ]);
    };
    const batchCheckBuffer = Buffer.concat(sorted.map((entry) => {
      const bytes = entry.path === specialPath ? Buffer.from("bad\r\n") : moduleBytes;
      return Buffer.from(`${entry.oid} blob ${bytes.length}\n`, "ascii");
    }));
    const attributeFields = sorted.flatMap((entry) =>
      [entry.path, "text", "unspecified", entry.path, "eol", "unspecified"]);
    const result = selfTestExpectGate(repo, "index", 1, "TXT003", {
      lsFilesBuffer: indexBuffer,
      batchCheckBuffer,
      catFileBuffer,
      attributeBuffer: Buffer.from(`${attributeFields.join("\0")}\0`, "utf8"),
    });
    if (result.stderr.length !== 1 || !/^[\x20-\x7e]+$/.test(result.stderr[0])
        || !result.stderr[0].includes("\\u00e9") || !result.stderr[0].includes("\\u0009")
        || !result.stderr[0].includes("\\u000a") || !result.stderr[0].includes("\\\\name")) {
      throw new Error(`stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("empty tracked selection fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "empty-selection");
    selfTestExpectGate(repo, "index", 2, "empty-tracked-selection", { lsFilesBuffer: Buffer.alloc(0) });
  });

  const binaryCases = [
    ["duplicate", ["blob.bin", "blob.bin"], "* text eol=lf\nblob.bin -text\n", "binary-allowlist-duplicate"],
    ["nonexistent", ["absent.bin"], "* text eol=lf\nabsent.bin -text\n", "binary-allowlist-nonexistent"],
    ["unspecified", ["blob.bin"], ".gitattributes text\n*.mjs text\n", "binary-attribute-unspecified"],
    ["set", ["blob.bin"], "* text eol=lf\nblob.bin text\n", "binary-attribute-set"],
    ["auto", ["blob.bin"], "* text eol=lf\nblob.bin text=auto\n", "binary-attribute-auto"],
    ["custom", ["blob.bin"], "* text eol=lf\nblob.bin text=custom\n", "binary-attribute-custom"],
  ];
  add("binary allowlist exact regular minus-text succeeds", () => {
    const repo = selfTestCreateRepo(tempParent, "binary-ok", {
      binaryAllowlist: ["blob.bin"],
      attributes: "* text eol=lf\nblob.bin -text\n",
      files: { "blob.bin": Buffer.from([0xff, 0x00]) },
    });
    selfTestExpectGate(repo, "index", 0);
    selfTestExpectGate(repo, "worktree", 0);
  });
  for (const [name, allowlist, attributes, reason] of binaryCases) {
    add(`binary allowlist ${name} misuse fails closed`, () => {
      const repo = selfTestCreateRepo(tempParent, `binary-${name}`, {
        binaryAllowlist: allowlist,
        attributes,
        files: { "blob.bin": Buffer.from([0xff, 0x00]) },
      });
      selfTestExpectGate(repo, "index", 2, reason);
    });
  }
  add("binary allowlist directory terminal fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "binary-directory", {
      binaryAllowlist: ["blob.bin"], attributes: "* text eol=lf\nblob.bin -text\n",
      files: { "blob.bin": Buffer.from([0xff]) },
    });
    unlinkSync(path.join(repo, "blob.bin"));
    mkdirSync(path.join(repo, "blob.bin"));
    selfTestExpectGate(repo, "worktree", 2, "nonregular-terminal");
  });
  add("binary allowlist index symlink fails closed", () => {
    const repo = selfTestCreateRepo(tempParent, "binary-link", {
      binaryAllowlist: ["blob.bin"], attributes: "* text eol=lf\nblob.bin -text\n",
      files: { "blob.bin": Buffer.from([0xff]) },
    });
    const oid = selfTestGit(repo, ["hash-object", "-w", "--stdin"], Buffer.from("target\n")).toString("ascii").trim();
    selfTestGit(repo, ["update-index", "--cacheinfo", `120000,${oid},blob.bin`]);
    selfTestExpectGate(repo, "index", 2, "unsupported-mode-120000");
  });

  const globalException = {
    signatureId: "MJ001",
    path: "a.txt",
    line: 1,
    occurrence: 1,
    lineSha256: SELF_TEST_MJ001_LINE_SHA256,
    rationale: "global self-test",
  };
  add("global exception validates once and suppresses exact target", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-ok", {
      exceptions: [globalException],
      files: { "a.txt": signatureBytes, "b.txt": Buffer.from("clean\n") },
    });
    selfTestExpectGate(repo, "index", 0);
  });
  add("global exception does not suppress same signature in another file", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-other", {
      exceptions: [globalException], files: { "a.txt": signatureBytes, "b.txt": signatureBytes },
    });
    const result = selfTestExpectGate(repo, "index", 1, "TXT006");
    if (result.stderr.filter((line) => line.startsWith("TXT006 ")).length !== 1
        || !result.stderr[0].includes("path=b.txt")) throw new Error(`stderr=${asciiEscape(result.stderr.join("|"))}`);
  });
  add("global stale line hash emits one TXT007 and leaves one TXT006", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-stale", {
      exceptions: [{ ...globalException, lineSha256: "0".repeat(64) }],
      files: { "a.txt": signatureBytes },
    });
    const result = selfTestExpectGate(repo, "index", 1, "stale-line-hash");
    const expected = [
      "TXT006 source=index path=a.txt byte=0 codepoint=0 reason=mojibake-MJ001",
      "TXT007 source=index path=a.txt byte=0 codepoint=0 reason=stale-line-hash",
    ];
    if (result.stdout.length !== 0 || JSON.stringify(result.stderr) !== JSON.stringify(expected)) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("global nonexistent exception emits one TXT007", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-missing", {
      exceptions: [{ ...globalException, path: "absent.txt" }], files: { "a.txt": signatureBytes },
    });
    const result = selfTestExpectGate(repo, "index", 1, "nonexistent-path");
    const expected = [
      "TXT006 source=index path=a.txt byte=0 codepoint=0 reason=mojibake-MJ001",
      "TXT007 source=index path=absent.txt byte=0 codepoint=0 reason=nonexistent-path",
    ];
    if (result.stdout.length !== 0 || JSON.stringify(result.stderr) !== JSON.stringify(expected)) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("global binary exception target is rejected once", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-binary", {
      binaryAllowlist: ["a.txt"],
      exceptions: [globalException],
      attributes: "* text eol=lf\na.txt -text\n",
      files: { "a.txt": signatureBytes, "b.txt": Buffer.from("clean\n") },
    });
    const result = selfTestExpectGate(repo, "index", 1, "binary-exception-target");
    const expected = [
      "TXT007 source=index path=a.txt byte=0 codepoint=0 reason=binary-exception-target",
    ];
    if (result.stdout.length !== 0 || JSON.stringify(result.stderr) !== JSON.stringify(expected)) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("global duplicate exception identity emits one TXT007", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-duplicate", {
      exceptions: [globalException, { ...globalException, rationale: "other" }],
      files: { "a.txt": signatureBytes },
    });
    const result = selfTestExpectGate(repo, "index", 1, "duplicate-exception");
    const expected = [
      "TXT006 source=index path=a.txt byte=0 codepoint=0 reason=mojibake-MJ001",
      "TXT007 source=index path=a.txt byte=0 codepoint=0 reason=duplicate-exception",
    ];
    if (result.stdout.length !== 0 || JSON.stringify(result.stderr) !== JSON.stringify(expected)) {
      throw new Error(`stdout=${asciiEscape(result.stdout.join("|"))} stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("global unused exception sweep runs once", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-unused", {
      exceptions: [globalException], files: { "a.txt": Buffer.from("clean\n") },
    });
    const result = selfTestExpectGate(repo, "index", 1, "no-matching-finding");
    if (result.stderr.filter((line) => line.includes("no-matching-finding")).length !== 1) {
      throw new Error(`stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("global unused sweep survives target decode failure", () => {
    const repo = selfTestCreateRepo(tempParent, "exception-invalid-utf8", {
      exceptions: [globalException], files: { "a.txt": Buffer.from([0xff, 0x0a]) },
    });
    const result = selfTestExpectGate(repo, "index", 1, "no-matching-finding");
    if (result.stderr.filter((line) => line.includes("no-matching-finding")).length !== 1
        || result.stderr.filter((line) => line.startsWith("TXT001 ")).length !== 1) {
      throw new Error(`stderr=${asciiEscape(result.stderr.join("|"))}`);
    }
  });
  add("repository findings combine and sort once", () => {
    const repo = selfTestCreateRepo(tempParent, "combined-sort", {
      files: { "b.txt": Buffer.from("b\r\n"), "a.txt": Buffer.from("a\r\n") },
    });
    const result = selfTestExpectGate(repo, "worktree", 1, "TXT003");
    const paths = result.stderr.filter((line) => line.startsWith("TXT003 ")).map((line) =>
      line.match(/ path=([^ ]+)/)?.[1]);
    if (JSON.stringify(paths) !== JSON.stringify(["a.txt", "b.txt"])) {
      throw new Error(`paths=${JSON.stringify(paths)}`);
    }
  });
  add("strict index parser rejects malformed framing and duplicate paths", () => {
    const repo = selfTestCreateRepo(tempParent, "parser-malformed");
    selfTestExpectGate(repo, "index", 2, "malformed-index-framing", {
      lsFilesBuffer: Buffer.from(`100644 ${"1".repeat(40)} 0\tplain.txt`),
    });
    const record = Buffer.from(`100644 ${"1".repeat(40)} 0\tplain.txt\0`);
    selfTestExpectGate(repo, "index", 2, "duplicate-index-path", {
      lsFilesBuffer: Buffer.concat([record, record]),
    });
  });
  add("strict Git path and attribute parsers reject malformed raw records", () => {
    const oid = "1".repeat(40);
    expectInfrastructure(() => parseIndexEntries(Buffer.concat([
      Buffer.from(`100644 ${oid} 0\t`, "ascii"), Buffer.from([0xff, 0]),
    ])), "invalid-utf8-index-path");
    expectInfrastructure(() => parsePathSet(Buffer.from([0xff, 0]), "ita-visible"),
      "invalid-utf8-ita-visible-path");
    expectInfrastructure(() => parsePathSet(Buffer.from("same\0same\0"), "ita-visible"),
      "duplicate-ita-visible-path");
    const fields = ["plain.txt", "text", "set", "plain.txt", "eol", "lf"];
    const encoded = (items) => Buffer.from(`${items.join("\0")}\0`, "utf8");
    expectInfrastructure(() => parseAttributes(encoded(fields).subarray(0, encoded(fields).length - 1), ["plain.txt"]),
      "malformed-attribute-framing");
    expectInfrastructure(() => parseAttributes(encoded(["plain.txt", "eol", "set", "plain.txt", "text", "lf"]),
      ["plain.txt"]), "malformed-attribute-response");
    expectInfrastructure(() => parseAttributes(encoded(["other.txt", ...fields.slice(1)]), ["plain.txt"]),
      "malformed-attribute-response");
    const invalidValue = Buffer.concat([
      Buffer.from("plain.txt\0text\0", "utf8"), Buffer.from([0xff, 0]),
      Buffer.from("plain.txt\0eol\0lf\0", "utf8"),
    ]);
    expectInfrastructure(() => parseAttributes(invalidValue, ["plain.txt"]), "invalid-utf8-attribute-value");
  });
  add("strict cat-file parser rejects header size truncation and trailing mutants", () => {
    const repo = selfTestCreateRepo(tempParent, "cat-mutants");
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const entry = entries.find((candidate) => candidate.path === "tests/check_text_integrity.mjs");
    if (!entry) throw new Error("missing-validator-entry");
    const input = Buffer.from(`${entry.oid}\n`, "ascii");
    const batch = selfTestGit(repo, ["cat-file", "--batch"], input);
    const newline = batch.indexOf(0x0a);
    const header = batch.subarray(0, newline).toString("latin1");
    const [headerOid, , size] = header.split(" ");
    const withHeader = (replacement) => Buffer.concat([Buffer.from(`${replacement}\n`, "ascii"), batch.subarray(newline + 1)]);
    const wrongOid = `${headerOid[0] === "0" ? "1" : "0"}${headerOid.slice(1)} blob ${size}`;
    selfTestExpectGate(repo, "index", 2, "malformed-cat-file-header", { catFileBuffer: withHeader(wrongOid) });
    selfTestExpectGate(repo, "index", 2, "malformed-cat-file-header", {
      catFileBuffer: withHeader(`${headerOid} tree ${size}`),
    });
    selfTestExpectGate(repo, "index", 2, "cat-file-size-mismatch", {
      catFileBuffer: withHeader(`${headerOid} blob ${Number(size) + 1}`),
    });
    selfTestExpectGate(repo, "index", 2, "malformed-cat-file-framing", {
      catFileBuffer: batch.subarray(0, batch.length - 1),
    });
    selfTestExpectGate(repo, "index", 2, "malformed-cat-file-trailing-data", {
      catFileBuffer: Buffer.concat([batch, Buffer.from("x")]),
    });
  });
  add("strict ITA NUL parser rejects malformed framing", () => {
    const repo = selfTestCreateRepo(tempParent, "ita-framing");
    selfTestExpectGate(repo, "index", 2, "malformed-ita-visible-framing", {
      itaVisibleBuffer: Buffer.from("plain.txt"),
    });
  });
  add("strict index parser rejects high-bit header bytes", () => {
    const repo = selfTestCreateRepo(tempParent, "parser-high-bit");
    const staged = Buffer.from(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    staged[0] |= 0x80;
    selfTestExpectGate(repo, "index", 2, "non-ascii-index-header", { lsFilesBuffer: staged });
  });
  add("strict cat-file parser rejects high-bit header bytes", () => {
    const repo = selfTestCreateRepo(tempParent, "cat-high-bit");
    const entries = parseIndexEntries(selfTestGit(repo, ["ls-files", "--stage", "-z"]));
    const entry = entries.find((candidate) => candidate.path === "tests/check_text_integrity.mjs");
    if (!entry) throw new Error("missing-validator-entry");
    const input = Buffer.from(`${entry.oid}\n`, "ascii");
    const batch = Buffer.from(selfTestGit(repo, ["cat-file", "--batch"], input));
    batch[0] |= 0x80;
    selfTestExpectGate(repo, "index", 2, "non-ascii-cat-file-header", { catFileBuffer: batch });
  });
  add("Git child error fails closed without summary", () => {
    const repo = selfTestCreateRepo(tempParent, "git-error");
    selfTestExpectGate(repo, "index", 2, "git-child-error", { gitFailure: "ls-files" });
  });

  let passed = 0;
  let failed = 0;
  let cleanupFailure = null;
  try {
    for (const test of tests) {
      try {
        test.run();
        passed += 1;
        console.log(`PASS ${test.name}`);
      } catch (error) {
        failed += 1;
        console.error(`FAIL ${test.name}: ${asciiEscape(error.message)}`);
      }
    }
  } finally {
    for (const registered of [...SELF_TEST_TEMP_REGISTRY].reverse()) {
      if (path.dirname(registered) !== tempParent) {
        cleanupFailure = `unsafe-temp-path=${asciiEscape(registered)}`;
        continue;
      }
      if (existsSync(registered)) rmSync(registered, { recursive: true, force: true });
    }
    SELF_TEST_TEMP_REGISTRY.length = 0;
    const tempInventoryAfter = readdirSync(tempParent).sort();
    if (JSON.stringify(tempInventoryAfter) !== JSON.stringify(tempInventoryBefore)) {
      cleanupFailure = `temp-inventory before=${JSON.stringify(tempInventoryBefore)} after=${JSON.stringify(tempInventoryAfter)}`;
    }
    if (path.resolve(path.dirname(tempParent)) !== path.resolve(tmpdir())) {
      cleanupFailure = `unsafe-temp-parent=${asciiEscape(tempParent)}`;
    } else {
      rmSync(tempParent, { recursive: true, force: true });
    }
  }
  if (cleanupFailure !== null) {
    failed += 1;
    console.error(`FAIL temporary repository cleanup: ${cleanupFailure}`);
  } else {
    passed += 1;
    console.log("PASS temporary repository cleanup inventory restored");
  }
  if (failed > 0) {
    console.error(`SELF-TEST FAIL passed=${passed} failed=${failed}`);
    return 1;
  }
  console.log(`SELF-TEST PASS count=${passed}`);
  return 0;
}

function main(argv, seams = {}) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`TXT900 source=cli path=<none> byte=0 codepoint=0 reason=${asciiEscape(error.message)}`);
    return 2;
  }
  if (options.mode === "self-test") return runSelfTests();
  return runRepositoryGate(options.source, seams);
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = main(process.argv.slice(2));
}
