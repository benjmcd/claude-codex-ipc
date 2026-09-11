---
name: ipc
description: |
  MANUAL TRIGGER ONLY: invoke when the user types /ipc. Inspect, watch, or manage Codex Desktop
  sessions and send opt-in handoffs after reading the target session history/current state.
disable-model-invocation: true
---

# /ipc — Claude Code to Codex coordination

Use this skill only for an explicit `/ipc` command or when the user directly asks to operate the
Claude-to-Codex IPC bridge.

The stable core is the **file-backed handoff**: a per-dispatch task file plus a correlated reply
file. The **live Codex Desktop IPC delivery route is optional and experimental** — it depends on
private Codex Desktop internals (a named pipe, `codex://` deep links, window-focus automation) that
can change without notice in any Codex Desktop update. Treat every live-IPC feature as
"revalidate after updates", and keep file-drop as default/fallback. ("Codex Desktop" is this
skill's stable label for the app hosting these surfaces; since 2026-07-09 that app is the ChatGPT
desktop app in Codex mode — GUI `ChatGPT.exe` under the unchanged `OpenAI.Codex` package family.
The technical names `codex://`, `codex-ipc`, `~/.codex`, and the `codex` CLI are unchanged.)

## Toolkit root

This skill bundles its own IPC tooling, so it does not depend on any project workspace. Resolve the
IPC toolkit root in this order:

1. `${CLAUDE_SKILL_DIR}` — the directory containing this SKILL.md, provided by Claude Code when the
   skill runs. The bundled toolkit is `${CLAUDE_SKILL_DIR}/scripts/` (containing
   `codex_ipc_client.mjs`). This is the default; prefer it.
2. Else, the `scripts/` directory next to this SKILL.md.
3. Else, as a manual override only: if `IPC_TOOLKIT_ROOT` is set and contains
   `scripts/codex_ipc_client.mjs`, use it.

The `.mjs` tools and `handoff_to_codex.sh` locate their sibling scripts by their own script
directory, so they work from any current working directory. If the bundled toolkit is somehow
missing, do not reach into an unrelated project — repair the skill bundle (re-copy `scripts/`) or
fall back to a manually pasted file-drop handoff.

## Before first use

Task envelopes and replies are plaintext and can be read and modified by same-user processes; task text must not contain secrets.
Keep-only retention may retain them indefinitely.
Pruning reduces ordinary accumulation but is not confidentiality or secure deletion.
Backups, sync tools, snapshots, and filesystem recovery may retain deleted content.

`handoff_to_codex.sh` writes its transport ENVELOPE — a per-dispatch `<dispatchId>.task.md`, plus
the `<dispatchId>.reply.md` Codex writes back — to a machine-local, repo-independent root keyed per
`(claudeSessionId, conversationId, dispatchId)`:
`${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSid>/<conversationId|filedrop>/<dispatchId>.task.md`.
This keeps any number of concurrent Claude sessions and Codex threads isolated by construction and
works from any CWD — no git repository is required. See
[references/architecture.md](references/architecture.md) for the full transport model, retention
behavior, and the reply viewer.

## First decision

Classify the invocation before doing anything else:

1. Existing Codex session: `/ipc <conversationId> [instruction]`
2. Watch/status: `/ipc watch <conversationId>` or `/ipc status <conversationId>`
3. New Codex session: `/ipc [new] [workspace/project] [instruction]` with no UUID

If a UUID is present, treat it as the explicit target. Do not infer a different target from title,
cwd, recency, or project name.

## Workspace-scoped handoff artifacts

The IPC tooling does not invoke the Codex CLI. As of v0.1.8 the `--app`, `--open` and `--exec`
modes are removed: they fail with a stable error before any transport access or child launch.
Delivery is the file-drop default (paste one line into your Codex session) or live `--ipc`
injection into a Desktop GUI thread — neither shells out to a `codex` binary.

