# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.1.8] — 2026-07-24

> Post-tag correction: the first v0.1.8 cut shipped correct runtime code but stale docs
> (still instructing the removed `--app`/`--open`/`--exec` modes and a "default 7"
> retention value), plus an octal-value validation hole, a GNU-only `ln -T`, a test seam
> that could suppress an executed dispatch, and a final-manifest bound to the wrong commit.
> An independent adversarial audit found these; all are fixed and the tag was moved to the
> corrected commit. See "Fixed after audit" below.

Identity: **No Codex CLI / No Ambiguous Resend.** Live `--ipc` GUI delivery, the
completion-wait contract, and reply harvesting are unchanged and remain the primary
path; this release removes the CLI-backed modes and closes two data-safety defects in
the daily-use wrapper. It supersedes the abandoned file-drop-only `v018-nocli` line,
which removed live delivery entirely and is not a release candidate.

### Removed
- `--app`, `--open`, and `--exec` modes and the `need_codex` helper. Each removed flag
  now exits non-zero with a replacement hint **before** any transport-root read, envelope
  write, or child launch. `--ipc` and the default file-drop path are unchanged. The
  wrapper no longer invokes the `codex` binary on any path; `codex_ipc_revalidate.mjs`
  no longer spawns `codex --version` (it reports the no-CLI invariant instead).

### Changed
- **Retention is keep-only by default.** `CODEX_IPC_RETENTION_DAYS` now defaults to
  never-delete: unset, empty, and exact `0` all mean keep-only, and pruning requires an
  explicit positive integer. Previously the default was 7, so a caller that never
  mentioned retention silently age-deleted transport envelopes — including replies
  nobody had harvested. A non-canonical value (negative, decimal, junk) is now rejected
  loudly before any envelope write instead of silently skipping the sweep. Retention is
  **not** a confidentiality control and is documented as such; plaintext persists
  indefinitely by default (SECURITY.md).
- **Create-once publication.** The envelope writer no longer publishes with `mv -f`
  (which could silently clobber a pre-existing, possibly in-flight envelope). It links
  the destination and fails loudly on collision, rejects a directory/symlink already at
  the path, distinguishes a genuine collision from an environmental link failure, and
  never reports a post-publication cleanup failure as a dispatch failure.
- **No ambiguous resend.** The follower request is written before its response is
  awaited, so a timeout, closed pipe, or protocol drift may leave a task already
  admitted. Such outcomes are now classified `confirmation=unknown` and do not print a
  pickup/resend line; the autoload retry poll retries only on an authoritative
  `no-client-found` and otherwise terminates as `retry-ambiguous-outcome`.

### Tests / CI
- `tests/test_retention_sweep.sh` is now gated in both CI and the local release runner
  (it previously ran nowhere); made hermetic against an inherited retention value; and
  asserts the keep-only default. The static contract audit is now a local release gate,
  not CI-only. A create-once collision/regression test was added. Final release
  manifests are regenerated at the tested commit and are now covered by `check-all`.

### Fixed after audit
- **Docs vs runtime:** removed every remaining `--app`/`--open`/`--exec` instruction from
  `SKILL.md`, `README.md`, `docs/{ARCHITECTURE,COMPATIBILITY,INSTALL,TROUBLESHOOTING}.md`,
  and `references/{architecture,troubleshooting}.md` (following one reached the wrapper and
  exited 64). Corrected the "default 7" retention text to keep-only in the docs that lagged.
- **Retention validation:** a leading-zero value (`08`/`09`) passed a bare `^[0-9]+$` then
  threw a Bash octal error that silently skipped the sweep while still publishing. Values
  are now `^(0|[1-9][0-9]*)$` compared in base-10; any non-canonical value exits 64 before
  any envelope write.
- **Portability:** `atomic_write` no longer uses GNU-only `ln -T`; it uses portable plain
  `ln` on BSD/macOS. A follow-on audit found that the destination pre-check alone did not
  close a raced-directory interleaving; the post-link hardening is recorded below.
