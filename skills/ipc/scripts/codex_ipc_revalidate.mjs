#!/usr/bin/env node
// Read-only revalidation wrapper for Codex Desktop IPC after Desktop/CLI updates.
//
// Default mode performs static/runtime-presence checks only. It does not connect
// to the IPC pipe unless --allow-live-ipc-read is supplied, and it never sends a
// follower-start-turn or writes SQLite.

import { existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// All required-file checks and sibling invocations are anchored to this script's
// own directory (the bundled skill's scripts/), so revalidation works from any cwd.
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SKILL_ROOT = path.dirname(SCRIPT_DIR);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REQUIRED_SCRIPT_FILES = [
  "scripts/codex_ipc_client.mjs",
  "scripts/codex_ipc_contract_audit.mjs",
  "scripts/codex_ipc_owner_probe.mjs",
  "scripts/codex_ipc_probe.mjs",
  "scripts/codex_ipc_session_inspect.mjs",
  "scripts/codex_ipc_thread_locator.mjs",
  "scripts/codex_ipc_snapshot.mjs",
  "scripts/codex_ipc_write_proof.mjs",
  "scripts/handoff_to_codex.sh",
  "scripts/codex_ipc_autoload.ps1",
];

function usage() {
  return `Usage:
  node scripts/codex_ipc_revalidate.mjs [options]

Options:
  --thread <uuid>             Optional target conversationId for read-only session inspection.
  --allow-live-ipc-read       Run router initialize via codex_ipc_probe.mjs. This connects to
                              \\\\.\\pipe\\codex-ipc but sends only initialize.
  --timeout-ms <n>            Timeout for live read probe. Default: 1500.
  --help                      Show this help.

Safety:
  No prompt injection, no follower-start-turn, no config writes, no SQLite writes,
  and no artifact generation. Without --allow-live-ipc-read, the script only
  checks files, syntax, local state, CLI/Desktop version hints, and pipe presence.`;
}

function parseArgs(argv) {
  const opts = {
    threadId: null,
    allowLiveIpcRead: false,
    timeoutMs: 1500,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--allow-live-ipc-read":
        opts.allowLiveIpcRead = true;
        break;
      case "--timeout-ms":
        opts.timeoutMs = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (opts.threadId && !UUID_RE.test(opts.threadId)) {
    throw new Error("--thread must be a UUID");
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

function parsePositiveInt(value, flag) {
  if (!/^\d+$/.test(String(value))) {
    throw new Error(`${flag} must be a positive integer`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}

function defaultUserPath(...parts) {
  const home = process.env.USERPROFILE || process.env.HOME;
  if (!home) {
    return null;
  }
  return path.join(home, ...parts);
}

function rel(filePath) {
  return filePath.split(path.sep).join("/");
}

// Resolve a "scripts/<name>" skill-relative path against the bundled skill root.
function skillPath(relPath) {
  if (path.isAbsolute(relPath)) {
    return relPath;
  }
  return path.join(SKILL_ROOT, ...relPath.split("/"));
}

function fileCheck(relPath) {
  const filePath = skillPath(relPath);
  if (!existsSync(filePath)) {
    return { ok: false, path: rel(relPath), exists: false };
  }
  const stat = statSync(filePath);
  return {
    ok: stat.isFile(),
    path: rel(relPath),
    exists: true,
    isFile: stat.isFile(),
    size: stat.size,
    mtimeMs: stat.mtimeMs,
  };
}

function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    encoding: "utf8",
    timeout: options.timeoutMs || 10000,
    windowsHide: true,
  });
  return {
    ok: result.status === 0,
    command: [command, ...args].join(" "),
    status: result.status,
    signal: result.signal,
    stdout: truncate(result.stdout || "", options.maxChars || 2000),
    stderr: truncate(result.stderr || "", options.maxChars || 2000),
    error: result.error ? result.error.message : null,
  };
}

function checkNodeSyntax(relPath) {
  return runCommand(process.execPath, ["--check", skillPath(relPath)], { maxChars: 1000 });
}

function checkGitBashSyntax(relPath) {
  const scriptPath = skillPath(relPath);
  // Prefer bash from PATH (Linux/macOS/Git Bash), then common Windows Git installs.
  const onPath = runCommand("bash", ["-n", scriptPath], { maxChars: 1000 });
  if (!onPath.error) {
    return onPath;
  }
  const candidates = [
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
  ];
  const bashPath = candidates.find((candidate) => existsSync(candidate));
  if (!bashPath) {
    return {
      ok: false,
      skipped: true,
      reason: "bash was not found on PATH or at the expected Windows Git install paths.",
    };
  }
  return runCommand(bashPath, ["-n", scriptPath], { maxChars: 1000 });
}

function checkPowerShellSyntax(relPath) {
  // Parser-only validation via PSParser::Tokenize — no execution of the script body.
  // Skips (not fails) when powershell.exe is absent (non-Windows hosts/CI runners):
  // the helper itself is Windows-only, so absence of PowerShell is not a defect.
  const scriptPath = skillPath(relPath);
  if (!existsSync(scriptPath)) {
    return { ok: false, exists: false, path: rel(relPath) };
  }
  const ps = [
    "$errors = $null;",
    `$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '${scriptPath.replace(/'/g, "''")}'), [ref]$errors);`,
    "if ($errors) { Write-Output 'PARSE-ERRORS'; $errors | ForEach-Object { Write-Output $_.Message }; exit 1 }",
    "Write-Output 'PARSE-OK'",
  ].join(" ");
  const result = runCommand("powershell.exe", ["-NoProfile", "-Command", ps], { maxChars: 2000 });
  if (result.error) {
    return {
      ok: true,
      skipped: true,
      reason: "powershell.exe not available on this host; PowerShell parse check skipped (helper is Windows-only).",
    };
  }
  return { ...result, ok: result.ok && result.stdout.includes("PARSE-OK") };
}

function checkNodeSqlite() {
  return runCommand(
    process.execPath,
    ["-e", "import('node:sqlite').then(()=>console.log('node:sqlite ok'))"],
    { maxChars: 1000 },
  );
}

function checkCodexCliVersion() {
  // The Codex CLI is deliberately NOT part of IPC: no launcher, version probe, resume,
  // exec, fallback, recovery, validator or broker worker may invoke it. This check
  // therefore reports the invariant instead of spawning `codex --version`. It never
  // gated the summary even when it did probe, so nothing downstream changes.
  //
  // `available` is null, not false: nothing was probed, so availability is UNKNOWN,
  // not "known-absent". Stable nullable status/signal/error/command/stdout/stderr keys
  // are preserved for any consumer that read the old command-result shape.
  return {
    ok: true,
    applicable: false,
    available: null,
    probed: false,
    command: null,
    status: null,
    signal: null,
    error: null,
    stdout: "",
    stderr: "",
    note: "Codex CLI is out of scope by design (no-CLI invariant); not probed. This report does not establish global no-CLI closure (N1).",
  };
}

function checkDesktopVersionHint() {
  // Informational hint only (never gates the summary). Since the 2026-07-09 host merge
  // the Codex Desktop GUI runs as ChatGPT.exe under the unchanged OpenAI.Codex package
  // family, alongside a headless resources\codex.exe child. Identify the GUI positively
  // via the package InstallLocation (legacy pre-merge 'Codex' name still matches), and
  // explicitly reject the resources\codex.exe app-server child as the GUI. When the GUI
  // cannot be identified, say so honestly instead of reporting the wrong binary.
  const ps = [
    "$pkg = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1;",
    "if (-not $pkg) { Write-Output '{\"packageInstalled\":false,\"guiIdentified\":false}'; exit 0 }",
    "$root = $pkg.InstallLocation;",
    "$gui = Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue |",
    "Where-Object { $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)",
    "-and $_.Path -notmatch '(?i)[\\\\/]resources[\\\\/]codex\\.exe$' } |",
    "Select-Object -First 1;",
    "$o = [ordered]@{ packageInstalled=$true; packageName=$pkg.Name; packageVersion=[string]$pkg.Version;",
    "packageFamily=$pkg.PackageFamilyName; guiIdentified=[bool]$gui };",
    "if ($gui) { $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($gui.Path);",
    "$o.guiName=$gui.Name; $o.guiPath=$gui.Path; $o.fileVersion=$v.FileVersion; $o.productVersion=$v.ProductVersion }",
    "$o | ConvertTo-Json -Compress",
  ].join(" ");
  const result = runCommand("powershell.exe", ["-NoProfile", "-Command", ps], { maxChars: 2000 });
  if (result.error || !result.ok) {
    // Hint is informational by contract: never gate the summary on a host where
    // powershell.exe or the Appx module is unavailable (e.g. non-Windows, Server Core).
    return {
      ...result,
      ok: true,
      skipped: true,
      reason: "desktop version hint unavailable on this host (informational check; never gating).",
    };
  }
  return result;
}

function checkCodexPipePresence() {
  let pipes = [];
  try {
    pipes = readdirSync("\\\\.\\pipe\\");
  } catch (error) {
    return {
      ok: false,
      exists: false,
      error: error.message,
      matchingPipes: [],
    };
  }

  const matchingPipes = pipes.filter((entry) => entry.toLowerCase().includes("codex"));
  return {
    ok: matchingPipes.includes("codex-ipc"),
    exists: matchingPipes.includes("codex-ipc"),
    matchingPipes,
  };
}

function checkCodexStateFiles() {
  const configPath = defaultUserPath(".codex", "config.toml");
  const dbPath = defaultUserPath(".codex", "state_5.sqlite");
  const sessionsPath = defaultUserPath(".codex", "sessions");
  return {
    ok: Boolean(configPath && dbPath && sessionsPath) &&
      existsSync(configPath) &&
      existsSync(dbPath) &&
      existsSync(sessionsPath),
    config: configPath ? fileCheck(configPath) : { ok: false, exists: false },
    stateDb: dbPath ? fileCheck(dbPath) : { ok: false, exists: false },
    sessionsRoot: sessionsPath
      ? {
          path: sessionsPath,
          exists: existsSync(sessionsPath),
          isDirectory: existsSync(sessionsPath) ? statSync(sessionsPath).isDirectory() : false,
        }
      : { exists: false },
  };
}

function runSessionInspect(threadId) {
  if (!threadId) {
    return {
      ok: true,
      skipped: true,
      reason: "No --thread supplied; target-specific rollout inspection skipped.",
    };
  }
  return runCommand(
    process.execPath,
    [skillPath("scripts/codex_ipc_session_inspect.mjs"), "--thread", threadId, "--tail-events", "5"],
    { timeoutMs: 20000, maxChars: 5000 },
  );
}

function runLiveIpcReadProbe(opts) {
  if (!opts.allowLiveIpcRead) {
    return {
      ok: true,
      skipped: true,
      reason: "--allow-live-ipc-read not supplied; no IPC pipe connection attempted.",
    };
  }
  return runCommand(
    process.execPath,
    [
      skillPath("scripts/codex_ipc_probe.mjs"),
      "--protocol",
      "ipc-router",
      "--framing",
      "uint32le",
      "--allow-live-ipc-read",
      "--timeout-ms",
      String(opts.timeoutMs),
    ],
    { timeoutMs: opts.timeoutMs + 3000, maxChars: 5000 },
  );
}

function truncate(text, maxChars) {
  const normalized = String(text).trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return `${normalized.slice(0, Math.max(0, maxChars - 14))}...[truncated]`;
}

function summarizeChecks(checks) {
  const failed = [];
  const skipped = [];
  for (const [name, check] of Object.entries(checks)) {
    if (check?.skipped) {
      skipped.push(name);
    } else if (check?.ok !== true) {
      failed.push(name);
    }
  }
  return { failed, skipped };
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

  const fileChecks = Object.fromEntries(
    REQUIRED_SCRIPT_FILES.map((filePath) => [filePath, fileCheck(filePath)]),
  );
  const nodeSyntax = Object.fromEntries(
    REQUIRED_SCRIPT_FILES
      .filter((filePath) => filePath.endsWith(".mjs"))
      .map((filePath) => [filePath, checkNodeSyntax(filePath)]),
  );
  const checks = {
    requiredFiles: {
      ok: Object.values(fileChecks).every((check) => check.ok),
      files: fileChecks,
    },
    nodeSyntax: {
      ok: Object.values(nodeSyntax).every((check) => check.ok),
      scripts: nodeSyntax,
    },
    handoffShellSyntax: checkGitBashSyntax("scripts/handoff_to_codex.sh"),
    autoloadPowerShellSyntax: checkPowerShellSyntax("scripts/codex_ipc_autoload.ps1"),
    nodeSqlite: checkNodeSqlite(),
    codexCliVersion: checkCodexCliVersion(),
    desktopVersionHint: checkDesktopVersionHint(),
    codexStateFiles: checkCodexStateFiles(),
    codexPipePresence: checkCodexPipePresence(),
    sessionInspect: runSessionInspect(opts.threadId),
    liveIpcReadProbe: runLiveIpcReadProbe(opts),
  };

  const summary = summarizeChecks(checks);
  const ok = summary.failed.length === 0;
  const result = {
    ok,
    mode: "codex-ipc-revalidate",
    generatedAt: new Date().toISOString(),
    threadId: opts.threadId,
    revalidationLevel: opts.allowLiveIpcRead ? "runtime-read-probe" : "static-and-presence",
    checks,
    summary,
    warnings: [
      "This wrapper is validate-only: it does not send prompts, follower-start-turn, config writes, SQLite writes, or generated artifacts.",
      "Without --allow-live-ipc-read, router framing compatibility is not re-proven; only pipe presence is checked.",
      "Even with --allow-live-ipc-read, this does not prove a live prompt send. Use controlled before/after snapshots for any future write proof.",
    ],
  };

  console.log(JSON.stringify(result, null, 2));
  if (!ok) {
    process.exit(1);
  }
}

await main();
