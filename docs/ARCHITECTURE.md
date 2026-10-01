# Architecture

Repo-level overview. The authoritative operational detail ships with the skill itself in
[skills/ipc/references/architecture.md](../skills/ipc/references/architecture.md) so it is present
in standalone installs too; this page orients a repo reader.

## Layout

```
claude-codex-ipc/
  .claude-plugin/plugin.json     plugin manifest (plugin name: codex-ipc)
  skills/ipc/                    CANONICAL skill source (skill name: ipc)
    SKILL.md                     operational contract (manual-trigger only)
    scripts/                     the toolkit (bash wrapper + Node tools + PS1 host policy/activation)
    references/                  bundled deep docs (architecture, security model, troubleshooting,
                                 handoff template)
    examples/                    synthetic payload example + quickstart commands
  tests/                         hermetic harnesses + public-safety scan (repo-only; not installed)
  docs/                          repo-level docs (this page, install, compatibility, troubleshooting)
  install.sh/.ps1, uninstall.*   standalone-install helpers
  .github/workflows/test.yml     CI: syntax, hermetic tests, safety scans (no live IPC)
```

## Core design: keyed file transport

One dispatch = one unique task file + one correlated reply file:

```
${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSessionId>/<conversationId|filedrop>/<dispatchId>.task.md
                                                                            /<dispatchId>.reply.md
```

- Atomic create (temp file + rename), never a shared mutable file → concurrent Claude sessions and
  Codex threads cannot cross-talk or clobber.
- Reply correlation is exact via `dispatchId`.
- Works from any cwd; no git repo required (git context is optional payload enrichment).
- Keep-only by default: `CODEX_IPC_RETENTION_DAYS` unset/empty/`0` never delete. A positive
  integer prunes envelopes opportunistically on the next dispatch after that many days.

## Reply resolution

The reply viewer is a derived, read-only projection. For each retained dispatch it selects a
readable regular non-symlink `.reply.md` first and labels it `source=reply-file`. Only when that
primary is absent or unreadable may an exactly correlated, completed rollout supply
`source=rollout-fallback`. If neither source yields content, the viewer emits `source=none` with
a visible reason. It never treats the two bodies as equal, and rollout-derived text is stdout-only:
no cache, reconstructed reply file, transport-root write, lock, or retention side effect is added.
Within the exactly correlated turn, final bodies are deduplicated by exact text. Multiple distinct
explicit `final_answer` bodies certify only when a nonempty `task_complete.last_agent_message`
exactly matches one body; missing, empty, or nonmatching terminal evidence remains unavailable.
The dispatch marker keeps the turn boundary it was observed inside. A later unmarked continuation
cannot replace that turn's terminal or supply a missing final body. When the dispatch's own
terminal has no assistant output, the reader may attach privacy-bounded `turn-error` and
`turn-model-state` facts. Those facts neither certify a body nor change lifecycle or source
selection.

Completion and freshness are separate projections. Historical completion remains evidence that an
exact dispatch occurrence completed; `latestOccurrence` reports the newest exact marker occurrence,
and global freshness additionally requires that occurrence to be certifiably complete with no
opaque malformed/unknown-schema suffix after its boundary. A valid primary reply remains selected
for viewing, but opaque later schema keeps the waiter machine token `unavailable`. Two distinct
bound-turn exact marker occurrences are dispatch-ID reuse: the single reply path cannot identify
its writer, so the waiter remains `unavailable` even when one or both occurrences completed. The
viewer may still show a primary reply, but marks supersession `unavailable` and cautions that the
body may be stale; it never supplies a rollout-fallback body or a positive/negative supersession
conclusion for the reused ID. Same-item mirror records collapsed into one logical occurrence are
not reuse. A distinct later user item in the same turn invalidates binding as
`intervening-user-message`; identical text alone does not create a separately bound reuse
occurrence. Absent reuse, rollout fallback and a negative supersession claim require settled
freshness. An exact positive `REPLY-SUPERSEDED` completion remains positive when later uncertainty
is not another exact occurrence, and discloses that uncertainty rather than erasing it.

