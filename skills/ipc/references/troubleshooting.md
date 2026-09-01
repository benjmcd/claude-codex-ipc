# /ipc troubleshooting (skill-level)

Repo-level triage lives in `docs/TROUBLESHOOTING.md`; this is the bundled quick reference.

## Dependencies by feature

| Symptom | Cause | Fix |
|---|---|---|
| `node:sqlite is unavailable` from inspector/locator/snapshot | Node.js without `node:sqlite` support (needs ≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`) | Upgrade Node, or skip inspection — file-drop handoff works without it |
| `--app/--open/--exec was removed in v0.1.8` | CLI-backed modes removed | Use the default file-drop handoff or `--ipc <conversationId>`; neither invokes the Codex CLI |
| `--ipc` says `node not found` | Node.js missing | Install Node; or use the printed file-drop pickup line (already written) |
| Inspector says `State DB was not found` | No Codex Desktop state on this machine (or non-default path) | Pass `--db`/`--sessions-root`, or accept that inspection is unavailable |
| `autoload helper unavailable` warning | Not Windows, or `powershell.exe` missing | Expected off-Windows: open `codex://threads/<id>` manually, or use file-drop |

## Before first use

Task envelopes and replies are plaintext and can be read and modified by same-user processes; task text must not contain secrets.
Keep-only retention may retain them indefinitely.
Pruning reduces ordinary accumulation but is not confidentiality or secure deletion.
Backups, sync tools, snapshots, and filesystem recovery may retain deleted content.

## Delivery triage (`--ipc`)

Results carry machine tokens: `RESULT: <top> -- reason=<token> -- confirmation=<token>`. Key
reasons: `renderer-owned`/`auto-loaded`/`foreground-switched` (delivered),
`codex-foreground-deferred` (use `--foreground-policy switch --ack-foreground-switch`, switch away
from Codex, or paste the file-drop line), `foreground-unidentified` (foreground app not provably
Codex; never auto-switched), `foreground-restore-unproven` (restore-if-known is fail-closed),
`autoload-incomplete` (poll window expired), `target-not-found`/`target-archived`/
`target-inspection-ambiguous` (positive proof required before any deep link),
`router-pipe-failure`, `foreground-switch-unacknowledged`, `invalid-foreground-policy`.
On an accepted send the wrapper emits one bounded confirmation token: `rollout-hit` (the exact
dispatch pickup was observed in a rollout user message — admission only, not completion),
`rollout-pending` (authoritative candidate readable but no pickup observed within budget — do not
infer non-delivery), or `rollout-unavailable` (observation could not determine a result). None
triggers an automatic resend. Thread-tail inspection can inform diagnosis, but negative bounded
evidence cannot prove non-admission or authorize a resend.

1. `RESULT: gui-delivered` — the router accepted exactly one target follower; this is not task
   completion or reply-file success. Read the rollout confirmation and use the printed
   `codex_ipc_wait.mjs` command. If the task still does not appear and the target may have been
   mid-turn, re-inspect the authoritative rollout before taking any recovery action.
2. `RESULT: gui-unowned` — no renderer owns the thread and auto-load did not complete. Open
   `codex://threads/<conversationId>` in the app, then rerun `/ipc`; or paste the printed
   file-drop pickup line.
3. `RESULT: failed-closed` with `confirmation=not-attempted` — structured evidence proves that no
   follower was admitted (target missing/archived, invalid arguments, refused policy, or exact
   `no-client-found` followed by a later refusal). A router request may have occurred, but no turn
   was admitted, so the printed file-drop pickup line is safe to paste.
4. `RESULT: failed-closed` with `confirmation=unknown` — router/pipe failure *after* a send was
   attempted (app closed, timeout, protocol drift). **The envelope is preserved but no pickup line
   is printed, and you must not paste one or resend** — the turn may already have been admitted,
   and resending would execute it twice. Re-inspect the thread tail to establish what happened.
   If Codex Desktop recently updated, run `codex_ipc_revalidate.mjs`; suspect protocol drift before
   suspecting the target.

## Post-update revalidation

```bash
node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_revalidate.mjs" --thread <conversationId>
# add --allow-live-ipc-read --timeout-ms 1500 to re-prove router framing (initialize only)
```

If drift is confirmed and a live re-proof is genuinely needed, use
`codex_ipc_write_proof.mjs` dry-run first, then the live path only with explicit operator approval
(`--send --ack-live-write --allow-any-thread`). It sends exactly one marker task to exactly one
explicit conversationId and compares before/after isolation evidence.

## Reply file never written (permission/sandbox denial)

Expected, not an error. The injected follower turn can run under a sandbox that blocks the
per-dispatch `.reply.md` write. The producer states the denial in one line and puts the full
substantive result in its final agent message. On a known-UUID `--ipc` dispatch,
`codex_ipc_wait --accept-rollout-fallback` certifies named-dispatch completion and
`replySource=rollout-fallback` but intentionally emits no body; retrieve and render the body with
the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer. Display is capped at 4096
bytes by default; if truncation is reported, rerun with a sufficient `--max-bytes`. Flagless and
filedrop do not auto-recover. The inspector's stored `sandboxPolicy`/`approvalMode` are advisory only
(`permissionProfileAdvisory`): they may differ from the effective turn and never predict
reply-writability.

## Completion / wait triage (`codex_ipc_wait`)

`codex_ipc_wait` prints exactly one of six tokens on stdout: `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. Bounded example:
`node "${CLAUDE_SKILL_DIR}/scripts/codex_ipc_wait.mjs" --thread <uuid> --dispatch <dispatchId>
--reply-path <path> --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000`. `done`
certifies the **named dispatch's own turn**, never current thread idleness. Flagless (no
`--accept-rollout-fallback`) is the legacy file-primary contract. Exit-code-driven callers may add
the opt-in `--status-exit-codes` (`done=0`, `pending=2`, `aborted=3`, `superseded=4`,
`reply-missing=5`, `unavailable=6`; usage errors stay exit 1 with no token); without it every
determination exits 0.

- `done`: the named dispatch's own turn completed — named-dispatch completion, not thread
  idleness. Source-aware callers read `replySource` / the `reply-source` diagnostic or the
  dual-source viewer; an opt-in `done` never proves the reply path exists.
- `pending`: no determination yet — wait longer or re-inspect; do not resend.
- `reply-missing`: Only a genuinely absent reply is eligible for waiter rollout fallback.
  A present-but-invalid reply returns `reply-missing` without consulting rollout fallback.
  An absent reply with no certifiable rollout body exhausts the eligible sources.
  Inspect its
  diagnostics/thread; do not re-harvest, auto-resend, or hand-roll rollout/report-file polling.
  Recovery caveat:
  resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
- `aborted`: the dispatch's own turn ended in `turn_aborted` (any reply is unverified) — surface
  it, do not wait. Recovery caveat:
  resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
- `superseded`: a newer `task_started` opened before the terminal; a later unrelated terminal
  never certifies it. Issue a NEW dispatch if the goal still matters.
- `unavailable`: no authoritative rollout candidate or rollout/reply-scan ambiguity — re-inspect;
  never infer non-delivery or auto-resend.

## Encoding and mojibake recovery

Valid stored UTF-8 may display with the wrong decoder.
Stored bytes may instead be invalid or corrupt.
Valid UTF-8 may also contain a known double-decoding signature.

Windows PowerShell 5.1 reads BOM-free UTF-8 correctly with:

```powershell
$Path = 'C:\path\to\file.md'
Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
```

Windows PowerShell 5.1 `Set-Content -Encoding UTF8` writes a BOM. For BOM-free writes, use a
configured UTF-8/LF editor, PowerShell 7 `utf8NoBOM`, or `.NET UTF8Encoding(false)`.

Inspect raw bytes first, then apply strict UTF-8 decoding.
If the bytes are valid, use the correct reader or editor and do not save the misrendered form.
If the bytes are corrupt, restore or reconstruct from authoritative source; a reconstruction is allowed only when its reviewed byte-to-codepoint mapping is unambiguous.
Then run index and worktree gates, then semantic tests.
Never paste broken console text back into a file.
There is no automatic transcoder.
Preserve intentional Unicode; do not normalize or auto-convert it.

## Reply viewer

- Exit 0 with "No IPC transport root": nothing has been dispatched yet — not an error.
- Exit 2: session unresolvable — pass `--session <sid>` (the listing printed is the same as
  `--list-sessions`).
- Exit 1: usage error, malformed `--since`, or enumeration failure (fails closed rather than
  reporting a false "0 replies").
- "(empty — possibly mid-write or pending)": Codex has not finished writing; re-run to refresh.
