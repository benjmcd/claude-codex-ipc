#!/usr/bin/env node

import { spawnSync } from "node:child_process";
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
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { scanTextBuffer } from "./check_text_integrity.mjs";

const MODULE_PATH = fileURLToPath(import.meta.url);
const SELF_TEST_TEMP_REGISTRY = [];

const DIRECT_DOCS = Object.freeze([
  "docs/ARCHITECTURE.md",
  "docs/COMPATIBILITY.md",
  "docs/INSTALL.md",
  "docs/TROUBLESHOOTING.md",
]);
const ROOT_DOCS = Object.freeze([
  "README.md",
  "CONTRIBUTING.md",
  "CHANGELOG.md",
  "SECURITY.md",
  "LICENSE.md",
]);
const BUNDLED_DOCS = Object.freeze([
  "skills/ipc/SKILL.md",
  "skills/ipc/references/architecture.md",
  "skills/ipc/references/handoff-template.md",
  "skills/ipc/references/security-model.md",
  "skills/ipc/references/troubleshooting.md",
  "skills/ipc/examples/example-dispatch-payload.md",
  "skills/ipc/examples/quickstart.md",
]);
const INSTALLED_DOCS = Object.freeze(BUNDLED_DOCS.map((item) => item.slice("skills/ipc/".length)));
const EXPECTED_BEHAVIORAL_SUITES = Object.freeze([
  "test_autoload_matrix.sh",
  "test_git_context_bound.sh",
  "test_ipc.sh",
  "test_ipc_wait.sh",
  "test_payload_mirror_parity.sh",
  "test_reply_harvest.sh",
  "test_reply_view.sh",
  "test_retention_sweep.sh",
  "test_rollout_reader.sh",
  "test_router_contract.sh",
  "test_session_inspect.sh",
  "test_uninstall_guard.sh",
  "test_wait_contract.sh",
]);
const MARKERS = Object.freeze([
  "<!-- IPC-DOCS:DIRECT:BEGIN -->",
  "<!-- IPC-DOCS:DIRECT:END -->",
  "<!-- IPC-DOCS:ROOT:BEGIN -->",
  "<!-- IPC-DOCS:ROOT:END -->",
  "<!-- IPC-DOCS:BUNDLED:BEGIN -->",
  "<!-- IPC-DOCS:BUNDLED:END -->",
]);
const WAITER_FILES = Object.freeze([
  "README.md",
  "docs/TROUBLESHOOTING.md",
  "skills/ipc/SKILL.md",
  "skills/ipc/examples/quickstart.md",
  "skills/ipc/references/troubleshooting.md",
]);
const FIRST_USE_FILES = Object.freeze([
  "README.md",
  "skills/ipc/SKILL.md",
  "skills/ipc/examples/quickstart.md",
  "skills/ipc/references/troubleshooting.md",
]);
const MOJIBAKE_GUIDANCE_FILES = Object.freeze([
  "CONTRIBUTING.md",
  "docs/TROUBLESHOOTING.md",
  "skills/ipc/references/troubleshooting.md",
]);
const REQUIRED_NONEMPTY_SECTIONS = Object.freeze([
  { file: "README.md", titles: ["Status"], required: true },
  { file: "README.md", titles: ["Install"], required: true },
  { file: "README.md", titles: ["Quickstart"], required: true },
  { file: "README.md", titles: ["Primary wrapper variables", "Configuration (all env vars)", "Configuration (all env vars; none required for file-drop)"], required: true },
  { file: "README.md", titles: ["Testing"], required: true },
  { file: "docs/ARCHITECTURE.md", titles: ["Inspection surfaces (read-only)", "Inspection and validation surfaces (all read-only)"], required: true },
  { file: "docs/ARCHITECTURE.md", titles: ["Authorized write proof"], required: false },
  { file: "docs/COMPATIBILITY.md", titles: ["Current feature matrix"], required: false },
  { file: "docs/COMPATIBILITY.md", titles: ["Dated historical evidence, not current certification", "Host-identity ledger"], required: true },
]);
const REQUIRED_OPERATIONAL_FILES = Object.freeze([
  ...new Set([
    ...DIRECT_DOCS,
    ...ROOT_DOCS,
    ...BUNDLED_DOCS,
    "docs/README.md",
    ".claude-plugin/plugin.json",
    ".github/workflows/test.yml",
    "skills/ipc/scripts/handoff_to_codex.sh",
    "tests/run_release_gates.sh",
  ]),
]);
const NEW_MARKER_SENTENCE = "resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.";
const INSTALL_SESSION_SENTENCES = Object.freeze([
  "`claude --plugin-dir /path/to/claude-codex-ipc` is a session-local plugin-development launch whose invocation is `/codex-ipc:ipc` for that Claude session.",
  "The persistent supported local path is the standalone installer, invoked as `/ipc` after a new or restarted session.",
]);
const FORCE_DISCLOSURE_SENTENCES = Object.freeze([
  "`--force` / `-Force` removes the entire existing target before copying.",
  "Local modifications and unlisted residue are not preserved.",
  "There is no automatic backup, transaction, or rollback.",
  "Run dry-run first.",
  "Preserve the current target outside the target path or retain a known source ref before force.",
  "Rollback means installing from that preserved or known source, not an automatic command.",
  "`CODEX_IPC_ROOT` transport files are separate and neither migrated nor cleaned by installer replacement.",
]);
const FIRST_USE_WARNING_SENTENCES = Object.freeze([
  "Task envelopes and replies are plaintext and can be read and modified by same-user processes; task text must not contain secrets.",
  "Keep-only retention may retain them indefinitely.",
  "Pruning reduces ordinary accumulation but is not confidentiality or secure deletion.",
  "Backups, sync tools, snapshots, and filesystem recovery may retain deleted content.",
]);

class InfrastructureError extends Error {}

function failInfrastructure(reason) {
  throw new InfrastructureError(reason);
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

function finding(id, pathName, line, reason) {
  return { id, path: pathName.split(path.sep).join("/"), line, reason };
}

function findingKey(item) {
  if (item.id?.startsWith("TXT")) {
    return `${item.id}\0${item.source}\0${item.path}\0${item.byteOffset}\0${item.codePointOffset}\0${item.reason}`;
  }
  return `${item.id}\0${item.path}\0${item.line}\0${item.reason}`;
}

function sortAndDedupe(findings) {
  const unique = new Map();
  for (const item of findings) unique.set(findingKey(item), item);
  const compareText = (left, right) => left < right ? -1 : left > right ? 1 : 0;
  return [...unique.values()].sort((left, right) => {
    const byPath = compareText(left.path, right.path);
    if (byPath !== 0) return byPath;
    if (left.id?.startsWith("TXT") || right.id?.startsWith("TXT")) {
      return compareText(left.source || "", right.source || "")
        || (left.byteOffset ?? 0) - (right.byteOffset ?? 0)
        || (left.codePointOffset ?? 0) - (right.codePointOffset ?? 0)
        || compareText(left.id, right.id)
        || compareText(left.reason, right.reason);
    }
    return (left.line ?? 0) - (right.line ?? 0)
      || compareText(left.id, right.id)
      || compareText(left.reason, right.reason);
  });
}

function formatFinding(item) {
  if (item.id?.startsWith("TXT")) {
    return `${item.id} source=${asciiEscape(item.source)} path=${asciiEscape(item.path)} byte=${item.byteOffset} codepoint=${item.codePointOffset} reason=${asciiEscape(item.reason)}`;
  }
  return `${item.id} path=${asciiEscape(item.path)} line=${item.line} reason=${asciiEscape(item.reason)}`;
}

function parseArgs(argv) {
  if (argv.length === 0) return { mode: "repository" };
  if (argv.length === 1 && argv[0] === "--self-test") return { mode: "self-test" };
  if (argv.length === 2 && argv[0] === "--installed-root"
      && argv[1].trim() !== "" && !argv[1].includes("\0")) return { mode: "installed-root", root: argv[1] };
  throw new Error("usage-exactly-no-args-or-self-test-or-installed-root-path");
}

function lineNumberAt(text, index) {
  if (index < 0) return 0;
  return text.slice(0, index).split("\n").length;
}

function isEscaped(text, index) {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && text[cursor] === "\\"; cursor -= 1) slashes += 1;
  return slashes % 2 === 1;
}

function maskMarkdownCode(text, metrics = null) {
  const lines = text.split("\n");
  const masked = [];
  let fence = null;
  for (const line of lines) {
    if (metrics) metrics.work += line.length + 1;
    if (fence !== null) {
      const closer = new RegExp(`^ {0,3}${fence.character === "`" ? "`" : "~"}{${fence.length},}[ \\t]*$`);
      if (closer.test(line)) fence = null;
      masked.push(" ".repeat(line.length));
      continue;
    }
    const opener = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (opener && !(opener[1][0] === "`" && opener[2].includes("`"))) {
      fence = { character: opener[1][0], length: opener[1].length };
      masked.push(" ".repeat(line.length));
      continue;
    }
    const chars = line.split("");
    let cursor = 0;
    while (cursor < line.length) {
      if (line[cursor] !== "`" || isEscaped(line, cursor)) { cursor += 1; continue; }
      let endRun = cursor + 1;
      while (line[endRun] === "`") endRun += 1;
      const runLength = endRun - cursor;
      let closerAt = endRun;
      while (closerAt < line.length) {
        closerAt = line.indexOf("`".repeat(runLength), closerAt);
        if (closerAt < 0) break;
        if (line[closerAt - 1] !== "`" && line[closerAt + runLength] !== "`") break;
        closerAt += runLength;
      }
      if (closerAt < 0) { cursor = endRun; continue; }
      for (let index = cursor; index < closerAt + runLength; index += 1) chars[index] = " ";
      cursor = closerAt + runLength;
    }
    masked.push(chars.join(""));
  }
  return masked;
}

function closingBracketMap(line, metrics = null) {
  const stack = [];
  const closes = new Map();
  const escapedAt = new Uint8Array(line.length);
  let precedingBackslashes = 0;
  for (let index = 0; index < line.length; index += 1) {
    if (metrics) metrics.work += 1;
    const escaped = precedingBackslashes % 2 === 1;
    escapedAt[index] = escaped ? 1 : 0;
    if (metrics) metrics.escapeUnits = (metrics.escapeUnits || 0) + 1;
    if (line[index] === "\\") {
      precedingBackslashes += 1;
      continue;
    }
    precedingBackslashes = 0;
    if (escapedAt[index]) continue;
    if (line[index] === "[") stack.push(index);
    else if (line[index] === "]" && stack.length > 0) closes.set(stack.pop(), index);
  }
  return closes;
}

function parseInlineCandidate(line, start, closes, metrics = null) {
  let cursor = start;
  if (line[cursor] === "!") cursor += 1;
  if (line[cursor] !== "[") return null;
  const labelStart = cursor;
  const labelEnd = closes.get(labelStart);
  if (labelEnd === undefined || line[labelEnd + 1] !== "(") return null;
  let invalidEscape = false;
  cursor = labelStart + 1;
  while (cursor < labelEnd) {
    if (metrics) metrics.work += 1;
    if (line[cursor] === "\\") {
      if (cursor + 1 >= line.length || !"\\[]!()".includes(line[cursor + 1])) invalidEscape = true;
      cursor += 2;
      continue;
    }
    cursor += 1;
  }
  cursor = labelEnd + 2;
  let closeParen;
  if (line[cursor] === "<") {
    const angleEnd = line.indexOf(">", cursor + 1);
    if (angleEnd < 0) return { start, end: line.length, invalid: true, reason: "malformed-inline-link" };
    const tail = line.slice(angleEnd + 1);
    const tailMatch = tail.match(/^(?:[ \t]+"([^"]*)")?\)/);
    if (!tailMatch) return { start, end: line.length, invalid: true, reason: "unsupported-destination-grammar" };
    closeParen = angleEnd + 1 + tailMatch[0].length - 1;
  } else {
    closeParen = line.indexOf(")", cursor);
  }
  if (closeParen < 0) return { start, end: line.length, invalid: true, reason: "malformed-inline-link" };
  const content = line.slice(cursor, closeParen);
  let destination = "";
  let title = null;
  if (content.startsWith("<")) {
    const match = content.match(/^<([^<>]*)>(?:[ \t]+"([^"]*)")?$/);
    if (!match) return { start, end: closeParen + 1, invalid: true, reason: "unsupported-destination-grammar" };
    destination = match[1];
    title = match[2] ?? null;
  } else {
    const match = content.match(/^([^\s()]*)?(?:[ \t]+"([^"]*)")?$/);
    if (!match) return { start, end: closeParen + 1, invalid: true, reason: "unsupported-destination-grammar" };
    destination = match[1] || "";
    title = match[2] ?? null;
  }
  return { start, end: closeParen + 1, destination, title, invalid: invalidEscape,
    reason: invalidEscape ? "unsupported-escape" : null };
}

function localDestinationReason(raw) {
  if (raw === "") return "empty-local-destination";
  if (/[#?\0\\]/.test(raw)) return "unsupported-local-query-fragment-or-separator";
  if (/^(?:[A-Za-z]:|\/|\\|\/\/)/.test(raw) || raw.includes(":")) return "unsupported-local-root-or-scheme";
  if (/%(?![0-9A-Fa-f]{2})/.test(raw)) return "malformed-percent-encoding";
  let decoded;
  try { decoded = decodeURIComponent(raw); } catch { return "malformed-percent-encoding"; }
  if (/[#?\0\\]/.test(decoded) || /^(?:[A-Za-z]:|\/|\\|\/\/)/.test(decoded) || decoded.includes(":")) {
    return "unsupported-decoded-local-path";
  }
  const segments = decoded.split("/");
  if (segments.some((segment) => segment === "" || segment === ".")) return "unsupported-local-segment";
  return null;
}

function validateMarkdownDocument(input) {
  const findings = [];
  const directTargetKinds = input.targetKinds || new Map();
  const targetKindCache = input.targetKindCache || new Map();
  const directCasefoldTargets = input.resolveTarget ? null
    : new Set([...directTargetKinds.keys()].map((item) => item.toLowerCase()));
  const resolveTargetKind = (resolved) => {
    if (!targetKindCache.has(resolved)) {
      targetKindCache.set(resolved, input.resolveTarget ? input.resolveTarget(resolved) : directTargetKinds.get(resolved));
    }
    return targetKindCache.get(resolved);
  };
  const maskedLines = maskMarkdownCode(input.text, input.structuralMetrics || null);
  for (let lineIndex = 0; lineIndex < maskedLines.length; lineIndex += 1) {
    const line = maskedLines[lineIndex];
    const residual = line.split("");
    const closes = closingBracketMap(line, input.structuralMetrics || null);
    let cursor = 0;
    while (cursor < line.length) {
      const bracket = line.indexOf("[", cursor);
      if (bracket < 0) break;
      if (isEscaped(line, bracket)) {
        const escapedEnd = line.indexOf(")", bracket + 1);
        if (escapedEnd >= 0) for (let index = bracket; index <= escapedEnd; index += 1) residual[index] = " ";
        cursor = bracket + 1;
        continue;
      }
      const start = bracket > 0 && line[bracket - 1] === "!" ? bracket - 1 : bracket;
      const candidate = parseInlineCandidate(line, start, closes, input.structuralMetrics || null);
      if (candidate === null) { cursor = bracket + 1; continue; }
      for (let index = candidate.start; index < candidate.end; index += 1) residual[index] = " ";
      cursor = Math.max(candidate.end, bracket + 1);
      if (candidate.invalid) {
        findings.push(finding("DQ002", input.path, lineIndex + 1, candidate.reason));
        continue;
      }
      const external = /^(?:https?|mailto):/i.test(candidate.destination);
      if (external) {
        if (input.metrics) input.metrics.links += 1;
        continue;
      }
      if (candidate.title !== null) {
        findings.push(finding("DQ002", input.path, lineIndex + 1, "local-title-unsupported"));
        continue;
      }
      const lexicalReason = localDestinationReason(candidate.destination);
      if (lexicalReason !== null) {
        findings.push(finding("DQ002", input.path, lineIndex + 1, lexicalReason));
        continue;
      }
      const decoded = decodeURIComponent(candidate.destination);
      const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(input.path), decoded));
      const boundary = input.boundary || "";
      if (resolved === ".." || resolved.startsWith("../")
          || (boundary && resolved !== boundary && !resolved.startsWith(`${boundary}/`))) {
        findings.push(finding("DQ001", input.path, lineIndex + 1, "local-target-escape"));
        continue;
      }
      const kind = resolveTargetKind(resolved);
      if (kind !== "file") {
        const caseAlias = kind === "case-mismatch"
          || (directCasefoldTargets !== null && directCasefoldTargets.has(resolved.toLowerCase()));
        const reason = caseAlias ? "local-target-case-mismatch"
          : kind === "directory" ? "local-target-nonregular"
            : kind === "redirected" ? "local-target-redirected" : "local-target-missing";
        findings.push(finding("DQ001", input.path, lineIndex + 1, reason));
      } else if (input.metrics) {
        input.metrics.links += 1;
      }
    }
    const leftover = residual.join("");
    if (/\]\(|^ {0,3}\[[^\]]+\]:|\[[^\]\n]+\]\[[^\]\n]*\]/.test(leftover)) {
      findings.push(finding("DQ002", input.path, lineIndex + 1, "unsupported-link-form"));
    }
  }
  const maskedText = maskedLines.join("\n");
  let htmlCursor = 0;
  let htmlLine = 1;
  for (const tag of maskedText.matchAll(/<(?:a|img)\b[^>]*>/gi)) {
    while (htmlCursor < tag.index) {
      if (maskedText[htmlCursor] === "\n") htmlLine += 1;
      htmlCursor += 1;
      if (input.structuralMetrics) input.structuralMetrics.htmlUnits = (input.structuralMetrics.htmlUnits || 0) + 1;
    }
    for (const attribute of tag[0].matchAll(/\b(?:href|src)\s*=\s*(?:["']([^"']+)["']|([^\s>]+))/gi)) {
      const target = attribute[1] ?? attribute[2];
      if (!/^(?:https?|mailto):/i.test(target)) {
        findings.push(finding("DQ002", input.path, htmlLine, "unsupported-local-html-link"));
      }
    }
  }
  return sortAndDedupe(findings);
}

