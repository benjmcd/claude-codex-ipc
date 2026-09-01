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
    scripts/                     the toolkit (bash wrapper + Node tools + PS1 autoload helper)
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
2. **`--ipc` live injection (optional, EXPERIMENTAL, Windows):** after writing the file-drop, the
   wrapper injects the pickup line into the renderer-owned Desktop thread over the app's private
   named-pipe router; unowned threads are auto-loaded via the app's own `codex://threads/<id>`
   deep link with focus snapback. Result taxonomy: `gui-delivered | gui-unowned | failed-closed`.
   An accepted send then receives one bounded confirmation token: `rollout-hit`,
   `rollout-pending`, or `rollout-unavailable`. A hit proves only that the exact dispatch pickup
   reached a rollout user message; pending means an authoritative candidate was readable/parseable
   but no pickup was observed within budget; unavailable means observation could not determine a
   result. None proves completion or reply-file success, and no observation outcome causes an
   automatic resend. The observation budget includes rollout integrity hashing and revalidation;
   expiry cannot emit a hit from an uncertified partial read.
   Built on private internals — revalidate after every Codex Desktop update. That includes
   host-identity drift: since 2026-07-09 the Codex Desktop GUI runs as `ChatGPT.exe` under the
   unchanged `OpenAI.Codex` package family, so foreground/GUI identification is positive
   (executable path + package), never process-name-only (see `docs/COMPATIBILITY.md`,
   "Dated historical evidence, not current certification").
   (The CLI-backed `--exec`/`--app`/`--open` modes were removed in v0.1.8; there is no headless
   execution path.)

The wrapper authorizes auto-load from parsed structure, not text matches. `no-client-found` must be
the exact failed response for the requested target with exactly one matching follower request; the
pre-navigation inspector must then prove a successful read-only DB open and one exact active row for
that same target. Rollout-only, missing, archived, malformed, or ambiguous state cannot authorize a
deep link. Initial renderer-owned success and post-autoload retry success both require parsed
`ok: true`, the exact `targetThreadId`, `response.resultType: "success"`, and exactly one follower
occurrence whose `name`, `method`, and `conversationId` all match. Client exit 0 with missing or
conflicting structure is post-attempt ambiguous: it is not classified as delivered and is never
automatically retried. Inspection is necessary before considering a manual retry, but negative
bounded/recent-tail evidence cannot prove non-admission. Retry requires either an exact
full-history outcome proving non-admission or an explicit owner decision acknowledging the
unresolved duplicate-send risk. The
unowned-branch recheck is defense in depth: the renderer-owned fast path relies on the mandatory
separate agent preflight and does not add another wrapper inspection before its initial attempt.
The resulting preflight-to-send state-change window remains disclosed. Exact target binding
prevents heuristic retargeting, and ambiguous outcomes are not retried.

## Inspection surfaces (read-only)

- `codex_ipc_session_inspect.mjs` — thread row + rollout tail + mid-turn heuristics.
- `codex_ipc_thread_locator.mjs` — candidate discovery for new-session mode (never send
  authority).
- `codex_ipc_snapshot.mjs` — config/DB hashing for before/after isolation evidence.
- `codex_ipc_revalidate.mjs` — post-update validate-only checks (pipe connect only with
  `--allow-live-ipc-read`, sending `initialize` only).
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
page, and cross-page N-to-N+1 rollover is not yet certified or supported. The standalone observer,
waiter, and harvester do not query the DB for that path; callers should pass
their exact `--rollout-path` when known, or accept root-discovery ambiguity. Between full reads, a
complete cursor may enable a metadata-only no-growth check of canonical path, physical
identity, and size. That check is pending-only and cannot prove pickup or completion. Growth and
change run the full certifying reader, as do final or budget-edge attempts that begin before the
deadline; a deadline that elapses during sleep returns unverified without a post-deadline read.

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