- **Test seam:** `_TEST_SOURCE_ONLY` is honored only when the script is sourced and exactly
  `1`; an executed wrapper ignores it, so an inherited value cannot silently exit 0 without
  dispatching. New `test_ipc.sh` and `test_retention_sweep.sh` sections guard both fixes.
- **Manifests:** `gen_release_manifest.sh check-all` fails closed if a final manifest exists
  but `FINAL_REF` is missing; the final pair is regenerated at the tested commit and the
  release commit touches no runtime/overlay file, so `FINAL_REF` stays tag-accurate.
- **Release gate:** `scan_public_safety.sh` excludes nested `worktrees/` (separate checkouts),
  so `run_release_gates.sh` passes from a primary checkout that has sibling worktrees.

### Hardened after audit-chain review
- **Create-once post-link verification:** after a successful portable `ln`, `atomic_write`
  now verifies that the exact destination is a regular file. If a directory races into
  place and `ln` succeeds inside it, the staging and inner hard-links are removed and the
  publication fails closed instead of reporting a false success.
- **Final-ref fail-closed check:** `gen_release_manifest.sh check-all` now parses
  `FINAL_REF` with the same whitespace stripping used by manifest enumeration. Missing,
  empty, and whitespace-only markers all fail closed while final manifests exist.
- **Release-document consistency:** the README status footer now reports v0.1.8; the
  release runner's header and every usage form now describe all ten `DEFAULT_SUITES`,
  the conditional safety scan, and the always-run contract audit; its older nine-suite
  timing figure is labelled historical. The retention test's seven-day wording now
  describes an explicit opt-in contract.
- **Worktree-path test stability:** the autoload matrix now collapses PowerShell's
  host-width-dependent diagnostic whitespace before fixed-token matching. Long required
  worktree paths no longer split `must be a UUID` across lines and produce a false red;
  the exit-code and message-content checks are unchanged.

## [0.1.7] — 2026-07-12

Defect tranche superseding v0.1.6. **Known issues in v0.1.6:** v0.1.6 shipped with all four
defects fixed below, including a release-gate process bound that could pass vacuously — the
v0.1.6 RC-PASS process-bound figures are therefore unreliable. Do not install or propagate
v0.1.6; it is superseded by 0.1.7.

### Fixed
- Release-gate process-bound trust (F2/A0): the "owned Node" accounting in
  `tests/run_release_gates.sh` was a bare before/after set difference of global node PID
  snapshots — no parent-PID logic (the header claimed a descendant confirmation that did not
  exist) — and the Windows enumeration path swallowed failures, so a broken enumerator silently
  measured an owned peak/residual of 0 and the process bound passed vacuously. Ownership is now
  fail-closed descendant-of-runner PID ancestry (POSIX: PPID chains to the runner; Windows: the
  runner's MSYS descendant closure mapped to Win32 PIDs and walked through the full
  `Win32_Process` parent table, catching node-spawned node that MSYS `ps` cannot see). An
  enumeration failure aborts the run with GATE ERROR (exit 3) instead of fabricating zero, at
  startup, mid-suite sampling, and post-suite drain. Documented residual: a node process whose
  intermediate parents already exited escapes ancestry attribution. Pinned by the new hermetic
  `tests/test_gate_process_ownership.sh` fixture (not part of the pinned nine-suite battery).
- In-window schema drift on a completed turn (F1/A4): the turn-boundary accumulator applied
  schema-drift attribution only to turns still open at `finish()`, so a completed turn with
  in-window drift kept a `closed` snapshot — the inspector and the write-proof pre-send gate
  certified a turn the dispatch lifecycle projection refused over the same records
  (`unavailable`, schema-drift). Drift arriving while a turn is open now poisons that turn at
  push time: inspector `turnActivity` degrades to `ambiguous` and `codex_ipc_write_proof.mjs`
  refuses the send, not overridable by `--allow-mid-turn` (fail closed on ambiguity).
