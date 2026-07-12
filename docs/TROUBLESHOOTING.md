# Troubleshooting

Skill-bundled quick reference:
[skills/ipc/references/troubleshooting.md](../skills/ipc/references/troubleshooting.md). This page
adds repo/install-level triage.

## Install issues

| Symptom | Cause / fix |
|---|---|
| `install.sh: refusing to overwrite existing install` | An `ipc` skill already exists at the target. Re-run with `--force` (it prints what it deletes) after checking the existing copy isn't a modified one you want to keep. |
| Installed but `/ipc` not found | Standalone target must be exactly `~/.claude/skills/ipc/` (or `%USERPROFILE%\.claude\skills\ipc\`). For plugin installs the invocation is `/codex-ipc:ipc`. Restart/reload Claude Code after installing. |
| Scripts fail with `\r: command not found` | CRLF line endings were introduced (editor or git config). The repo's `.gitattributes` forces LF for `*.sh`/`*.mjs`; re-checkout or `dos2unix` the scripts. |
| `Permission denied` running `.sh` | `bash path/to/script.sh` works regardless of the execute bit; or `chmod +x` the scripts. |

## Runtime issues

| Symptom | Cause / fix |
|---|---|
| `node:sqlite is unavailable` | Inspection tools need Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`). Upgrade Node, or skip inspection — file-drop works without it. |
| `ERROR: 'codex' not found on PATH` | Only `--app` / `--open` / `--exec` need the Codex CLI. File-drop and `--ipc` do not. |
| `mapfile: command not found` | The reply viewer needs bash ≥ 4; stock macOS bash is 3.2. `brew install bash` and run the script with the newer bash. |
| `--ipc` → `failed-closed` with pipe/connect errors | Codex Desktop is not running, or the private router protocol drifted after an update. Start the app; run `codex_ipc_revalidate.mjs`; suspect drift before suspecting the target. |
| `--ipc` → `gui-unowned` repeatedly | No renderer owns the thread and auto-load could not complete (or you are actively working in Codex — the helper defers on purpose). Open `codex://threads/<conversationId>` manually, then rerun; or use the printed file-drop line. |
| `confirmation=rollout-hit` | The exact dispatch pickup was observed in a rollout user message. This confirms admission only; inspect completion/reply state separately. |
| `confirmation=rollout-pending` | At least one authoritative rollout candidate was readable/parseable, but no pickup was observed within the bounded budget. Do not infer non-delivery or resend automatically; inspect current thread state first. |
| `confirmation=rollout-unavailable` | Observation could not make a determination because no authoritative candidate was usable or ambiguity/schema drift intervened. The accepted send remains `gui-delivered`; inspect current state without automatic resend. |
| Reply view shows `source=rollout-fallback` | The primary reply file was absent or unreadable at check time, so the viewer selected an exactly correlated completed rollout body. The two source bodies are not assumed equal; fallback is stdout-only. |
| Reply view shows `source=none` | Neither source yielded content. Use the visible `pending`, `unavailable`, `ambiguous`, or `unparseable` reason; no cache or reply file is synthesized. |
| Reply viewer exit 2 | No session id resolvable. Pass `--session <sid>` (the printed listing shows what exists). |
| Reply viewer exit 1 on `--since` | Malformed `find -newermt` spec — the viewer fails closed rather than reporting a false "0 replies". |
| Old envelopes disappeared | Retention pruning (`CODEX_IPC_RETENTION_DAYS`, default 7) ran on a later dispatch. Set `0` to disable. |
| Reply file never written (permission/sandbox denial) | Expected, not an error: the injected turn can run under a sandbox that blocks the per-dispatch `.reply.md` write. The producer states the denial and puts the full result in its final agent message; recover it with `codex_ipc_wait --accept-rollout-fallback` on a known-UUID `--ipc` dispatch (flagless/filedrop do not auto-recover). The inspector's stored `sandboxPolicy`/`approvalMode` are advisory only (`permissionProfileAdvisory`) and never predict reply-writability. |

## Completion / wait triage (`codex_ipc_wait`)

`codex_ipc_wait` prints exactly one of six tokens on stdout: `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. A bounded wait is
`node skills/ipc/scripts/codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> --reply-path
<path> --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000`. `done` certifies the
**named dispatch's own turn**, never current thread idleness. Flagless (no
`--accept-rollout-fallback`) is the legacy file-primary contract.

| Token | Cause / remediation |
|---|---|
| `done` | The named dispatch's own turn reached `task_complete`. This is named-dispatch completion, NOT proof the thread is idle now. Source-aware callers read `replySource` / the `reply-source` diagnostic, or open the dual-source viewer; an opt-in `done` is never proof the reply path exists. |
| `pending` | No determination yet (single-shot, or budget expired with the turn still open). Wait longer or re-inspect; do not resend. |
| `reply-missing` | Under `--accept-rollout-fallback` the waiter already exhausted BOTH body sources (reply file and rollout store). Inspect its diagnostics/thread; do not re-harvest, auto-resend, or hand-roll rollout/report-file polling. resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker. |
| `aborted` | The dispatch's own turn ended in `turn_aborted` (any reply is unverified). Surface it; do not wait. resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker. |
| `superseded` | A newer `task_started` opened before the dispatch turn's terminal. A later, unrelated terminal never certifies it; issue a NEW dispatch if the goal still matters. |
| `unavailable` | No authoritative rollout candidate, or rollout/reply-scan ambiguity / schema failure. Re-inspect the thread; never infer non-delivery or auto-resend. |

## Test issues

| Symptom | Cause / fix |
|---|---|
| `tests/test_ipc.sh` fails at git-dependent checks | The harness creates its own throwaway repo; it needs `git` on PATH (identity is set locally by the harness). |
| Tests pass locally, CI safety scan fails | You introduced a private-looking pattern (personal path, real-looking UUID, key-like string). See `tests/scan_public_safety.sh` for the exact patterns. |
| `test_reply_view.sh` T12 fails on macOS | The viewer and harness assume GNU `find`/`date`. Run in a GNU userland (Linux CI image or Git Bash). |

## After a Codex Desktop update

1. `node skills/ipc/scripts/codex_ipc_revalidate.mjs --thread <conversation-id>` (validate-only).
2. If drift is suspected: `--allow-live-ipc-read --timeout-ms 1500` re-proves router framing
   (sends `initialize` only).
3. Only with explicit operator approval: controlled live re-proof via
   `codex_ipc_write_proof.mjs --thread <id> --marker <unique> --send --ack-live-write
   --allow-any-thread` against a thread you own.
4. Check **host identity** explicitly: an update may change the GUI process/executable name
   without changing the package family. Known case (2026-07-09): the GUI became `ChatGPT.exe`
   under the unchanged `OpenAI.Codex` package family, which broke name-only foreground
   detection until the identity check became path/package based. `revalidate`'s
   `desktopVersionHint` reports the package identity and the positively-identified GUI
   (`guiIdentified:false` means the GUI could not be identified — treat foreground safety as
   unproven, keep to file-drop, and run the hermetic matrix `tests/test_autoload_matrix.sh`).