The IPC transport envelope (the `.task.md`/`.reply.md` pair) is deliberately machine-local under
`${CODEX_IPC_ROOT:-~/.claude/ipc}` — that is the ONE exception to the rule below. Envelopes and
replies are KEPT by default: `CODEX_IPC_RETENTION_DAYS` defaults to keep-only (unset, empty and
`0` all mean never delete), and pruning runs only if you set an explicit positive integer —
opportunistically, on the next dispatch. Nothing is deleted behind your back; the trade-off is
that the root grows until you prune or rotate it.
To skim replies consolidated newest-first, use `scripts/codex_ipc_replies.sh` — a read-only,
point-in-time DERIVED view (never the authoritative channel; it writes, locks, and creates
nothing). Run it with `-h` for the full flag list; a malformed `--since` fails closed.

Any artifact created so it can be referenced by or provided to another agent or session —
handoffs, pickup notes, prompt files, context bundles, transcript excerpts, reference files — must
live inside the repo, project folder, workspace, or worktree it is associated with, never in
global or ad-hoc paths (Desktop, Downloads, temp dirs, or the IPC toolkit root). When composing the handoff
content itself, use the field schema in
[references/handoff-template.md](references/handoff-template.md) — objective, scope fence,
non-goals, boundaries/safety, canonical sources of truth, isolation, done-criteria, verification,
constraints, and context — so the handoff is self-contained and needs no follow-up steering.

## Existing-session mode

Before using existing-session `/ipc`, the /ipc agent must run the read-only inspector as its separate preflight step. Selecting `--ipc <uuid>` is itself the live-delivery acknowledgement; the wrapper supplies the client's `--send --ack-live-write --allow-any-thread` internally. Inspect-before-send is the /ipc agent's own preflight step, not a wrapper gate.

Run the read-only inspector (requires a Node.js version with `node:sqlite`; see
[references/troubleshooting.md](references/troubleshooting.md)):

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_session_inspect.mjs" --thread <conversationId> --tail-events 20 --summary
```

If Codex Desktop or Codex CLI may have updated since the last proven IPC run, run the validate-only
post-update wrapper before sending:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_revalidate.mjs" --thread <conversationId>
```

Use `--allow-live-ipc-read --timeout-ms 1500` only when you need to re-prove router framing on the
current Desktop runtime; it sends `initialize` only and must not be confused with a prompt-send
proof.

If read-only revalidation detects drift after a Codex Desktop update, do not improvise a live
probe. Use the controlled write-proof harness, dry-run first:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_write_proof.mjs" --thread <conversationId> --marker <unique-marker>
```

Run the live path only with explicit operator approval:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_write_proof.mjs" --thread <conversationId> --marker <unique-marker> --send --ack-live-write --allow-any-thread
```