function validateDocsIndex(text, context) {
  if (text.trim() === "") return [finding("DQ009", "docs/README.md", 0, "required-file-empty")];
  const findings = [];
  const rawLines = text.split("\n");
  const visibleLines = maskMarkdownCode(text);
  const positions = [];
  for (const marker of MARKERS) {
    const matches = [];
    rawLines.forEach((line, index) => { if (line === marker && visibleLines[index] === marker) matches.push(index); });
    if (matches.length !== 1) findings.push(finding("DQ003", "docs/README.md", matches[0] === undefined ? 0 : matches[0] + 1, "marker-cardinality"));
    positions.push(matches[0] ?? -1);
  }
  rawLines.forEach((line, index) => {
    if ((/IPC-D.?CS:/i.test(line) || line.includes("IPC-D0CS:")) && !MARKERS.includes(line)) {
      findings.push(finding("DQ003", "docs/README.md", index + 1, "marker-near-miss"));
    }
  });
  if (positions.some((item) => item < 0) || positions.some((item, index) => index > 0 && item <= positions[index - 1])) {
    findings.push(finding("DQ003", "docs/README.md", 0, "marker-order-or-nesting"));
    return sortAndDedupe(findings);
  }
  const expectedGroups = [
    context.direct.map((item) => item.slice("docs/".length)),
    context.root.map((item) => `../${item}`),
    context.bundled.map((item) => `../${item}`),
  ].map((group) => [...group].sort());
  for (let group = 0; group < 3; group += 1) {
    const start = positions[group * 2] + 1;
    const end = positions[group * 2 + 1];
    const targets = [];
    let descriptionEmpty = false;
    for (let index = start; index < end; index += 1) {
      const line = rawLines[index];
      if (line === "") continue;
      const row = line.match(/^- \[([^\]\r\n]+)\]\(([^()\s]+)\) - ([A-Z][^.!?]*\.)$/);
      if (!row) {
        findings.push(finding("DQ003", "docs/README.md", index + 1, "malformed-index-row"));
        if (/ -\s*$/.test(line)) descriptionEmpty = true;
        continue;
      }
      targets.push(row[2]);
    }
    if (targets.length === 0 || descriptionEmpty) findings.push(finding("DQ009", "docs/README.md", start + 1, "required-index-section-empty"));
    if (JSON.stringify(targets) !== JSON.stringify(expectedGroups[group])) {
      findings.push(finding("DQ003", "docs/README.md", start + 1, "scoped-index-membership-or-order"));
    }
  }
  return sortAndDedupe(findings);
}

function containsAll(text, clauses) {
  const lower = text.toLowerCase();
  return clauses.every((clause) => lower.includes(clause.toLowerCase()));
}

function hasCanonicalAffirmations(text, sentences) {
  return sentences.every((sentence) => text.includes(sentence))
    && !sentences.some((sentence) => text.includes(`It is false that ${sentence}`)
      || text.includes(`It is not true that ${sentence}`)
      || text.includes(`${sentence} This sentence is false.`));
}

function containsInOrder(text, clauses) {
  const lower = text.toLowerCase();
  let cursor = 0;
  for (const clause of clauses) {
    const found = lower.indexOf(clause.toLowerCase(), cursor);
    if (found < 0) return false;
    cursor = found + clause.length;
  }
  return true;
}

function firstLine(text, needle) {
  return lineNumberAt(text, text.toLowerCase().indexOf(needle.toLowerCase()));
}

function maskHtmlComments(text) {
  return text.replace(/<!--[\s\S]*?-->/g, (match) => match.replace(/[^\n]/g, " "));
}

function visibleMarkdown(text) {
  return maskHtmlComments(maskMarkdownCode(text).join("\n"));
}

function headingSections(text, metrics = null) {
  const lines = text.split("\n");
  const headings = [];
  const open = [];
  let offset = 0;
  for (let index = 0; index < lines.length; index += 1) {
    if (metrics) metrics.work += lines[index].length + 1;
    const match = lines[index].match(/^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$/);
    if (match) {
      const level = match[1].length;
      while (open.length > 0 && headings[open.at(-1)].level >= level) {
        headings[open.pop()].end = offset;
        if (metrics) metrics.boundaries += 1;
      }
      headings.push({ level, title: match[2], line: index + 1, start: offset, bodyStart: offset + lines[index].length + 1 });
      open.push(headings.length - 1);
    }
    offset += lines[index].length + 1;
  }
  while (open.length > 0) {
    headings[open.pop()].end = text.length;
    if (metrics) metrics.boundaries += 1;
  }
  return headings;
}

function uniqueSection(text, title) {
  const visible = visibleMarkdown(text);
  const matches = headingSections(visible).filter((item) => item.title === title);
  return matches.length === 1 ? visible.slice(matches[0].bodyStart, matches[0].end) : null;
}

function maskExactHistorical(text) {
  const visible = visibleMarkdown(text);
  const sections = headingSections(visible).filter((item) => item.title === "Dated historical evidence, not current certification");
  let masked = visible;
  for (const section of [...sections].reverse()) {
    masked = `${masked.slice(0, section.start)}${masked.slice(section.start, section.end).replace(/[^\n]/g, " ")}${masked.slice(section.end)}`;
  }
  return masked;
}

function maskExactHistoricalKeepFences(text) {
  const structural = visibleMarkdown(text);
  const sections = headingSections(structural).filter((item) => item.title === "Dated historical evidence, not current certification");
  let masked = maskHtmlComments(text);
  for (const section of [...sections].reverse()) {
    masked = `${masked.slice(0, section.start)}${masked.slice(section.start, section.end).replace(/[^\n]/g, " ")}${masked.slice(section.end)}`;
  }
  return masked;
}

function parseDefaultSuites(text) {
  const lines = text.split("\n");
  const starts = lines.map((line, index) => line === "DEFAULT_SUITES=(" ? index : -1).filter((index) => index >= 0);
  if (starts.length === 1) {
    const end = lines.indexOf(")", starts[0] + 1);
    if (end < 0 || lines.slice(end + 1).some((line) => line === "DEFAULT_SUITES=(")) return null;
    const suites = [];
    for (const line of lines.slice(starts[0] + 1, end)) {
      const trimmed = line.trim();
      if (trimmed === "") continue;
      if (!/^test_[A-Za-z0-9_]+\.sh$/.test(trimmed)) return null;
      suites.push(trimmed);
    }
    return suites;
  }
  const single = lines.filter((line) => /^DEFAULT_SUITES=\([^)]*\)$/.test(line));
  if (single.length !== 1) return null;
  const body = single[0].slice("DEFAULT_SUITES=(".length, -1).trim();
  if (body === "") return [];
  const suites = body.split(/[ \t]+/);
  return suites.every((item) => /^test_[A-Za-z0-9_]+\.sh$/.test(item)) ? suites : null;
}

function analyzeRunnerTopology(text) {
  // Bounded admitted shapes only; this is not general shell semantic evaluation.
  const lines = text.split("\n");
  const topLevel = new Set();
  const contexts = [];
  let heredoc = null;
  let awkProgram = false;
  let substitutionDepth = 0;
  let suiteLoop = false;
  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (awkProgram) {
      if (/'\s*$/.test(lines[index])) awkProgram = false;
      continue;
    }
    if (heredoc !== null) {
      if (trimmed === heredoc) heredoc = null;
      continue;
    }
    const closing = trimmed.match(/^(fi|done|esac|})$/)?.[1];
    if (closing) {
      const closed = contexts.pop();
      if (closing === "done" && closed === "suite-loop") suiteLoop = true;
    }
    const suiteLoopOpener = contexts.length === 0 && substitutionDepth === 0
      && trimmed === 'for s in "${SUITES[@]}"; do'
      && lines[index + 1]?.trim() === 'run_one "$s" || true';
    if (contexts.length === 0 && substitutionDepth === 0 && !closing) {
      topLevel.add(index);
    }
    const heredocMatch = lines[index].match(/<<-?\s*["']?([A-Za-z_][A-Za-z0-9_]*)["']?/);
    if (heredocMatch) heredoc = heredocMatch[1];
    const opensFunction = /^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{\s*$/.test(trimmed);
    const opensIf = /^if\b.*(?:;|\s)then\s*$/.test(trimmed);
    const opensLoop = /^(?:for|while|until|select)\b.*(?:;|\s)do\s*$/.test(trimmed);
    const opensCase = /^case\b.*\bin\s*$/.test(trimmed);
    if (opensFunction || opensIf || opensLoop || opensCase) contexts.push(suiteLoopOpener ? "suite-loop" : "block");
    const singleQuotes = (lines[index].match(/'/g) || []).length;
    if (/\bawk\b.*'\s*$/.test(lines[index]) && singleQuotes % 2 === 1) awkProgram = true;
    const opens = (lines[index].match(/\$\(/g) || []).length;
    const closes = (lines[index].match(/\)/g) || []).length;
    substitutionDepth = Math.max(0, substitutionDepth + opens - closes);
  }
  const suiteLoopShapes = [
    ['for s in "${SUITES[@]}"; do', '  run_one "$s" || true', "done"],
    [
      'for s in "${SUITES[@]}"; do',
      '  run_one "$s" || true',
      '  if [ $((SECONDS - LAYOUT_T0)) -ge "$WHOLE_LAYOUT_TIMEOUT_S" ]; then',
      '    record_fail "whole-layout wall clock exceeded ${WHOLE_LAYOUT_TIMEOUT_S}s"',
      "    break",
      "  fi",
      "done",
    ],
  ];
  const suiteLoopStarts = lines.map((line, index) => line === 'for s in "${SUITES[@]}"; do' ? index : -1)
    .filter((index) => index >= 0);
  suiteLoop = suiteLoop && suiteLoopStarts.length === 1 && suiteLoopShapes.some((shape) =>
    JSON.stringify(lines.slice(suiteLoopStarts[0], suiteLoopStarts[0] + shape.length)) === JSON.stringify(shape));
  const suites = parseDefaultSuites(text);
  const starts = lines.map((line, index) => line === "DEFAULT_SUITES=(" || /^DEFAULT_SUITES=\([^)]*\)$/.test(line) ? index : -1)
    .filter((index) => index >= 0);
  const activeLines = lines.map((line, index) => topLevel.has(index) ? line.trim() : "")
    .filter((line) => line !== "" && !line.startsWith("#"));
  const defaultBinding = '[ "${#SUITES[@]}" -gt 0 ] || SUITES=("${DEFAULT_SUITES[@]}")';
  const bindingIndex = activeLines.indexOf(defaultBinding);
  const suiteLoopActiveIndex = activeLines.indexOf('for s in "${SUITES[@]}"; do');
  const usesDefaultSuites = bindingIndex >= 0 && activeLines.lastIndexOf(defaultBinding) === bindingIndex;
  const suiteSelectionValid = usesDefaultSuites && suiteLoopActiveIndex > bindingIndex
    && !activeLines.slice(bindingIndex + 1, suiteLoopActiveIndex).some((line) => /\bSUITES\b/.test(line));
  const staticFalse = String.raw`(?:false|:|\[[ \t]+0[ \t]+-eq[ \t]+1[ \t]+\])`;
  const deadLiteral = new RegExp(String.raw`(?:^|\n)[ \t]*(?:if[ \t]+${staticFalse}[ \t]*(?:;[ \t]*then|\n[ \t]*then)|while[ \t]+${staticFalse}[ \t]*(?:;[ \t]*do|\n[ \t]*do))(?:\n|$)`).test(text);
  const earlyTerminal = starts[0] >= 0 && lines.slice(0, starts[0])
    .some((line) => /^(?:exit|return)(?:\s|$)/.test(line.trim()));
  const validShape = !deadLiteral && !earlyTerminal && contexts.length === 0 && heredoc === null
    && !awkProgram && substitutionDepth === 0;
  if (suites === null || starts.length !== 1 || !topLevel.has(starts[0])) return { suites: null, lines: activeLines, suiteLoop, suiteSelectionValid, validShape };
  if (lines[starts[0]] === "DEFAULT_SUITES=(") {
    const end = lines.indexOf(")", starts[0] + 1);
    if (end < 0 || !topLevel.has(end) || lines.slice(starts[0] + 1, end).some((_, offset) => !topLevel.has(starts[0] + 1 + offset))) {
      return { suites: null, lines: [], suiteLoop, suiteSelectionValid, validShape };
    }
  }
  return {
    suites,
    lines: activeLines,
    suiteLoop,
    suiteSelectionValid,
    validShape,
  };
}

function parseWorkflowTopology(text) {
  // Bounded admitted shapes only; this is not general YAML semantic evaluation.
  if (text.includes("\t")) return null;
  const lines = text.split("\n");
  const jobs = lines.map((line, index) => line === "jobs:" ? index : -1).filter((index) => index >= 0);
  if (jobs.length !== 1) return null;
  const tests = lines.map((line, index) => index > jobs[0] && line === "  test:" ? index : -1).filter((index) => index >= 0);
  if (tests.length !== 1) return null;
  const start = tests[0];
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^  [A-Za-z0-9_-]+:\s*$/.test(lines[index])) { end = index; break; }
  }
  const block = lines.slice(start + 1, end);
  if (block.some((line) => /^    (?:if|continue-on-error):/.test(line))) return null;
  if (JSON.stringify(block.filter((line) => /^    [A-Za-z0-9_-]+:/.test(line))) !== JSON.stringify(["    strategy:", "    runs-on: ${{ matrix.os }}", "    defaults:", "    steps:"])) return null;
  const strategyIndex = block.indexOf("    strategy:");
  const matrixIndex = block.indexOf("      matrix:");
  const osIndex = block.findIndex((line) => /^        os:\s*\[[^\]]*\]\s*$/.test(line));
  const runsOnIndex = block.indexOf("    runs-on: ${{ matrix.os }}");
  const defaultsIndex = block.indexOf("    defaults:");
  const runDefaultsIndex = block.indexOf("      run:");
  const shellIndex = block.indexOf("        shell: bash");
  const stepsIndex = block.indexOf("    steps:");
  const structuralIndexes = [strategyIndex, matrixIndex, osIndex, runsOnIndex, defaultsIndex, runDefaultsIndex, shellIndex, stepsIndex];
  const strategyControls = block.slice(strategyIndex + 1, matrixIndex);
  const strategyKeys = block.slice(strategyIndex + 1, runsOnIndex)
    .filter((line) => /^      [A-Za-z0-9_-]+:/.test(line));
  if (JSON.stringify(strategyKeys) !== JSON.stringify(strategyControls.length === 0
    ? ["      matrix:"] : ["      fail-fast: false", "      matrix:"])) return null;
  const matrixChildren = block.slice(matrixIndex + 1, runsOnIndex);
  if (matrixChildren.length !== 1 || !/^        os:\s*\[[^\]]*\]\s*$/.test(matrixChildren[0])) return null;
  if (structuralIndexes.some((index) => index < 0)
      || matrixIndex <= strategyIndex
      || strategyControls.length > 1 || strategyControls.some((line) => line !== "      fail-fast: false")
      || osIndex !== matrixIndex + 1
      || runDefaultsIndex !== defaultsIndex + 1 || shellIndex !== runDefaultsIndex + 1
      || !(osIndex < runsOnIndex && runsOnIndex < defaultsIndex && shellIndex < stepsIndex)) return null;
  if (JSON.stringify(block.slice(defaultsIndex + 1, stepsIndex))
      !== JSON.stringify(["      run:", "        shell: bash"])) return null;
  const osLines = block.filter((line) => /^        os:\s*\[[^\]]*\]\s*$/.test(line));
  if (osLines.length !== 1) return null;
  const osValues = osLines[0].match(/\[([^\]]*)\]/)[1].split(",").map((item) => item.trim()).sort();
  if (JSON.stringify(osValues) !== JSON.stringify(["ubuntu-latest", "windows-latest"])) return null;
  if (block.filter((line) => line === "    strategy:").length !== 1
      || block.filter((line) => line === "      matrix:").length !== 1
      || block.filter((line) => line === "    runs-on: ${{ matrix.os }}").length !== 1
      || block.filter((line) => line === "    defaults:").length !== 1
      || block.filter((line) => line === "      run:").length !== 1
      || block.filter((line) => line === "        shell: bash").length !== 1
      || block.filter((line) => /^    steps:/.test(line)).length !== 1) return null;
  if (block.slice(0, stepsIndex).some((line) => /^      - /.test(line))
      || block.slice(stepsIndex + 1).some((line) => /^    [A-Za-z0-9_-]+:/.test(line))) return null;
  const steps = block.slice(stepsIndex + 1);
  const commands = [];
  for (let index = 0; index < steps.length; index += 1) {
    if (!/^      - /.test(steps[index])) continue;
    let next = index + 1;
    while (next < steps.length && !/^      - /.test(steps[next])) next += 1;
    const step = steps.slice(index, next);
    const runs = step.map((line) => line.match(/^        run: ([^|>].*)$/)?.[1] ?? null).filter((item) => item !== null);
    if (runs.length > 1) return null;
    if (runs.length === 1 && !step.some((line) => /^        (?:if|continue-on-error):/.test(line))) commands.push(runs[0]);
    index = next - 1;
  }
  return { commands };
}

function runnerGateCount(lines, direct, monitored) {
  return lines.filter((line) => {
    if (line === direct || monitored.test(line)) return true;
    if (direct !== "bash tests/scan_public_safety.sh") return false;
    const prefix = '[ "$RUN_SAFETY" -eq 1 ] && ';
    if (!line.startsWith(prefix)) return false;
    const guarded = line.slice(prefix.length);
    return guarded === direct || monitored.test(guarded);
  }).length;
}

