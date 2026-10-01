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
matches one body; missing, empty, or nonmatching terminal evidence remains unavailable. When that
terminal copy does resolve several distinct finals to one, the resolution is disclosed rather than
erased: `finalMessageCount` reports the true number of distinct logical finals, and the certifying
path emits a `terminal-copy-disambiguated` diagnostic carrying the terminal line, the turn id and
that count. The diagnostic never carries body text, and `multiple-final-message-bodies` stays
reserved for turns that refuse.

A turn the boundary machine did not close is never certified, whatever the terminal record says.
The dispatch projection applies the same predicate the marker proof applies: a snapshot carrying a
terminal but not marked `closed` returns `unavailable`/`unparseable` with the snapshot's own
diagnostics. This matters for turns the machine opened defensively rather than from a
`task_started` record, whose integrity window is too narrow for the in-window checks to see the
gap that made them ambiguous.

### `item_completed` item classes

Current-format rollouts wrap semantic records in an `item_completed` envelope whose `item.type`
names an item class. Named classes are a closed, dated set: `AgentMessage` and `UserMessage` are
promoted to their semantic types, and the rest are admitted as lifecycle-inert. The set is pinned
to a corpus census re-derived at each release cut, so it is a statement about what the producer was
observed writing on a date, not a permanent grammar. The current census read 88,498
`item_completed` records in exactly thirteen classes over 6,145 retained rollout files, measured
2026-09-03T02:42:28Z.

A class outside that set is **inert but logged**: it is never promoted, never exposes text, phase
or role, is never retained for correlation, and does not make its turn ambiguous. The reader emits
an `unknown-item-class` diagnostic naming the class, which is a distinct code from `schema-drift`
precisely because every drift consumer treats drift as an integrity failure. `FunctionCallOutput`,
which the app writes whenever a thread uses its own thread-delegation tool, and `Plan` are named
explicitly in the inert set.

Four conditions still fail such a record closed, as `schema-drift` naming the class in `itemType`:

1. the item itself carries a body- or role-bearing field (`content`, `text`, `phase`, `role`);
2. the record's outer turn/thread identity is invalid;
3. the item names **no** class, or names one that is not a string. A missing class is not an
   unknown class: the diagnostic that makes an inert admission acceptable is the one that names
   the class, and a class-less record has no name to log, so admitting it would certify a turn
   containing a record the reader never classified and leave no trace of it;
4. the class is only a case or separator variant of a named class - `agent_message`,
   `agentmessage` or `AgentMEssage` for `AgentMessage`. The two namespaces this reader carries,
   PascalCase item classes and snake_case semantic types, differ from each other by exactly case
   and separator, so a variant spelling is a producer mis-spelling of a known class rather than a
   fourteenth class, and treating it as new would let a real final answer go inert whenever its
   body sits under a key outside the four in condition 1.

### Top-level envelope types

The same problem exists one level up. Every rollout record is a top-level envelope: `event_msg` and
`response_item` declare a `payload.type` the reader matches as a **pair**, and six further types -
`compacted`, `inter_agent_communication_metadata`, `session_meta`, `token_usage_record`,
`turn_context` and `world_state` - declare none at all and are lifecycle-inert. That set is pinned
to the same kind of dated census: 6,479,880 records in exactly eight envelope types over 6,176
retained rollout files, measured 2026-09-03T22:08:25Z.

An envelope type outside the set that declares no `payload.type` is **inert but logged**, on the
same terms as an unknown item class and for the same reason, with an `unknown-envelope-type`
diagnostic naming the type once per occurrence. Six conditions still fail such a record closed as
`schema-drift`: it names no envelope type or names one that is not a string; its payload is present
but is not a plain object; the payload declares a `type` key, which makes the record an unknown
*pair* rather than an unknown envelope, and relaxing that would silently admit every future event
class as well; the payload carries an `item`, a shape the `item_completed` adapter owns; the
payload carries `content`, `text`, `message`, `last_agent_message`, `phase` or `role` - two keys
wider than the item rule, because the reader reads both of the additions: `textFromAllowedFields`
reads `payload.message` first, and `last_agent_message` is projected onto every normalized record
before and regardless of correlation retention, so a body under either key would otherwise be
admitted unread; or the record's owner identity is invalid. With both keys guarded, "an admitted
envelope exposes no text, role, phase or final body" holds by construction rather than by a
downstream guard that could drift away from this one.

`token_usage_record` is the class that forced the rule. It carries per-turn and per-thread token
accounting and no body, and it is the only unnamed typeless envelope the census found, so naming it
and adding the forward rule changes no other retained rollout's verdict. Before it was named, every
rollout carrying one read `ambiguous` even where the turn had completed - which meant the reader
withdrew certification from the producer version then in use, for a record that says nothing about
whether the turn finished.

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
  thread is already loaded in the app. The shared host gate runs before the initial attempt and
  before every retry, so ownership alone never bypasses host identity.