Use the inspector output to identify: the target title, cwd/project, model, reasoning effort,
archived flag, and rollout path; the thread's stored `approvalMode`/`sandboxPolicy` (carried
alongside `permissionProfileAdvisory`) — advisory context only: they are the stored thread row,
may differ from the effective turn, and MUST NOT gate the dispatch or be read as a
reply-writability prediction. A blocked reply write is expected, not an error. For a known-UUID
`--ipc` dispatch, `codex_ipc_wait --accept-rollout-fallback` certifies named-dispatch completion
and `replySource=rollout-fallback` but intentionally emits no body; retrieve and render the body
with the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer. Display is capped at
4096 bytes by default; if truncation is reported, rerun with a sufficient `--max-bytes`. This is
never a policy gate. Identify the latest
user/agent/task-complete signals; and `activitySignals.turnActivity` — the authoritative
open/closed/ambiguous read of the latest turn boundary from the shared turn-boundary machine over
the FULL rollout stream (`open` = a start/user turn with no matching terminal; `closed` = the
latest turn reached its terminal; `ambiguous` = boundary/rollout ambiguity — fail closed). Prefer
`turnActivity` over the historical `maybeMidTurn` tail heuristic; `terminalState` and a per-dispatch
wait `done` both describe past turns and never prove current idleness. Immediately before a live
send, the write-proof harness recomputes `turnActivity` from an owner-bound,
integrity-validated, complete-EOF baseline; that gate requires `turnActivity==="closed"`.
`rollout.primary.recentItems` is a raw physical display tail and, for a fork, may include copied
ancestor records. Treat it as provenance/display only, never as child-local activity; use the
owner- and history-scoped `activitySignals` projection for that determination.
After the fresh state snapshot and before invoking the client, it fully revalidates the same
cursor: canonical path, physical identity, complete EOF, offset/size, and whole-prefix SHA-256 must
still match. Growth, replacement, or a same-size historical rewrite therefore blocks with zero
sends. `--allow-mid-turn` overrides `open` only, never `ambiguous`.
After the one send attempt, a certifiable client result requires a successful client process,
top-level `ok: true`, the exact canonical top-level `targetThreadId`,
`response.resultType: "success"`, and exactly one follower occurrence whose `name`, `method`, and
`conversationId` match the target. The matching follower proves send occurrence only; it does not
prove router acceptance or task completion. If occurrence is confirmed but any certification
field fails, the harness preserves it, performs zero rollout polls, and reports non-retryable
`sent-but-unverified`; unparseable output leaves occurrence unknown as `send-outcome-unknown`.
Only a certified result with one unconflicted response turn ID may start polling; missing or
conflicting turn IDs likewise yield zero polls and `sent-but-unverified`. End-to-end success
additionally requires the rollout proof to bind that turn and show the agent marker followed by
completion, plus structured config/DB isolation proof. Null, malformed, contradictory, or bare-`ok`
post-send proofs cannot certify. Inspection is necessary before considering any retry, but a
negative bounded/recent-tail inspection cannot prove non-admission and is never sufficient retry
authority. Retry only after an exact full-history outcome proves non-admission, or after an
explicit owner decision that acknowledges the unresolved duplicate-send risk.
Also note whether the instruction is a handoff, oversight request, status check, continuation, review,
wait/watch request, or management request. If the inspector
is ambiguous, read the referenced rollout JSONL directly with targeted grep/tail before asking the
user. That bounded inspection is diagnostic only; it cannot authorize a retry after an attempted
send. Ask one concise question only when sending would risk interrupting or misdirecting the wrong
thread.

`--summary` is the preflight projection: the same computed object under the same parsing
parameters, restricted to the fields named above plus a bounded 3-item rollout tail and a
bounded candidate list (`selection.candidateCount` always states the true total). Read it
whole — never pipe the preflight through `head`/`tail`. Re-run the identical command without
`--summary` for the full object; that is the first escalation step, before reading the
rollout JSONL directly.

### Send rule