function currentReleaseSection(text) {
  const visible = visibleMarkdown(text);
  const headings = [...visible.matchAll(/^## \[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\][^\n]*$/gm)];
  if (headings.length < 2 || headings[0][1] !== "Unreleased" || headings[0].index !== visible.indexOf(headings[0][0])) return null;
  const start = headings[1].index;
  const end = headings[2]?.index ?? visible.length;
  return { version: headings[1][1], text: visible.slice(start + headings[1][0].length, end) };
}

function releaseSection(text, version) {
  const visible = visibleMarkdown(text);
  const headings = [...visible.matchAll(/^## \[([0-9]+\.[0-9]+\.[0-9]+)\][^\n]*$/gm)];
  const index = headings.findIndex((item) => item[1] === version);
  if (index < 0 || headings.some((item, itemIndex) => item[1] === version && itemIndex !== index)) return null;
  const start = headings[index].index;
  const end = headings[index + 1]?.index ?? visible.length;
  return { version, text: visible.slice(start, end) };
}

function validateOperationalModel(files) {
  const findings = [];
  const add = (id, file, reason, needle = "") => findings.push(finding(id, file, firstLine(files.get(file) || "", needle), reason));
  const get = (file) => files.get(file) || "";
  for (const file of REQUIRED_OPERATIONAL_FILES.filter((item) => item.endsWith(".md"))) {
    if (get(file).trim() === "") add("DQ009", file, "required-authority-empty");
  }
  for (const { file, titles, required } of REQUIRED_NONEMPTY_SECTIONS) {
    const present = titles.map((title) => [title, uniqueSection(get(file), title)]).filter(([, section]) => section !== null);
    if ((required && present.length !== 1) || present.some(([, section]) => section.trim() === "")) {
      add("DQ009", file, "required-section-empty", titles[0]);
    }
  }
  let pluginVersion = null;
  try { pluginVersion = JSON.parse(get(".claude-plugin/plugin.json")).version; } catch { pluginVersion = null; }
  const wrapperArms = [...get("skills/ipc/scripts/handoff_to_codex.sh").matchAll(/^[ \t]*-v\|--version\)[ \t]*\n([\s\S]*?)^[ \t]*;;[ \t]*$/gm)];
  let wrapperVersion = null;
  if (wrapperArms.length === 1) {
    const body = wrapperArms[0][1].split("\n").map((line) => line.trim()).filter(Boolean);
    const match = body[0]?.match(/^printf '%s\\n' 'handoff_to_codex\.sh ([0-9]+\.[0-9]+\.[0-9]+)'$/);
    if (body.length === 2 && body[1] === "exit 0" && match) wrapperVersion = match[1];
  }
  const status = uniqueSection(get("README.md"), "Status");
  const statusMatches = status ? [...status.matchAll(/^v([0-9]+\.[0-9]+\.[0-9]+) [^\n]*$/gm)] : [];
  const readmeVersion = statusMatches.length === 1 ? statusMatches[0][1] : null;
  const release = currentReleaseSection(get("CHANGELOG.md"));
  const changelogVersion = release?.version ?? null;
  const releaseHasContent = release?.text.split("\n").some((line) => line.trim() !== "" && !/^#{1,6}\s/.test(line));
  if (release && !releaseHasContent) add("DQ009", "CHANGELOG.md", "required-section-empty", `[${release.version}]`);
  if (!pluginVersion || new Set([pluginVersion, wrapperVersion, readmeVersion, changelogVersion]).size !== 1) add("DQ004", ".claude-plugin/plugin.json", "semantic-version-parity");

  const currentDocs = [...files].filter(([name]) => name.endsWith(".md") && name !== "CHANGELOG.md")
    .map(([, text]) => maskExactHistoricalKeepFences(text)).join("\n");
  const readme = get("README.md");
  const visibleReadme = maskExactHistorical(readme);
  const currentReadmeCommands = maskExactHistoricalKeepFences(readme);
  if (/claude plugin add/i.test(currentDocs) || !hasCanonicalAffirmations(currentReadmeCommands, INSTALL_SESSION_SENTENCES)) {
    add("DQ005", "README.md", "install-command-or-session-scope", "Install");
  }
  const waiterClauses = ["genuinely absent reply", "eligible for waiter rollout fallback", "present-but-invalid reply", "without consulting rollout fallback", "no certifiable rollout body", "exhausts the eligible sources", NEW_MARKER_SENTENCE];
  for (const file of WAITER_FILES) {
    const text = maskExactHistorical(get(file));
    if (!containsAll(text, waiterClauses) || /(?:exhausted|exhausts)[^\n]{0,40}both[^\n]{0,20}(?:body )?sources|both[^\n]{0,40}(?:body )?sources/i.test(text)) add("DQ006", file, "waiter-branch-contract", "reply");
  }
  const runner = get("tests/run_release_gates.sh");
  const workflow = get(".github/workflows/test.yml");
  const runnerTopology = analyzeRunnerTopology(runner);
  const workflowTopology = parseWorkflowTopology(workflow);
  const runnerSuites = runnerTopology.suites;
  const ciSuites = (workflowTopology?.commands || []).map((command) => command.match(/^bash tests\/(test_[A-Za-z0-9_]+\.sh)$/)?.[1] ?? null)
    .filter((name) => name !== null && name !== "test_gate_process_ownership.sh");
  const runnerSet = [...new Set(runnerSuites || [])].sort();
  const ciSet = [...new Set(ciSuites)].sort();
  const expectedSet = [...EXPECTED_BEHAVIORAL_SUITES].sort();
  if (!runnerSuites || !runnerTopology.suiteLoop || !runnerTopology.suiteSelectionValid || !runnerTopology.validShape
      || workflowTopology === null || JSON.stringify(runnerSuites) !== JSON.stringify(EXPECTED_BEHAVIORAL_SUITES)
      || ciSuites.length !== EXPECTED_BEHAVIORAL_SUITES.length
      || ciSet.length !== EXPECTED_BEHAVIORAL_SUITES.length
      || JSON.stringify(ciSet) !== JSON.stringify(expectedSet)
      || JSON.stringify(runnerSet) !== JSON.stringify(expectedSet)) add("DQ007", "tests/run_release_gates.sh", "behavioral-suite-parity", "DEFAULT_SUITES");
  const runnerLines = runnerTopology.lines;
  const ciLines = workflowTopology?.commands || [];
  const runnerGates = [
    ["node tests/check_text_integrity.mjs --self-test", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" tests\/check_text_integrity\.mjs --self-test$/],
    ["node tests/check_text_integrity.mjs --source index", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" tests\/check_text_integrity\.mjs --source index$/],
    ["node tests/check_text_integrity.mjs --source worktree", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" tests\/check_text_integrity\.mjs --source worktree$/],
    ["node tests/check_docs_quality.mjs --self-test", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" tests\/check_docs_quality\.mjs --self-test$/],
    ["node tests/check_docs_quality.mjs", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" tests\/check_docs_quality\.mjs$/],
    ["bash tests/gen_release_manifest.sh check-all --no-roots", /^run_monitored "[^"]+" bash tests\/gen_release_manifest\.sh check-all --no-roots$/],
    ["bash tests/scan_public_safety.sh", /^run_monitored "[^"]+" bash tests\/scan_public_safety\.sh$/],
    ["node skills/ipc/scripts/codex_ipc_contract_audit.mjs", /^run_monitored "[^"]+" "\$NODE_BIN" "\$\{NODE_FLAGS\[@\]\}" skills\/ipc\/scripts\/codex_ipc_contract_audit\.mjs$/],
  ];
  const ciGates = ["node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --source index", "node tests/check_text_integrity.mjs --source worktree", "node tests/check_docs_quality.mjs --self-test", "node tests/check_docs_quality.mjs", "bash tests/gen_release_manifest.sh check-all --no-roots", "bash tests/scan_public_safety.sh", "node skills/ipc/scripts/codex_ipc_contract_audit.mjs", "bash tests/test_gate_process_ownership.sh"];
  const runnerGateIndexes = runnerLines.map((line, index) => runnerGates.some(([direct, monitored]) => runnerGateCount([line], direct, monitored) === 1) ? index : -1)
    .filter((index) => index >= 0);
  const lastRunnerGate = runnerGateIndexes.length === 0 ? -1 : Math.max(...runnerGateIndexes);
  const terminalBeforeOuterCompletion = runnerLines.some((line, index) => index < lastRunnerGate && /^(?:exit|return)(?:\s|$)/.test(line));
  const runnerOwnership = runnerLines.filter((line) => /test_gate_process_ownership\.sh/.test(line)).length;
  const ciOwnership = ciLines.filter((line) => line === "bash tests/test_gate_process_ownership.sh").length;
  if (!runnerTopology.validShape || terminalBeforeOuterCompletion || workflowTopology === null
      || runnerGates.some(([direct, monitored]) => runnerGateCount(runnerLines, direct, monitored) !== 1)
      || ciGates.slice(0, -1).some((gate) => ciLines.filter((line) => line === gate).length !== 1)
      || runnerOwnership !== 0 || ciOwnership !== 1) add("DQ008", "tests/run_release_gates.sh", "outer-or-meta-gate-missing", "DEFAULT_SUITES");
  const install = maskExactHistoricalKeepFences(get("docs/INSTALL.md"));
  if (!hasCanonicalAffirmations(install, FORCE_DISCLOSURE_SENTENCES)) add("DQ010", "docs/INSTALL.md", "force-install-disclosure", "force");
  const boundaries = new Map([["README.md", "## Quickstart"], ["skills/ipc/SKILL.md", "## First decision"], ["skills/ipc/examples/quickstart.md", "handoff_to_codex.sh"], ["skills/ipc/references/troubleshooting.md", "## Delivery triage"]]);
  for (const file of FIRST_USE_FILES) {
    const text = maskExactHistorical(get(file));
    const boundary = text.indexOf(boundaries.get(file));
    const prefix = boundary < 0 ? "" : text.slice(0, boundary);
    if (!hasCanonicalAffirmations(prefix, FIRST_USE_WARNING_SENTENCES)) {
      add("DQ011", file, "first-use-plaintext-retention-warning", "plaintext");
    }
  }
  if (!containsAll(visibleReadme, ["Desktop-independent", "private-schema-dependent", "Experimental live Desktop"])
      || /Desktop update[^\n]*\|\s*Unaffected/i.test(visibleReadme) || /unaffected after Desktop updates/i.test(visibleReadme)) add("DQ012", "README.md", "desktop-update-sensitivity", "Desktop");
  if (!containsAll(visibleReadme, ["Primary wrapper variables", "Component-specific", "--help", "bundled references"]) || /Configuration \(all env vars/i.test(visibleReadme)) add("DQ013", "README.md", "configuration-scope", "Configuration");
  if (!containsAll(visibleReadme, ["bash tests/run_release_gates.sh", "13 behavioral suites", "text self-test/index/worktree", "docs self-test/repository", "manifest", "public safety", "static contract audit", "separate process-ownership meta-gate", "partial smoke set"])) add("DQ014", "README.md", "complete-vs-smoke-gates", "Testing");
  const architecture = get("docs/ARCHITECTURE.md");
  const inspection = uniqueSection(architecture, "Inspection surfaces (read-only)");
  const writeProof = uniqueSection(architecture, "Authorized write proof");
  if (inspection === null || writeProof === null || !containsAll(writeProof, ["dry-run by default", "explicit authorization"])
      || /\bread-only\b/i.test(writeProof)) add("DQ015", "docs/ARCHITECTURE.md", "readonly-vs-authorized-write", "Inspection");
  const compatibility = get("docs/COMPATIBILITY.md");
  const history = uniqueSection(compatibility, "Dated historical evidence, not current certification");
  const currentMatrix = uniqueSection(compatibility, "Current feature matrix");
  if (history === null || currentMatrix === null || !containsAll(currentMatrix, ["Current-host confidence requires validate-only revalidation", "live proof remains separately authorized"])
      || history.trim() === "" || !/\b20[0-9]{2}-[0-9]{2}-[0-9]{2}\b/.test(history)
      || /(?:dated|historical)[^\n.]*current certification/i.test(history)) add("DQ016", "docs/COMPATIBILITY.md", "current-vs-dated-history", "historical");
  const changelog = get("CHANGELOG.md");
  const changelogVisible = visibleMarkdown(changelog);
  const correctedVersionSentence = "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.";
  const correctedRelease = releaseSection(changelog, "0.1.13");
  if (!correctedRelease || !correctedRelease.text.includes(correctedVersionSentence)
      || /(?:false|not true|incorrect)[^\n.]{0,80}Normal dispatch control flow|Normal dispatch control flow[^\n.]{0,120}(?:false|not true|incorrect)/i.test(correctedRelease?.text || "")
      || /No script['\u2019]s control flow, output bytes, or exit codes/i.test(correctedRelease?.text || "")) add("DQ017", "CHANGELOG.md", "version-output-truth", "0.1.13");
  const quickstart = get("skills/ipc/examples/quickstart.md");
  const quickstartVisible = maskExactHistorical(quickstart);
  if (!/skills\/ipc\/scripts[^\n.]*repository root|repository root[^\n.]*skills\/ipc\/scripts/i.test(quickstartVisible)
      || !/\bscripts\b[^\n.]*installed skill root|installed skill root[^\n.]*\bscripts\b/i.test(quickstartVisible)
      || !/\/ipc[^\n.]*Claude slash-command UI|Claude slash-command UI[^\n.]*\/ipc/i.test(quickstartVisible)
      || /All commands run from any directory/i.test(quickstartVisible)) add("DQ018", "skills/ipc/examples/quickstart.md", "execution-contexts", "commands");
  const recoveryClauses = ["wrong decoder", "invalid or corrupt", "double-decoding signature", "PowerShell 5.1", "writes a BOM", "raw bytes first", "restore or reconstruct from authoritative source", "index and worktree gates", "then semantic tests", "no automatic transcoder"];
  for (const file of MOJIBAKE_GUIDANCE_FILES) {
    const text = maskExactHistorical(get(file));
    if (!containsAll(text, recoveryClauses)
        || !containsInOrder(text, ["raw bytes first", "restore or reconstruct from authoritative source", "index and worktree gates", "then semantic tests"])) {
      add("DQ019", file, "encoding-recovery-order", "encoding");
    }
  }
  return sortAndDedupe(findings);
}
function decodeUtf8Strict(bytes, reason) {
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { failInfrastructure(reason); }
}

function parseIndexEntries(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0) failInfrastructure("empty-index-inventory");
  if (bytes.at(-1) !== 0) failInfrastructure("malformed-index-framing");
  const records = [];
  let start = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] !== 0) continue;
    if (index === start) failInfrastructure("malformed-index-framing");
    records.push(bytes.subarray(start, index));
    start = index + 1;
  }
  const entries = [];
  const exact = new Set();
  const folded = new Map();
  for (const record of records) {
    const tab = record.indexOf(0x09);
    if (tab <= 0 || tab === record.length - 1) failInfrastructure("malformed-index-record");
    const headerBytes = record.subarray(0, tab);
    if ([...headerBytes].some((value) => value > 0x7f)) failInfrastructure("non-ascii-index-header");
    const header = headerBytes.toString("ascii");
    const match = header.match(/^([0-9]{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-3])$/);
    if (!match) failInfrastructure("malformed-index-header");
    const [, mode, oid, stage] = match;
    if (stage !== "0") failInfrastructure("unmerged-index-entry");
    if (!['100644', '100755'].includes(mode)) failInfrastructure("unsupported-index-mode");
    if (/^0+$/.test(oid)) failInfrastructure("intent-to-add-index-entry");
    const name = decodeUtf8Strict(record.subarray(tab + 1), "invalid-utf8-index-path");
    if (name === "" || name.includes("\\") || name.startsWith("/") || name.split("/").some((part) => part === "" || part === "." || part === "..")) {
      failInfrastructure("noncanonical-index-path");
    }
    if (exact.has(name)) failInfrastructure("duplicate-index-path");
    const fold = name.toLowerCase();
    if (folded.has(fold)) failInfrastructure("casefold-index-collision");
    exact.add(name);
    folded.set(fold, name);
    entries.push({ mode, oid, stage: 0, path: name });
  }
  return entries;
}

function parseNulPathSet(bytes, reason) {
  if (!Buffer.isBuffer(bytes)) failInfrastructure(reason);
  if (bytes.length === 0) return [];
  if (bytes.at(-1) !== 0) failInfrastructure(reason);
  const paths = [];
  const exact = new Set();
  let start = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    if (bytes[index] !== 0) continue;
    if (index === start) failInfrastructure(reason);
    const name = decodeUtf8Strict(bytes.subarray(start, index), reason);
    if (name === "" || name.includes("\\") || name.startsWith("/")
        || name.split("/").some((part) => part === "" || part === "." || part === "..")) failInfrastructure(reason);
    if (exact.has(name)) failInfrastructure(reason);
    exact.add(name);
    paths.push(name);
    start = index + 1;
  }
  return paths.sort();
}

function sanitizedGitEnv(source = process.env) {
  const env = {};
  for (const [name, value] of Object.entries(source)) {
    if (!/^GIT_/i.test(name)) env[name] = value;
  }
  return {
    ...env,
    GIT_OPTIONAL_LOCKS: "0",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: process.platform === "win32" ? "NUL" : "/dev/null",
    GIT_ATTR_NOSYSTEM: "1",
    GIT_PAGER: "cat",
    GIT_NO_REPLACE_OBJECTS: "1",
    GIT_NO_LAZY_FETCH: "1",
    GIT_TERMINAL_PROMPT: "0",
  };
}

function runGitRaw(cwd, args, input, seams, operation) {
  const env = sanitizedGitEnv();
  if (seams.runGitRaw) return seams.runGitRaw(cwd, args, input, operation, env);
  const result = spawnSync("git", args, { cwd, input, encoding: null, env, shell: false, windowsHide: true });
  if (result.error || result.status !== 0 || !Buffer.isBuffer(result.stdout) || !Buffer.isBuffer(result.stderr)) {
    failInfrastructure(`git-${operation}-failed`);
  }
  return result.stdout;
}

function gitRepositoryRoot(cwd, seams) {
  const bytes = runGitRaw(cwd, ["rev-parse", "--show-toplevel"], undefined, seams, "show-toplevel");
  const text = decodeUtf8Strict(bytes, "invalid-utf8-repository-root");
  if (!text.endsWith("\n") || text.slice(0, -1).includes("\n")) failInfrastructure("malformed-repository-root");
  return path.resolve(text.slice(0, -1).replace(/\r$/, ""));
}

function readIndexBlob(cwd, entry, seams) {
  const bytes = runGitRaw(cwd, ["cat-file", "--batch"], Buffer.from(`${entry.oid}\n`, "ascii"), seams, "cat-file");
  const newline = bytes.indexOf(0x0a);
  if (newline <= 0 || [...bytes.subarray(0, newline)].some((value) => value > 0x7f)) failInfrastructure("malformed-cat-file-header");
  const header = bytes.subarray(0, newline).toString("ascii");
  const match = header.match(/^([0-9a-f]{40}|[0-9a-f]{64}) blob ([0-9]+)$/);
  if (!match || match[1] !== entry.oid) failInfrastructure("malformed-cat-file-header");
  const size = Number(match[2]);
  if (!Number.isSafeInteger(size)) failInfrastructure("malformed-cat-file-header");
  const contentStart = newline + 1;
  const contentEnd = contentStart + size;
  if (contentEnd >= bytes.length || bytes[contentEnd] !== 0x0a || contentEnd + 1 !== bytes.length) {
    failInfrastructure("malformed-cat-file-framing");
  }
  return bytes.subarray(contentStart, contentEnd);
}

function ensureContained(root, candidate, reason) {
  const relative = path.relative(root, candidate);
  if (relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative))) return;
  failInfrastructure(reason);
}

function rejectSelectedDirent(selected, reason) {
  if (selected.isSymbolicLink()) failInfrastructure(reason);
}

function exactSelectedDirent(parent, expectedName, seamKey, seams, reasons) {
  let entries;
  try { entries = readdirSync(parent, { encoding: "utf8", withFileTypes: true }); }
  catch { failInfrastructure(reasons.missing); }
  const match = entries.find((entry) => entry.name === expectedName);
  if (!match) {
    if (entries.some((entry) => entry.name.toLowerCase() === expectedName.toLowerCase())) failInfrastructure(reasons.caseMismatch);
    failInfrastructure(reasons.missing);
  }
  const selected = seams.direntKind?.[seamKey] === "reparse"
    ? Object.create(match, { isSymbolicLink: { value: () => true } }) : match;
  rejectSelectedDirent(selected, reasons.redirected);
  return selected;
}

function inspectSafeRoot(root, seams, scope) {
  const reasons = scope === "installed"
    ? { missing: "missing-installed-root", caseMismatch: "installed-case-mismatch", redirected: "redirected-installed-segment" }
    : { missing: "missing-repository-root", caseMismatch: "repository-case-mismatch", redirected: "redirected-repository-segment" };
  const parsed = path.parse(root);
  if (root === parsed.root || path.dirname(root) === root || path.basename(root) === "") {
    failInfrastructure(scope === "installed" ? "unsupported-installed-root-anchor" : "unsupported-repository-root-anchor");
  }
  exactSelectedDirent(path.dirname(root), path.basename(root), "<root>", seams, reasons);
  let stat;
  try { stat = lstatSync(root); } catch { failInfrastructure(reasons.missing); }
  if (stat.isSymbolicLink()) failInfrastructure(reasons.redirected);
  if (!stat.isDirectory()) failInfrastructure(scope === "installed" ? "nonregular-installed-root" : "nonregular-repository-root");
  let real;
  try { real = seams.realpath?.["<root>"] || realpathSync.native(root); }
  catch { failInfrastructure(scope === "installed" ? "installed-realpath-failure" : "repository-realpath-failure"); }
  return real;
}

function acquirePath(root, relative, seams = {}, scope = "installed", rootReal = null,
  terminalKind = "file", readTerminal = true) {
  const installed = scope === "installed";
  const reasons = installed
    ? { missing: "missing-installed-member", caseMismatch: "installed-case-mismatch", redirected: "redirected-installed-segment" }
    : { missing: "missing-repository-source", caseMismatch: "repository-case-mismatch", redirected: "redirected-repository-segment" };
  const anchorReal = rootReal || inspectSafeRoot(root, seams, scope);
  const segments = relative.split("/");
  let parent = root;
  let relativeSoFar = "";
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    relativeSoFar = relativeSoFar ? `${relativeSoFar}/${segment}` : segment;
    exactSelectedDirent(parent, segment, relativeSoFar, seams, reasons);
    const candidate = path.join(parent, segment);
    let stat;
    try { stat = lstatSync(candidate); } catch { failInfrastructure(reasons.missing); }
    if (stat.isSymbolicLink()) failInfrastructure(reasons.redirected);
    let real;
    try { real = seams.realpath?.[relativeSoFar] || realpathSync.native(candidate); }
    catch { failInfrastructure(installed ? "installed-realpath-failure" : "repository-realpath-failure"); }
    ensureContained(anchorReal, real, installed ? "installed-realpath-escape" : "repository-realpath-escape");
    const terminal = index === segments.length - 1;
    if (terminal) {
      if ((terminalKind === "file" && !stat.isFile()) || (terminalKind === "directory" && !stat.isDirectory())) {
        failInfrastructure(installed ? "nonregular-installed-member" : "nonregular-repository-source");
      }
      if (terminalKind === "file") {
        if (!readTerminal) return candidate;
        try {
          const reader = seams.readFile || readFileSync;
          return reader(candidate);
        } catch {
          failInfrastructure(installed ? "installed-read-failure" : "repository-read-failure");
        }
      }
      return candidate;
    }
    if (!stat.isDirectory()) failInfrastructure(installed ? "nonregular-installed-member" : "nonregular-repository-source");
    parent = candidate;
  }
  failInfrastructure(installed ? "missing-installed-member" : "missing-repository-source");
}

function classifyTarget(root, relative, seams, scope, rootReal) {
  try {
    acquirePath(root, relative, seams, scope, rootReal, "file", false);
    return "file";
  } catch (error) {
    if (!(error instanceof InfrastructureError)) throw error;
    if (error.message.includes("case-mismatch")) return "case-mismatch";
    if (error.message.includes("redirected")) return "redirected";
    if (error.message.includes("nonregular")) return "directory";
    if (error.message.includes("missing")) return "missing";
    throw error;
  }
}


function createCorpusTargetPolicy(paths, classify, metrics = {}) {
  const exact = new Set(paths);
  const folded = new Map();
  metrics.casefoldBuilds = (metrics.casefoldBuilds || 0) + 1;
  metrics.casefoldEntries = (metrics.casefoldEntries || 0) + exact.size;
  metrics.casefoldLookups = metrics.casefoldLookups || 0;
  metrics.classifications = metrics.classifications || 0;
  for (const name of exact) {
    const fold = name.toLowerCase();
    if (folded.has(fold) && folded.get(fold) !== name) failInfrastructure("casefold-target-collision");
    folded.set(fold, name);
  }
  const targetKindCache = new Map();
  return {
    targetKindCache,
    resolveTarget: (resolved) => {
      metrics.casefoldLookups += 1;
      if (!exact.has(resolved)) return folded.has(resolved.toLowerCase()) ? "case-mismatch" : "missing";
      metrics.classifications += 1;
      return classify(resolved);
    },
  };
}
function acquireRepositoryCorpus(seams = {}) {
  const cwd = seams.cwd || process.cwd();
  const root = gitRepositoryRoot(cwd, seams);
  const entries = parseIndexEntries(runGitRaw(cwd, ["ls-files", "--stage", "-z"], undefined, seams, "ls-files"));
  const itaInvisible = parseNulPathSet(runGitRaw(cwd,
    ["diff", "--cached", "--name-only", "-z", "--ita-invisible-in-index"], undefined, seams, "ita-invisible"), "malformed-ita-invisible");
  const itaVisible = parseNulPathSet(runGitRaw(cwd,
    ["diff", "--cached", "--name-only", "-z", "--ita-visible-in-index"], undefined, seams, "ita-visible"), "malformed-ita-visible");
  if (JSON.stringify(itaInvisible) !== JSON.stringify(itaVisible)) failInfrastructure("intent-to-add");
  const byPath = new Map(entries.map((entry) => [entry.path, entry]));
  const modulePath = path.resolve(seams.modulePath || MODULE_PATH);
  const moduleRelative = path.relative(root, modulePath).split(path.sep).join("/");
  if (moduleRelative !== "tests/check_docs_quality.mjs") failInfrastructure("validator-path-mismatch");
  const moduleEntry = byPath.get(moduleRelative);
  if (!moduleEntry) failInfrastructure("validator-not-staged");
  const rootReal = inspectSafeRoot(root, seams, "repository");
  const moduleBytes = acquirePath(root, moduleRelative, seams, "repository", rootReal);
  if (!moduleBytes.equals(readIndexBlob(cwd, moduleEntry, seams))) failInfrastructure("validator-index-divergence");
  const direct = entries.map((entry) => entry.path)
    .filter((name) => /^docs\/[^/]+\.md$/.test(name) && name !== "docs/README.md").sort();
  if (direct.length === 0) failInfrastructure("empty-direct-docs-scope");
  const bundled = entries.map((entry) => entry.path).filter((name) => name === "skills/ipc/SKILL.md"
    || /^skills\/ipc\/(?:references|examples)\/[^/]+\.md$/.test(name)).sort();
  if (!bundled.includes("skills/ipc/SKILL.md")) failInfrastructure("missing-required-index-entry");
  const selected = [...new Set([...REQUIRED_OPERATIONAL_FILES, ...direct, ...bundled])];
  const files = new Map();
  const bytes = new Map();
  for (const name of selected) {
    if (!byPath.has(name)) failInfrastructure("missing-required-index-entry");
    const content = acquirePath(root, name, seams, "repository", rootReal);
    bytes.set(name, content);
    files.set(name, decodeUtf8Strict(content, "invalid-utf8-repository-source"));
  }
  return { root, rootReal, entries, byPath, direct, bundled, files, bytes, seams };
}

function enumerateInstalledMarkdown(root, relativeDirectory, expectedNames, seams, rootReal) {
  const directory = relativeDirectory === "" ? root
    : acquirePath(root, relativeDirectory, seams, "installed", rootReal, "directory");
  let entries;
  try { entries = readdirSync(directory, { encoding: "utf8", withFileTypes: true }); }
  catch { failInfrastructure("installed-inventory-read-failure"); }
  const markdown = entries.filter((entry) => entry.name.toLowerCase().endsWith(".md"));
  if (JSON.stringify(markdown.map((entry) => entry.name).sort()) !== JSON.stringify([...expectedNames].sort())) {
    if (markdown.some((entry) => expectedNames.some((name) => name.toLowerCase() === entry.name.toLowerCase() && name !== entry.name))) {
      failInfrastructure("installed-case-mismatch");
    }
    failInfrastructure("installed-inventory-mismatch");
  }
  const walk = (parent, prefix) => {
    let nested;
    try { nested = readdirSync(parent, { encoding: "utf8", withFileTypes: true }); }
    catch { failInfrastructure("installed-inventory-read-failure"); }
    for (const entry of nested) {
      const key = prefix ? `${prefix}/${entry.name}` : entry.name;
      const selected = seams.direntKind?.[key] === "reparse"
        ? Object.create(entry, { isSymbolicLink: { value: () => true } }) : entry;
      rejectSelectedDirent(selected, "redirected-installed-segment");
      if (entry.isDirectory()) walk(path.join(parent, entry.name), key);
      else if (prefix !== relativeDirectory && entry.name.toLowerCase().endsWith(".md")) failInfrastructure("installed-nested-markdown");
    }
  };
  for (const entry of entries.filter((item) => item.isDirectory())) {
    if (relativeDirectory === "" && ["references", "examples"].includes(entry.name)) continue;
    walk(path.join(directory, entry.name), `${relativeDirectory}/${entry.name}`.replace(/^\//, ""));
  }
}

function validateInstalledInventory(root, seams, rootReal) {
  enumerateInstalledMarkdown(root, "", ["SKILL.md"], seams, rootReal);
  enumerateInstalledMarkdown(root, "references", INSTALLED_DOCS.filter((name) => name.startsWith("references/")).map((name) => name.slice("references/".length)), seams, rootReal);
  enumerateInstalledMarkdown(root, "examples", INSTALLED_DOCS.filter((name) => name.startsWith("examples/")).map((name) => name.slice("examples/".length)), seams, rootReal);
}

function scannerFindings(bytes, projectedPath, seams) {
  let result;
  try {
    const scanner = seams.scanTextBuffer || scanTextBuffer;
    result = scanner(bytes, { source: "installed-root", path: projectedPath });
  } catch { failInfrastructure("text-scanner-threw"); }
  if (!Array.isArray(result) || result.some((item) => !item || !/^TXT00[1-7]$/.test(item.id)
      || item.source !== "installed-root" || item.path !== projectedPath
      || !Number.isInteger(item.byteOffset) || !Number.isInteger(item.codePointOffset)
      || typeof item.reason !== "string")) failInfrastructure("malformed-text-scanner-result");
  return result;
}

function validateInstalledCorpus(rootInput, seams = {}) {
  const root = path.resolve(rootInput);
  const rootReal = inspectSafeRoot(root, seams, "installed");
  validateInstalledInventory(root, seams, rootReal);
  const findings = [];
  const metrics = { links: 0 };
  const targetPolicy = createCorpusTargetPolicy(
    INSTALLED_DOCS.map((relative) => `skills/ipc/${relative}`),
    (resolved) => classifyTarget(root, resolved.slice("skills/ipc/".length), seams, "installed", rootReal),
    seams.targetMetrics || {},
  );
  for (const relative of INSTALLED_DOCS) {
    const bytes = acquirePath(root, relative, seams, "installed", rootReal);
    const projectedPath = `skills/ipc/${relative}`;
    const textFindings = scannerFindings(bytes, projectedPath, seams);
    if (textFindings.length > 0) {
      findings.push(...textFindings);
      continue;
    }
    let text;
    try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { failInfrastructure("text-scanner-missed-invalid-utf8"); }
    if (text.trim() === "") findings.push(finding("DQ009", projectedPath, 1, "required-authority-empty"));
    findings.push(...validateMarkdownDocument({
      path: projectedPath,
      text,
      boundary: "skills/ipc",
      metrics,
      targetKindCache: targetPolicy.targetKindCache,
      resolveTarget: targetPolicy.resolveTarget,
    }));
  }
  return { findings: sortAndDedupe(findings), files: INSTALLED_DOCS.length, links: metrics.links, root };
}

function validateInstalledFixture(rootInput, seams = {}) {
  return validateInstalledCorpus(rootInput, seams).findings;
}

function validateRepositoryCorpus(corpus) {
  const findings = [...validateOperationalModel(corpus.files)];
  findings.push(...validateDocsIndex(corpus.files.get("docs/README.md"), {
    direct: corpus.direct,
    root: ROOT_DOCS,
    bundled: corpus.bundled,
  }));
  const metrics = { links: 0 };
  const markdown = ["docs/README.md", ...corpus.direct, ...ROOT_DOCS, ...corpus.bundled];
  const targetPolicy = createCorpusTargetPolicy(
    corpus.byPath.keys(),
    (resolved) => classifyTarget(corpus.root, resolved, corpus.seams, "repository", corpus.rootReal),
    corpus.seams.targetMetrics || {},
  );
  for (const source of [...new Set(markdown)]) {
    const text = corpus.files.get(source);
    if (typeof text !== "string") failInfrastructure("missing-selected-markdown-source");
    if (text.trim() === "") findings.push(finding("DQ009", source, 1, "required-authority-empty"));
    findings.push(...validateMarkdownDocument({
      path: source,
      text,
      boundary: source.startsWith("skills/ipc/") ? "skills/ipc" : "",
      metrics,
      targetKindCache: targetPolicy.targetKindCache,
      resolveTarget: targetPolicy.resolveTarget,
    }));
  }
  return { findings: sortAndDedupe(findings), files: new Set(markdown).size, links: metrics.links };
}

function emitGateResult(mode, result) {
  if (result.findings.length > 0) {
    for (const item of result.findings) console.error(formatFinding(item));
    return 1;
  }
  console.log(`DOCS-QUALITY PASS mode=${mode} files=${result.files} links=${result.links}`);
  return 0;
}

function runRepositoryGate(seams = {}) {
  const corpus = acquireRepositoryCorpus(seams);
  return emitGateResult("repository", validateRepositoryCorpus(corpus));
}

function runInstalledGate(rootInput, seams = {}) {
  return emitGateResult("installed-root", validateInstalledCorpus(rootInput, seams));
}

function idsOf(findings) {
  return [...new Set(findings.map((item) => item.id))].sort();
}

function assertIds(name, actualFindings, expectedIds) {
  const actual = idsOf(actualFindings);
  const expected = [...expectedIds].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${name} expected=${expected.join(",") || "none"} actual=${actual.join(",") || "none"}`);
  }
}

function expectInfrastructure(name, run, reason) {
  try {
    run();
  } catch (error) {
    if (error instanceof InfrastructureError && error.message === reason) return;
    throw new Error(`${name} expected=${reason} actual=${asciiEscape(error.message)}`);
  }
  throw new Error(`${name} expected=${reason} actual=no-error`);
}

function validIndexText() {
  const rows = (targets, prefix = "") => targets.map((target) => `${prefix}${target}`).sort().map((relative) => {
    return `- [${path.posix.basename(relative, ".md")}](${relative}) - Authority for ${path.posix.basename(relative, ".md")}.`;
  }).join("\n");
  return [
    "# Documentation index",
    "",
    "These are intentional documentation scopes, not one global Markdown inventory.",
    "",
    MARKERS[0], rows(DIRECT_DOCS.map((item) => item.slice("docs/".length))), MARKERS[1],
    "", MARKERS[2], rows(ROOT_DOCS, "../"), MARKERS[3],
    "", MARKERS[4], rows(BUNDLED_DOCS.map((item) => item.slice("skills/ipc/".length)), "../skills/ipc/"), MARKERS[5],
    "",
  ].join("\n");
}

function validOperationalFiles() {
  const files = new Map();
  for (const file of REQUIRED_OPERATIONAL_FILES) files.set(file, "# Authority\n\nValid authority text.\n");
  files.set("docs/README.md", validIndexText());
  files.set(".claude-plugin/plugin.json", '{"version":"0.1.13"}\n');
  files.set("skills/ipc/scripts/handoff_to_codex.sh", "case x in\n-v|--version)\n  printf '%s\\n' 'handoff_to_codex.sh 0.1.13'\n  exit 0\n  ;;\nesac\n");
  files.set("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.13] - 2026-08-05\nNormal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.\n");
  files.set("README.md", [
    "# README", "", "## Status", "", "v0.1.13 \u00b7 Stable.",
    "Desktop-independent file transport; file-drop envelope and primary reply file do not depend on Desktop schema or pipe.",
    "Read-only private-schema-dependent inspector locator snapshot and rollout-derived fallback may drift after a Desktop update; validate.",
    "Experimental live Desktop named pipe codex:// focus behavior and write proof are unproven after every update.",
    "## Install", ...INSTALL_SESSION_SENTENCES,
    ...FIRST_USE_WARNING_SENTENCES,
    "## Quickstart", "Run from repository root: skills/ipc/scripts/handoff_to_codex.sh task.",
    "Only a genuinely absent reply is eligible for waiter rollout fallback. A present-but-invalid reply returns reply-missing without consulting rollout fallback. An absent reply with no certifiable rollout body exhausts the eligible sources.", NEW_MARKER_SENTENCE,
    "## Primary wrapper variables", "Component-specific options are documented by each tool's --help and bundled references.",
    "## Testing", "Complete local gate: bash tests/run_release_gates.sh. It includes 13 behavioral suites, text self-test/index/worktree, docs self-test/repository, manifest check, public safety scan, static contract audit, and separate process-ownership meta-gate.",
    "A four-command example is only a partial smoke set.", "",
  ].join("\n"));
  const waiterText = `# Waiter\n\nOnly a genuinely absent reply is eligible for waiter rollout fallback. A present-but-invalid reply returns reply-missing without consulting rollout fallback. An absent reply with no certifiable rollout body exhausts the eligible sources.\n${NEW_MARKER_SENTENCE}\n`;
  for (const file of WAITER_FILES) if (file !== "README.md") files.set(file, waiterText);
  const warning = FIRST_USE_WARNING_SENTENCES.join(" ");
  files.set("skills/ipc/SKILL.md", `${warning}\n\n## First decision\n${waiterText}`);
  files.set("skills/ipc/examples/quickstart.md", `${warning}\n\nRun from repository root for skills/ipc/scripts commands. Run from installed skill root for scripts commands. Run /ipc in Claude slash-command UI.\n\nskills/ipc/scripts/handoff_to_codex.sh task\n\n${waiterText}`);
  files.set("skills/ipc/references/troubleshooting.md", `${warning}\n\n## Delivery triage\n\n${waiterText}\n${validMojibakeGuidance()}`);
  files.set("docs/TROUBLESHOOTING.md", `# Troubleshooting\n\n${waiterText}\n${validMojibakeGuidance()}`);
  files.set("CONTRIBUTING.md", `# Contributing\n\n${validMojibakeGuidance()}`);
  files.set("docs/INSTALL.md", validInstallDisclosure());
  files.set("docs/ARCHITECTURE.md", "# Architecture\n\n## Inspection surfaces (read-only)\nInspector locator snapshot and validate-only revalidation are read-only.\n\n## Authorized write proof\nWrite-proof is dry-run by default and may send one marker only with explicit authorization.\n");
  files.set("docs/COMPATIBILITY.md", "# Compatibility\n\n## Current feature matrix\nCurrent-host confidence requires validate-only revalidation; live proof remains separately authorized.\n\n## Dated historical evidence, not current certification\n2026-07-09 historical observation.\n");
  files.set("tests/run_release_gates.sh", validRunnerText());
  files.set(".github/workflows/test.yml", validWorkflowText());
  return files;
}

function validInstallDisclosure() {
  return ["# Installation", "", ...FORCE_DISCLOSURE_SENTENCES, ""].join("\n");
}

function validMojibakeGuidance() {
  return [
    "Valid stored UTF-8 may display with the wrong decoder.",
    "Stored bytes may instead be invalid or corrupt.",
    "Valid UTF-8 may contain a known double-decoding signature.",
    "Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes a BOM; use a UTF-8/LF editor, PowerShell 7 utf8NoBOM, or .NET UTF8Encoding(false).",
    "Inspect raw bytes first, then restore or reconstruct from authoritative source, then run index and worktree gates, then semantic tests. Never paste broken console text back and no automatic transcoder is used.",
  ].join("\n");
}

function validRunnerText() {
  return [
    "DEFAULT_SUITES=(test_autoload_matrix.sh test_git_context_bound.sh test_ipc.sh test_ipc_wait.sh test_payload_mirror_parity.sh test_reply_harvest.sh test_reply_view.sh test_retention_sweep.sh test_rollout_reader.sh test_router_contract.sh test_session_inspect.sh test_uninstall_guard.sh test_wait_contract.sh)",
    '[ "${#SUITES[@]}" -gt 0 ] || SUITES=("${DEFAULT_SUITES[@]}")',
    "for s in \"${SUITES[@]}\"; do", "  run_one \"$s\" || true", "done",
    "node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --source index", "node tests/check_text_integrity.mjs --source worktree",
    "node tests/check_docs_quality.mjs --self-test", "node tests/check_docs_quality.mjs", "bash tests/gen_release_manifest.sh check-all --no-roots",
    "bash tests/scan_public_safety.sh", "node skills/ipc/scripts/codex_ipc_contract_audit.mjs", "",
  ].join("\n");
}

function validMonitoredRunnerText() {
  const prefix = validRunnerText().split("\n").slice(0, 5);
  return [...prefix,
    'run_monitored "text self-test" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --self-test',
    'run_monitored "text index" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --source index',
    'run_monitored "text worktree" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --source worktree',
    'run_monitored "docs self-test" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_docs_quality.mjs --self-test',
    'run_monitored "docs repository" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_docs_quality.mjs',
    'run_monitored "manifest" bash tests/gen_release_manifest.sh check-all --no-roots',
    'run_monitored "safety" bash tests/scan_public_safety.sh',
    'run_monitored "contract" "$NODE_BIN" "${NODE_FLAGS[@]}" skills/ipc/scripts/codex_ipc_contract_audit.mjs',
    "",
  ].join("\n");
}

function validWorkflowText() {
  const suites = ["test_autoload_matrix.sh", "test_git_context_bound.sh", "test_ipc.sh", "test_ipc_wait.sh", "test_payload_mirror_parity.sh", "test_reply_harvest.sh", "test_reply_view.sh", "test_retention_sweep.sh", "test_rollout_reader.sh", "test_router_contract.sh", "test_session_inspect.sh", "test_uninstall_guard.sh", "test_wait_contract.sh"];
  const commands = [...suites.map((suite) => `bash tests/${suite}`),
    "node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --source index", "node tests/check_text_integrity.mjs --source worktree",
    "node tests/check_docs_quality.mjs --self-test", "node tests/check_docs_quality.mjs", "bash tests/gen_release_manifest.sh check-all --no-roots",
    "bash tests/scan_public_safety.sh", "node skills/ipc/scripts/codex_ipc_contract_audit.mjs", "bash tests/test_gate_process_ownership.sh"];
  return ["jobs:", "  test:", "    strategy:", "      matrix:", "        os: [ubuntu-latest, windows-latest]",
    "    runs-on: ${{ matrix.os }}", "    defaults:", "      run:", "        shell: bash", "    steps:",
    ...commands.flatMap((command, index) => [`      - name: gate-${index}`, `        run: ${command}`]), "",
  ].join("\n");
}

function cloneFiles(files) {
  return new Map([...files].map(([name, text]) => [name, text]));
}

function replaceOnce(files, file, from, to = "") {
  const next = cloneFiles(files);
  const text = next.get(file);
  if (typeof text !== "string" || !text.includes(from)) throw new Error(`fixture-mutation-miss=${file}`);
  next.set(file, text.replace(from, to));
  return next;
}

function markdownFixture(text, targetKinds = {}) {
  return {
    path: "docs/source.md",
    text,
    root: "/fixture",
    targetKinds: new Map(Object.entries({
      "docs/target.md": "file",
      "docs/Dir/Nested.md": "file",
      "docs/image.png": "file",
      ...targetKinds,
    })),
  };
}

function expectNamedIds(run, expected) {
  return () => assertIds("behavior", run(), expected);
}

function expectHasId(run, expected) {
  return () => {
    const actual = idsOf(run());
    if (!actual.includes(expected)) throw new Error(`behavior expected-to-include=${expected} actual=${actual.join(",") || "none"}`);
  };
}

function addMarkdownTests(add) {
  const valid = [
    ["empty link label", "[](target.md)\n"],
    ["empty image alt", "![](image.png)\n"],
    ["plain local link", "[target](target.md)\n"],
    ["angle local link", "[target](<target.md>)\n"],
    ["inline image", "![image](image.png)\n"],
    ["escaped and nested labels", "[outer [inner] \\]](target.md)\n"],
    ["uppercase external schemes query fragment and title", "[h](HTTPS://example.test/a?q=1#f \"title\") [m](MAILTO:user@example.test)\n"],
    ["angle external and standalone autolink", "[h](<HTTPS://example.test/a?q=1#f> \"title\") <https://example.test/plain>\n"],
    ["external raw HTML", "<a href=\"https://example.test/a\">x</a>\n"],
    ["multiline external raw HTML", "<a\n href=\"https://example.test/a\">x</a>\n"],
    ["variable inline code run", "`` [masked](missing.md) `` [target](target.md)\n"],
    ["backtick fence masks links", "  ````lang\n[masked](missing.md)\n`````   \n[target](target.md)\n"],
    ["tilde fence masks links", "~~~\n[masked](missing.md)\n~~~~\n[target](target.md)\n"],
    ["shorter fence closer does not close", "````\n[masked](missing.md)\n```\n[still masked](missing.md)\n"],
    ["unterminated fence masks remainder", "~~~\n[masked](missing.md)\n"],
  ];
  for (const [name, text] of valid) add(`Markdown accepts ${name}`, expectNamedIds(
    () => validateMarkdownDocument(markdownFixture(text)), []));
  add("Markdown accepts safe decoded parent segment", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("[x](../target.md) [y](%2e%2e/target.md)\n", { "target.md": "file" })), []));
  add("Markdown accepts angle destination whitespace", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("[x](<target file.md>)\n", { "docs/target file.md": "file" })), []));
  add("Markdown accepts angle external nested parentheses", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("[x](<https://example.test/a(b)>)\n")), []));
  add("Markdown accepts residual percent after one decode", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("[x](Dir%252FNested.md)\n", { "docs/Dir%2FNested.md": "file" })), []));
  add("Markdown accepts encoded separator after containment", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("[x](Dir%2FNested.md)\n")), []));
  add("Markdown ignores escaped bracket opener", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("\\[x](missing.md)\n")), []));
  add("Markdown treats escaped backticks as literal", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("\\`[x](missing.md)\\`\n")), ["DQ001"]));
  add("Markdown rejects backtick-fence opener whose info string contains backtick", expectNamedIds(
    () => validateMarkdownDocument(markdownFixture("```lang`\n[x](missing.md)\n```\n")), ["DQ001"]));
  add("Markdown preserves astral code-mask offsets", expectNamedIds(() => validateMarkdownDocument(
    markdownFixture("\u{1f600}\u{1f600}\u{1f600} `code` [x](missing.md)\n")), ["DQ001"]));
  add("Markdown parser work is structurally linear", () => {
    const text = `${"[".repeat(8192)}x\n`;
    const metrics = { work: 0 };
    assertIds("linear-parser", validateMarkdownDocument({ ...markdownFixture(text), structuralMetrics: metrics }), []);
    if (!Number.isInteger(metrics.work) || metrics.work <= 0 || metrics.work > 12 * text.length) {
      throw new Error(`nonlinear-work=${metrics.work}`);
    }
  });
  add("Markdown escape parity work is structurally linear", () => {
    const text = `${"\\".repeat(8192)}plain\n`;
    const metrics = { work: 0 };
    assertIds("linear-escape-parser", validateMarkdownDocument({ ...markdownFixture(text), structuralMetrics: metrics }), []);
    if (!Number.isInteger(metrics.work) || metrics.work <= 0 || metrics.work > 4 * text.length
        || metrics.escapeUnits !== text.length - 1) {
      throw new Error(`nonlinear-escape-work=${metrics.work} escape-units=${metrics.escapeUnits}`);
    }
  });
  add("Repeated links classify one target once", () => {
    let reads = 0;
    const text = `${Array.from({ length: 1024 }, (_, index) => `[x${index}](target.md)`).join(" ")}\n`;
    const fixture = markdownFixture(text);
    fixture.resolveTarget = (resolved) => {
      reads += 1;
      return resolved === "docs/target.md" && reads === 1 ? "file" : "missing";
    };
    assertIds("target-classification-cache", validateMarkdownDocument(fixture), []);
    if (reads !== 1) throw new Error(`target-classification-reads=${reads}`);
  });
  add("Raw HTML line accounting is structurally linear", () => {
    const text = `${Array.from({ length: 2048 }, (_, index) => `<a href="https://example.test/${index}">x</a>`).join("\n")}\n`;
    const metrics = { work: 0 };
    assertIds("linear-raw-html", validateMarkdownDocument({ ...markdownFixture(text), structuralMetrics: metrics }), []);
    if (!Number.isInteger(metrics.htmlUnits) || metrics.htmlUnits <= 0 || metrics.htmlUnits > text.length) {
      throw new Error(`nonlinear-html-units=${metrics.htmlUnits}`);
    }
  });

  const grammarFailures = [
    ["local fragment", "[x](target.md#part)\n"],
    ["local query", "[x](target.md?q=1)\n"],
    ["malformed percent", "[x](target%ZZ.md)\n"],
    ["encoded fragment", "[x](target.md%23part)\n"],
    ["encoded query", "[x](target.md%3Fq)\n"],
    ["encoded backslash", "[x](Dir%5CNested.md)\n"],
    ["malformed UTF8 percent", "[x](%C3%28.md)\n"],
    ["raw backslash", "[x](Dir\\Nested.md)\n"],
    ["absolute rooted", "[x](/target.md)\n"],
    ["drive path", "[x](C:/target.md)\n"],
    ["drive relative path", "[x](C:target.md)\n"],
    ["UNC path", "[x](//server/share.md)\n"],
    ["device path", "[x](\\\\?\\C:\\target.md)\n"],
    ["ADS path", "[x](target.md:stream)\n"],
    ["dot segment", "[x](./target.md)\n"],
    ["empty destination", "[x]()\n"],
    ["protocol relative", "[x](//example.test/x)\n"],
    ["file scheme", "[x](file:///tmp/x)\n"],
    ["data scheme", "[x](data:text/plain,x)\n"],
    ["javascript scheme", "[x](javascript:alert)\n"],
    ["local title", "[x](target.md \"title\")\n"],
    ["local whitespace destination", "[x](two words.md)\n"],
    ["nested destination parentheses", "[x](a(b).md)\n"],
    ["reference definition", "[x]: target.md\n"],
    ["full reference usage", "[x][ref]\n"],
    ["collapsed reference usage", "[x][]\n"],
    ["shortcut reference usage", "[ref]\n[ref]: target.md\n"],
    ["raw HTML href", "<a href=\"target.md\">x</a>\n"],
    ["raw HTML src", "<img src=\"image.png\">\n"],
    ["unquoted raw HTML src", "<img src=image.png>\n"],
    ["second local raw HTML target", "<a href=\"https://example.test\">x</a><img src=\"image.png\">\n"],
    ["second attribute on one raw HTML tag", "<a href=\"https://example.test\" href=\"image.png\">x</a>\n"],
    ["multiline raw HTML href", "<a\n href=\"target.md\">x</a>\n"],
    ["malformed inline close", "[x](target.md\n"],
    ["unsupported escape", "[x\\q](target.md)\n"],
  ];
  for (const [name, text] of grammarFailures) add(`Markdown rejects ${name}`, expectNamedIds(
    () => validateMarkdownDocument(markdownFixture(text)), ["DQ002"]));

  const targetFailures = [
    ["containment escape", "[x](../../outside.md)\n", {}],
    ["missing target", "[x](missing.md)\n", {}],
    ["wrong-case target", "[x](dir/Nested.md)\n", {}],
    ["non-file target", "[x](target.md)\n", { "docs/target.md": "directory" }],
    ["redirected target", "[x](target.md)\n", { "docs/target.md": "redirected" }],
  ];
  for (const [name, text, kinds] of targetFailures) add(`Markdown rejects ${name}`, expectNamedIds(
    () => validateMarkdownDocument(markdownFixture(text, kinds)), ["DQ001"]));
}

