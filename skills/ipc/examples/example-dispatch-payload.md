# Handoff from Claude Code -> Codex
<!-- EXAMPLE ONLY: this is a synthetic illustration of the payload handoff_to_codex.sh
     generates. All ids/paths below are placeholders, not real values. -->

Generated: 2026-01-01 12:00:00 UTC on branch `feature/example` (dispatch 1735732800-12345-0123456789abcdef)

## How to use this file
You (Codex) have been handed follow-up work from a Claude Code session.
Read the **Task** below and complete it in the associated workspace at:
  C:/path/to/your/project
When finished, write your reply/result to this per-dispatch reply file (create it):
  C:/Users/<you>/.claude/ipc/<claude-session-id>/filedrop/1735732800-12345-0123456789abcdef.reply.md
Use that absolute path exactly. It is unique to this handoff, so your reply is
correlated to this task with no ambiguity even if other handoffs are in flight.

## Branch
feature/example  (merge target: main)

## Commits on this branch (not yet on main)
abc1234 example: add feature scaffold

## Files changed vs main
 src/example.js | 10 ++++++++++
 1 file changed, 10 insertions(+)

## Task
Review src/example.js for edge cases and add the missing null-input guard.

## Claude session context (optional -- for deeper investigation)
Produced by Claude Code session: <claude-session-id>
Claude transcript pointer (only present when the sender opted in with
CODEX_IPC_INCLUDE_TRANSCRIPT=1; if it is a path, the JSONL is large -- grep or tail it for the
relevant part; it may include context unrelated to this task):
  (transcript path omitted by default; re-run with CODEX_IPC_INCLUDE_TRANSCRIPT=1 to include it)

When you reply in the reply file above, include your Codex session/conversation id if it is
available to you.