## Delivery routes on top of the transport

1. **File-drop (default, stable):** operator pastes one printed pickup line into their Codex
   session. Zero dependencies beyond bash; zero effect on other sessions.
2. **Thread-bound manual (`--ipc <uuid> --deliver manual`):** writes the ordinary envelope under
   the UUID channel, performs the shared target inspection, and prints pickup plus a fully bound
   `WAIT:` command. It exits before host policy, PowerShell, client, observer, or opener code and
   prints no live `RESULT:`. A trusted inspector page is propagated; absent page authority emits
   fixed `ROLLOUT-PATH:` guidance. The default root stays `~/.claude/ipc`; an explicit shared
   `CODEX_IPC_ROOT` is an operator configuration choice for a target-writable location.
3. **`--ipc` live injection (optional, EXPERIMENTAL, Windows):** after writing the envelope, the
   wrapper checks a read-only host inventory and injects the pickup line into the renderer-owned
   Desktop thread over the app's private named-pipe router. The host check runs freshly before the
   initial send and every retry. Activation of an unowned package thread is a separate, default-off
   `--autoload codex-uri` request with package/update/protocol and foreground gates; alternate
   intended hosts are never protocol-activated. Result taxonomy:
   `gui-delivered | gui-unowned | failed-closed`.
   An accepted send then receives one bounded confirmation token: `rollout-hit`,
   `rollout-pending`, or `rollout-unavailable`. A hit proves only that the exact dispatch pickup
   reached a rollout user message; pending means an authoritative candidate was readable/parseable
   but no pickup was observed within budget; unavailable means observation could not determine a
   result. None proves completion or reply-file success, and no observation outcome causes an
   automatic resend. The observation budget includes rollout integrity hashing and revalidation;
   expiry cannot emit a hit from an uncertified partial read.
   The current real-machine readers intentionally leave package-update clearance and the effective
   protocol handler unqualified, so real activation refuses until qualified sources replace those
   unknowns. Hermetic mocks exercise the positive decision without granting live authority.
   Built on private internals — revalidate after every Codex Desktop update. That includes
   host-identity drift: since 2026-07-09 the Codex Desktop GUI runs as `ChatGPT.exe` under the
   unchanged `OpenAI.Codex` package family, so foreground/GUI identification is positive
   (executable path + package), never process-name-only (see `docs/COMPATIBILITY.md`,
   "Dated historical evidence, not current certification").
   (The CLI-backed `--exec`/`--app`/`--open` modes were removed in v0.1.8; there is no headless
   execution path.)

Host configuration applies only to live delivery and resolves per field as wrapper flag,
environment, `${CODEX_IPC_ROOT}/host-policy.json`,
then defaults (`autoload=off`, intended host `package`). Every present layer is validated even when
overridden. After publishing the thread-bound envelope, the wrapper runs one read-only target
inspection. Manual delivery returns after preparation; live delivery reuses that snapshot across
guarded recovery before its first host gate or pipe contact. The inspection requires a trusted
exact active DB row, a `root` or warned `legacy-root-assumed` classification, and a nonempty stored
model. Explicit child evidence is non-root; a null legacy source is assumed root only when every
available child indicator is absent. Missing, archived, non-root, empty-model, malformed,
contradictory, or ambiguous state refuses before host policy or pipe contact. Manual delivery emits
its fixed refusal and no actionable pickup; live delivery reports `confirmation=not-attempted`.

The wrapper considers activation only from parsed structure, not text matches. `no-client-found`
must be the exact failed response for the requested target with exactly one matching follower
request; the existing pre-send snapshot remains target authority. Initial renderer-owned success
and post-autoload retry success both require parsed
`ok: true`, the exact `targetThreadId`, `response.resultType: "success"`, and exactly one follower
occurrence whose `name`, `method`, and `conversationId` all match. Client exit 0 with missing or
conflicting structure is post-attempt ambiguous: it is not classified as delivered and is never
automatically retried. Inspection is necessary before considering a manual retry, but negative
bounded/recent-tail evidence cannot prove non-admission. Retry requires either an exact
full-history outcome proving non-admission or an explicit owner decision acknowledging the
unresolved duplicate-send risk. The same target snapshot gates the renderer-owned and unowned
paths; only the host inventory repeats immediately before each send or retry. Exact target binding
prevents heuristic retargeting, and ambiguous outcomes are not retried.