function mutateMarker(text, marker, replacement) {
  if (!text.includes(marker)) throw new Error(`missing-marker-fixture=${marker}`);
  return text.replace(marker, replacement);
}

function addIndexTests(add) {
  const valid = validIndexText();
  const context = { direct: DIRECT_DOCS, root: ROOT_DOCS, bundled: BUNDLED_DOCS };
  add("Docs index accepts exact exhaustive scopes", expectNamedIds(() => validateDocsIndex(valid, context), []));
  const cases = [
    ["missing marker", mutateMarker(valid, MARKERS[0], "")],
    ["duplicate marker", `${MARKERS[0]}\n${valid}`],
    ["indented marker near miss", mutateMarker(valid, MARKERS[0], ` ${MARKERS[0]}`)],
    ["trailing marker near miss", mutateMarker(valid, MARKERS[0], `${MARKERS[0]} `)],
    ["case marker near miss", mutateMarker(valid, MARKERS[0], "<!-- IPC-DOCS:direct:BEGIN -->")],
    ["lookalike marker", mutateMarker(valid, MARKERS[0], "<!-- IPC-D0CS:DIRECT:BEGIN -->")],
    ["same-line marker", mutateMarker(valid, `${MARKERS[0]}\n`, `${MARKERS[0]} ${MARKERS[1]}\n`)],
    ["marker inside fence", mutateMarker(valid, MARKERS[0], `\`\`\`\n${MARKERS[0]}\n\`\`\``)],
    ["out-of-order markers", valid.replace(`${MARKERS[0]}\n`, `${MARKERS[1]}\n`).replace(`${MARKERS[1]}\n\n`, `${MARKERS[0]}\n\n`)],
    ["nested markers", valid.replace(MARKERS[1], `${MARKERS[2]}\n${MARKERS[1]}`)],
    ["missing row", valid.replace(/- \[ARCHITECTURE[^\n]+\n/, "")],
    ["duplicate row", valid.replace(/(- \[ARCHITECTURE[^\n]+\n)/, "$1$1")],
    ["extra stale row", valid.replace(MARKERS[1], "- [STALE](STALE.md) - Stale authority.\n" + MARKERS[1])],
    ["out-of-order rows", valid.replace(/(- \[ARCHITECTURE[^\n]+\n)(- \[COMPATIBILITY[^\n]+\n)/, "$2$1")],
    ["malformed row", valid.replace(" - Authority for ARCHITECTURE.", "")],
    ["extra title", valid.replace("(ARCHITECTURE.md)", "(ARCHITECTURE.md \"title\")")],
    ["casefold alias", valid.replace("(ARCHITECTURE.md)", "(architecture.md)")],
  ];
  for (const [name, text] of cases) add(`Docs index rejects ${name}`, expectNamedIds(
    () => validateDocsIndex(text, context), ["DQ003"]));
  add("Docs index rejects empty required file", expectNamedIds(() => validateDocsIndex("", context), ["DQ009"]));
  for (const [name, begin, end] of [["direct", 0, 1], ["root", 2, 3], ["bundled", 4, 5]]) {
    const pattern = new RegExp(`${MARKERS[begin].replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[\\s\\S]*?${MARKERS[end].replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`);
    add(`Docs index rejects empty ${name} marker section`, expectNamedIds(() => validateDocsIndex(
      valid.replace(pattern, `${MARKERS[begin]}\n${MARKERS[end]}`), context), ["DQ009", "DQ003"]));
  }
  add("Docs index rejects empty row description", expectNamedIds(() => validateDocsIndex(
    valid.replace(" - Authority for ARCHITECTURE.", " - "), context), ["DQ009", "DQ003"]));
  add("Docs index rejects multi-sentence description", expectNamedIds(() => validateDocsIndex(
    valid.replace("Authority for ARCHITECTURE.", "Authority for ARCHITECTURE. Not authority."), context), ["DQ003"]));
}

function addOperationalTests(add) {
  const valid = validOperationalFiles();
  add("Operational rules accept complete fixture", expectNamedIds(() => validateOperationalModel(valid), []));
  for (const file of REQUIRED_OPERATIONAL_FILES.filter((item) => item.endsWith(".md"))) {
    add(`DQ009 rejects empty selected Markdown ${file}`, expectHasId(
      () => validateOperationalModel(new Map([...valid, [file, "\n"]])), "DQ009"));
  }
  const blankSections = [
    ["architecture inspection", "docs/ARCHITECTURE.md", "Inspector locator snapshot and validate-only revalidation are read-only."],
    ["architecture write proof", "docs/ARCHITECTURE.md", "Write-proof is dry-run by default and may send one marker only with explicit authorization."],
    ["compatibility current matrix", "docs/COMPATIBILITY.md", "Current-host confidence requires validate-only revalidation; live proof remains separately authorized."],
    ["compatibility history", "docs/COMPATIBILITY.md", "2026-07-09 historical observation."],
  ];
  for (const [name, file, body] of blankSections) add(`DQ009 rejects blank ${name} section`, expectHasId(
    () => validateOperationalModel(replaceOnce(valid, file, body)), "DQ009"));
  const blankStatus = cloneFiles(valid);
  blankStatus.set("README.md", blankStatus.get("README.md").replace(/## Status\n[\s\S]*?## Install\n/, "## Status\n\n## Install\n"));
  add("DQ009 rejects blank README status section", expectHasId(
    () => validateOperationalModel(blankStatus), "DQ009"));
  const futureRelease = cloneFiles(valid);
  futureRelease.set(".claude-plugin/plugin.json", '{"version":"0.1.14"}\n');
  futureRelease.set("skills/ipc/scripts/handoff_to_codex.sh", futureRelease.get("skills/ipc/scripts/handoff_to_codex.sh").replaceAll("0.1.13", "0.1.14"));
  futureRelease.set("README.md", futureRelease.get("README.md").replace("v0.1.13", "v0.1.14"));
  futureRelease.set("CHANGELOG.md", [
    "# Changelog", "", "## [Unreleased]", "", "## [0.1.14] - 2026-08-09", "Current release notes.", "",
    "## [0.1.13] - 2026-08-05",
    "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.", "",
  ].join("\n"));
  add("DQ009 rejects empty current release body", expectNamedIds(() => validateOperationalModel(
    replaceOnce(futureRelease, "CHANGELOG.md", "## [0.1.14] - 2026-08-09\nCurrent release notes.",
      "## [0.1.14] - 2026-08-09\n")), ["DQ009"]));
  add("DQ009 rejects heading-only current release body", expectNamedIds(() => validateOperationalModel(
    replaceOnce(futureRelease, "CHANGELOG.md", "Current release notes.", "### Future")), ["DQ009"]));
  add("DQ017 accepts preserved corrected 0.1.13 behind current 0.1.14", expectNamedIds(
    () => validateOperationalModel(futureRelease), []));
  add("DQ017 rejects contradiction in preserved historical 0.1.13", expectNamedIds(
    () => validateOperationalModel(replaceOnce(futureRelease, "CHANGELOG.md",
      "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.",
      "No script's control flow, output bytes, or exit codes changed.")), ["DQ017"]));
  const monitored = cloneFiles(valid);
  monitored.set("tests/run_release_gates.sh", validMonitoredRunnerText());
  add("DQ008 accepts monitored argv-array runner invocations", expectNamedIds(() => validateOperationalModel(monitored), []));
  const guardedSafety = cloneFiles(valid);
  guardedSafety.set("tests/run_release_gates.sh", guardedSafety.get("tests/run_release_gates.sh").replace(
    "bash tests/scan_public_safety.sh", '[ "$RUN_SAFETY" -eq 1 ] && bash tests/scan_public_safety.sh'));
  add("DQ008 accepts exact RUN_SAFETY guard only for safety gate", expectNamedIds(
    () => validateOperationalModel(guardedSafety), []));
  const reordered = cloneFiles(valid);
  const workflowLines = reordered.get(".github/workflows/test.yml").split("\n");
  const behavioral = workflowLines.filter((line) => /^\s*run: bash tests\/test_/.test(line) && !line.includes("gate_process_ownership"));
  const reversedBehavioral = [...behavioral].reverse();
  let behavioralIndex = 0;
  reordered.set(".github/workflows/test.yml", workflowLines.map((line) => behavioral.includes(line)
    ? reversedBehavioral[behavioralIndex++] : line).join("\n"));
  add("DQ007 accepts differing runner and CI order", expectNamedIds(() => validateOperationalModel(reordered), []));
  const commentedSuite = cloneFiles(valid);
  commentedSuite.set("tests/run_release_gates.sh", commentedSuite.get("tests/run_release_gates.sh")
    .replace("test_ipc_wait.sh ", "# test_ipc_wait.sh "));
  add("DQ007 rejects comment-only suite name", expectNamedIds(() => validateOperationalModel(commentedSuite), ["DQ007"]));
  const inertArrayComment = cloneFiles(valid);
  inertArrayComment.set("tests/run_release_gates.sh", [
    "DEFAULT_SUITES=(", "# inert comment", ...EXPECTED_BEHAVIORAL_SUITES, ")",
    ...validRunnerText().split("\n").slice(1),
  ].join("\n"));
  add("DQ007 rejects inert comment inside multiline array", expectNamedIds(() => validateOperationalModel(inertArrayComment), ["DQ007"]));
  const inertGates = cloneFiles(valid);
  inertGates.set("tests/run_release_gates.sh", inertGates.get("tests/run_release_gates.sh").split("\n")
    .map((line) => /^(?:node|bash) /.test(line) ? `echo ${line}` : line).join("\n"));
  add("DQ008 rejects inert gate commands", expectNamedIds(() => validateOperationalModel(inertGates), ["DQ008"]));
  const duplicateGate = cloneFiles(valid);
  duplicateGate.set("tests/run_release_gates.sh", duplicateGate.get("tests/run_release_gates.sh")
    .replace("node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --self-test; node tests/check_text_integrity.mjs --self-test"));
  add("DQ008 rejects duplicate same-line gate", expectNamedIds(() => validateOperationalModel(duplicateGate), ["DQ008"]));
  const duplicateGateLines = cloneFiles(valid);
  duplicateGateLines.set("tests/run_release_gates.sh", duplicateGateLines.get("tests/run_release_gates.sh")
    .replace("node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --self-test\nnode tests/check_text_integrity.mjs --self-test"));
  add("DQ008 rejects duplicate exact executable gate lines", expectNamedIds(() => validateOperationalModel(duplicateGateLines), ["DQ008"]));
  const hiddenGateShapes = [
    ["function", 'dead_gate() {\nnode tests/check_docs_quality.mjs --self-test\n}'],
    ["heredoc", "cat <<'DEAD'\nnode tests/check_docs_quality.mjs --self-test\nDEAD"],
    ["substitution", "dead=$(\nnode tests/check_docs_quality.mjs --self-test\n)"],
    ["unapproved if", "if true; then\nnode tests/check_docs_quality.mjs --self-test\nfi"],
    ["loop", "while true; do\nnode tests/check_docs_quality.mjs --self-test\ndone"],
  ];
  for (const [shape, replacement] of hiddenGateShapes) add(`DQ008 rejects required runner gate inside ${shape}`, expectNamedIds(
    () => validateOperationalModel(replaceOnce(valid, "tests/run_release_gates.sh",
      "node tests/check_docs_quality.mjs --self-test", replacement)), ["DQ008"]));
  add("DQ007 and DQ008 reject one-OS CI matrix", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "os: [ubuntu-latest, windows-latest]", "os: [ubuntu-latest]")), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject excluded Windows matrix leg", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        os: [ubuntu-latest, windows-latest]",
      "        os: [ubuntu-latest, windows-latest]\n        exclude:\n          - os: windows-latest")), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject matrix include child", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        os: [ubuntu-latest, windows-latest]",
      "        os: [ubuntu-latest, windows-latest]\n        include:\n          - os: ubuntu-latest")), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject duplicate runs-on override", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "    runs-on: ${{ matrix.os }}",
      "    runs-on: ${{ matrix.os }}\n    runs-on: ubuntu-latest")), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject duplicate default shell override", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        shell: bash", "        shell: bash\n        shell: pwsh")), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject disabled CI job", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "  test:\n", "  test:\n    if: false\n")), ["DQ007", "DQ008"]));
  add("DQ007 rejects behavioral suite under if false", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        run: bash tests/test_ipc_wait.sh",
      "        if: false\n        run: bash tests/test_ipc_wait.sh")), ["DQ007"]));
  add("DQ007 rejects behavioral suite with continue-on-error", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        run: bash tests/test_ipc_wait.sh",
      "        continue-on-error: true\n        run: bash tests/test_ipc_wait.sh")), ["DQ007"]));
  add("DQ008 rejects outer gate under if false", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, ".github/workflows/test.yml", "        run: node tests/check_docs_quality.mjs --self-test",
      "        if: false\n        run: node tests/check_docs_quality.mjs --self-test")), ["DQ008"]));
  const deadRunner = cloneFiles(valid);
  deadRunner.set("tests/run_release_gates.sh", `if false; then\n${deadRunner.get("tests/run_release_gates.sh")}fi\n`);
  add("DQ007 and DQ008 reject whole runner under literal false", expectNamedIds(
    () => validateOperationalModel(deadRunner), ["DQ007", "DQ008"]));
  const multilineDeadRunner = cloneFiles(valid);
  multilineDeadRunner.set("tests/run_release_gates.sh", `if false\nthen\n${multilineDeadRunner.get("tests/run_release_gates.sh")}fi\n`);
  add("DQ007 and DQ008 reject multiline literal-false runner", expectNamedIds(
    () => validateOperationalModel(multilineDeadRunner), ["DQ007", "DQ008"]));
  const staticDeadRunner = cloneFiles(valid);
  staticDeadRunner.set("tests/run_release_gates.sh", `if [ 0 -eq 1 ]\nthen\n${staticDeadRunner.get("tests/run_release_gates.sh")}fi\n`);
  add("DQ007 and DQ008 reject statically false runner", expectNamedIds(
    () => validateOperationalModel(staticDeadRunner), ["DQ007", "DQ008"]));
  add("DQ007 and DQ008 reject early successful exit", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, "tests/run_release_gates.sh", "DEFAULT_SUITES=", "exit 0\nDEFAULT_SUITES=")), ["DQ007", "DQ008"]));
  add("DQ007 requires effective default-suite binding", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, "tests/run_release_gates.sh",
      '[ "${#SUITES[@]}" -gt 0 ] || SUITES=("${DEFAULT_SUITES[@]}")', "SUITES=()")), ["DQ007"]));
  const laterSuitesReset = cloneFiles(valid);
  laterSuitesReset.set("tests/run_release_gates.sh", laterSuitesReset.get("tests/run_release_gates.sh").replace(
    'SUITES=("${DEFAULT_SUITES[@]}")', 'SUITES=("${DEFAULT_SUITES[@]}")\nSUITES=()'));
  add("DQ007 rejects later suite reset", expectNamedIds(() => validateOperationalModel(laterSuitesReset), ["DQ007"]));
  add("DQ007 rejects suite unset before loop", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, "tests/run_release_gates.sh", 'for s in "${SUITES[@]}"; do',
      'unset SUITES\nfor s in "${SUITES[@]}"; do')), ["DQ007"]));
  add("DQ008 rejects active exit before outer gates", expectNamedIds(() => validateOperationalModel(
    replaceOnce(valid, "tests/run_release_gates.sh", '  run_one "$s" || true\ndone',
      '  run_one "$s" || true\ndone\nexit 0')), ["DQ008"]));
  const misplacedWorkflowSteps = cloneFiles(valid);
  misplacedWorkflowSteps.set(".github/workflows/test.yml", misplacedWorkflowSteps.get(".github/workflows/test.yml")
    .replace("    steps:\n", "    unrelated:\n") + "    steps:\n");
  add("DQ007 and DQ008 reject commands outside steps", expectNamedIds(
    () => validateOperationalModel(misplacedWorkflowSteps), ["DQ007", "DQ008"]));
  const duplicateInlineSteps = cloneFiles(valid);
  duplicateInlineSteps.set(".github/workflows/test.yml", `${duplicateInlineSteps.get(".github/workflows/test.yml")}    steps: []\n`);
  add("DQ007 and DQ008 reject inline duplicate steps key", expectNamedIds(
    () => validateOperationalModel(duplicateInlineSteps), ["DQ007", "DQ008"]));
  const cases = [
    ["DQ004 plugin version drift", replaceOnce(valid, ".claude-plugin/plugin.json", "0.1.13", "0.1.12"), "DQ004"],
    ["DQ004 wrapper version drift", replaceOnce(valid, "skills/ipc/scripts/handoff_to_codex.sh", "0.1.13", "0.1.12"), "DQ004"],
    ["DQ004 README version drift", replaceOnce(valid, "README.md", "v0.1.13", "v0.1.12"), "DQ004"],
    ["DQ004 changelog version drift", replaceOnce(valid, "CHANGELOG.md", "[0.1.13]", "[0.1.12]"), ["DQ004", "DQ017"]],
    ["DQ004 requires Unreleased before current release", replaceOnce(valid, "CHANGELOG.md", "## [Unreleased]\n\n"), "DQ004"],
    ["DQ005 invalid plugin add", replaceOnce(valid, "README.md", "claude --plugin-dir", "claude plugin add"), "DQ005"],
    ["DQ005 session scope removed", replaceOnce(valid, "README.md", "session-local", "persistent"), "DQ005"],
    ["DQ005 restart scope removed", replaceOnce(valid, "README.md", "new or restarted session", "current session"), "DQ005"],
  ];
  cases.push(["DQ005 rejects direct session-local negation", replaceOnce(valid, "README.md",
    "is a session-local plugin-development launch", "is not a session-local plugin-development launch"), "DQ005"]);
  const negatedCanonicalInstall = cloneFiles(valid);
  negatedCanonicalInstall.set("README.md", `${negatedCanonicalInstall.get("README.md")}It is false that ${INSTALL_SESSION_SENTENCES[0]}\n`);
  cases.push(["DQ005 rejects canonical sentence plus scoped negation", negatedCanonicalInstall, "DQ005"]);
  const scatteredInstall = cloneFiles(valid);
  scatteredInstall.set("README.md", scatteredInstall.get("README.md").replace(
    INSTALL_SESSION_SENTENCES.join("\n"),
    "claude --plugin-dir /path/to/claude-codex-ipc is persistent, not session-local. The phrase new or restarted session is obsolete. Elsewhere: /codex-ipc:ipc and standalone installer /ipc."));
  cases.push(["DQ005 rejects scattered contradictory install tokens", scatteredInstall, "DQ005"]);
  const fencedPluginAdd = cloneFiles(valid);
  fencedPluginAdd.set("README.md", `${fencedPluginAdd.get("README.md")}\n\`\`\`bash\nclaude plugin add /path/to/claude-codex-ipc\n\`\`\`\n`);
  cases.push(["DQ005 rejects unsupported command inside current fence", fencedPluginAdd, "DQ005"]);
  const wrapperDecoy = cloneFiles(valid);
  wrapperDecoy.set("skills/ipc/scripts/handoff_to_codex.sh", `# handoff_to_codex.sh 0.1.13\n${wrapperDecoy.get("skills/ipc/scripts/handoff_to_codex.sh").replace("0.1.13", "0.1.12")}`);
  cases.push(["DQ004 wrapper decoy cannot mask branch", wrapperDecoy, "DQ004"]);
  const readmeDecoy = cloneFiles(valid);
  readmeDecoy.set("README.md", readmeDecoy.get("README.md").replace("v0.1.13 \u00b7 Stable.", "Historical v0.1.13.\nv0.1.12 \u00b7 Stable."));
  cases.push(["DQ004 README decoy cannot mask status", readmeDecoy, "DQ004"]);
  const waiterClauses = [
    "Only a genuinely absent reply is eligible for waiter rollout fallback.",
    "A present-but-invalid reply returns reply-missing without consulting rollout fallback.",
    "An absent reply with no certifiable rollout body exhausts the eligible sources.",
    NEW_MARKER_SENTENCE,
  ];
  for (const file of WAITER_FILES) for (const clause of waiterClauses) {
    cases.push([`DQ006 ${file} clause removal`, replaceOnce(valid, file, clause), "DQ006"]);
  }
  cases.push(["DQ006 broad both-sources claim", replaceOnce(valid, "README.md", waiterClauses[0], "reply-missing exhausted both body sources."), "DQ006"]);
  cases.push(["DQ007 runner suite removed", replaceOnce(valid, "tests/run_release_gates.sh", "test_ipc_wait.sh "), "DQ007"]);
  cases.push(["DQ007 runner suite loop removed", replaceOnce(valid, "tests/run_release_gates.sh",
    "for s in \"${SUITES[@]}\"; do\n  run_one \"$s\" || true\ndone\n"), "DQ007"]);
  cases.push(["DQ007 rejects active break in suite loop", replaceOnce(valid, "tests/run_release_gates.sh",
    "  run_one \"$s\" || true\ndone", "  run_one \"$s\" || true\n  break\ndone"), "DQ007"]);
  cases.push(["DQ007 rejects unterminated suite loop", replaceOnce(valid, "tests/run_release_gates.sh",
    "  run_one \"$s\" || true\ndone\n", "  run_one \"$s\" || true\n"), ["DQ007", "DQ008"]]);
  cases.push(["DQ007 CI suite removed", replaceOnce(valid, ".github/workflows/test.yml", "run: bash tests/test_ipc_wait.sh\n"), "DQ007"]);
  cases.push(["DQ007 syntax line not suite", replaceOnce(valid, ".github/workflows/test.yml", "run: bash tests/test_ipc_wait.sh", "run: bash -n tests/test_ipc_wait.sh"), "DQ007"]);
  cases.push(["DQ007 rejects same-count substitution", replaceOnce(valid, ".github/workflows/test.yml", "test_ipc_wait.sh", "test_fake_wait.sh"), "DQ007"]);
  cases.push(["DQ007 rejects duplicate same-count suite", replaceOnce(valid, ".github/workflows/test.yml", "test_router_contract.sh", "test_ipc_wait.sh"), "DQ007"]);
  const coordinatedSubstitution = replaceOnce(
    replaceOnce(valid, "tests/run_release_gates.sh", "test_ipc_wait.sh", "test_fake_wait.sh"),
    ".github/workflows/test.yml", "test_ipc_wait.sh", "test_fake_wait.sh",
  );
  cases.push(["DQ007 rejects coordinated runner and CI substitution", coordinatedSubstitution, "DQ007"]);
  const gates = [
    "node tests/check_text_integrity.mjs --self-test", "node tests/check_text_integrity.mjs --source index", "node tests/check_text_integrity.mjs --source worktree",
    "node tests/check_docs_quality.mjs --self-test", "node tests/check_docs_quality.mjs", "bash tests/gen_release_manifest.sh check-all --no-roots",
    "bash tests/scan_public_safety.sh", "node skills/ipc/scripts/codex_ipc_contract_audit.mjs",
  ];
  for (const gate of gates) cases.push([`DQ008 runner gate ${gate}`, replaceOnce(valid, "tests/run_release_gates.sh", gate), "DQ008"]);
  for (const gate of gates) cases.push([`DQ008 CI gate ${gate}`, replaceOnce(valid, ".github/workflows/test.yml", `        run: ${gate}`), "DQ008"]);
  const duplicateCiGate = cloneFiles(valid);
  duplicateCiGate.set(".github/workflows/test.yml", duplicateCiGate.get(".github/workflows/test.yml").replace(
    "        run: node tests/check_docs_quality.mjs --self-test",
    "        run: node tests/check_docs_quality.mjs --self-test\n      - name: duplicate-docs-self\n        run: node tests/check_docs_quality.mjs --self-test"));
  cases.push(["DQ008 rejects duplicate exact CI outer gate", duplicateCiGate, "DQ008"]);
  cases.push(["DQ007 and DQ008 require matrix parent", replaceOnce(valid, ".github/workflows/test.yml",
    "    strategy:\n      matrix:", "    unrelated:\n      matrix:"), ["DQ007", "DQ008"]]);
  cases.push(["DQ007 and DQ008 require defaults run parent", replaceOnce(valid, ".github/workflows/test.yml",
    "    defaults:\n      run:", "    unrelated:\n      run:"), ["DQ007", "DQ008"]]);
  const failFastMatrix = cloneFiles(valid);
  failFastMatrix.set(".github/workflows/test.yml", failFastMatrix.get(".github/workflows/test.yml").replace(
    "    strategy:\n      matrix:", "    strategy:\n      fail-fast: false\n      matrix:"));
  add("DQ007 accepts exact fail-fast false matrix control", expectNamedIds(() => validateOperationalModel(failFastMatrix), []));
  cases.push(["DQ008 meta gate removed", replaceOnce(valid, ".github/workflows/test.yml", "run: bash tests/test_gate_process_ownership.sh"), "DQ008"]);
  cases.push(["DQ009 required file empty", new Map([...valid, ["SECURITY.md", ""]]), "DQ009"]);
  const forceClauses = ["entire existing target", "Local modifications and unlisted residue are not preserved", "no automatic backup", "transaction", "rollback", "Run dry-run first", "CODEX_IPC_ROOT"];
  for (const clause of forceClauses) cases.push([`DQ010 force clause ${clause}`, replaceOnce(valid, "docs/INSTALL.md", clause), "DQ010"]);
  cases.push(["DQ010 rejects direct force-removal negation", replaceOnce(valid, "docs/INSTALL.md",
    "`--force` / `-Force` removes the entire existing target before copying.", "`--force` / `-Force` does not remove the entire existing target before copying."), "DQ010"]);
  const negatedCanonicalForce = cloneFiles(valid);
  negatedCanonicalForce.set("docs/INSTALL.md", `${negatedCanonicalForce.get("docs/INSTALL.md")}${FORCE_DISCLOSURE_SENTENCES[0]} This sentence is false.\n`);
  cases.push(["DQ010 rejects canonical sentence plus suffix contradiction", negatedCanonicalForce, "DQ010"]);
  const warningClauses = ["plaintext", "read and modified", "secrets", "indefinite", "not confidentiality or secure deletion", "Backups, sync tools, snapshots, and filesystem recovery"];
  for (const file of FIRST_USE_FILES) for (const clause of warningClauses) {
    cases.push([`DQ011 ${file} clause ${clause}`, replaceOnce(valid, file, clause), "DQ011"]);
  }
  const moved = cloneFiles(valid);
  const quickWarning = moved.get("skills/ipc/examples/quickstart.md").split("\n\n")[0];
  moved.set("skills/ipc/examples/quickstart.md", moved.get("skills/ipc/examples/quickstart.md").replace(`${quickWarning}\n\n`, "") + `\n${quickWarning}\n`);
  cases.push(["DQ011 warning after first dispatch", moved, "DQ011"]);
  cases.push(["DQ011 rejects other-user opposite", replaceOnce(valid, "README.md", "same-user processes", "other-user processes"), "DQ011"]);
  cases.push(["DQ011 rejects no-secrets inversion", replaceOnce(valid, "README.md", "task text must not contain secrets", "task text may contain secrets"), "DQ011"]);
  cases.push(["DQ011 rejects retention negation", replaceOnce(valid, "README.md", "may retain deleted content", "cannot retain deleted content"), "DQ011"]);
  const negatedCanonicalWarning = cloneFiles(valid);
  negatedCanonicalWarning.set("README.md", negatedCanonicalWarning.get("README.md").replace(
    "## Quickstart", `It is false that ${FIRST_USE_WARNING_SENTENCES[0]}\n## Quickstart`));
  cases.push(["DQ011 rejects canonical warning plus scoped negation", negatedCanonicalWarning, "DQ011"]);
  cases.push(["DQ012 unaffected overclaim", replaceOnce(valid, "README.md", "do not depend on Desktop schema or pipe", "are unaffected after Desktop updates"), "DQ012"]);
  cases.push(["DQ012 visible claim cannot be replaced by comment decoy", replaceOnce(valid, "README.md", "Desktop-independent", "<!-- Desktop-independent -->"), "DQ012"]);
  for (const clause of ["Desktop-independent", "private-schema-dependent", "Experimental live Desktop"]) cases.push([`DQ012 class ${clause}`, replaceOnce(valid, "README.md", clause), "DQ012"]);
  cases.push(["DQ013 all env vars restored", replaceOnce(valid, "README.md", "Primary wrapper variables", "Configuration (all env vars)"), "DQ013"]);
  cases.push(["DQ013 component pointer removed", replaceOnce(valid, "README.md", "Component-specific options are documented by each tool's --help and bundled references."), ["DQ009", "DQ013"]]);
  cases.push(["DQ014 complete runner removed", replaceOnce(valid, "README.md", "bash tests/run_release_gates.sh"), "DQ014"]);
  cases.push(["DQ014 smoke label removed", replaceOnce(valid, "README.md", "partial smoke set", "complete gate"), "DQ014"]);
  cases.push(["DQ015 all read-only restored", replaceOnce(valid, "docs/ARCHITECTURE.md", "Inspection surfaces (read-only)", "Inspection and validation surfaces (all read-only)"), "DQ015"]);
  cases.push(["DQ015 write proof class removed", replaceOnce(valid, "docs/ARCHITECTURE.md", "Authorized write proof"), "DQ015"]);
  cases.push(["DQ015 rejects write proof as read-only", replaceOnce(valid, "docs/ARCHITECTURE.md", "Write-proof is dry-run by default", "Write-proof is read-only and dry-run by default"), "DQ015"]);
  const historicalReadonly = cloneFiles(valid);
  historicalReadonly.set("docs/ARCHITECTURE.md", `${historicalReadonly.get("docs/ARCHITECTURE.md")}\n## Dated history\nHistorical prose said all read-only.\n`);
  add("DQ015 ignores historical all-read-only prose", expectNamedIds(() => validateOperationalModel(historicalReadonly), []));
  cases.push(["DQ016 history heading removed", replaceOnce(valid, "docs/COMPATIBILITY.md", "Dated historical evidence, not current certification", "Host-identity ledger"), "DQ016"]);
  cases.push(["DQ016 historical section requires dated row", replaceOnce(valid, "docs/COMPATIBILITY.md", "2026-07-09 historical observation."), ["DQ009", "DQ016"]]);
  cases.push(["DQ016 current nonclaim removed", replaceOnce(valid, "docs/COMPATIBILITY.md", "Current-host confidence requires validate-only revalidation; live proof remains separately authorized."), ["DQ009", "DQ016"]]);
  const currentCertification = cloneFiles(valid);
  currentCertification.set("docs/COMPATIBILITY.md", `${currentCertification.get("docs/COMPATIBILITY.md")}\nThe dated row is current certification.\n`);
  cases.push(["DQ016 rejects current-certification contradiction", currentCertification, "DQ016"]);
  const claimsMovedToHistory = cloneFiles(valid);
  claimsMovedToHistory.set("docs/COMPATIBILITY.md", "# Compatibility\n\n## Current feature matrix\nNo current claims.\n\n## Dated historical evidence, not current certification\nCurrent-host confidence requires validate-only revalidation; live proof remains separately authorized.\n");
  cases.push(["DQ016 current claims cannot live only in history", claimsMovedToHistory, "DQ016"]);
  cases.push(["DQ017 no output bytes contradiction", replaceOnce(valid, "CHANGELOG.md", "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.", "No script's control flow, output bytes, or exit codes changed."), "DQ017"]);
  const versionCommentDecoy = replaceOnce(valid, "CHANGELOG.md", "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.", "<!-- Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13. -->");
  cases.push(["DQ017 comment decoy cannot satisfy corrected relationship", versionCommentDecoy, ["DQ009", "DQ017"]]);
  cases.push(["DQ017 explicit negation cannot satisfy corrected relationship", replaceOnce(valid, "CHANGELOG.md", "Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.", "It is false that Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13."), "DQ017"]);
  const trailingVersionNegation = cloneFiles(valid);
  trailingVersionNegation.set("CHANGELOG.md", `${trailingVersionNegation.get("CHANGELOG.md")}It is false that Normal dispatch control flow and operational output did not change.\n`);
  cases.push(["DQ017 rejects trailing scoped negation", trailingVersionNegation, "DQ017"]);
  for (const clause of ["repository root", "installed skill root", "Claude slash-command UI"]) cases.push([`DQ018 context ${clause}`, replaceOnce(valid, "skills/ipc/examples/quickstart.md", clause), "DQ018"]);
  const swappedContexts = cloneFiles(valid);
  swappedContexts.set("skills/ipc/examples/quickstart.md", swappedContexts.get("skills/ipc/examples/quickstart.md").replace(
    "Run from repository root for skills/ipc/scripts commands. Run from installed skill root for scripts commands. Run /ipc in Claude slash-command UI.",
    "Run /ipc from repository root. Run scripts from Claude slash-command UI. The installed skill root is only a storage label.",
  ));
  cases.push(["DQ018 rejects swapped contexts", swappedContexts, "DQ018"]);
  const historicalContexts = cloneFiles(valid);
  historicalContexts.set("skills/ipc/examples/quickstart.md", historicalContexts.get("skills/ipc/examples/quickstart.md").replace(
    "Run from repository root for skills/ipc/scripts commands. Run from installed skill root for scripts commands. Run /ipc in Claude slash-command UI.",
    "Current command contexts are unspecified.",
  ) + "\n## Dated historical evidence, not current certification\nRun from repository root for skills/ipc/scripts commands. Run from installed skill root for scripts commands. Run /ipc in Claude slash-command UI.\n");
  cases.push(["DQ018 historical context decoy cannot satisfy current claim", historicalContexts, "DQ018"]);
  const historicalPlugin = cloneFiles(valid);
  historicalPlugin.set("docs/COMPATIBILITY.md", `${historicalPlugin.get("docs/COMPATIBILITY.md")}\nHistorical note: claude plugin add was once discussed.\n`);
  add("DQ005 ignores exact historical section", expectNamedIds(() => validateOperationalModel(historicalPlugin), []));
  const recoveryClauses = ["wrong decoder", "invalid or corrupt", "double-decoding signature", "PowerShell 5.1", "writes a BOM", "raw bytes first", "restore or reconstruct from authoritative source", "index and worktree gates", "then semantic tests", "no automatic transcoder"];
  for (const file of MOJIBAKE_GUIDANCE_FILES) for (const clause of recoveryClauses) {
    cases.push([`DQ019 ${file} clause ${clause}`, replaceOnce(valid, file, clause), "DQ019"]);
  }
  for (const file of MOJIBAKE_GUIDANCE_FILES) {
    const reordered = cloneFiles(valid);
    reordered.set(file, reordered.get(file).replace(
      "Inspect raw bytes first, then restore or reconstruct from authoritative source, then run index and worktree gates, then semantic tests.",
      "Run semantic tests first, then inspect raw bytes first, then restore or reconstruct from authoritative source.",
    ));
    cases.push([`DQ019 ${file} rejects semantic-before-raw order`, reordered, "DQ019"]);
  }
  for (const [name, files, id] of cases) add(name, expectNamedIds(() => validateOperationalModel(files), Array.isArray(id) ? id : [id]));
}