Send only after inspection and only when the invocation contains, or clearly implies, a task for
Codex. Use the maintained wrapper, not raw IPC:

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversationId> "<task>"
```

On Windows PowerShell, run the `.sh` wrapper through Git Bash.

`--allow-any-thread` is a **client** flag (`codex_ipc_client.mjs`) that the wrapper sets
**internally** on the explicit-thread path; it is NOT a `handoff_to_codex.sh` argument. Do not pass
it — or any flag — to the wrapper after the conversationId; the wrapper reads the next argument as
the task. (The wrapper gracefully absorbs a mistakenly-forwarded `--allow-any-thread` and fails
closed on any other stray flag.) It is accepted on the client because production `--ipc` requires
a caller-supplied UUID, the router is conversation-scoped, and the script writes a file-drop
fallback first. Keep the invariant: one explicit conversationId per send.

The wrapper treats `no-client-found` as authority to consider auto-load only when the parsed client
result is structurally exact: failed result for this target, the exact router error, and exactly
one matching follower request. Nested or incidental text never qualifies. Before any deep link,
the inspector must likewise report a successful read-only DB open and one thread row with the exact
target ID and numeric active archive state (`0`); a matching rollout without that trusted row is not
target authority. Missing, archived, malformed, or ambiguous state fails closed without navigation.
Neither the initial renderer-owned path nor a post-autoload retry treats client exit 0 alone as
delivery. Both require parsed `ok: true`, the exact `targetThreadId`,
`response.resultType: "success"`, and exactly one follower occurrence whose `name`, `method`, and
`conversationId` all match. Missing or conflicting structure after exit 0 is post-attempt
ambiguous: it is not classified as delivered and is never automatically retried. Inspection is
necessary before considering a manual retry, but negative bounded/recent-tail evidence cannot
prove non-admission. Retry only after an exact full-history outcome proves non-admission, or after
an explicit owner decision that acknowledges the unresolved duplicate-send risk.
This recheck is defense-in-depth on the authoritative unowned branch only. The renderer-owned fast
path deliberately does not repeat the inspector before its initial attempt; the separate agent
preflight above remains mandatory. That preserves the fast path but leaves a disclosed
preflight-to-send state-change window. Exact target binding prevents heuristic retargeting, while
any ambiguous post-attempt outcome still requires inspection and forbids automatic retry.

Every `--ipc` send reports exactly one machine-parseable result:
`RESULT: gui-delivered|gui-unowned|failed-closed -- reason=<token> -- confirmation=<token>`.
After router acceptance, confirmation is:

- `rollout-hit`: the exact dispatch task basename was observed in a rollout user message. This
  confirms admission only, not completion or reply-file success.
- `rollout-pending`: at least one authoritative candidate was readable and parseable, but no
  pickup was observed within the bounded budget.
- `rollout-unavailable`: no authoritative candidate was usable, or ambiguity/schema drift
  prevented a determination.

All three preserve `gui-delivered` and exit 0 after an accepted send. Observer failure maps to
`rollout-unavailable`; pending/unavailable never cause an automatic resend.
See [references/architecture.md](references/architecture.md) for the full taxonomy, the auto-load
/focus-snapback behavior (experimental, Windows-only), and their disclosed residues. The file-drop
**envelope** is preserved in every outcome; the **pickup line** is printed only when the failure is
structurally proven not to have admitted a follower. `confirmation=not-attempted` names that
non-admission state; an exact `no-client-found` router request may still have occurred. After an
ambiguous post-attempt result (`confirmation=unknown`) pickup is suppressed and resending is
forbidden — the turn may already have been admitted.

When the target is unowned and Codex itself is the operator's foreground window, a **foreground
policy** applies (default `defer` — never navigate the visible app). Canonical grammar:

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversationId> --foreground-policy switch --ack-foreground-switch -- "<task>"
```

`switch` requires the explicit acknowledgement (it visibly navigates the Codex app and leaves it
on the target thread); `restore-if-known` is fail-closed until in-app thread restoration can be
proven by a read-only authority. The active policy and acknowledgement source are printed on every
send. Valid UUID/task invocations always write the file-drop envelope before any policy refusal.

Do not send while the target appears mid-turn unless the user explicitly asked to interrupt,
continue, or manage that active state. Router acceptance alone does not prove pickup. Use the
post-acceptance confirmation token as bounded admission evidence; `rollout-pending` means only
that no pickup was observed within budget and must not cause an automatic resend. Never use
`turn/interrupt`, config/account/plugin methods, or direct SQLite writes as part of `/ipc`.

### Watch/status mode

For `/ipc <conversationId>` with no task, report status only. For `watch`, repeat read-only
inspection at a conservative interval and stop when the user-specified condition is met, when a
terminal lifecycle event appears (`task_complete` or `turn_aborted`), or when the watch loop's
own timeout elapses (a bail-out stop condition, not evidence of completion). Do not send during
watch mode unless the user separately requests a send.

