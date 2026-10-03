# /ipc quickstart examples

Use the command form for its stated execution context:

- skills/ipc/scripts paths run from the repository root.
- scripts paths run from the installed skill root (`~/.claude/skills/ipc`).
- /ipc is invoked in the Claude slash-command UI.

`${CLAUDE_SKILL_DIR}` is set by Claude Code while the skill runs; when running a bundled command by
hand, substitute the installed skill root. `<conversation-id>` is always a Codex Desktop thread
UUID you supply explicitly.

## Before first use

Task envelopes and replies are plaintext and can be read and modified by same-user processes; task text must not contain secrets.
Keep-only retention may retain them indefinitely.
Pruning reduces ordinary accumulation but is not confidentiality or secure deletion.
Backups, sync tools, snapshots, and filesystem recovery may retain deleted content.

The first dispatch command below uses handoff_to_codex.sh.

## 1. File-drop handoff (stable default — no pipe, no SQLite, no Codex CLI)

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" "review src/parser.js for edge cases"
```

Paste the printed pickup line (`read "<task path>" and proceed`) into your Codex session. Codex
writes its reply to the printed per-dispatch `.reply.md` path.

Goal setup is omitted by default. When the operator explicitly wants this dispatch to create a
goal, add `--request-goal` before the task.

## 2. Thread-bound manual delivery (no live contact)

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversation-id> --deliver manual -- "review src/parser.js for edge cases"
```

This writes the ordinary envelope under the UUID channel, performs one shared target inspection,
and prints the pickup plus a fully correlated `WAIT:` command. It never calls host policy,
PowerShell, the pipe client, an observer, or an opener, and prints no live `RESULT:`. If the
inspector cannot establish a rollout page, the WAIT command omits it and fixed `ROLLOUT-PATH:`
guidance explains how to supply one. For a thread that already runs a goal, leave
`--request-goal` off; the operator may paste the pickup while a turn is open. Expect `pending` until
the named dispatch has its own completion evidence. Do not use `turn/interrupt` or resend to create
an idle gap.

## 3. Explicit live Codex Desktop conversation handoff (optional, EXPERIMENTAL)

```bash
# 1. Inspect the target first (read-only; requires node:sqlite):
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_session_inspect.mjs" --thread <conversation-id> --tail-events 20 --summary

# 2. Send via the wrapper (writes the file-drop fallback first). It independently inspects once
#    and requires a root target with a nonempty stored model, then sends only when the intended GUI
#    is the sole proven host; activation of an unowned thread remains off:
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversation-id> "run the failing test and fix it"
```

Host settings resolve per field as wrapper flag > environment >
`${CODEX_IPC_ROOT}/host-policy.json` > defaults. Defaults are `autoload=off` and intended host
`package`; alternate intended hosts use an absolute executable path and are never protocol-activated.
The shipped real-machine evidence readers currently refuse package activation because update
clearance and the effective `codex` protocol handler are not yet qualified.
The wrapper refuses missing, archived, non-root, empty-model, or ambiguous targets before host
policy or pipe contact. A locator hint is not send authority.

## 4. Reply viewing (read-only derived view)

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh"                     # current session, newest first
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" --list-sessions    # what sessions exist
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" -c <conversation-id> -n 5
```

## 5. Wait for a NAMED dispatch to complete (bounded; opt-in rollout fallback)

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_wait.mjs" \
  --thread <conversation-id> --dispatch <dispatchId> \
  --reply-path <printed .reply.md path> \
  --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000
```

`codex_ipc_wait` prints exactly one of six tokens on stdout: `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. `done` certifies the **named dispatch's own turn**
reached completion — it is never proof that the thread is idle now.
An immediate unmarked continuation cannot replace the dispatch terminal or provide its missing
body. Correlated `turn-error` / `turn-model-state` detail may appear on stderr without changing the
six-token contract; see [troubleshooting](../references/troubleshooting.md).
Only a genuinely absent reply is eligible for waiter rollout fallback.
A present-but-invalid reply returns `reply-missing` without consulting rollout fallback.
An absent reply with no certifiable rollout body exhausts the eligible sources.
Inspect its diagnostics/thread; do not re-harvest,
auto-resend, or hand-roll rollout/report-file polling. On `reply-missing`/`aborted`:
resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
Manual preparation prints a ready-to-run `WAIT:` line after its pickup and no `RESULT:`. An accepted
live `--ipc` send prints the same WAIT contract before its final `RESULT:` line. Flagless (no
`--accept-rollout-fallback`) is the legacy file-primary contract.

For local alternate state roots, use only the component aliases documented in the
[skill guide](../SKILL.md): `CODEX_IPC_SESSIONS_ROOT` and, where supported,
`CODEX_IPC_ROLLOUT_PATH`. An explicit flag wins; `CODEX_HOME` is not an alias.

## 6. Opt-in transcript pointer

```bash
CODEX_IPC_INCLUDE_TRANSCRIPT=1 "${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" "task that needs my full session context"
```
