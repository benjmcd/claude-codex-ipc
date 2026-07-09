# /ipc troubleshooting (skill-level)

Repo-level triage lives in `docs/TROUBLESHOOTING.md`; this is the bundled quick reference.

## Dependencies by feature

| Symptom | Cause | Fix |
|---|---|---|
| `node:sqlite is unavailable` from inspector/locator/snapshot | Node.js without `node:sqlite` support (needs ≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`) | Upgrade Node, or skip inspection — file-drop handoff works without it |
| `'codex' not found on PATH` | Codex CLI not installed | Only `--app`, `--open`, `--exec` need the CLI; file-drop and `--ipc` do not |
| `--ipc` says `node not found` | Node.js missing | Install Node; or use the printed file-drop pickup line (already written) |
| Inspector says `State DB was not found` | No Codex Desktop state on this machine (or non-default path) | Pass `--db`/`--sessions-root`, or accept that inspection is unavailable |
| `autoload helper unavailable` warning | Not Windows, or `powershell.exe` missing | Expected off-Windows: open `codex://threads/<id>` manually, or use file-drop |

## Delivery triage (`--ipc`)

Results carry machine tokens: `RESULT: <top> -- reason=<token> -- confirmation=<token>`. Key
reasons: `renderer-owned`/`auto-loaded`/`foreground-switched` (delivered),
`codex-foreground-deferred` (use `--foreground-policy switch --ack-foreground-switch`, switch away
from Codex, or paste the file-drop line), `foreground-unidentified` (foreground app not provably
Codex; never auto-switched), `foreground-restore-unproven` (restore-if-known is fail-closed),
`autoload-incomplete` (poll window expired), `target-not-found`/`target-archived`/
`target-inspection-ambiguous` (positive proof required before any deep link),
`router-pipe-failure`, `foreground-switch-unacknowledged`, `invalid-foreground-policy`.
`confirmation=not-checked` on delivery means rollout observation has not run — re-inspect the
thread tail when certainty matters.

1. `RESULT: gui-delivered` — done. If the task still does not appear and the target may have been
   mid-turn, re-inspect and confirm the task text is in the thread tail (the router can report
   success for a mid-turn send that never materializes).
2. `RESULT: gui-unowned` — no renderer owns the thread and auto-load did not complete. Open
   `codex://threads/<conversationId>` in the app, then rerun `/ipc`; or paste the printed
   file-drop pickup line.
3. `RESULT: failed-closed` — target missing/archived, or router/pipe failure (app closed, timeout,
   protocol drift). Diagnostics are printed. If Codex Desktop recently updated, run
   `codex_ipc_revalidate.mjs`; suspect protocol drift before suspecting the target.

## Post-update revalidation

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_revalidate.mjs" --thread <conversationId>
# add --allow-live-ipc-read --timeout-ms 1500 to re-prove router framing (initialize only)
```

If drift is confirmed and a live re-proof is genuinely needed, use
`codex_ipc_write_proof.mjs` dry-run first, then the live path only with explicit operator approval
(`--send --ack-live-write --allow-any-thread`). It sends exactly one marker task to exactly one
explicit conversationId and compares before/after isolation evidence.

## Reply viewer

- Exit 0 with "No IPC transport root": nothing has been dispatched yet — not an error.
- Exit 2: session unresolvable — pass `--session <sid>` (the listing printed is the same as
  `--list-sessions`).
- Exit 1: usage error, malformed `--since`, or enumeration failure (fails closed rather than
  reporting a false "0 replies").
- "(empty — possibly mid-write or pending)": Codex has not finished writing; re-run to refresh.