function registerFixture(tempParent, name) {
  const target = path.join(tempParent, name);
  if (path.dirname(target) !== tempParent || existsSync(target)) failInfrastructure("unsafe-self-test-fixture-path");
  SELF_TEST_TEMP_REGISTRY.push(target);
  mkdirSync(target, { recursive: false });
  return target;
}

function cleanupSelfTestTemp(tempParent, inventoryBefore, registry) {
  let failure = null;
  for (const registered of [...registry].reverse()) {
    if (path.dirname(registered) !== tempParent) {
      failure = "unsafe-registered-temp-path";
      continue;
    }
    try { if (existsSync(registered)) rmSync(registered, { recursive: true, force: true }); }
    catch { failure = "registered-temp-removal-failed"; }
  }
  registry.length = 0;
  try {
    if (inventoryBefore !== null) {
      const after = readdirSync(tempParent).sort();
      if (JSON.stringify(after) !== JSON.stringify(inventoryBefore)) failure = "temp-parent-inventory-not-restored";
    }
    if (path.resolve(path.dirname(tempParent)) !== path.resolve(tmpdir())) failure = "unsafe-temp-parent";
    else rmSync(tempParent, { recursive: true, force: true });
    if (existsSync(tempParent)) failure = "temp-parent-removal-failed";
  } catch { failure = "temp-cleanup-failed"; }
  return failure;
}

