# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] — Unreleased

First public preparation of the `ipc` skill as the `codex-ipc` plugin. Not yet released.

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
