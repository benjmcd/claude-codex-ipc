#!/usr/bin/env node
// Static/read-only requirement audit for the Claude Code -> Codex IPC skill.
//
// This emits a requirement matrix from the bundled skill files (SKILL.md and
// scripts/), anchored to this script's own directory, so it works from any cwd
// in both the plugin/repo layout and a standalone ~/.claude/skills/ipc install.
// It does not connect to the IPC pipe, does not inspect SQLite, does not send
// prompts, and does not write artifacts. Use codex_ipc_revalidate.mjs for
// runtime/presence checks.

import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SKILL_ROOT = path.dirname(SCRIPT_DIR);

const REQUIRED_FILES = [
  "SKILL.md",
  "scripts/handoff_to_codex.sh",
  "scripts/codex_ipc_replies.sh",
  "scripts/codex_ipc_client.mjs",
  "scripts/codex_ipc_owner_probe.mjs",
  "scripts/codex_ipc_probe.mjs",
  "scripts/codex_ipc_revalidate.mjs",
  "scripts/codex_ipc_session_inspect.mjs",
  "scripts/codex_ipc_snapshot.mjs",
  "scripts/codex_ipc_thread_locator.mjs",
  "scripts/codex_ipc_write_proof.mjs",
  "references/handoff-template.md",
];

function usage() {
  return `Usage:
  node scripts/codex_ipc_contract_audit.mjs

Safety:
  Static/read-only audit only. Reads the bundled skill files and emits JSON. It
  does not connect to IPC, inspect SQLite, send prompts, or write artifacts.`;
}

function skillPath(relPath) {
  return path.join(SKILL_ROOT, ...relPath.split("/"));
}

function readText(relPath) {
  return readFileSync(skillPath(relPath), "utf8");
}

