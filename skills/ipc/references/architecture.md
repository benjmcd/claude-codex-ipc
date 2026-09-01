# /ipc architecture — transport model and delivery routes

## Transport envelope (stable core)

The Claude→Codex transport ENVELOPE — the per-dispatch `.task.md` the wrapper writes, and the
`.reply.md` Codex writes back — lives in a machine-local, repo-independent root, keyed per
`(Claude sessionId, conversationId, dispatchId)`:

```
${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSid>/<conversationId|filedrop>/<dispatchId>.task.md
                                                                      /<dispatchId>.reply.md
```

Properties this buys by construction:

- **Isolation.** Any number of concurrent Claude sessions and Codex threads never share a mutable
  file; there is no cross-talk and no clobbering (each dispatch is a unique leaf, written
  atomically via temp-file-then-rename).
- **Exact correlation.** A reply is matched to its task by `dispatchId`, with no ambiguity even
  when multiple handoffs are in flight.
- **CWD independence.** No git repository is required; the transport works from any directory.
  Task-CONTEXT artifacts (briefs, specs, bundles) still live inside the associated project and are
  referenced from the payload by absolute path — only the transport envelope is machine-local.
- **Missing-session safety.** If no Claude session id is injected, the wrapper mints an isolated
  `nosid-*` token instead of guessing another session's identity, and never guesses a transcript.

### Retention

Envelopes and replies are **kept by default**: `CODEX_IPC_RETENTION_DAYS` defaults to keep-only
(unset, empty and `0` all mean never delete). Pruning requires an explicit positive integer, so a
reply file persists until you opt in to deleting it. Pruning is **opportunistic**: it runs
only on the *next* `handoff_to_codex.sh` dispatch (the read-only viewer sweeps nothing), so a
terminal session's envelopes persist until a future handoff prunes them — an opportunistic bound,
not a scheduled sweep.

### Reply viewing

`scripts/codex_ipc_replies.sh` renders a consolidated, newest-first view of the per-dispatch
`.reply.md` files. It is a read-only, point-in-time DERIVED view — never the authoritative channel;
it writes, locks, and creates nothing (not even the transport root). Flags:
`[--session <sid>] [-c <uuid|filedrop>] [-n <count>] [--max-bytes <n>]
[--since <find -newermt spec>] [--paths-only] [--list-sessions] [-h]`. A malformed `--since` fails
closed (exit 1, never a false "0 replies"). Per-entry (session/thread/dispatch) attribution is what
keeps this a view rather than a re-commingling of channels.

### Completion, freshness, and supersession

The rollout correlator exposes orthogonal evidence rather than one overloaded success flag:

- historical lifecycle completion proves that an exact dispatch occurrence completed;
- `latestOccurrence` describes the newest exact dispatch-marker occurrence; and
- global `freshness` requires that newest occurrence to be certifiably complete with no later
  malformed or unknown-schema record making the post-boundary suffix opaque.

Within the bound turn, final bodies are deduplicated by exact text. Multiple distinct explicit
`final_answer` bodies certify only when a nonempty `task_complete.last_agent_message` exactly
matches one body; missing, empty, or nonmatching terminal evidence remains unavailable.

Historical completion is monotone evidence for that occurrence. A readable primary reply therefore
remains selected for viewing when later schema makes freshness opaque, but it may be stale and the
waiter returns `unavailable`. Two distinct bound-turn exact marker occurrences reuse one dispatch
ID; the one reply path cannot identify its writer, so the waiter remains `unavailable` even if one
or both occurrences completed. The viewer may still show a primary reply, but it marks supersession
`unavailable`, emits a stale-body caution, and never supplies a rollout-fallback body or a
positive/negative supersession conclusion for the reused ID. Same-item mirror records collapsed to
one logical occurrence are not reuse. A distinct later user item in the same turn invalidates
binding as `intervening-user-message`; identical text alone does not create a separately bound
reuse occurrence. Absent reuse, rollout fallback and a negative claim that
`REPLY-SUPERSEDED` was not seen require settled freshness, so neither can borrow an older completed
occurrence. An exact positive `REPLY-SUPERSEDED` completion remains positive only when later
uncertainty is not another exact occurrence; that uncertainty is disclosed separately.

## Delivery routes

### File-drop (default, stable)

The wrapper writes the payload to the keyed task file and prints one pickup line for the operator
to paste into their Codex session (Desktop app or TUI):

```
read "<absolute task path>" and proceed
```