When waiting for delegated work, a reply file's existence alone is NOT completion: Codex can
write the reply mid-turn and keep working (e.g. final re-verification). Scope the check to the
dispatch's OWN turn — the turn whose `user_message` carries this dispatch's task marker
(correlate by `turn_id` when present), not merely the thread's latest event. Classify the
delegation done only when the reply artifact exists AND that same turn reached `task_complete`
without being superseded (no newer `task_started` opened before its terminal). A superseded
turn is provisional/unavailable for this dispatch — never borrow a later, unrelated turn's
terminal to certify it. `turn_aborted` on the dispatch's own turn is terminal-failed regardless
of whether a reply was written (stop waiting; surface any reply as unverified, not a hang).
A distinct later `user_message` in that turn also invalidates the dispatch binding. Only repeated
normalized user records with the same non-empty item identity are collapsed; equal text or a
direct/wrapped representation alone is not proof of one delivery.
Final bodies are deduplicated by exact text within that bound turn. If multiple distinct explicit
`final_answer` bodies remain, only a nonempty `task_complete.last_agent_message` that exactly
matches one body selects it; missing, empty, or nonmatching terminal evidence is unavailable.
Read-only inspection only; parse event types, never substring-grep (which also matches inside
tool output). One delegation produces one reply: app-driven turns after the reply (e.g. goal
checks) are supersession territory, discovered by re-inspection, not by watching forever.
The prose above remains the completion-contract definition; mechanically check it with
`scripts/codex_ipc_wait.mjs`, which emits `done`, `aborted`, `superseded`, `reply-missing`,
`pending`, or `unavailable` (single-shot by default; `--budget-ms` bounds an optional poll).
The correlator keeps three questions separate. Historical lifecycle completion records that an
exact dispatch occurrence completed and remains valid evidence for that occurrence.
`latestOccurrence` describes the newest exact dispatch-marker occurrence, which may instead be
noncomplete or uncertifiable. Global `freshness` is settled only when that newest occurrence is
certifiably complete and no later malformed or unknown-schema record makes the post-boundary
suffix opaque. A readable primary reply remains selected for viewing when historical completion is
proven, but it may be stale: opaque post-occurrence schema keeps the waiter `unavailable`. Two
distinct bound-turn exact marker occurrences are dispatch-ID reuse; because one reply path cannot identify
which occurrence wrote it, the waiter returns `unavailable` even if one or both occurrences are
complete. The viewer may still show a primary reply, but it marks supersession `unavailable`, emits
a stale-body caution, and never supplies a rollout-fallback body or a positive/negative
supersession conclusion for that reused ID. Same-item mirror records that collapse to one logical
occurrence are not reuse. A distinct later user item in the same turn invalidates binding as
`intervening-user-message`; identical text alone does not create a separately bound reuse
occurrence. Absent reuse, rollout fallback and a negative claim that
`REPLY-SUPERSEDED` was not seen require settled freshness; they never borrow the older completion.
Conversely, an exact positive `REPLY-SUPERSEDED` completion remains positive when later
non-occurrence freshness is unknown, with uncertainty disclosed.
Rollout identity precondition: an explicit `--rollout-path`, including the exact path designated
by the state DB, must use the legacy `...-<threadId>.jsonl` basename or the paginated
`...-<threadId>_<pageUuid>.jsonl` basename. Its first record must be a matching
`session_meta`. The paginated form additionally requires `payload.session_id` to match the root
thread, `payload.history_mode` to equal `paginated`, and a valid
`payload.history_base.thread_id`. Without an explicit authoritative path, discovery recognizes
both forms, but returns ambiguous when more than one distinct physical page is valid; it never
chooses a page by mtime. Even with one valid file, root-only discovery returns
`candidate-set-unresolved` when the same scan finds a recognized exact-target candidate that fails
validation, any `rollout-*` basename containing the target UUID that is not understood as a
candidate for that root (including when a trailing second UUID makes the legacy parser attribute
the name to another root), or an unreadable subtree. The token-collision exception is a recognized
paginated basename whose page ID merely equals the target while its root is another session. The
scan never discards unresolved diagnostics to select the valid file. Polling remains bound to the
selected physical file, so automatic page rollover from N to N+1 is not certified or supported.
A renamed or copied mismatch yields `unavailable` rather than reading the wrong thread. A
target-thread ID that Desktop internally remaps to a differently owned physical rollout is likewise
`unavailable`: no trusted alias authority exists, so rollout observation/fallback never follows the
remap heuristically. File-primary replies and the preserved file-drop envelope are unaffected. The
standalone observer, waiter, and harvester accept but do not derive the DB-designated path; pass
their exact `--rollout-path` when it is known, or accept root-only discovery ambiguity. Cursor
polling revalidates the canonical path, physical identity, complete first-record anchor, and a
SHA-256 digest of every byte in the consumed prefix; every certifying locator-to-reader handoff
also carries the expected owner and physical identity, so an in-place historical rewrite or path
swap fails closed. Intermediate polls may use a metadata-only no-growth check when a complete
cursor's canonical path, physical identity, and size are unchanged, but that check can only
continue pending. Growth and change run the full certifying reader; so do
final or budget-edge attempts that begin before the deadline. If the deadline elapses during
sleep, the operation returns unverified/pending without a post-deadline read.
The read deadline covers prefix hashing, final anchor revalidation, and path rebinding checks;
expiry returns no certifying cursor or trusted partial projection. A forked/subagent rollout must
declare a valid `forked_from_id`, a safe-integer `subagent_history_start_ordinal >= 1`, and contiguous
top-level ordinals beginning at zero. Records before that producer boundary are parsed and hashed
but never observed, correlated, or projected as child activity; the boundary record must be
`event_msg/thread_settings_applied`. Missing, invalid, gapped, reordered, or not-yet-reached fork
boundaries are unavailable, and UUID timestamps are never ownership authority. At and after a
valid boundary, later inherited `session_meta` records remain provenance only: admitted lineage IDs
never rebind the pinned owner, and record-level `thread_id` fields must still name the child.
A bounded example (30-minute budget, opt-in rollout fallback):
`node scripts/codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> --reply-path <path>
--accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000`. A `done` token is
**named-dispatch completion, never current thread idleness** — `terminalState` and a per-dispatch
`done` both describe past turns.
Only a genuinely absent reply is eligible for waiter rollout fallback.
A present-but-invalid reply returns `reply-missing` without consulting rollout fallback.
An absent reply with no certifiable rollout body exhausts the eligible sources.
Inspect its
diagnostics/thread; do not re-harvest, auto-resend, or hand-roll rollout/report-file polling. On
`reply-missing`/`aborted`:
resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
Flagless (no `--accept-rollout-fallback`) is the legacy file-primary contract.
Exit-code-driven callers may add the opt-in `--status-exit-codes`, which maps the determination to
`done=0`, `pending=2`, `aborted=3`, `superseded=4`, `reply-missing=5`, `unavailable=6` (usage errors
stay exit 1 with no token); the token remains the sole stdout line. Without the flag every
determination exits 0.
Compose handoffs with the completion contract in
[references/handoff-template.md](references/handoff-template.md): finish and inspect the complete
result, self-verify it BEFORE a separate single reply-write attempt (never combine result
production and reply writing in one command); the reply is the last act of the turn; the
dispatcher still checks the returned body against the task's done-criteria before accepting it.

