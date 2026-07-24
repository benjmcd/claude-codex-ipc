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
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_session_inspect.mjs" --thread <conversationId> --tail-events 20
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
reply-writability prediction. A blocked reply write is expected, not an error, and is recovered
via `codex_ipc_wait --accept-rollout-fallback` (a known-UUID `--ipc` dispatch), never a policy
gate; the latest
user/agent/task-complete signals; and `activitySignals.turnActivity` — the authoritative
open/closed/ambiguous read of the latest turn boundary from the shared turn-boundary machine over
the FULL rollout stream (`open` = a start/user turn with no matching terminal; `closed` = the
latest turn reached its terminal; `ambiguous` = boundary/rollout ambiguity — fail closed). Prefer
`turnActivity` over the historical `maybeMidTurn` tail heuristic; `terminalState` and a per-dispatch
wait `done` both describe past turns and never prove current idleness. The pre-send write-proof gate
requires `turnActivity==="closed"`; `--allow-mid-turn` overrides `open` only, never `ambiguous`. Also
note whether the instruction is a handoff, oversight request, status check, continuation, review,
wait/watch request, or management request. If the inspector
is ambiguous, read the referenced rollout JSONL directly with targeted grep/tail before asking the
user. Ask one concise question only when sending would risk interrupting or misdirecting the wrong
thread.

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
pickup line is preserved in every outcome.

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
Read-only inspection only; parse event types, never substring-grep (which also matches inside
tool output). One delegation produces one reply: app-driven turns after the reply (e.g. goal
checks) are supersession territory, discovered by re-inspection, not by watching forever.
The prose above remains the completion-contract definition; mechanically check it with
`scripts/codex_ipc_wait.mjs`, which emits `done`, `aborted`, `superseded`, `reply-missing`,
`pending`, or `unavailable` (single-shot by default; `--budget-ms` bounds an optional poll).
Rollout identity precondition: an explicit `--rollout-path` must name a `<threadId>.jsonl`-suffixed
file whose first record is a matching `session_meta` — the shared reader validates identity even
for explicit paths, so a renamed or copied rollout yields `unavailable` with an identity-mismatch
diagnostic rather than reading the wrong thread.
A bounded example (30-minute budget, opt-in rollout fallback):
`node scripts/codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> --reply-path <path>
--accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000`. A `done` token is
**named-dispatch completion, never current thread idleness** — `terminalState` and a per-dispatch
`done` both describe past turns. With `--accept-rollout-fallback`, `reply-missing` means the waiter
already exhausted **both** body sources (reply file and rollout store): inspect its
diagnostics/thread; do not re-harvest, auto-resend, or hand-roll rollout/report-file polling. On
`reply-missing`/`aborted`:
resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
Flagless (no `--accept-rollout-fallback`) is the legacy file-primary contract.
Exit-code-driven callers may add the opt-in `--status-exit-codes`, which maps the determination to
`done=0`, `pending=2`, `aborted=3`, `superseded=4`, `reply-missing=5`, `unavailable=6` (usage errors
stay exit 1 with no token); the token remains the sole stdout line. Without the flag every
determination exits 0.
Compose handoffs with the completion contract in
[references/handoff-template.md](references/handoff-template.md): self-verify BEFORE writing the
reply; the reply is the last act of the turn.

Producer denied-reply protocol (a denied reply write is EXPECTED, not an error): the generated
payload instructs the follower to self-verify, then attempt the printed reply path exactly once. On
a sandbox/permission denial the follower must NOT retry, debug, request escalation, or substitute
another file — it states the denial in one line AND puts the full substantive result (not just the
denial) in its final agent message, then completes. A one-line denial with no result is a contract
violation. On the dispatcher side, a full final message is recoverable only via the opt-in
`codex_ipc_wait.mjs --accept-rollout-fallback` path on a known-UUID `--ipc` dispatch (it certifies
`done` with `replySource=rollout-fallback`); flagless invocation stays file-primary and filedrop is not
auto-recoverable. Dispatch never changes the target thread's model, reasoning, sandbox, or approval.

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
are NEVER changed by `/ipc`: a delegated turn runs under whatever the thread is already set to
(the router ignores `turnStartParams.model` overrides in any case — verified 2026-07-10). Do not
attempt to override them through the delivery route, the client flags, or any other mechanism;
if the inspector preflight shows the thread's stored settings are unsuitable for the handoff
(e.g. a `managed` sandbox where reply-file writes are needed), pick a suitable thread or ask the
operator — never mutate. Model/reasoning tier guidance in a task belongs to the thread's
SUBAGENT deployment instructions, not to the thread itself.

## Cross-session context

Every `handoff_to_codex.sh` handoff includes Claude's session id for reply correlation. The Claude
transcript path is included only when the operator opts in with
`CODEX_IPC_INCLUDE_TRANSCRIPT=1`; by default it is omitted, because transcript pointers expose full
session context that may include unrelated material. For `--ipc`, Claude already knows the Codex
conversationId, which is the rollout id and can be used to find the full Codex JSONL transcript
under `~/.codex/sessions/`. Use transcript pointers for orientation and verification, not for broad
disclosure outside the local machine.

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
- The consolidated reply view (`scripts/codex_ipc_replies.sh`) is a read-only, point-in-time
  DERIVED view. For each dispatch, a readable regular non-symlink `.reply.md` is primary and is
  labeled `source=reply-file`. Only when that primary is absent or unreadable may a completed,
  exactly correlated rollout provide `source=rollout-fallback`; otherwise the view reports
  `source=none` with a visible reason. Source bodies are not assumed equal. Rollout-derived text is
  stdout-only: the viewer writes, locks, and creates nothing (not even the transport root).
- Do not modify global Codex config, account state, plugins, marketplace, thread archive state, or
  SQLite directly.
- Keep all assertions scoped to the evidence actually inspected in the current run.

## Further reading

- [references/architecture.md](references/architecture.md) — transport model, delivery result
  taxonomy, auto-load behavior, reply viewer.
- [references/security-model.md](references/security-model.md) — threat model and safety gates.
- [references/troubleshooting.md](references/troubleshooting.md) — dependency and failure-mode
  triage.