function fileInfo(relPath) {
  const filePath = skillPath(relPath);
  if (!existsSync(filePath)) {
    return { ok: false, path: relPath, exists: false };
  }
  const stat = statSync(filePath);
  return {
    ok: stat.isFile(),
    path: relPath,
    exists: true,
    isFile: stat.isFile(),
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function contains(relPath, pattern) {
  if (!existsSync(skillPath(relPath))) {
    return false;
  }
  const text = readText(relPath);
  if (pattern instanceof RegExp) {
    return pattern.test(text);
  }
  return text.includes(pattern);
}

function matchCount(relPath, pattern) {
  if (!existsSync(skillPath(relPath))) {
    return 0;
  }
  return [...readText(relPath).matchAll(pattern)].length;
}

function check(id, requirement, evidenceChecks, residualRisk = null) {
  const evidence = evidenceChecks.map((item) => ({
    label: item.label,
    file: item.file || null,
    ok: Boolean(item.ok),
  }));
  return {
    id,
    requirement,
    status: evidence.every((item) => item.ok) ? "evidenced" : "missing-or-weak",
    evidence,
    residualRisk,
  };
}

function main() {
  const files = Object.fromEntries(REQUIRED_FILES.map((relPath) => [relPath, fileInfo(relPath)]));
  const handoffText = readText("scripts/handoff_to_codex.sh");
  // Anchor on the ACTUAL transport-root assignment, not the earlier doc-comment mention
  // of CODEX_IPC_ROOT=<dir>. The removed-mode errors must fire before this line runs.
  const transportInit = handoffText.search(/^IPC_ROOT="\$\{CODEX_IPC_ROOT/m);
  const removedModeErrors = ["--app", "--open", "--exec"].map(
    (flag) => `ERROR: ${flag} was removed in v0.1.8 (No Codex CLI);`,
  );
  const requirements = [
    check("REQ-001", "The default handoff path remains file-drop and GUI-safe.", [
      {
        label: "handoff script defaults to filedrop",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", 'MODE="filedrop"'),
      },
      {
        label: "SKILL.md keeps file-drop as default/fallback",
        file: "SKILL.md",
        ok: contains("SKILL.md", "file-drop as default/fallback"),
      },
    ]),
    check("REQ-002", "Live IPC is opt-in, explicit-target, and starts from a caller-supplied UUID.", [
      {
        label: "handoff script exposes --ipc mode",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", "--ipc <conversationId>"),
      },
      {
        label: "handoff script validates IPC conversationId as UUID",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", "is_uuid"),
      },
      {
        label: "client requires --thread UUID and live-write acknowledgement",
        file: "scripts/codex_ipc_client.mjs",
        ok:
          contains("scripts/codex_ipc_client.mjs", "--thread <uuid>") &&
          contains("scripts/codex_ipc_client.mjs", "--ack-live-write"),
      },
    ]),
    check("REQ-003", "IPC sends are thread-scoped and reject heuristic write targeting.", [
      {
        label: "client sends explicit conversationId",
        file: "scripts/codex_ipc_client.mjs",
        ok: contains("scripts/codex_ipc_client.mjs", "conversationId: opts.threadId"),
      },
      {
        label: "SKILL.md forbids title/cwd/recency target inference when a UUID is present",
        file: "SKILL.md",
        ok: contains("SKILL.md", "Do not infer a different target from title"),
      },
    ]),
    check("REQ-004", "IPC path is fallback-backed by writing file-drop first.", [
      {
        label: "IPC branch writes OUTBOUND before live delivery",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", '| atomic_write "$OUTBOUND_MSYS"'),
      },
      {
        label: "IPC branch has fallback function and file-drop instruction",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", "fallback()") &&
          contains("scripts/handoff_to_codex.sh", "FALLBACK -- file-drop is ready"),
      },
    ]),
    check("REQ-005", "Claude session context is available but transcript paths are opt-in.", [
      {
        label: "handoff payload includes Claude session context block",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", "## Claude session context"),
      },
      {
        label: "transcript path inclusion is gated on CODEX_IPC_INCLUDE_TRANSCRIPT",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", 'CODEX_IPC_INCLUDE_TRANSCRIPT:-0'),
      },
    ], "Transcript pointers expose full local session context; include them only when needed."),
    check("REQ-006", "Existing-session /ipc has static preflight inspection guidance and the inspector file exists.", [
      {
        label: "session inspector exists",
        file: "scripts/codex_ipc_session_inspect.mjs",
        ok: existsSync(skillPath("scripts/codex_ipc_session_inspect.mjs")),
      },
      {
        label: "SKILL.md scopes inspect-before-send as agent preflight",
        file: "SKILL.md",
        ok:
          contains("SKILL.md", "Selecting `--ipc <uuid>` is itself the live-delivery acknowledgement") &&
          contains("SKILL.md", "Inspect-before-send is the /ipc agent's own preflight step, not a wrapper gate."),
      },
    ], "Static doc/file-existence evidence only: this does not verify runtime ordering. Selecting `--ipc <uuid>` is itself the live-delivery acknowledgement; the wrapper supplies the client's `--send --ack-live-write --allow-any-thread` internally. Inspect-before-send is the /ipc agent's own preflight step, not a wrapper gate."),
    check("REQ-007", "No-UUID /ipc has read-only candidate discovery before target selection.", [
      {
        label: "thread locator exists",
        file: "scripts/codex_ipc_thread_locator.mjs",
        ok: existsSync(skillPath("scripts/codex_ipc_thread_locator.mjs")),
      },
      {
        label: "locator warns candidate is not write authority",
        file: "scripts/codex_ipc_thread_locator.mjs",
        ok: contains("scripts/codex_ipc_thread_locator.mjs", "Candidate discovery is not write authority"),
      },
      {
        label: "SKILL.md uses locator and requires follow-up inspection",
        file: "SKILL.md",
        ok:
          contains("SKILL.md", "codex_ipc_thread_locator.mjs") &&
          contains("SKILL.md", "run `codex_ipc_session_inspect.mjs`"),
      },
    ]),
    check("REQ-008", "Post-update robustness has a validate-only revalidation surface.", [
      {
        label: "revalidation wrapper exists",
        file: "scripts/codex_ipc_revalidate.mjs",
        ok: existsSync(skillPath("scripts/codex_ipc_revalidate.mjs")),
      },
      {
        label: "revalidation wrapper forbids prompt/follower/config/sqlite writes",
        file: "scripts/codex_ipc_revalidate.mjs",
        ok:
          contains("scripts/codex_ipc_revalidate.mjs", "No prompt injection") &&
          contains("scripts/codex_ipc_revalidate.mjs", "no follower-start-turn") &&
          contains("scripts/codex_ipc_revalidate.mjs", "no SQLite writes"),
      },
    ], "A future Desktop update can still require controlled write re-proof if read-only checks detect drift."),
    check("REQ-009", "No direct SQLite writes are part of the tooling.", [
      {
        label: "read-only SQLite helpers open with readOnly:true",
        file: "scripts/codex_ipc_session_inspect.mjs",
        ok:
          contains("scripts/codex_ipc_session_inspect.mjs", "readOnly: true") &&
          contains("scripts/codex_ipc_thread_locator.mjs", "readOnly: true") &&
          contains("scripts/codex_ipc_snapshot.mjs", "readOnly: true"),
      },
      {
        label: "SKILL.md forbids direct SQLite modification",
        file: "SKILL.md",
        ok: contains("SKILL.md", /SQLite directly/),
      },
    ]),
    check("REQ-010", "No real/default authorized thread id is shipped; authorization is operator-supplied.", [
      {
        label: "client resolves the authorized test thread from the environment only",
        file: "scripts/codex_ipc_client.mjs",
        ok:
          contains("scripts/codex_ipc_client.mjs", "CODEX_IPC_AUTHORIZED_TEST_THREAD") &&
          !contains(
            "scripts/codex_ipc_client.mjs",
            /AUTHORIZED_TEST_THREAD_ID\s*=\s*"[0-9a-f]{8}-/i,
          ),
      },
      {
        label: "write proof harness resolves the authorized test thread from the environment only",
        file: "scripts/codex_ipc_write_proof.mjs",
        ok:
          contains("scripts/codex_ipc_write_proof.mjs", "CODEX_IPC_AUTHORIZED_TEST_THREAD") &&
          !contains(
            "scripts/codex_ipc_write_proof.mjs",
            /AUTHORIZED_TEST_THREAD_ID\s*=\s*"[0-9a-f]{8}-/i,
          ),
      },
      {
        label: "snapshot helper has no default thread id",
        file: "scripts/codex_ipc_snapshot.mjs",
        ok: !contains("scripts/codex_ipc_snapshot.mjs", /DEFAULT_THREAD_ID\s*=\s*"/),
      },
    ]),
    check("REQ-012", "Foreground policy defaults to the conservative 'defer'.", [
      {
        label: "wrapper env default is defer",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", 'CODEX_IPC_FOREGROUND_POLICY:-defer'),
      },
      {
        label: "autoload helper default policy is defer",
        file: "scripts/codex_ipc_autoload.ps1",
        ok: contains("scripts/codex_ipc_autoload.ps1", '[string]$ForegroundPolicy = "defer"'),
      },
    ]),
    check("REQ-013", "Foreground switch requires explicit acknowledgement or printed standing approval.", [
      {
        label: "wrapper fails closed without acknowledgement",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", "reason=foreground-switch-unacknowledged") &&
          contains("scripts/handoff_to_codex.sh", "--ack-foreground-switch"),
      },
      {
        label: "wrapper prints active policy and acknowledgement source on every send",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", 'POLICY: foreground=${FOREGROUND_POLICY}'),
      },
      {
        label: "autoload helper refuses switch without ack (exit 5)",
        file: "scripts/codex_ipc_autoload.ps1",
        ok:
          contains("scripts/codex_ipc_autoload.ps1", "AckForegroundSwitch") &&
          contains("scripts/codex_ipc_autoload.ps1", "exit 5"),
      },
    ]),
    check("REQ-014", "Valid UUID/task invocations write the file-drop envelope before policy failures.", [
      {
        label: "policy validation is placed after the envelope write (file-drop-first)",
        file: "scripts/handoff_to_codex.sh",
        ok: contains(
          "scripts/handoff_to_codex.sh",
          /atomic_write "\$OUTBOUND_MSYS"[\s\S]*Semantic policy validation AFTER the envelope write/,
        ),
      },
      {
        label: "SKILL.md states the envelope-before-policy-refusal guarantee",
        file: "SKILL.md",
        ok: contains("SKILL.md", "write the file-drop envelope before any policy refusal"),
      },
    ]),
    check("REQ-015", "Deep-linking requires positive target-inspection proof; ambiguity fails closed.", [
      {
        label: "wrapper requires positive ok:true and refuses ambiguous inspector output",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", '"ok": true') &&
          contains("scripts/handoff_to_codex.sh", "reason=target-inspection-ambiguous"),
      },
      {
        label: "missing and archived targets refuse with distinct reasons",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", "reason=target-not-found") &&
          contains("scripts/handoff_to_codex.sh", "reason=target-archived"),
      },
    ]),
    check("REQ-016", "Results are parser-compatible: top-level category plus machine reason/confirmation tokens.", [
      {
        label: "both accepted-send branches observe once and emit the resulting confirmation token",
        file: "scripts/handoff_to_codex.sh",
        ok:
          matchCount("scripts/handoff_to_codex.sh", /CONFIRMATION=\$\(observe_rollout\)/g) === 2 &&
          matchCount(
            "scripts/handoff_to_codex.sh",
            /RESULT: gui-delivered -- reason=[a-z0-9$"{}_A-Z-]+ -- confirmation=\$\{CONFIRMATION\}/g,
          ) === 2 &&
          contains("scripts/handoff_to_codex.sh", /RESULT: gui-unowned -- reason=[a-z0-9-]+ -- confirmation=/) &&
          contains("scripts/handoff_to_codex.sh", /RESULT: failed-closed -- reason=[a-z0-9-]+ -- confirmation=/),
      },
      {
        label: "no accepted-send RESULT hard-codes confirmation=not-checked",
        file: "scripts/handoff_to_codex.sh",
        ok: !contains(
          "scripts/handoff_to_codex.sh",
          /RESULT: gui-delivered[^\n]*confirmation=not-checked/,
        ),
      },
      {
        label: "SKILL.md documents the taxonomy format",
        file: "SKILL.md",
        ok: contains("SKILL.md", "-- reason=<token> -- confirmation=<token>"),
      },
      {
        label: "unknown autoload exit codes fail closed instead of falling through",
        file: "scripts/handoff_to_codex.sh",
        ok: contains("scripts/handoff_to_codex.sh", "reason=autoload-unexpected-status"),
      },
    ]),
    check("REQ-017", "No Codex CLI: legacy CLI-backed modes fail before transport access or child launch.", [
      {
        label: "SKILL.md states the no-CLI wrapper contract",
        file: "SKILL.md",
        ok: contains("SKILL.md", "The IPC tooling does not invoke the Codex CLI"),
      },
      {
        label: "all removed modes have stable errors before transport initialization",
        file: "scripts/handoff_to_codex.sh",
        // Assert each removed-mode error is present AND exits nonzero before transport
        // init. Anchored to the three removed-mode errors specifically -- NOT a count of
        // all `exit 64`, which other unrelated validation (e.g. an invalid retention
        // value) may also legitimately use.
        ok:
          transportInit > 0 &&
          removedModeErrors.every((needle) => {
            const index = handoffText.indexOf(needle);
            return index >= 0 && index < transportInit;
          }) &&
          ["--app", "--open", "--exec"].every((flag) =>
            new RegExp(`--${flag.slice(2)}\\)[\\s\\S]{0,300}?exit 64`).test(handoffText),
          ),
      },
      {
        label: "wrapper contains no Codex CLI lookup, helper, or invocation",
        file: "scripts/handoff_to_codex.sh",
        ok:
          !contains("scripts/handoff_to_codex.sh", "need_codex") &&
          !contains("scripts/handoff_to_codex.sh", /command\s+-v\s+codex/) &&
          !contains("scripts/handoff_to_codex.sh", /\bcodex(?:\.exe)?\s+(?:app|resume|exec|--version)\b/),
      },
    ], "Static ordering and source greps are backed by hermetic tests that run every removed flag under a poisoned pre-transport environment and retain the Codex stub as an invocation tripwire."),
    check("REQ-011", "Future controlled write re-proof is dry-run-first and evidence-backed.", [
      {
        label: "write proof harness exists",
        file: "scripts/codex_ipc_write_proof.mjs",
        ok: existsSync(skillPath("scripts/codex_ipc_write_proof.mjs")),
      },
      {
        label: "write proof harness requires explicit live-send gates",
        file: "scripts/codex_ipc_write_proof.mjs",
        ok:
          contains("scripts/codex_ipc_write_proof.mjs", "Dry-run is the default") &&
          contains("scripts/codex_ipc_write_proof.mjs", "--send requires --ack-live-write"),
      },
      {
        label: "write proof harness inspects, revalidates, snapshots, polls, and compares",
        file: "scripts/codex_ipc_write_proof.mjs",
        ok:
          contains("scripts/codex_ipc_write_proof.mjs", "inspectTarget") &&
          contains("scripts/codex_ipc_write_proof.mjs", "revalidateRuntime") &&
          contains("scripts/codex_ipc_write_proof.mjs", "compareSnapshots") &&
          contains("scripts/codex_ipc_write_proof.mjs", "pollRolloutForMarker"),
      },
      {
        label: "post-update revalidation includes the proof harness in its required-file checks",
        file: "scripts/codex_ipc_revalidate.mjs",
        ok: contains("scripts/codex_ipc_revalidate.mjs", "scripts/codex_ipc_write_proof.mjs"),
      },
    ], "Live write re-proof still starts a real turn and must remain explicit/operator-approved."),
    check("REQ-018", "Producer denied-reply protocol: one attempt, no retry, full result in the final agent message.", [
      {
        label: "handoff scaffold instructs one attempt, no retry, and the full result in the final message",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", "attempt to write the printed reply path exactly once") &&
          contains("scripts/handoff_to_codex.sh", "do NOT retry") &&
          contains("scripts/handoff_to_codex.sh", "the full substantive result") &&
          contains("scripts/handoff_to_codex.sh", "A one-line denial with no result is a contract violation"),
      },
      {
        label: "SKILL.md documents the denied-reply producer protocol and the opt-in recovery path",
        file: "SKILL.md",
        ok:
          contains("SKILL.md", "Producer denied-reply protocol") &&
          contains("SKILL.md", "the full substantive result") &&
          contains("SKILL.md", "--accept-rollout-fallback"),
      },
      {
        label: "handoff template carries the denied-reply completion obligation",
        file: "references/handoff-template.md",
        ok:
          contains("references/handoff-template.md", "Denied reply write") &&
          contains("references/handoff-template.md", "attempt to write the printed reply path exactly once") &&
          contains("references/handoff-template.md", "the full substantive result"),
      },
    ], "Static prose lock only: it proves the mandatory instruction bytes are present, not that a follower runtime honored them."),
    check("REQ-019", "The completion waiter is on every easy-path surface with the OQ-4 re-certification caveat.", [
      {
        label: "SKILL.md teaches the bounded codex_ipc_wait with the D2 fallback flag",
        file: "SKILL.md",
        ok:
          contains("SKILL.md", "codex_ipc_wait") &&
          contains("SKILL.md", "--accept-rollout-fallback"),
      },
      {
        label: "bundled quickstart shows a runnable codex_ipc_wait",
        file: "examples/quickstart.md",
        ok: contains("examples/quickstart.md", "codex_ipc_wait.mjs"),
      },
      {
        label: "bundled troubleshooting carries the six-token wait triage and codex_ipc_wait",
        file: "references/troubleshooting.md",
        ok: contains("references/troubleshooting.md", "codex_ipc_wait"),
      },
      {
        label: "the OQ-4 re-certification caveat is present verbatim on the recovery surfaces",
        file: "references/troubleshooting.md",
        ok:
          contains(
            "references/troubleshooting.md",
            "resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.",
          ) &&
          contains(
            "SKILL.md",
            "resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.",
          ),
      },
      {
        label: "the wrapper prints the runnable WAIT: hint only on accepted live --ipc success",
        file: "scripts/handoff_to_codex.sh",
        ok:
          contains("scripts/handoff_to_codex.sh", "print_wait_hint") &&
          contains("scripts/handoff_to_codex.sh", "--accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000"),
      },
    ], "Static easy-path/reference lock only: it proves the wait references and OQ-4 caveat bytes are present, not their runtime effect."),
  ];

  const ok = Object.values(files).every((item) => item.ok) &&
    requirements.every((item) => item.status === "evidenced");
  const result = {
    ok,
    mode: "codex-ipc-contract-audit",
    generatedAt: new Date().toISOString(),
    skillRoot: SKILL_ROOT,
    files,
    requirements,
    summary: {
      evidenced: requirements.filter((item) => item.status === "evidenced").length,
      missingOrWeak: requirements.filter((item) => item.status !== "evidenced").map((item) => item.id),
    },
    warnings: [
      "Static skill-file audit only; it does not prove the current Desktop runtime is open or that a future write will succeed.",
      "Run codex_ipc_revalidate.mjs for current runtime checks, and codex_ipc_write_proof.mjs for any future controlled write re-proof.",
    ],
  };

  console.log(JSON.stringify(result, null, 2));
  if (!ok) {
    process.exit(1);
  }
}

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  console.log(usage());
} else {
  main();
}