Producer denied-reply protocol (a denied reply write is EXPECTED, not an error): the generated
payload instructs the follower to finish and inspect the complete result, self-verify it, then
attempt the printed reply path exactly once as a separate final action. Only an error returned by
that write supports a denial claim; a calculation, command-construction, or parse failure is
reported as its actual failure, and empty output is never evidence of a denial. On
a sandbox/permission denial the follower must NOT retry, debug, request escalation, or substitute
another file — it states the denial in one line AND puts the full substantive result (not just the
denial) in its final agent message, then completes. A one-line denial with no result is a contract
violation. On the dispatcher side, the opt-in `codex_ipc_wait.mjs --accept-rollout-fallback` path
on a known-UUID `--ipc` dispatch certifies named-dispatch `done` with
`replySource=rollout-fallback` but intentionally emits no body. Retrieve and render the full final
message with the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer; flagless
invocation stays file-primary and filedrop is not auto-recoverable. The wrapper dispatch never
changes the target thread's model, reasoning, sandbox, or approval: it omits every version-2
override field. A direct client `--model`/`--effort` override is a thread-settings change, not a
per-turn override (see the new-session-mode note below and `docs/COMPATIBILITY.md`); `/ipc` never
passes them.

## New-session mode

No UUID means there is not yet a proven IPC target. Resolve the intended workspace first.

