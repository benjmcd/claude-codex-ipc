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
"revalidate after updates", and keep file-drop as default/fallback.

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

The IPC transport envelope (the `.task.md`/`.reply.md` pair) is deliberately machine-local under
`${CODEX_IPC_ROOT:-~/.claude/ipc}` — that is the ONE exception to the rule below. Envelopes and
replies are pruned after `CODEX_IPC_RETENTION_DAYS` (default 7; 0 disables), opportunistically on
the next dispatch, so read replies within the session or disable retention if you need them kept.
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
archived flag, and rollout path; the latest user/agent/task-complete signals; whether the tail
suggests the session may be mid-turn; and whether the instruction is a handoff, oversight
request, status check, continuation, review, wait/watch request, or management request. If the inspector
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
continue, or manage that active state. This rule is load-bearing: the router can report success for
a mid-turn send while the message silently never materializes (observed in testing — no rollout
entry, no queued follow-up). When delivery matters, re-inspect after sending and confirm the task
text appeared in the thread tail. Never use `turn/interrupt`, config/account/plugin methods, or
direct SQLite writes as part of `/ipc`.

### Watch/status mode

For `/ipc <conversationId>` with no task, report status only. For `watch`, repeat read-only
inspection at a conservative interval and stop when the user-specified condition is met or when a
clear `task_complete`/idle signal appears. Do not send during watch mode unless the user separately
requests a send.

## New-session mode

No UUID means there is not yet a proven IPC target. Resolve the intended workspace first.

Prefer an explicit path or project name in the command. If absent, infer from the current repo and
current conversation context. If it is genuinely ambiguous, ask one concise question before
creating/opening the wrong context.

To open a project in Codex Desktop, use the maintained wrapper:

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --app
```

or run `codex app <workspace>` from the intended workspace.

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

Model and reasoning effort for a Codex thread are controlled by the Desktop thread itself; `/ipc`
cannot set them through the delivery route. Mention desired model/reasoning in the task text only
when it matters. For headless `--exec` handoffs, model/reasoning pins are opt-in via the
`CODEX_MODEL` / `CODEX_REASONING_EFFORT` environment variables and are passed only when set.

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
- `/ipc` success is strictly GUI delivery into the renderer-owned Desktop thread. Never use
  headless `codex exec resume` (or any non-GUI execution) as an `/ipc` fallback or call it `/ipc`
  success; `--exec` remains a separate explicit tool.
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
  DERIVED view of the per-dispatch `.reply.md` files; it is never the authoritative channel and
  writes, locks, and creates nothing (not even the transport root).
- Do not modify global Codex config, account state, plugins, marketplace, thread archive state, or
  SQLite directly.
- Keep all assertions scoped to the evidence actually inspected in the current run.

## Further reading

- [references/architecture.md](references/architecture.md) — transport model, delivery result
  taxonomy, auto-load behavior, reply viewer.
- [references/security-model.md](references/security-model.md) — threat model and safety gates.
- [references/troubleshooting.md](references/troubleshooting.md) — dependency and failure-mode
  triage.