- Retention-sweep silent data loss (WS-7): the opportunistic sweep in `handoff_to_codex.sh`
  deleted transport files by age alone, so an aged UNREPLIED `*.task.md` — an outstanding
  dispatch that was never answered — was silently destroyed once it crossed the retention
  horizon. An aged task is now deleted only on positive proof that its same-dispatch
  `*.reply.md` exists (pairing decided before any reply is deleted, so aged pairs still sweep
  in one run); an unreplied task is retained regardless of age, pairing ambiguity errs toward
  retention, and a failed task deletion is reported to stderr rather than suppressed
  (reply/empty-dir deletion failures remain suppressed and err toward retention). New hermetic
  survival suite `tests/test_retention_sweep.sh`.

### Changed
- `tests/test_reply_view.sh` (F3/T23) no longer re-runs the entire `tests/test_ipc.sh`
  transport suite inside itself — the standalone gated `test_ipc.sh` run in the same battery
  already delivers that whole-suite guarantee, and the nested rerun pushed the suite past the
  legitimate 600s per-suite cap on a loaded host. T23 is now a direct wrapper→viewer
  envelope-seam contract check (the one interaction the rerun never exercised): one hermetic
  wrapper dispatch must produce the keyed on-disk envelope layout, and the viewer must
  enumerate it as awaiting-primary and render the reply once it lands at the advertised path.
  Suite runtime ~150s versus the 400–1400s observed with the nested rerun; the per-suite cap
  is NOT raised.

## [0.1.6] — 2026-07-12

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
- `codex_ipc_wait.mjs` opt-in `--status-exit-codes` (A6, D4): maps the determination to a frozen
  exit code (`done=0`, `pending=2`, `aborted=3`, `superseded=4`, `reply-missing=5`, `unavailable=6`;
  usage errors stay exit 1 with no token). The token stays the sole stdout line. Flagless mode is
  unchanged and byte-identical: every determination exits 0. Documented in `SKILL.md` and both
  troubleshooting surfaces.
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
- Completion waiter on every easy path (A3): README Quickstart, `skills/ipc/examples/quickstart.md`,
  `docs/TROUBLESHOOTING.md`, `skills/ipc/references/troubleshooting.md`, and `SKILL.md` now show a
  bounded `codex_ipc_wait --accept-rollout-fallback` with all six tokens and the named-dispatch-
  completion-vs-thread-idleness distinction, and carry the verbatim OQ-4 caveat ("resuming the goal
  in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification
  requires a NEW dispatch with a new marker.") on every recovery surface. The `handoff_to_codex.sh`
  wrapper prints one POSIX-escaped `WAIT:` line before the final `RESULT:` on the two accepted live
  `--ipc` success branches only (D3); file-drop/exec/failure never print it. `codex_ipc_contract_audit.mjs`
  gains REQ-019 enforcing the easy-path references and the verbatim OQ-4 caveat.
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
  It now uses the dual-layout probe every other suite uses (landed after the v0.1.5 tag; `fc54ce1`).
- Transport-root containment (A-02) and wrong-turn reply attribution (A-05), fixed post-v0.1.5 at
  `0fbd517` and first shipped in this release. A-02: `CLAUDE_SESSION_ID` became a path segment
  under `CODEX_IPC_ROOT`, so a `../escape` id wrote the envelope outside the transport root and
  still exited 0; the wrapper now requires one safe segment and fails closed rather than sanitizing
  a rewritten id (which would silently split a session's channel in two). A-05: the shared
  correlator accepted a `user_message` whose `turn_id` disagreed with its enclosing turn, so the
  harvester/viewer could serve that turn's final answer for this dispatch; the guard that
  `codex_ipc_wait` already applied now lives in the shared correlation authority so every consumer
  refuses.

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