Prefer an explicit path or project name in the command. If absent, infer from the current repo and
current conversation context. If it is genuinely ambiguous, ask one concise question before
creating/opening the wrong context.

To open a project in Codex Desktop, open the Codex Desktop app yourself and select (or create) the
intended workspace/thread. v0.1.8 removed the CLI-backed `--app`/`--open`/`--exec` modes, so the
wrapper no longer opens the app for you.

After the Desktop project/session exists, obtain a concrete conversationId before using `--ipc`.
Use the read-only locator to discover candidates from Codex Desktop's local thread index:

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_thread_locator.mjs" --project <project-folder-name> --limit 10
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_thread_locator.mjs" --cwd <absolute-workspace-path> --since-iso <timestamp-before-open>
```

If the user created a clearly titled waiting thread, narrow with `--title-contains <text>` and
`--require-single`. A locator result is only candidate discovery, not send authority. If exactly
one intended candidate remains, run `codex_ipc_session_inspect.mjs` on that conversationId and then
apply the existing-session send rule. If no candidate or multiple plausible candidates remain, fall
back to the file-drop handoff and ask the user to select/create the Desktop thread and paste the
pickup line or provide the session id.

The target thread's own settings — model, reasoning effort, sandbox policy, and approval mode —
are NEVER changed by `/ipc`: a delegated turn runs under whatever the thread is already set to.
**This is enforced by omission, not by the protocol.** The 2026-07-10 observation that the router
ignores a `turnStartParams.model` override described a payload the app no longer reads; under the
version-2 `params.turnStart` payload the app does read `request.model` and `request.effort`, and
writes them back as the thread's stored model and reasoning effort. The wrapper and the write-proof
harness pass neither, and the client omits both unless an operator explicitly supplies
`--model`/`--effort` — which is a thread-settings change, not a per-turn override. Do not attempt
to override these through the delivery route, the client flags, or any other mechanism — never
mutate. Consistent with the advisory rule above, do NOT treat a stored `sandboxPolicy` or
`approvalMode` as a prediction that the reply write will fail: a stored `managed` sandbox is not a
reason to pick a different thread. A blocked reply write is expected, not an error, and is
certified as named-dispatch completion with `replySource=rollout-fallback` by
`codex_ipc_wait --accept-rollout-fallback`; the waiter intentionally emits no body, so retrieve and
render it with the read-only dual-source `scripts/codex_ipc_replies.sh` viewer. Reserve "choose
another thread or ask the operator" for cases the inspector proves — missing, archived, or
identity-mismatched targets — not for stored policy rows. Model/reasoning tier guidance in a task belongs to the thread's
SUBAGENT deployment instructions, not to the thread itself.

## Cross-session context

Every `handoff_to_codex.sh` handoff includes Claude's session id for reply correlation. The Claude
transcript path is included only when the operator opts in with
`CODEX_IPC_INCLUDE_TRANSCRIPT=1`; by default it is omitted, because transcript pointers expose full
session context that may include unrelated material. For `--ipc`, Claude already knows the Codex
conversationId, which is the rollout id and can be used to find the full Codex JSONL transcript
under `~/.codex/sessions/`. Use transcript pointers for orientation and verification, not for broad
disclosure outside the local machine.

## Payload git context

Since v0.1.11 every `handoff_to_codex.sh` payload's three git-context sections — `## Commits on
this branch`, `## Files changed vs <main>`, `## Uncommitted changes` — are **bounded by default**.
`CODEX_IPC_GIT_CONTEXT` is the switch, and it is the **rollback** for that default:

