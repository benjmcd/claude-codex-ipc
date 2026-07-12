# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- One shared turn-boundary state machine, `createTurnBoundaryAccumulator()`, in
  `codex_ipc_rollout_reader.mjs`: an I/O-free, text-free accumulator that emits immutable per-turn
  snapshots (eight boundary fields) and alone owns start/terminal/id binding, supersession, and
  parser/schema-gap attribution. `createDispatchCorrelator` (A1 dispatch correlation) and
  `summarizeThreadActivity` (A4 thread activity, consumed later) are thin projections over it.
- `codex_ipc_wait.mjs` opt-in `--accept-rollout-fallback` (D2): when the reply file is genuinely
  absent, a completed own turn whose verified rollout body matches its terminal certifies `done`
  with `replySource=rollout-fallback` (one stderr `WAIT_DIAGNOSTIC reply-source`; stdout stays one
  token; the recovered body is never emitted). Flagless v0.1.6 stays file-primary and byte-identical.
- Inspector `turnActivity` (A4): `codex_ipc_session_inspect.mjs` feeds the FULL rollout parse stream
  (not the clipped display tail) into the shared `createTurnBoundaryAccumulator` and adds an additive
  `activitySignals.turnActivity` (`open`/`closed`/`ambiguous`) via the pure `summarizeThreadActivity`
  projection. Summarized lifecycle items gain an additive `turnId`. `maybeMidTurn` values/fields are
  byte-compatible; the `conclusion` now derives from `turnActivity`; `terminalState` stays historical.

### Changed
- Consolidated the two duplicated correlation reducers onto the single boundary machine: removed
  `correlateDispatchWindow` (reader) and `classifyDispatch` (wait). Correlation now also allows a
  later same-`turn_id` user message (ordered fallback stays ambiguous) and rejects a non-null
  `agent_message.turn_id` that disagrees with its enclosing turn — extending the A-05 fail-closed
  class without reopening it.
- Producer denied-reply protocol (A5): the handoff scaffold, `SKILL.md`, `handoff-template.md`, and
  the example payload now state that a denied reply write is expected — self-verify, attempt the
  reply once, and on denial put the full substantive result in the final agent message (no
  retry/escalation). `codex_ipc_contract_audit.mjs` locks these bytes.
- Marker-proof completion is turn-scoped (A4, fixes A-04): the `codex_ipc_rollout_reader.mjs`
  marker proof (`pollRolloutForMarker`/`inspectRolloutMarker`) migrated onto the shared
  turn-boundary accumulator as a named consumer, so a `task_complete` certifies the agent marker
  only when it closes the SAME turn that carried it. The old pure line-order relation returned a
  cross-turn false-positive proof (agent marker in turn 1, `task_complete` in turn 2).
- Write-proof pre-send gate (A4): `codex_ipc_write_proof.mjs` now requires `turnActivity==="closed"`;
  `--allow-mid-turn` overrides an `open` turn only, never `ambiguous` (fail closed on ambiguity).
- Stored-policy preflight demoted to advisory (A2): `codex_ipc_session_inspect.mjs` now emits an
  additive `permissionProfileAdvisory` sibling of `approvalMode`/`sandboxPolicy` (names/values
  unchanged) marking the stored `threads.sandbox_policy`/`threads.approval_mode` columns as
  `source:"stored-thread-row"`, `mayDifferFromEffectiveTurn:true`, `mustNotGateDispatch:true`,
  `predictsReplyWritability:false`. The false "these predict whether an injected turn can write its
  reply file / preflight before delegating" guidance is corrected across `SKILL.md` and both
  troubleshooting surfaces (which gain a denied-reply-write row pointing to
  `codex_ipc_wait --accept-rollout-fallback`); a dated correction is appended to the
  `docs/COMPATIBILITY.md` host-identity/permission ledger without rewriting the historical rows.

### Fixed
- `tests/test_wait_contract.sh` probed only the repo layout, so from an installed skill root it
  reported `SKIP: codex_ipc_wait.mjs absent` and exited 0 while the tool sat one directory away.
  It now uses the dual-layout probe every other suite uses (landed after the v0.1.5 tag).

## [0.1.5] — 2026-07-10

Makes the delegation completion contract mechanically checkable, and surfaces the per-thread
settings a dispatcher needs before delegating.

