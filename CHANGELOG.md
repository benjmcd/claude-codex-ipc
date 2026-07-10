# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

### Changed

### Fixed

## [0.1.2] — 2026-07-09

Host-identity compatibility patch for the 2026-07-09 Codex/ChatGPT Windows app merge: the Codex
Desktop GUI now runs as `ChatGPT.exe` under the unchanged `OpenAI.Codex` package family. Transport
surfaces (`\\.\pipe\codex-ipc`, `codex://`, router methods, `~/.codex` state, RESULT taxonomy,
exit codes) are unaffected and unchanged.

### Added
- `tests/test_autoload_matrix.sh`: hermetic behavioral matrix for `codex_ipc_autoload.ps1` —
  runs the real script under `-DryRun` with mocked foreground identity across
  legacy-Codex / merged-host / other-ChatGPT / ambiguous / unknown × defer / switch /
  restore-if-known; skips cleanly where `powershell.exe` is absent; asserts process hygiene.
  Wired into CI.
- `codex_ipc_autoload.ps1`: `-MockForegroundPath` test hook (used only when
  `-MockForegroundProcess` is supplied; inert in production).
- `docs/COMPATIBILITY.md`: "Host-identity ledger" section with the 2026-07-09 entry.

### Fixed
- **Foreground safety failed open on the merged host** (`codex_ipc_autoload.ps1`): detection was
  name-only (`^(?i)codex$`), so the ChatGPT-branded Codex GUI was classified "known non-Codex"
  and an unowned-thread handoff could fire `codex://` while the operator was in the visible app —
  under every policy. Identity is now positive: legacy `Codex` process name, or `ChatGPT` name
  with executable path under `WindowsApps\OpenAI.Codex_*` (ACL-protected, not name-spoofable).
  A `ChatGPT`-named foreground with unreadable path is ambiguous and defers (fail closed). A
  distinct ChatGPT-family app with a readable non-Codex path keeps the original
  deep-link + snapback behavior. Exit codes, action records, and policy semantics unchanged.
- **`desktopVersionHint` misattributed the Desktop after the rename**
  (`codex_ipc_revalidate.mjs`): `Get-Process -Name Codex` now matched the headless
  `resources\codex.exe` app-server child. The hint (still informational, never gating) now
  reports the `OpenAI.Codex` package identity/version and positively identifies the GUI under
  the package install location, explicitly rejecting `resources\codex.exe`, with an honest
  `guiIdentified:false` when no GUI is found.

## [0.1.1] — 2026-07-09

Post-release hardening from an exhaustive dual-lane audit, verified by a multi-agent workflow.
No breaking changes.

### Added
- CI now runs `install.ps1`/`uninstall.ps1` `-DryRun` on the Windows runner (runtime coverage,
  not just PowerShell parsing).

### Changed
- Docs reconciled with the wrapper's live-send model: `handoff_to_codex.sh --ipc <uuid>` treats
  the explicit UUID as the live-delivery acknowledgement and supplies the client's
  `--send --ack-live-write --allow-any-thread` internally; inspect-before-send is the `/ipc`
  agent's preflight step, not a wrapper gate (README, SECURITY, SKILL.md, contract audit REQ-006
  relabeled as static guidance).
- `codex_ipc_probe.mjs` now defaults to dry-run; live pipe connection requires the explicit
  `--allow-live-ipc-read` flag (`codex_ipc_revalidate.mjs` updated to pass it through).
- Clarified transcript disclosure (automatic resolution fails closed without an injected session
  id; explicit `CLAUDE_TRANSCRIPT` honored only under `CODEX_IPC_INCLUDE_TRANSCRIPT=1`) and the
  local-file threat model (same-user processes can read **and modify** envelope files).
- Contract audit REQ-016 now covers the `gui-unowned` result taxonomy; `test_ipc.sh` asserts no
  `/ipc` path invokes `codex exec` (making the REQ-017 no-headless note verifiable).

### Fixed
- **Installers refuse a destructive `--force`**: `install.sh`/`install.ps1` now reject a
  `--target` that is the source tree, `$HOME`, a filesystem/drive root, or any directory that is
  not an existing ipc-skill install — closing an `rm -rf`/`Remove-Item` data-loss footgun.