function writeFixtureFile(root, relative, bytes) {
  const target = path.join(root, ...relative.split("/"));
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, bytes);
}

function validInstalledText(relative) {
  if (relative === "SKILL.md") return "# Skill\n\n[Architecture](references/architecture.md)\n";
  return `# ${path.posix.basename(relative)}\n\nInstalled authority.\n`;
}

function createInstalledFixture(tempParent, name) {
  const root = registerFixture(tempParent, name);
  for (const relative of INSTALLED_DOCS) writeFixtureFile(root, relative, Buffer.from(validInstalledText(relative)));
  return root;
}

function fixtureSnapshot(root) {
  const records = [];
  const walk = (directory, prefix = "") => {
    for (const entry of readdirSync(directory, { encoding: "utf8", withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        records.push(`d:${relative}`);
        walk(path.join(directory, entry.name), relative);
      } else {
        records.push(`f:${relative}:${readFileSync(path.join(directory, entry.name)).toString("base64")}`);
      }
    }
  };
  walk(root);
  return records.join("\n");
}

function selfTestGit(cwd, args, input = undefined) {
  const isolated = path.join(cwd, ".isolated-home");
  mkdirSync(isolated, { recursive: true });
  const env = {
    PATH: process.env.PATH,
    SystemRoot: process.env.SystemRoot,
    HOME: isolated,
    USERPROFILE: isolated,
    CODEX_IPC_ROOT: path.join(isolated, "ipc-disabled"),
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: path.join(isolated, "missing.gitconfig"),
    GIT_OPTIONAL_LOCKS: "0",
    GIT_ATTR_NOSYSTEM: "1",
    GIT_NO_REPLACE_OBJECTS: "1",
    GIT_NO_LAZY_FETCH: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_PAGER: "cat",
  };
  const result = spawnSync("git", args, { cwd, input, encoding: null, env, shell: false, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error(`fixture-git-failed=${args[0]}`);
  return result.stdout;
}

function createRepositoryFixture(tempParent, name) {
  const root = registerFixture(tempParent, name);
  selfTestGit(root, ["init", "--quiet"]);
  selfTestGit(root, ["config", "user.email", "fixture@example.invalid"]);
  selfTestGit(root, ["config", "user.name", "Fixture"]);
  const files = validOperationalFiles();
  for (const [relative, text] of files) writeFixtureFile(root, relative, Buffer.from(text));
  writeFixtureFile(root, "tests/check_docs_quality.mjs", readFileSync(MODULE_PATH));
  selfTestGit(root, ["add", "--", "."]);
  return root;
}

function addInstalledTests(add, tempParent) {
  const validRoot = createInstalledFixture(tempParent, "installed-valid");
  add("Installed fixture exact inventory passes without writes", () => {
    const before = fixtureSnapshot(validRoot);
    assertIds("installed-valid", validateInstalledFixture(validRoot), []);
    if (fixtureSnapshot(validRoot) !== before) throw new Error("installed-validation-wrote-fixture");
  });
  const sharedTarget = createInstalledFixture(tempParent, "installed-shared-target");
  writeFixtureFile(sharedTarget, "examples/quickstart.md",
    Buffer.from("# Quickstart\n\n[Architecture](../references/architecture.md)\n"));
  add("Installed corpus classifies a shared target once without target-body rereads", () => {
    const reads = new Map();
    const targetMetrics = {};
    const result = validateInstalledCorpus(sharedTarget, {
      targetMetrics,
      readFile: (candidate) => {
        const key = path.relative(sharedTarget, candidate).split(path.sep).join("/");
        reads.set(key, (reads.get(key) || 0) + 1);
        return readFileSync(candidate);
      },
    });
    assertIds("installed-shared-target", result.findings, []);
    const totalReads = [...reads.values()].reduce((sum, count) => sum + count, 0);
    if (targetMetrics.classifications !== 1 || totalReads !== INSTALLED_DOCS.length
        || reads.get("references/architecture.md") !== 1) {
      throw new Error(`target-classifications=${targetMetrics.classifications} reads=${totalReads} architecture=${reads.get("references/architecture.md")}`);
    }
  });
  const manyMissing = createInstalledFixture(tempParent, "installed-many-missing");
  const missingCount = 128;
  writeFixtureFile(manyMissing, "SKILL.md", Buffer.from(`# Skill\n\n${Array.from(
    { length: missingCount }, (_, index) => `[missing-${index}](missing-${index}.md)`,
  ).join(" ")}\n`));
  add("Installed corpus precomputes casefold lookup for many unique missing targets", () => {
    const targetMetrics = {};
    assertIds("installed-many-missing", validateInstalledCorpus(manyMissing, { targetMetrics }).findings, ["DQ001"]);
    if (targetMetrics.casefoldBuilds !== 1 || targetMetrics.casefoldEntries !== INSTALLED_DOCS.length
        || targetMetrics.casefoldLookups !== missingCount || targetMetrics.classifications !== 0) {
      throw new Error(`casefold-builds=${targetMetrics.casefoldBuilds} entries=${targetMetrics.casefoldEntries} lookups=${targetMetrics.casefoldLookups} classifications=${targetMetrics.classifications}`);
    }
  });
  add("Installed CLI success has exact rc0 byte contract", () => {
    const result = spawnSync(process.execPath, [MODULE_PATH, "--installed-root", validRoot], { encoding: null, shell: false, windowsHide: true });
    const expected = Buffer.from(`DOCS-QUALITY PASS mode=installed-root files=${INSTALLED_DOCS.length} links=1\n`, "ascii");
    if (result.error || result.status !== 0 || !result.stdout.equals(expected) || result.stderr.length !== 0) throw new Error("installed-cli-success-contract");
  });
  add("Installed CLI acquisition failure has exact rc2 byte contract", () => {
    const missingPath = path.join(tempParent, "cli-missing");
    const result = spawnSync(process.execPath, [MODULE_PATH, "--installed-root", missingPath], { encoding: null, shell: false, windowsHide: true });
    const expected = Buffer.from(`DQ900 path=${asciiEscape(path.resolve(missingPath))} line=0 reason=missing-installed-root\n`, "ascii");
    if (result.error || result.status !== 2 || result.stdout.length !== 0 || !result.stderr.equals(expected)) throw new Error("installed-cli-failure-contract");
  });
  add("Installed root accepts relative caller path after explicit resolution", () => {
    const relative = path.relative(process.cwd(), validRoot);
    assertIds("relative-installed", validateInstalledFixture(relative), []);
  });
  add("Installed missing root fails closed", () => expectInfrastructure("missing-root",
    () => validateInstalledFixture(path.join(tempParent, "missing")), "missing-installed-root"));
  add("Installed filesystem anchor fails closed", () => expectInfrastructure("anchor-root",
    () => validateInstalledFixture(path.parse(path.resolve(validRoot)).root), "unsupported-installed-root-anchor"));

  const missing = createInstalledFixture(tempParent, "installed-missing");
  rmSync(path.join(missing, "references", "architecture.md"));
  add("Installed missing member fails closed", () => expectInfrastructure("missing-member",
    () => validateInstalledFixture(missing), "installed-inventory-mismatch"));
  const extra = createInstalledFixture(tempParent, "installed-extra");
  writeFixtureFile(extra, "references/extra.md", Buffer.from("# Extra\n"));
  add("Installed extra direct Markdown fails closed", () => expectInfrastructure("extra-member",
    () => validateInstalledFixture(extra), "installed-inventory-mismatch"));
  const nested = createInstalledFixture(tempParent, "installed-nested");
  writeFixtureFile(nested, "references/nested/extra.md", Buffer.from("# Extra\n"));
  add("Installed nested Markdown fails closed", () => expectInfrastructure("nested-member",
    () => validateInstalledFixture(nested), "installed-nested-markdown"));
  const nonregular = createInstalledFixture(tempParent, "installed-nonregular");
  rmSync(path.join(nonregular, "references", "architecture.md"));
  mkdirSync(path.join(nonregular, "references", "architecture.md"));
  add("Installed nonregular member fails closed", () => expectInfrastructure("nonregular-member",
    () => validateInstalledFixture(nonregular), "nonregular-installed-member"));
  const empty = createInstalledFixture(tempParent, "installed-empty");
  writeFixtureFile(empty, "references/architecture.md", Buffer.from("\n"));
  add("DQ009 rejects empty installed bundled Markdown", expectHasId(
    () => validateInstalledFixture(empty), "DQ009"));
  const wrongCase = createInstalledFixture(tempParent, "installed-wrong-case");
  const oldCase = path.join(wrongCase, "references", "architecture.md");
  const newCase = path.join(wrongCase, "references", "ARCHITECTURE.md");
  const tempCase = path.join(wrongCase, "references", "case.tmp");
  renameSync(oldCase, tempCase);
  renameSync(tempCase, newCase);
  add("Installed wrong-case member fails closed", () => expectInfrastructure("wrong-case-member",
    () => validateInstalledFixture(wrongCase), "installed-case-mismatch"));
  const wrongCaseLink = createInstalledFixture(tempParent, "installed-wrong-case-link");
  writeFixtureFile(wrongCaseLink, "SKILL.md", Buffer.from("# Skill\n\n[Architecture](references/Architecture.md)\n"));
  add("Installed actual wrong-case link target is DQ001", expectNamedIds(
    () => validateInstalledFixture(wrongCaseLink), ["DQ001"]));
  for (const seamKey of ["<root>", "references", "references/architecture.md"]) {
    add(`Installed selected Dirent predicate rejects ${seamKey} reparse`, () => expectInfrastructure("reparse",
      () => validateInstalledFixture(validRoot, { direntKind: { [seamKey]: "reparse" } }), "redirected-installed-segment"));
  }
  const junction = createInstalledFixture(tempParent, "installed-junction");
  const junctionTarget = registerFixture(tempParent, "junction-target");
  for (const relative of INSTALLED_DOCS.filter((item) => item.startsWith("references/"))) {
    writeFixtureFile(junctionTarget, relative.slice("references/".length), Buffer.from(validInstalledText(relative)));
  }
  rmSync(path.join(junction, "references"), { recursive: true, force: true });
  let junctionNative = true;
  try { symlinkSync(junctionTarget, path.join(junction, "references"), "junction"); }
  catch (error) {
    if (!["EPERM", "EACCES", "ENOTSUP", "EINVAL"].includes(error.code)) throw error;
    junctionNative = false;
    mkdirSync(path.join(junction, "references"));
    for (const relative of INSTALLED_DOCS.filter((item) => item.startsWith("references/"))) {
      writeFixtureFile(junction, relative, Buffer.from(validInstalledText(relative)));
    }
  }
  add("Installed native junction or mandatory selected-Dirent fallback is rejected", () => expectInfrastructure("junction",
    () => validateInstalledFixture(junction, junctionNative ? {} : { direntKind: { references: "reparse" } }), "redirected-installed-segment"));
  add("Installed realpath escape fails closed", () => expectInfrastructure("realpath-escape",
    () => validateInstalledFixture(validRoot, { realpath: { "references/architecture.md": path.dirname(validRoot) } }), "installed-realpath-escape"));

  const textCases = [
    ["invalid UTF-8", Buffer.from([0xff, 0x0a]), "TXT001"],
    ["BOM", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("x\n")]), "TXT002"],
    ["CR", Buffer.from("x\r\n"), "TXT003"],
    ["format control", Buffer.from("x\u200b\n"), "TXT004"],
    ["missing final LF", Buffer.from("x"), "TXT005"],
    ["mojibake tuple", Buffer.from("\u00e2\u20ac\u201d\n"), "TXT006"],
  ];
  for (const [name, bytes, id] of textCases) {
    const root = createInstalledFixture(tempParent, `installed-text-${id.toLowerCase()}`);
    writeFixtureFile(root, "references/architecture.md", bytes);
    add(`Installed scanner preserves ${name} ${id}`, expectNamedIds(() => validateInstalledFixture(root), [id]));
  }
  add("Installed scanner preserves TXT007 fields", expectNamedIds(() => validateInstalledFixture(validRoot, {
    scanTextBuffer: (_bytes, context) => context.path === "skills/ipc/SKILL.md"
      ? [{ id: "TXT007", source: context.source, path: context.path, byteOffset: 0, codePointOffset: 0, reason: "fixture-exception" }]
      : [],
  }), ["TXT007"]));
  add("Installed scanner throw fails as infrastructure", () => expectInfrastructure("scanner-throw",
    () => validateInstalledFixture(validRoot, { scanTextBuffer: () => { throw new Error("fixture"); } }), "text-scanner-threw"));
  for (const [name, result] of [["non-array", null], ["malformed entry", [{}]]]) {
    add(`Installed scanner rejects ${name} result`, () => expectInfrastructure(name,
      () => validateInstalledFixture(validRoot, { scanTextBuffer: () => result }), "malformed-text-scanner-result"));
  }
  const leak = createInstalledFixture(tempParent, "installed-repo-link");
  writeFixtureFile(leak, "SKILL.md", Buffer.from("# Skill\n\n[Repo](../../README.md)\n"));
  add("Installed repository-only link leakage fails", expectNamedIds(() => validateInstalledFixture(leak), ["DQ001"]));
}

function indexRecord(mode = "100644", oid = "1".repeat(40), stage = "0", name = "docs/A.md") {
  return Buffer.from(`${mode} ${oid} ${stage}\t${name}\0`, "utf8");
}

function addRepositoryAcquisitionTests(add, tempParent) {
  add("Index parser accepts regular stage0 records", () => {
    const parsed = parseIndexEntries(Buffer.concat([indexRecord(), indexRecord("100755", "2".repeat(40), "0", "docs/B.md")]));
    if (parsed.length !== 2) throw new Error(`expected=2 actual=${parsed.length}`);
  });
  const bad = [
    ["malformed framing", indexRecord().subarray(0, indexRecord().length - 1), "malformed-index-framing"],
    ["empty inventory", Buffer.alloc(0), "empty-index-inventory"],
    ["invalid UTF8 path", Buffer.concat([Buffer.from(`100644 ${"1".repeat(40)} 0\t`), Buffer.from([0xff, 0])]), "invalid-utf8-index-path"],
    ["unknown mode", indexRecord("100600"), "unsupported-index-mode"],
    ["symlink mode", indexRecord("120000"), "unsupported-index-mode"],
    ["submodule mode", indexRecord("160000"), "unsupported-index-mode"],
    ["zero oid ITA", indexRecord("100644", "0".repeat(40)), "intent-to-add-index-entry"],
  ];
  for (const [name, bytes, reason] of bad) add(`Index parser rejects ${name}`, () => expectInfrastructure(name,
    () => parseIndexEntries(bytes), reason));
  for (const stage of ["1", "2", "3"]) add(`Index parser rejects unmerged stage ${stage}`, () => expectInfrastructure(`stage-${stage}`,
    () => parseIndexEntries(indexRecord("100644", "1".repeat(40), stage)), "unmerged-index-entry"));
  add("Index parser rejects duplicate path", () => expectInfrastructure("duplicate",
    () => parseIndexEntries(Buffer.concat([indexRecord(), indexRecord()])), "duplicate-index-path"));
  add("Index parser rejects casefold collision", () => expectInfrastructure("casefold",
    () => parseIndexEntries(Buffer.concat([indexRecord(), indexRecord("100644", "2".repeat(40), "0", "docs/a.md")])), "casefold-index-collision"));
  add("Git environment strips ambient Git variables and installs exact safe overrides", () => {
    const env = sanitizedGitEnv({ PATH: "fixture-path", Git_TrAcE: "1", GIT_INDEX_FILE: "hostile", HOME: "fixture-home" });
    const expected = {
      GIT_OPTIONAL_LOCKS: "0", GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: process.platform === "win32" ? "NUL" : "/dev/null",
      GIT_ATTR_NOSYSTEM: "1", GIT_PAGER: "cat", GIT_NO_REPLACE_OBJECTS: "1", GIT_NO_LAZY_FETCH: "1", GIT_TERMINAL_PROMPT: "0",
    };
    if (env.PATH !== "fixture-path" || env.HOME !== "fixture-home" || "Git_TrAcE" in env || "GIT_INDEX_FILE" in env) {
      throw new Error(`git-env-leak=${JSON.stringify(env)}`);
    }
    for (const [name, value] of Object.entries(expected)) if (env[name] !== value) throw new Error(`git-env-${name}=${env[name]}`);
  });

  const repo = createRepositoryFixture(tempParent, "repository-valid");
  add("Repository acquisition uses staged membership and worktree bytes", () => {
    writeFixtureFile(repo, "README.md", Buffer.from("# Worktree authority\n"));
    const corpus = acquireRepositoryCorpus({ cwd: repo, modulePath: path.join(repo, "tests", "check_docs_quality.mjs") });
    if (JSON.stringify(corpus.direct) !== JSON.stringify(DIRECT_DOCS)) throw new Error(`direct=${JSON.stringify(corpus.direct)}`);
    if (corpus.files.get("README.md") !== "# Worktree authority\n") throw new Error("index-bytes-used-for-source");
  });
  writeFixtureFile(repo, "docs/UNTRACKED.md", Buffer.from("# Untracked\n"));
  add("Repository acquisition ignores untracked direct docs", () => {
    const corpus = acquireRepositoryCorpus({ cwd: repo, modulePath: path.join(repo, "tests", "check_docs_quality.mjs") });
    if (corpus.direct.includes("docs/UNTRACKED.md")) throw new Error("untracked-selected");
  });
  add("Repository acquisition ignores hostile ambient Git index and trace variables", () => {
    const priorIndex = process.env.GIT_INDEX_FILE;
    const priorTrace = process.env.GIT_TRACE;
    try {
      process.env.GIT_INDEX_FILE = path.join(tempParent, "hostile-index");
      process.env.GIT_TRACE = "1";
      const corpus = acquireRepositoryCorpus({ cwd: repo, modulePath: path.join(repo, "tests", "check_docs_quality.mjs") });
      if (!corpus.byPath.has("README.md")) throw new Error("sanitized-git-acquisition-empty");
    } finally {
      if (priorIndex === undefined) delete process.env.GIT_INDEX_FILE; else process.env.GIT_INDEX_FILE = priorIndex;
      if (priorTrace === undefined) delete process.env.GIT_TRACE; else process.env.GIT_TRACE = priorTrace;
    }
  });
  const staged = createRepositoryFixture(tempParent, "repository-staged");
  writeFixtureFile(staged, "docs/NEW.md", Buffer.from("# New\n"));
  selfTestGit(staged, ["add", "--", "docs/NEW.md"]);
  add("Repository newly staged direct doc becomes exhaustive member", () => {
    const corpus = acquireRepositoryCorpus({ cwd: staged, modulePath: path.join(staged, "tests", "check_docs_quality.mjs") });
    if (!corpus.direct.includes("docs/NEW.md")) throw new Error("staged-not-selected");
  });
  const stagedEmpty = createRepositoryFixture(tempParent, "repository-staged-empty");
  writeFixtureFile(stagedEmpty, "docs/EMPTY.md", Buffer.from("\n"));
  selfTestGit(stagedEmpty, ["add", "--", "docs/EMPTY.md"]);
  add("DQ009 rejects dynamically staged empty Markdown", expectHasId(() => {
    const corpus = acquireRepositoryCorpus({ cwd: stagedEmpty, modulePath: path.join(stagedEmpty, "tests", "check_docs_quality.mjs") });
    return validateRepositoryCorpus(corpus).findings;
  }, "DQ009"));
  const bundled = createRepositoryFixture(tempParent, "repository-bundled");
  writeFixtureFile(bundled, "skills/ipc/references/new.md", Buffer.from("# New bundled authority\n"));
  selfTestGit(bundled, ["add", "--", "skills/ipc/references/new.md"]);
  add("Repository newly staged direct bundled doc becomes exhaustive member", () => {
    const corpus = acquireRepositoryCorpus({ cwd: bundled, modulePath: path.join(bundled, "tests", "check_docs_quality.mjs") });
    if (!corpus.bundled.includes("skills/ipc/references/new.md")) throw new Error("bundled-staged-not-selected");
    assertIds("stale-bundled-index", validateRepositoryCorpus(corpus).findings, ["DQ003"]);
  });
  const ita = createRepositoryFixture(tempParent, "repository-ita");
  writeFixtureFile(ita, "docs/ITA.md", Buffer.from("# Intent to add\n"));
  selfTestGit(ita, ["add", "-N", "--", "docs/ITA.md"]);
  add("Repository acquisition rejects native intent-to-add", () => expectInfrastructure("native-ita",
    () => acquireRepositoryCorpus({ cwd: ita, modulePath: path.join(ita, "tests", "check_docs_quality.mjs") }), "intent-to-add"));

  const emptyScope = registerFixture(tempParent, "repository-empty-scope");
  selfTestGit(emptyScope, ["init", "--quiet"]);
  writeFixtureFile(emptyScope, "tests/check_docs_quality.mjs", readFileSync(MODULE_PATH));
  selfTestGit(emptyScope, ["add", "--", "tests/check_docs_quality.mjs"]);
  add("Repository acquisition rejects empty direct docs scope", () => expectInfrastructure("empty-scope",
    () => acquireRepositoryCorpus({ cwd: emptyScope, modulePath: path.join(emptyScope, "tests", "check_docs_quality.mjs") }), "empty-direct-docs-scope"));

  const missing = createRepositoryFixture(tempParent, "repository-missing-source");
  rmSync(path.join(missing, "README.md"));
  add("Repository acquisition rejects missing source", () => expectInfrastructure("missing-source",
    () => acquireRepositoryCorpus({ cwd: missing, modulePath: path.join(missing, "tests", "check_docs_quality.mjs") }), "missing-repository-source"));
  const nonregular = createRepositoryFixture(tempParent, "repository-nonregular-source");
  rmSync(path.join(nonregular, "README.md"));
  mkdirSync(path.join(nonregular, "README.md"));
  add("Repository acquisition rejects nonregular source", () => expectInfrastructure("nonregular-source",
    () => acquireRepositoryCorpus({ cwd: nonregular, modulePath: path.join(nonregular, "tests", "check_docs_quality.mjs") }), "nonregular-repository-source"));
  const redirected = createRepositoryFixture(tempParent, "repository-redirected-source");
  add("Repository acquisition rejects redirected source", () => expectInfrastructure("redirected-source",
    () => acquireRepositoryCorpus({ cwd: redirected, modulePath: path.join(redirected, "tests", "check_docs_quality.mjs"), direntKind: { "README.md": "reparse" } }), "redirected-repository-segment"));
  const divergent = createRepositoryFixture(tempParent, "repository-validator-divergence");
  writeFixtureFile(divergent, "tests/check_docs_quality.mjs", Buffer.concat([readFileSync(MODULE_PATH), Buffer.from("// drift\n")]));
  add("Repository validator index identity precedes policy acquisition", () => expectInfrastructure("validator-divergence",
    () => acquireRepositoryCorpus({ cwd: divergent, modulePath: path.join(divergent, "tests", "check_docs_quality.mjs"), direntKind: { "README.md": "reparse" } }), "validator-index-divergence"));
}

function runSelfTests() {
  const tests = [];
  const add = (name, run) => tests.push({ name, run });
  const tempParent = mkdtempSync(path.join(tmpdir(), "ipc-docs-self-"));
  let tempInventoryBefore = null;
  let cleanupFailure = null;
  let setupFailure = null;
  let passed = 0;
  let failed = 0;
  try {
  tempInventoryBefore = readdirSync(tempParent).sort();
  add("Self-test setup failure cleanup removes registered children and parent", () => {
    const probe = mkdtempSync(path.join(tmpdir(), "ipc-docs-setup-"));
    const before = readdirSync(probe).sort();
    const child = path.join(probe, "registered");
    const registry = [child];
    mkdirSync(child);
    let reason = null;
    try { throw new InfrastructureError("fixture-setup-failed"); }
    catch (error) {
      if (!(error instanceof InfrastructureError) || error.message !== "fixture-setup-failed") throw error;
    } finally {
      reason = cleanupSelfTestTemp(probe, before, registry);
    }
    if (reason !== null || existsSync(probe) || registry.length !== 0) throw new Error(`setup-cleanup=${reason}`);
  });
  add("CLI accepts exact modes", () => {
    if (parseArgs([]).mode !== "repository" || parseArgs(["--self-test"]).mode !== "self-test"
        || parseArgs(["--installed-root", "relative/root"]).mode !== "installed-root") throw new Error("valid-mode-rejected");
  });
  add("CLI rejects every other shape", () => {
    for (const argv of [["--installed-root"], ["--installed-root", ""], ["--installed-root", " \t"],
      ["--installed-root", "bad\0root"], ["--installed-root", "a", "b"], ["--self-test", "x"], ["--unknown"], ["x"]]) {
      let rejected = false;
      try { parseArgs(argv); } catch { rejected = true; }
      if (!rejected) throw new Error(`accepted=${argv.join(",")}`);
    }
  });
  add("Imported scanTextBuffer remains callable and pure", () => {
    const bytes = Buffer.from("text\n");
    const frozen = Object.freeze({ source: "installed-root", path: "skills/ipc/SKILL.md", nested: Object.freeze({ value: 1 }) });
    if (scanTextBuffer(bytes, frozen).length !== 0 || bytes.toString() !== "text\n") throw new Error("scanner-contract-failed");
  });
  add("Module import is silent and side-effect-free", () => {
    const script = `import(${JSON.stringify(pathToFileURL(MODULE_PATH).href)})`;
    const result = spawnSync(process.execPath, ["--input-type=module", "--eval", script], { encoding: null, shell: false, windowsHide: true });
    if (result.error || result.status !== 0 || result.stdout.length !== 0 || result.stderr.length !== 0) throw new Error("import-not-silent");
  });
  add("Invalid CLI shapes have exact rc2 byte contract", () => {
    const shapes = [["--installed-root"], ["--installed-root", "a", "b"], ["--self-test", "x"], ["--unknown"], ["x"]];
    const expected = Buffer.from("DQ900 path=<cli> line=0 reason=usage-exactly-no-args-or-self-test-or-installed-root-path\n", "ascii");
    for (const shape of shapes) {
      const result = spawnSync(process.execPath, [MODULE_PATH, ...shape], { encoding: null, shell: false, windowsHide: true });
      if (result.error || result.status !== 2 || result.stdout.length !== 0 || !result.stderr.equals(expected)) {
        throw new Error(`invalid-cli-contract=${shape.join(",")}`);
      }
    }
  });
  add("Diagnostics are deterministic deduped ASCII and one-line-per-record", () => {
    const raw = [
      finding("DQ002", path.join("b", "\u96ea\t\n", "x"), 2, "why\u2603\t"),
      finding("DQ001", "a.md", 10, "alpha"),
      finding("DQ002", path.join("b", "\u96ea\t\n", "x"), 2, "why\u2603\t"),
    ];
    const rendered = `${sortAndDedupe(raw).map(formatFinding).join("\n")}\n`;
    const expected = "DQ001 path=a.md line=10 reason=alpha\nDQ002 path=b/\\u96ea\\u0009\\u000a/x line=2 reason=why\\u2603\\u0009\n";
    if (rendered !== expected || !Buffer.from(rendered).every((byte) => byte <= 0x7f)
        || rendered.split("\n").length !== 3) throw new Error(`diagnostic=${asciiEscape(rendered)}`);
  });
  add("TXT findings sort by source and offsets", () => {
    const findings = sortAndDedupe([
      { id: "TXT001", source: "installed-root", path: "p.md", byteOffset: 10, codePointOffset: 10, reason: "later" },
      { id: "TXT007", source: "installed-root", path: "p.md", byteOffset: 1, codePointOffset: 1, reason: "earlier" },
      { id: "TXT006", source: "a-source", path: "p.md", byteOffset: 99, codePointOffset: 99, reason: "source-first" },
    ]);
    const actual = findings.map((item) => `${item.source}:${item.byteOffset}:${item.id}`).join(",");
    const expected = "a-source:99:TXT006,installed-root:1:TXT007,installed-root:10:TXT001";
    if (actual !== expected) throw new Error(`txt-order=${actual}`);
  });
  add("Heading section boundaries use one structural pass", () => {
    const source = Array.from({ length: 4096 }, (_, index) => `${index % 3 === 0 ? "##" : "###"} H${index}\nbody\n`).join("");
    const metrics = { work: 0, boundaries: 0 };
    const sections = headingSections(source, metrics);
    if (sections.length !== 4096 || metrics.work <= 0 || metrics.work > 2 * source.length
        || metrics.boundaries !== sections.length) {
      throw new Error(`heading-structure sections=${sections.length} work=${metrics.work} boundaries=${metrics.boundaries}`);
    }
  });
  addMarkdownTests(add);
  addIndexTests(add);
  addOperationalTests(add);
  addInstalledTests(add, tempParent);
  addRepositoryAcquisitionTests(add, tempParent);
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
  } catch (error) {
    setupFailure = error instanceof InfrastructureError ? error.message : "self-test-setup-failed";
  } finally {
    cleanupFailure = cleanupSelfTestTemp(tempParent, tempInventoryBefore, SELF_TEST_TEMP_REGISTRY);
  }
  if (cleanupFailure !== null) {
    console.error(`DQ900 path=<self-test> line=0 reason=${cleanupFailure}`);
    return 2;
  }
  if (setupFailure !== null) {
    console.error(`DQ900 path=<self-test> line=0 reason=${asciiEscape(setupFailure)}`);
    return 2;
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
    console.error(`DQ900 path=<cli> line=0 reason=${asciiEscape(error.message)}`);
    return 2;
  }
  try {
    if (options.mode === "self-test") return runSelfTests();
    if (options.mode === "installed-root") return runInstalledGate(options.root, seams);
    return runRepositoryGate(seams);
  } catch (error) {
    const reason = error instanceof InfrastructureError ? error.message : "internal-error";
    const failurePath = options.mode === "installed-root" ? asciiEscape(path.resolve(options.root))
      : options.mode === "self-test" ? "<self-test>" : "<repository>";
    console.error(`DQ900 path=${failurePath} line=0 reason=${asciiEscape(reason)}`);
    return 2;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = main(process.argv.slice(2));
}
