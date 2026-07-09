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
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_session_inspect.mjs" --thread <conversation-id> --tail-events 20

# 2. Send via the wrapper (writes the file-drop fallback first):
"${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" --ipc <conversation-id> "run the failing test and fix it"
```

## 3. Reply viewing (read-only derived view)

```bash
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh"                     # current session, newest first
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" --list-sessions    # what sessions exist
"${CLAUDE_SKILL_DIR}/scripts/codex_ipc_replies.sh" -c <conversation-id> -n 5
```

## 4. Opt-in transcript pointer

```bash
CODEX_IPC_INCLUDE_TRANSCRIPT=1 "${CLAUDE_SKILL_DIR}/scripts/handoff_to_codex.sh" "task that needs my full session context"
```