- `gui-unowned` — the exact router response proved that no renderer admitted the follower. With the
  default `autoload=off`, or with an alternate intended host, the wrapper returns immediately and
  prints the file-drop pickup line. A package activation request may also return this category when
  foreground handling defers or a permitted activation does not establish ownership in time.
- `failed-closed` — the host inventory is incomplete/mixed, target is missing or archived, package
  activation evidence refuses, or the router/pipe failed. Actual bounded diagnostics are printed.

Host configuration resolves independently per field as wrapper flag > environment
(`CODEX_IPC_AUTOLOAD`, `CODEX_IPC_INTENDED_HOST`) >
`${CODEX_IPC_ROOT}/host-policy.json` > defaults. Defaults are `autoload=off` and intended host
`package`. The descriptor schema is 1; unknown keys, invalid values, malformed JSON, unreadable
content, or invalid present environment values fail closed even when a higher-priority flag exists.
An alternate host must be an absolute executable path. It can receive an IPC send only when it is
the sole proven GUI host, and it is never activated through the package protocol.

`--autoload codex-uri` only requests activation after an authoritative `no-client-found`; it does
not authorize it by itself. The helper rechecks the shared host gate before foreground handling and
again immediately before the sole protocol launch. Activation additionally requires qualified
package-update clearance and proof that the effective Shell handler resolves to the running package.
The shipped real-machine readers currently prove neither: deployment event history cannot prove a
complete negative update state, and package candidate registration is not an effective-handler
resolver. Real activation therefore refuses with helper exit 6 until qualified readers land;
hermetic DryRun mocks exercise the positive decision path without granting live authority.

When activation is eventually eligible, a non-Codex foreground path saves the foreground window,
fires the package link, and verifies focus snapback. A `switch` path leaves the visible app on the
target thread. The file-drop **envelope** is preserved in every outcome; the
**pickup line** is printed only when structured evidence proves no follower was admitted.
`confirmation=not-attempted` names that state, although an exact `no-client-found` router request
may have occurred. After an ambiguous post-attempt result (`confirmation=unknown`) pickup is
suppressed and resending is forbidden.

#### Foreground policy (`--foreground-policy`, EXPERIMENTAL)

When a package activation request reaches foreground handling, the wrapper applies one of three
policies (flag overrides the `CODEX_IPC_FOREGROUND_POLICY` env default of `defer`):

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

Target authority is structural and precedes every live route. After publishing the fallback
envelope, the wrapper runs one read-only inspector snapshot before its first pipe contact and reuses
that snapshot across guarded auto-load recovery. The snapshot must prove a successful read-only DB
open, one exact active row, a `root` or warned `legacy-root-assumed` classification, and a
nonempty stored model. Explicit sub-agent or guardian-review evidence is `non-root`; legacy null
source is assumed root only when every available child indicator is absent. Conflicting, invalid,
or unreadable indicators are ambiguous. Missing, archived, non-root, empty-model, malformed, or
ambiguous targets fail with `confirmation=not-attempted` before the fresh host gate or any pipe
contact. Known parent identity is reported, while locator hints remain discovery-only.

Activation authority is likewise structural. The wrapper accepts `no-client-found` only from a
parsed failed client response for the exact target with exactly one matching follower request;
nested or incidental text is ignored. The existing pre-send snapshot remains target authority; a
matching rollout alone is insufficient. Initial renderer-owned success and post-autoload retry
success both require parsed `ok: true`,
the exact `targetThreadId`, `response.resultType: "success"`, and exactly one follower occurrence
whose `name`, `method`, and `conversationId` all match. Client exit 0 with missing or conflicting
structure is post-attempt ambiguous: it is not classified as delivered and is never automatically
retried. Inspection is necessary before considering a manual retry, but negative
bounded/recent-tail evidence cannot prove non-admission. Retry requires either an exact
full-history outcome proving non-admission or an explicit owner decision acknowledging the
unresolved duplicate-send risk. The one target snapshot gates both renderer-owned and unowned
paths. It is intentionally not repeated during recovery; the shared host inventory is repeated
immediately before every send or retry. Exact target binding prevents heuristic retargeting, and
ambiguous outcomes are never retried automatically.

Rollout readers share one fail-closed owner and lineage contract. The first physical JSONL record
must be a `session_meta` whose `payload.id` matches the requested thread; it pins the file-global
owner. Later `session_meta` records are lineage only: their `payload.id` must already be the owner
or have been predeclared through `forked_from_id` on an admitted metadata record; they may extend
that lineage through their own `forked_from_id`, but never rebind the owner. Any recognized
record-level `thread_id` carrier must resolve to one valid UUID matching the pinned owner.
Forked rollouts are read under the producer-ordinal contract **only where the producer declares
it**. When the first record carries `forked_from_id` together with a
`subagent_history_start_ordinal`, that contract applies in full: a valid `forked_from_id`, a
safe-integer `subagent_history_start_ordinal >= 1`, contiguous top-level ordinals beginning at
zero, and `event_msg/thread_settings_applied` at that boundary. Earlier records are parsed and
hashed but never observed, correlated, or projected as child activity. Malformed, gapped,
reordered, or unreached boundaries fail closed, as does a first record that declares a top-level
`ordinal` while omitting the boundary field - that is drift inside the contract's own grammar.
UUID timestamps are never provenance authority.