### Added
- `skills/ipc/scripts/codex_ipc_wait.mjs`: the sanctioned dispatcher-side completion check.
  Correlates a dispatch to its OWN turn (task-marker `user_message`, `turn_id`-primary) and emits
  exactly one token — `done` (reply file present AND that turn reached `task_complete`
  un-superseded), `aborted` (that turn ended in `turn_aborted`, regardless of reply), `superseded`
  (a newer turn opened before its terminal — never certified by a later, unrelated terminal),
  `reply-missing`, `pending`, or `unavailable`. Single-shot by default; `--budget-ms` bounds an
  optional in-process poll. Read-only, Node built-ins only, no `node:sqlite`, no daemon.
  A reply file's existence alone was never completion — dispatchers previously hand-rolled this
  check and got it wrong.
- `tests/test_ipc_wait.sh` (unit) and `tests/test_wait_contract.sh` (black-box conformance suite
  authored independently from the contract text, with a negative self-test proving a wrong
  implementation fails it). Both wired into CI.
- `codex_ipc_session_inspect.mjs` surfaces the thread's stored `approvalMode` and `sandboxPolicy`
  (schema-tolerant, fail-visible parse), so a dispatcher can preflight whether an injected turn
  will be able to write its reply file before delegating.

### Changed
- `skills/ipc/SKILL.md` and `references/handoff-template.md` document the completion contract's
  mechanical checker, the rollout identity precondition for explicit `--rollout-path`, and the
  rules that dispatch never alters a target thread's model/reasoning/sandbox/approval and that
  subagent model+effort must be set explicitly on every spawn.

## [0.1.4] — 2026-07-10

Post-v0.1.3 hardening: adversarial-review follow-ups plus the R3 router-contract drift sentinel.

### Added
- `tests/test_router_contract.sh`: hermetic router-contract drift sentinel — snapshots the
  `initialize` / `thread-follower-start-turn` request shapes via the client's dry-run CLI and
  classifies canned `no-client-found` / acceptance / malformed responses through the wrapper's
  stubbed-transport path, so a Desktop update that drifts the private contract turns CI red
  before a live failure does. Sentineled vs excluded facets documented in the suite header.
- `tests/test_session_inspect.sh`: hermetic session-inspector suite (temp fixture state; never
  touches `~/.codex`; self-skips without `node:sqlite`).
- Reply viewer/harvester surface a visible advisory when a correlated turn's final message
  starts with `REPLY-SUPERSEDED` while a readable reply file exists (file stays primary;
  machine-consumed output shapes unchanged).

### Changed
- `CODEX_IPC_OBSERVE_BUDGET_MS` default raised `8000` → `20000` ms, informed by a read-only
  census of real dispatch→pickup latencies (auto-load recoveries dominate the tail; census is
  same-machine and mostly idle-thread — documented caveat, still a bounded one-shot cap).
- `codex_ipc_session_inspect.mjs`: `turn_aborted` now has terminal parity wherever
  `task_complete` was treated as terminal (additive output fields; existing fields unchanged);
  rollout candidate discovery canonicalizes Windows `\\?\` aliases, dedupes to physical
  identity, and surfaces genuine multi-candidate ambiguity additively instead of silently
  selecting the first candidate (DB-designated rollout remains the higher authority).
- Harvest/observe diagnostics hex-escape C0/C1/ESC bytes before reaching stderr (stdout token
  and body contracts unchanged).

### Fixed
- Session-inspector mid-turn inference no longer misreports an aborted turn as still active.

## [0.1.3] — 2026-07-09

M2 milestone: dual-source reply harvesting and bounded rollout confirmation, built and verified
by two isolated implementation lanes against the final verified spec (GO_WITH_CONDITIONS; all
gating conditions resolved at integration).

### Added
- Bounded post-acceptance rollout confirmation for both live-send success branches:
  `rollout-hit`, `rollout-pending`, or `rollout-unavailable`. Accepted sends remain
  `gui-delivered`; observation failures map to unavailable without resend.
- Hermetic rollout-reader and dual-source reply-harvest suites are syntax-checked and run on both
  CI matrix legs.

### Changed
- Reply viewing is file-primary with an exactly correlated, read-only rollout fallback when the
  primary is absent or unreadable. Source labels are explicit and fallback text remains
  stdout-only.
- Current-facing README, skill, architecture, compatibility, install, and troubleshooting guidance
  now documents M2 confirmation and dual-source reply semantics.

### Fixed
- Auto-load retry deadline/interval knobs now reject zero or malformed values, warn visibly, and
  fall back to documented positive defaults.
- Corrected the host-identity ledger's refuted universal follower-sandbox claim and the README's
  stale v0.1.1 status line.

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
