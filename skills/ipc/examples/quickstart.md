# /ipc quickstart examples

All commands run from any directory. `${CLAUDE_SKILL_DIR}` is set by Claude Code while the skill
runs; when running by hand, substitute the skill directory (e.g. `~/.claude/skills/ipc`).
`<conversation-id>` is always a Codex Desktop thread UUID you supply explicitly.

## 1. File-drop handoff (stable default — no pipe, no SQLite, no Codex CLI)

```bash
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" "review src/parser.js for edge cases"
```

Paste the printed pickup line (`read "<task path>" and proceed`) into your Codex session. Codex
writes its reply to the printed per-dispatch `.reply.md` path.

## 2. Explicit Codex Desktop conversation handoff (optional, EXPERIMENTAL)

```bash
# 1. Inspect the target first (read-only; requires node:sqlite):
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_session_inspect.mjs" --thread <conversation-id> --tail-events 20 --summary

# 2. Send via the wrapper (writes the file-drop fallback first):
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversation-id> "run the failing test and fix it"
```

## 3. Reply viewing (read-only derived view)

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh"                     # current session, newest first
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" --list-sessions    # what sessions exist
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" -c <conversation-id> -n 5
```

## 4. Wait for a NAMED dispatch to complete (bounded; opt-in rollout fallback)

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_wait.mjs" \
  --thread <conversation-id> --dispatch <dispatchId> \
  --reply-path <printed .reply.md path> \
  --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000
```

`codex_ipc_wait` prints exactly one of six tokens on stdout: `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. `done` certifies the **named dispatch's own turn**
reached completion — it is never proof that the thread is idle now. With
`--accept-rollout-fallback`, `reply-missing` means the waiter already exhausted **both** body
sources (reply file and rollout store): inspect its diagnostics/thread; do not re-harvest,
auto-resend, or hand-roll rollout/report-file polling. On `reply-missing`/`aborted`:
resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
After an accepted live `--ipc` send the wrapper prints a ready-to-run `WAIT:` line before its final
`RESULT:` line. Flagless (no `--accept-rollout-fallback`) is the legacy file-primary contract.

## 5. Opt-in transcript pointer

```bash
CODEX_IPC_INCLUDE_TRANSCRIPT=1 "${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" "task that needs my full session context"
```