- Retention sweep in `handoff_to_codex.sh` refuses to run against a dangerous `CODEX_IPC_ROOT`
  (`$HOME`, `/`, drive root).
- Numeric CLI flags across the `.mjs` tools now reject malformed values (e.g. `10junk`) instead
  of silently truncating them.
- Public-safety scan no longer wholesale-excludes the CI workflow file, so a leak elsewhere in it
  would be caught.
- `codex_ipc_revalidate.mjs` reports the real absolute Codex state-file paths instead of
  skill-relative garbage (`codexStateFiles` diagnostics).
- `codex_ipc_owner_probe.mjs` now requires `--ack-live-write` alongside `--send`.

## [0.1.0] — 2026-07-09

First public release of the `ipc` skill as the `codex-ipc` plugin.

### Added
- **Foreground policy for `--ipc`** (experimental, Windows): default `defer` (never navigate the
  visible Codex app; explicit `codex-foreground-deferred` subreason), opt-in
  `--foreground-policy switch --ack-foreground-switch` (delivers by navigating the visible app to
  the target — disclosed residue), fail-closed `restore-if-known`. Machine-parseable results
  (`RESULT: <top> -- reason=<token> -- confirmation=<token>`), positive-proof target inspection
  before any deep link (ambiguity refuses), total autoload exit-code handling (unknown codes fail
  closed), dry-run/mock test hooks in the autoload helper, and poll timing knobs. Bounded rollout
  observation and dispatch idempotency markers are deferred to a follow-up milestone
  (`confirmation=not-checked` until then).
- Plugin-first repo layout: canonical skill source at `skills/ipc/`, plugin manifest at
  `.claude-plugin/plugin.json`, hermetic tests at `tests/`, docs, installers, and CI.
- `CODEX_IPC_INCLUDE_TRANSCRIPT=1` opt-in gate: Claude transcript paths are no longer included in
  handoff payloads by default.
- `CODEX_IPC_AUTHORIZED_TEST_THREAD` environment variable: replaces the previous built-in
  authorized test thread id; no thread id ships with the code.
- `CODEX_MODEL` environment variable for opt-in `--exec` model pinning.
- Graceful runtime error when `node:sqlite` is unavailable (inspection tools); file-drop mode
  works without it.
- Script-dir-relative sibling resolution in the orchestrating tools (`codex_ipc_revalidate.mjs`,
  `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`) so they run from any cwd.
- QA infrastructure: hermetic transport tests extended 33→70 assertions (foreground-policy,
  inspection-ambiguity, taxonomy, transcript-opt-in coverage) with dual-layout probes so the same
  test files run in both the repo and installed-skill layouts; contract audit extended to 17
  requirements (REQ-012..017: conservative policy default, ack-gated switch,
  file-drop-before-policy-failure, positive inspection proof, parser-compatible taxonomy,
  no-headless); revalidate gained a PowerShell parser check (skip-if-absent); CI gained a
  Windows-guarded PowerShell parse step.

### Changed
- `codex_ipc_write_proof.mjs`: the DB-byte marker count (`markerIncreased`) is now diagnostics
  only, not a pass/fail conjunct — current Codex Desktop stores message text only in the rollout
  JSONL (verified live), which the harness's rollout probe already checks with strictly stronger
  evidence (agent marker acknowledgement + `task_complete`).
- `--exec` no longer defaults model/reasoning-effort pins; they are passed only when
  `CODEX_MODEL` / `CODEX_REASONING_EFFORT` are set.
- `codex_ipc_snapshot.mjs` now requires `--thread` in snapshot mode (no default id).
- `codex_ipc_contract_audit.mjs` rewritten to audit the bundled skill files (the previous version
  depended on private dev-repo artifacts).
- SKILL.md split: deep background moved to `skills/ipc/references/` (architecture, security
  model, troubleshooting).

### Security
- Removed all personal paths, private conversation/thread ids, and machine-specific defaults from
  code, docs, examples, and tests.
- Hardened the public-safety scan with structural checks (tool-state directories such as
  `.omc`/`.claude`/`.codex`, and non-synthetic UUIDs embedded in file/dir names), and converted the
  installers from a filename denylist to a source allowlist (`SKILL.md`, `scripts/`, `references/`,
  `examples/` only) so locally generated state can never be copied or shipped.