## Inspection surfaces (read-only)

- `codex_ipc_session_inspect.mjs` — thread row, fail-closed root classification and parent facts,
  stored settings, database-selected rollout, full-stream turn activity, and bounded display tail.
- `codex_ipc_thread_locator.mjs` — candidate discovery for new-session mode (never send
  authority); its root/non-root/legacy hints do not replace inspection. Its `--since-*` filters
  use the current indexed timestamps, which can be rewritten by thread reset/revert, so a match is
  not proof that a thread was newly created.
- `codex_ipc_snapshot.mjs` — config/DB hashing for before/after isolation evidence.
- `codex_ipc_revalidate.mjs` — post-update validate-only checks. It parses and runs the shared host
  policy before the optional pipe read; a host refusal suppresses `--allow-live-ipc-read` rather
  than contacting the pipe. Its report lists each detected GUI host and app-server executable and
  classification without command lines. A permitted live read sends `initialize` only; inventory
  does not prove thread ownership.
- `codex_ipc_contract_audit.mjs` — static requirement matrix over the bundled skill files.

## Authorized write proof

`codex_ipc_write_proof.mjs` is dry-run by default. Its controlled live path performs inspect →
revalidate → snapshot → owner-bound, integrity-validated, complete-EOF rollout cursor plus a freshly
recomputed turn-activity gate → full revalidation of that cursor after the snapshot → one marker
send → returned-turn-bound post-cursor poll → snapshot → compare. Rollout owner metadata is a file-global
integrity condition: the first physical record must be `session_meta` and pins the current owner;
cursor reads revalidate the canonical path, physical identity, first record, and a SHA-256 digest
of the entire consumed prefix (not only its trailing window), and certifying locator-to-reader
handoffs carry both the expected owner and physical identity. Forked rollouts additionally require
a valid `forked_from_id`, `subagent_history_start_ordinal >= 1`, contiguous top-level ordinals from
zero, and `event_msg/thread_settings_applied` at the boundary. Earlier copied records are parsed and
hashed but never observed or projected as child evidence. A missing, invalid, gapped, reordered, or
unreached boundary fails closed; timestamps are not provenance. Later inherited metadata is inert
only when admitted lineage predeclared its ID, and it never rebinds lifecycle ownership. Missing,
invalid, changed, or unlinked ownership fails closed. The inspector's `recentItems` remains a raw
physical display tail and may show copied ancestor records; only the owner- and history-scoped
`activitySignals` projection describes child-local activity. The
live path requires explicit authorization through
`--send --ack-live-write [--allow-any-thread]`.
The final pre-send revalidation requires unchanged canonical/physical identity, complete EOF,
offset/size, and whole-prefix SHA-256, so growth, replacement, and same-size rewrites all produce
zero sends. After the one send attempt, a certifiable client result requires a successful client
process, top-level `ok: true`, the exact canonical top-level `targetThreadId`,
`response.resultType: "success"`, and exactly one follower occurrence whose `name`, `method`, and
`conversationId` match the target. The matching follower proves send occurrence only; it does not
prove router acceptance or task completion. If occurrence is confirmed but any certification
field fails, the harness preserves it, performs zero rollout polls, and reports non-retryable
`sent-but-unverified`; unparseable output leaves occurrence unknown as `send-outcome-unknown`.
Only a certified result with one unconflicted response turn ID may start polling; missing or
conflicting turn IDs likewise yield zero polls and `sent-but-unverified`. End-to-end success
additionally requires the rollout proof to bind that turn and show the agent marker followed by
completion, plus structured config/DB isolation proof. Null, malformed, contradictory, or bare-`ok`
post-send proofs cannot certify. Inspection is necessary before considering a retry, but negative
bounded/recent-tail evidence cannot prove non-admission. Retry requires either an exact
full-history outcome proving non-admission or an explicit owner decision acknowledging the
unresolved duplicate-send risk.