This appears in the Codex Desktop GUI (the operator's own session reads the file) and has zero
effect on any other running Codex session. It requires no pipe, no SQLite support, and no Codex
CLI.

### Live Desktop IPC injection (`--ipc`, optional, EXPERIMENTAL)

Provenance: this transport was validated against a live Codex Desktop in the private predecessor
project and re-validated at a point in time (2026-07-08) during this repository's preparation —
the write-proof harness plus the `defer` and `switch`+ack delivery paths, with delivery confirmed
out-of-band via the reply loop (the wrapper now also runs one bounded post-acceptance rollout
observation and reports `confirmation=rollout-hit|rollout-pending|rollout-unavailable`).
`restore-if-known` remains unvalidated (fail-closed). It rides private Codex Desktop internals, so
run `codex_ipc_revalidate.mjs` on your own machine before first use and after every Desktop
update.

`handoff_to_codex.sh --ipc <conversationId> "task"` writes the file-drop first (so the fallback is
always ready), then injects the pickup line into the live Desktop GUI thread via the Desktop app's
IPC router named pipe (`\\.\pipe\codex-ipc`, `thread-follower-start-turn`). This route is built on
**private Codex Desktop internals** and can break in any Codex Desktop update; revalidate with
`codex_ipc_revalidate.mjs` (and, if needed, a controlled `codex_ipc_write_proof.mjs` run) after
updates.

Every `--ipc` send reports exactly one result:

- `gui-delivered` — the Desktop renderer accepted the turn. Silent and instant when the target
  thread is already loaded in the app. Loaded threads typically stay deliverable across repeated
  sends, but ownership can lapse (app restart, renderer eviction) — the wrapper then simply
  auto-loads again, so a lapse costs one extra auto-load, never a failure.
- `gui-unowned` — the thread exists but no renderer took ownership. Before reporting this, the
  wrapper auto-loads the thread through the app's own `codex://threads/<conversationId>` deep link
  and retries: it saves the operator's foreground window, fires the link, snaps focus back
  automatically (~100–150 ms), and polls ~30 s. The auto-load is foreground-aware — it defers
  (does nothing visible) while Codex itself is the foreground window, because the in-app thread
  view cannot be restored; it proceeds once the operator switches away, or reports `gui-unowned`
  after ~2 min. Success after auto-load leaves one disclosed residue: the Codex background window
  is left with the target thread selected.
- `failed-closed` — the target is missing or archived (refused before any deep link fires), or the
  router/pipe itself failed (app closed, timeout, protocol drift) — with the client's actual
  diagnostics printed instead of suppressed.

No click is normally required when the target thread is already renderer-owned, or when Codex is
not the foreground app and the wrapper can safely auto-load the target (focus restore is verified;
a failed verification is reported as a WARNING rather than staying silent). If Codex IS the
foreground app and the target thread is unowned, the default policy defers rather than changing
the visible Codex view — foreground recovery then requires explicit switch authorization (below)
or a future proven restore path. The file-drop **envelope** is preserved in every outcome; the
**pickup line** is printed only when structured evidence proves no follower was admitted.
`confirmation=not-attempted` names that state, although an exact `no-client-found` router request
may have occurred. After an ambiguous post-attempt result (`confirmation=unknown`) pickup is
suppressed and resending is forbidden.

#### Foreground policy (`--foreground-policy`, EXPERIMENTAL)

When the target is unowned and Codex itself is the foreground window, the wrapper applies one of
three policies (flag overrides the `CODEX_IPC_FOREGROUND_POLICY` env default of `defer`):

- `defer` (default): never navigate the visible Codex app. The helper waits up to ~2 min for the
  operator to switch away, then reports `gui-unowned -- reason=codex-foreground-deferred`.
- `switch`: with `--ack-foreground-switch` (or the standing-approval env, printed on every send),
  navigate the visible Codex app straight to the target and deliver. Disclosed residue: the
  visible Codex app REMAINS on the target thread. Without acknowledgement: refused
  (`failed-closed -- reason=foreground-switch-unacknowledged`) — before any live IPC, with the
  file-drop already written.
- `restore-if-known`: FAIL-CLOSED this milestone (`gui-unowned -- reason=foreground-restore-unproven`).
  Restoring the Windows foreground handle is not restoring the in-app selected thread, and no
  read-only selected-thread authority exists yet; a syntactically valid restore UUID is not proof.

An unidentifiable foreground process is treated conservatively: it defers and is never
auto-switched. Windows may also route `codex://threads/<id>` through a Codex window the wrapper
cannot predict, so success is judged by owner acceptance, never by assumptions about which visible
window moved.

Result lines are machine-parseable:
`RESULT: gui-delivered|gui-unowned|failed-closed -- reason=<token> -- confirmation=<token>`.
On an accepted send, `confirmation` carries one bounded rollout-observation token:
`rollout-hit` (the exact dispatch pickup was observed in a rollout user message — proves
admission only, never completion or reply-file success), `rollout-pending` (an authoritative
candidate was readable/parseable but no pickup was observed within the bounded budget), or
`rollout-unavailable` (observation could not determine a result). Observation failures never
reclassify an accepted send and never trigger an automatic resend. A thread-tail inspection can
inform diagnosis, but a negative bounded/recent-tail result cannot prove non-admission or
authorize a resend.

Auto-load authority is structural. The wrapper accepts `no-client-found` only from a parsed failed
client response for the exact target with exactly one matching follower request; nested or
incidental text is ignored. It then requires the inspector to prove a successful read-only DB open
and one exact active row for that target before navigation. A matching rollout alone, a
missing/archived row, or malformed/ambiguous inspector output fails closed without firing a deep
link. Initial renderer-owned success and post-autoload retry success both require parsed `ok: true`,
the exact `targetThreadId`, `response.resultType: "success"`, and exactly one follower occurrence
whose `name`, `method`, and `conversationId` all match. Client exit 0 with missing or conflicting
structure is post-attempt ambiguous: it is not classified as delivered and is never automatically
retried. Inspection is necessary before considering a manual retry, but negative
bounded/recent-tail evidence cannot prove non-admission. Retry requires either an exact
full-history outcome proving non-admission or an explicit owner decision acknowledging the
unresolved duplicate-send risk. The inspector recheck is
defense in depth on the authoritative unowned branch only; the renderer-owned fast path relies on
the mandatory separate agent preflight and does not repeat that inspection before its initial
attempt. The preflight-to-send state-change window remains disclosed. Exact target binding prevents
heuristic retargeting, and ambiguous outcomes are never retried automatically.

Rollout readers share one fail-closed owner and lineage contract. The first physical JSONL record
must be a `session_meta` whose `payload.id` matches the requested thread; it pins the file-global
owner. Later `session_meta` records are lineage only: their `payload.id` must already be the owner
or have been predeclared through `forked_from_id` on an admitted metadata record; they may extend
that lineage through their own `forked_from_id`, but never rebind the owner. Any recognized
record-level `thread_id` carrier must resolve to one valid UUID matching the pinned owner.
Forked rollouts additionally require a valid `forked_from_id`, a safe-integer
`subagent_history_start_ordinal >= 1`, contiguous top-level ordinals beginning at zero, and
`event_msg/thread_settings_applied` at that boundary. Earlier records are parsed and hashed but
never observed, correlated, or projected as child activity. Missing, malformed, gapped, reordered,
or unreached boundaries fail closed; UUID timestamps are never provenance authority.
The inspector's `recentItems` is the raw physical display tail and may therefore include copied
ancestor records; it is not child-activity evidence. Use the owner- and history-scoped
`activitySignals` projection for that determination.
Certifying locator-to-reader handoffs bind both that expected owner and the physical file identity. A
certifying cursor must be reader-issued at complete EOF (`offset === size`, with no partial tail)
and carry canonical path/file identity, first-record and trailing-content anchors, plus a SHA-256
digest of the entire consumed prefix. Resumed reads revalidate every binding, so replacement,
truncation, an older in-place identity rewrite, or growth across the read cannot certify.
Locator basenames are strict: legacy `...-<rootUuid>.jsonl` and paginated
`...-<rootUuid>_<pageUuid>.jsonl` are the only admitted forms. A paginated first
`session_meta` must also bind `session_id` to the root, declare `history_mode: paginated`, and carry
a valid `history_base.thread_id`. The state DB's explicit rollout path is authoritative. Root-only
discovery may recognize both forms, but multiple distinct valid physical pages are ambiguous and
are never resolved by mtime. A poll remains on its selected page; cross-page N-to-N+1 rollover is
not yet certified or supported. Even with one valid file, root-only discovery returns
`candidate-set-unresolved` when its scan also finds a recognized exact-target candidate that fails
validation, any `rollout-*` basename containing the target UUID that is not understood as a
candidate for that root (including when a trailing second UUID makes the legacy parser attribute
the name to another root), or an unreadable subtree. A recognized paginated basename is exempt when
only its page ID equals the target and its root is another session. Other unresolved diagnostics
are never suppressed to select the valid file. The standalone observer, waiter, and harvester also
do not follow a target-thread ID to a differently owned physical rollout:
without a trusted alias authority that remap is `unavailable`, not inferred. This limits rollout
observation/fallback only; file-primary replies and the preserved file-drop envelope remain usable.
They accept `--rollout-path` but do not derive it from the DB; pass the exact
designated path when known, or accept that root-only discovery can be ambiguous.
After a complete certifying cursor exists, polling callers may skip an intermediate full read only
when a metadata check finds the same canonical path, physical identity, and size. Such a no-growth
observation cannot certify pickup, completion, a reply, or proof success. Any growth/change and the
final attempt or budget edge that begins before the deadline runs the unchanged full reader, so replacement and same-size tampering
still fail closed when certification is required.
The read deadline covers prefix hashing, final anchor revalidation, and path rebinding checks; expiry returns
no certifying cursor or trusted partial projection. A distinct later user event within the dispatch
turn invalidates marker ownership. Only repeated normalized user records with the
same non-empty item identity are collapsed; equal text or a direct/wrapped representation alone is
not proof of one delivery.

The controlled write-proof adds one final pre-send boundary after its fresh state snapshot: it
fully revalidates the baseline cursor and requires unchanged canonical/physical identity, complete
EOF, offset/size, and whole-prefix SHA-256. Growth, replacement, or a same-size historical rewrite
therefore stops before the client is invoked. After the one send attempt, a certifiable client
result requires a successful client process, top-level `ok: true`, the exact canonical top-level
`targetThreadId`, `response.resultType: "success"`, and exactly one follower occurrence whose
`name`, `method`, and `conversationId` match the target. The matching follower proves send
occurrence only; it does not prove router acceptance or task completion. If occurrence is confirmed
but any certification field fails, the harness preserves it, performs zero rollout polls, and
reports non-retryable `sent-but-unverified`; unparseable output leaves occurrence unknown as
`send-outcome-unknown`. Only a certified result with one unconflicted response turn ID may start
polling; missing or conflicting turn IDs likewise yield zero polls and `sent-but-unverified`.
End-to-end success additionally requires the rollout proof to bind that turn and show the agent
marker followed by completion, plus structured config/DB isolation proof. Null, malformed,
contradictory, or bare-`ok` post-send proofs cannot certify. Inspection is necessary before
considering a retry, but negative bounded/recent-tail evidence cannot prove non-admission. Retry
requires either an exact full-history outcome proving non-admission or an explicit owner decision
acknowledging the unresolved duplicate-send risk.

Autoload helper exit codes: `0` deep-link permitted/completed (or dry-run equivalent), `1` link
fired but focus restore unverified, `2` foreground-Codex (or unidentifiable foreground) deferral,
`4` restore authority unproven, `5` switch without acknowledgement. The wrapper maps every code
explicitly; unrecognized codes fail closed.

The auto-load helper (`codex_ipc_autoload.ps1`) and focus snapback are **Windows-only** and depend
on `powershell.exe` plus Win32 foreground-window APIs. On other platforms — or when the helper is
unavailable — the wrapper still polls, and on failure reports `gui-unowned` with the manual
`codex://threads/<id>` remediation plus the file-drop fallback.

### Removed in v0.1.8: headless `--exec` (and `--app` / `--open`)

The CLI-backed modes were removed in v0.1.8. The wrapper no longer invokes the `codex` binary on
any path, and there is no headless execution path. Delivery is the default file-drop handoff or
live `--ipc` GUI injection.

## Read-only inspection surfaces

- `codex_ipc_session_inspect.mjs` — one thread's state-DB row plus rollout JSONL tail, with
  heuristic activity signals (mid-turn detection). Opens SQLite `readOnly:true`.
- `codex_ipc_thread_locator.mjs` — candidate conversationIds for a workspace/project from the
  Desktop thread index. Candidates are discovery, not send authority.
- `codex_ipc_snapshot.mjs` — config/state-DB evidence (hashes, marker counts) around a controlled
  write; also a pure-JSON `--compare` mode.
- `codex_ipc_probe.mjs` / `codex_ipc_owner_probe.mjs` — transport/framing research tools; dry-run
  by default, non-mutating methods only.
- `codex_ipc_revalidate.mjs` — static/presence checks; pipe connection only with
  `--allow-live-ipc-read` (sends `initialize` only).
- `codex_ipc_contract_audit.mjs` — static requirement matrix from the bundled skill files.

All of these send no prompts and write no SQLite. The orchestrating tools
(`codex_ipc_revalidate.mjs`, `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`) resolve
their sibling scripts relative to their own directory, so they work from any cwd in both the
plugin/repo layout and a standalone install.