A fork whose first record carries neither the boundary field nor a top-level `ordinal` declares no
ordinal stream at all. It has no inherited-history prefix to skip and nothing for the contract to
check, so it is admitted and read exactly as an unforked rollout, with the same state the unforked
path produces. This is not a legacy-only shape: both the Codex CLI in use on 2026-09-01 and its
successor version have been observed writing it, and it is the majority shape **among forks** -
1,200 of the 1,390 retained rollout files whose first record is a fork, out of 6,145 retained
rollout files in all, measured 2026-09-03T02:42:28Z. Treating it as a contract violation made
every such thread unreadable end to end - the observer reported `rollout-unavailable`, the waiter
returned `unavailable` before it could reach an existing reply file, harvest returned
`unavailable`, and the write-proof preflight returned a non-overridable `ambiguous`.
Because such a fork declares no ordinal stream, the whole file is in scope for the reader,
including any ancestor records the producer physically copied into it - the prefix the
declared-ordinal path skips. That is the behaviour this reader had before the ordinal contract
existed, not a new hazard, but it is the same caution the inspector's `recentItems` carries below
and it applies here for the same reason.
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
are never resolved by mtime. A poll remains on its selected page and never auto-hops or stitches
records. A SQLite-free veto recursively scans the configured sessions root for one direct
paginated successor with a complete first record, `history_base.thread_id` equal to the bound page
ID, and a safe record-boundary `end_byte_offset` no larger than the bound page. A marker at or
beyond that cutoff is `dispatch-history-abandoned`; an earlier marker is
`rollout-page-superseded`; malformed, incomplete, or multiple claims are
`page-supersession-unproven`. Each state vetoes positive pickup, completion, and rollout-fallback
results while keeping the reader on the original page. Even with one valid file, root-only discovery returns
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
designated path when known, or accept that root-only discovery can be ambiguous. The maintained
wrapper propagates its single trusted inspector page to both observation and the printed waiter.
The read-only reply viewer accepts an explicit page for a UUID-scoped `-c` view or can derive it
once with `--derive-rollout-path`; session-wide and filedrop views cannot select a page. Missing
authority prints fixed `ROLLOUT-PATH:` guidance, page vetoes print fixed `ROLLOUT-PAGE:` guidance,
and a primary reply stays visible with a stale-body caution while fallback remains unavailable.
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

Activation-helper exit codes: `0` protocol launch permitted/completed (or dry-run equivalent), `1`
launch fired but focus restore unverified, `2` foreground-Codex (or unidentifiable foreground)
deferral, `4` restore authority unproven, `5` switch without acknowledgement, `6` fresh
host/activation policy refusal. The wrapper maps exit 6 to
`failed-closed -- reason=autoload-policy-refused -- confirmation=not-attempted`; unrecognized codes
fail closed.

The activation helper (`codex_ipc_autoload.ps1`) and focus handling are **Windows-only** and depend
on `powershell.exe` plus Win32 foreground-window APIs. If the helper or PowerShell is unavailable,
the wrapper does not poll or suggest a manual protocol launch; it returns
`gui-unowned -- reason=autoload-helper-unavailable -- confirmation=not-attempted` with the safe
file-drop pickup line.

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
- `codex_ipc_probe.mjs` — transport/framing research tool; dry-run by default, non-mutating
  methods only.
- `codex_ipc_owner_probe.mjs` — **retired and inert.** It sent a version-1 follower start-turn at a
  synthetic sentinel thread and read `no-client-found` as proof that the follower route is
  reachable from an external client. The router matches the per-method version exactly during
  discovery, before ownership is evaluated, so that frame was refused on the way in — and the same
  token stands for at least nine distinct causes. The file remains only to satisfy the
  required-file contracts and to explain itself.
- `codex_ipc_revalidate.mjs` — static/presence checks plus the shared runtime host policy. A host
  refusal suppresses the optional `--allow-live-ipc-read`; a permitted probe sends `initialize`
  only. Revalidation does not waive or certify the separate activation gates.
- `codex_ipc_contract_audit.mjs` — static requirement matrix from the bundled skill files.

All of these send no prompts and write no SQLite. The orchestrating tools
(`codex_ipc_revalidate.mjs`, `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`) resolve
their sibling scripts relative to their own directory, so they work from any cwd in both the
plugin/repo layout and a standalone install.