- `bounded` (the default) caps each section (recent commits 4096 B, diffstat 4096 B, uncommitted
  8192 B), cuts at a whole-line boundary, and appends an in-section notice naming bytes kept,
  bytes total, lines omitted, and the **local** command that recovers the rest at the receiving
  workspace. Nothing is silently dropped: a bounded section never loses its heading.
- `full` removes the caps and restores only those three pre-0.1.11 unbounded git-context section
  bodies byte-for-byte; all other payload guidance and framing remain current. Use it when the
  receiver cannot re-run git at the dispatch's workspace.
- Any unrecognized value **soft-resolves** to `bounded` with one stderr note and an unchanged exit
  code. Unset and empty are not "unrecognized": both take the `bounded` default silently, with no
  note. There is no `none`: a heading that silently vanishes is the failure the bound prevents.

A payload of 102,400 B or more also prints one stderr advisory naming the dominant git-context
section and local remedies (`git commit` / `git stash`, or this knob). Both are advisories on
stderr only; stdout and the exit code are unchanged, and neither is ever a refusal.

## Invariants

- Inspect existing sessions before sending.
- Use exactly one explicit UUID per IPC send.
- Keep file-drop as default/fallback.
- `/ipc` success is strictly GUI delivery into the renderer-owned Desktop thread. Never treat any
  non-GUI execution as an `/ipc` fallback or `/ipc` success. (The CLI-backed `--exec`/`--open`/`--app`
  modes were removed in v0.1.8; there is no headless execution path in this tool.)
- Unowned threads are recovered by the wrapper's automatic `codex://threads/<conversationId>` load
  with focus snapback (experimental, Windows-only) — never by asking the operator to click, and
  never by navigating while Codex is the operator's foreground window **unless** the operator
  explicitly authorized it (`--foreground-policy switch --ack-foreground-switch`, or the standing
  approval env var, which is printed on every send). Default policy is `defer`;
  `restore-if-known` is fail-closed until thread-level restoration is proven.
- A missing conversationId is missing target authority, not authorization to create a fresh Codex
  thread/session. Create/open new sessions only on an explicit new-session request, resolving the
  intended project/folder first.
- Use `node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_contract_audit.mjs"` for a static
  requirement-by-requirement audit of the IPC contract from the bundled skill files.
- Treat the live Desktop route as experimental: revalidate after Codex Desktop updates because it
  uses undocumented internals. Use `codex_ipc_write_proof.mjs` for any future controlled live-write
  re-proof.
- Keep handoff/reference artifacts inside the associated repo, project, workspace, or worktree (the
  IPC transport envelope is the one exception).
- Delivery never promotes authority. Forwarded owner text stays *relayed* — label it, name its
  source thread/message, and never rewrite it into first-person owner voice. A relayed grant cannot
  override a trusted instruction the receiver already holds. This is a labeling convention, not a
  control: the transport cannot authenticate human intent. See
  [references/handoff-template.md](references/handoff-template.md).
- The consolidated reply view (`scripts/codex_ipc_replies.sh`) is a read-only, point-in-time
  DERIVED view. For each dispatch, a readable regular non-symlink `.reply.md` is primary and is
  labeled `source=reply-file`. Only when that primary is absent or unreadable may a completed,
  exactly correlated rollout provide `source=rollout-fallback`; otherwise the view reports
  `source=none` with a visible reason. Source bodies are not assumed equal. Rollout-derived text is
  stdout-only: the viewer writes, locks, and creates nothing (not even the transport root).
- Read replies through that view by default: it caps each body at `--max-bytes` (4096 B default) and
  a truncated body names the full reply path. Open the raw `.reply.md` only when grading or
  verification needs byte-exact content.
- Do not modify global Codex config, account state, plugins, marketplace, thread archive state, or
  SQLite directly.
- Keep all assertions scoped to the evidence actually inspected in the current run.

## Further reading

- [references/architecture.md](references/architecture.md) — transport model, delivery result
  taxonomy, auto-load behavior, reply viewer.
- [references/security-model.md](references/security-model.md) — threat model and safety gates.
- [references/troubleshooting.md](references/troubleshooting.md) — dependency and failure-mode
  triage.