Rollout locator basenames admit only legacy `...-<rootUuid>.jsonl` and paginated
`...-<rootUuid>_<pageUuid>.jsonl`. A paginated first record must additionally bind
`session_id` to the root, declare `history_mode: paginated`, and include a valid
`history_base.thread_id`. The state DB's explicit rollout path is authoritative; discovery returns
ambiguous rather than choosing among distinct valid physical pages by mtime. Even with one valid
file, root-only discovery returns `candidate-set-unresolved` if the scan also finds an invalid
recognized exact-target candidate, any `rollout-*` basename containing the target UUID that is not
understood as a candidate for that root (including when a trailing second UUID makes the legacy
parser attribute the name to another root), or an unreadable subtree. A recognized paginated
basename is exempt when only its page ID equals the target and its root is another session. Other
unresolved diagnostics are never discarded to select the valid file. Polling remains bound to that
page and never auto-hops or stitches records. A SQLite-free veto recursively scans the configured
sessions root for one direct paginated successor whose complete first record names the bound page
ID in `history_base.thread_id` and gives a safe record-boundary `end_byte_offset` no larger than the
bound page. A marker at or beyond that cutoff is `dispatch-history-abandoned`; an earlier marker is
`rollout-page-superseded`; malformed, incomplete, or multiple claims are
`page-supersession-unproven`. Each state vetoes positive pickup, completion, and rollout-fallback
results while leaving the reader on the original page. The standalone observer, waiter, and
harvester do not query the DB for that path; callers should pass their exact `--rollout-path` when
known, or accept root-discovery ambiguity. The maintained wrapper propagates its one trusted
inspector page to observation and the printed waiter. The reply viewer accepts an
explicit page for a UUID-scoped `-c` view or can derive it once with `--derive-rollout-path`;
session-wide and filedrop views cannot select a page. Missing authority prints fixed
`ROLLOUT-PATH:` guidance, page vetoes print fixed `ROLLOUT-PAGE:` guidance, and a primary reply
stays visible with a stale-body caution while fallback remains unavailable. Between full reads, a
complete cursor may enable a metadata-only no-growth check of canonical path, physical
identity, and size. That check is pending-only and cannot prove pickup or completion. Growth and
change run the full certifying reader, as do final or budget-edge attempts that begin before the
deadline; a deadline that elapses during sleep returns unverified without a post-deadline read.

Path configuration is deliberately component-scoped. Inspector accepts
`CODEX_IPC_SESSIONS_ROOT`; waiter accepts `CODEX_IPC_ROLLOUT_PATH` and
`CODEX_IPC_SESSIONS_ROOT`; observer accepts `CODEX_IPC_ROLLOUT_PATH` and its existing
environment-only `CODEX_IPC_SESSIONS_ROOT`; harvester retains both aliases. Where a corresponding
flag exists, precedence is explicit flag, then nonempty environment, then the existing default or
discovery behavior. The viewer has no independent environment option, although its harvester child
inherits the process environment; use viewer flags for an auditable selection. `CODEX_HOME` is not
a supported path alias. A configured path is input, never page or owner authority.

## Design invariants

- Explicit conversation UUID per live send; no heuristic write targeting.
- File-drop fallback precedes and survives every live attempt.
- Exactly one RESULT line follows every post-envelope live outcome; accepted sends stay
  `gui-delivered` regardless of observation token.
- Reply files remain primary; unsettled freshness cautions that evidence, while rollout fallback
  requires settled freshness and remains correlated, read-only, and stdout-only.
- SQLite is opened `readOnly:true` everywhere; no config/account/plugin/archive mutation.
- Transcript disclosure is opt-in (`CODEX_IPC_INCLUDE_TRANSCRIPT=1`).
- No authorized thread id ships in the code (`CODEX_IPC_AUTHORIZED_TEST_THREAD` is
  operator-supplied).
- Tools self-locate siblings by script directory → any-cwd operation in plugin, repo, and
  standalone layouts.
