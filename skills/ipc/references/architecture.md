# /ipc architecture — transport model and delivery routes

## Transport envelope (stable core)

The Claude→Codex transport ENVELOPE — the per-dispatch `.task.md` the wrapper writes, and the
`.reply.md` Codex writes back — lives in a machine-local, repo-independent root, keyed per
`(Claude sessionId, conversationId, dispatchId)`:

```
${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSid>/<conversationId|filedrop>/<dispatchId>.task.md
                                                                      /<dispatchId>.reply.md
```

Properties this buys by construction:

- **Isolation.** Any number of concurrent Claude sessions and Codex threads never share a mutable
  file; there is no cross-talk and no clobbering (each dispatch is a unique leaf, written
  atomically via temp-file-then-rename).
- **Exact correlation.** A reply is matched to its task by `dispatchId`, with no ambiguity even
  when multiple handoffs are in flight.
- **CWD independence.** No git repository is required; the transport works from any directory.
  Task-CONTEXT artifacts (briefs, specs, bundles) still live inside the associated project and are
  referenced from the payload by absolute path — only the transport envelope is machine-local.
- **Missing-session safety.** If no Claude session id is injected, the wrapper mints an isolated
  `nosid-*` token instead of guessing another session's identity, and never guesses a transcript.

### Retention

Envelopes and replies are **kept by default**: `CODEX_IPC_RETENTION_DAYS` defaults to keep-only
(unset, empty and `0` all mean never delete). Pruning requires an explicit positive integer, so a
reply file persists until you opt in to deleting it. Pruning is **opportunistic**: it runs
only on the *next* `handoff_to_codex.sh` dispatch (the read-only viewer sweeps nothing), so a
terminal session's envelopes persist until a future handoff prunes them — an opportunistic bound,
not a scheduled sweep.

### Reply viewing

`scripts/codex_ipc_replies.sh` renders a consolidated, newest-first view of the per-dispatch
`.reply.md` files. It is a read-only, point-in-time DERIVED view — never the authoritative channel;
it writes, locks, and creates nothing (not even the transport root). Flags:
`[--session <sid>] [-c <uuid|filedrop>] [-n <count>] [--max-bytes <n>]
[--since <find -newermt spec>] [--paths-only] [--list-sessions] [-h]`. A malformed `--since` fails
closed (exit 1, never a false "0 replies"). Per-entry (session/thread/dispatch) attribution is what
keeps this a view rather than a re-commingling of channels.

## Delivery routes

### File-drop (default, stable)

The wrapper writes the payload to the keyed task file and prints one pickup line for the operator
to paste into their Codex session (Desktop app or TUI):

```
read "<absolute task path>" and proceed
```

This appears in the Codex Desktop GUI (the operator's own session reads the file) and has zero
effect on any other running Codex session. It requires no pipe, no SQLite support, and no Codex
CLI.

### Live Desktop IPC injection (`--ipc`, optional, EXPERIMENTAL)

Provenance: this transport was validated against a live Codex Desktop in the private predecessor
project and re-validated at a point in time (2026-07-08) during this repository's preparation —
the write-proof harness plus the `defer` and `switch`+ack delivery paths, with delivery confirmed
out-of-band via the reply loop (the wrapper now also runs one bounded post-acceptance rollout
observation and reports `confirmation=rollout-hit|rollout-pending|rollout-unavailable`).
`restore-if-known` remains unvalidated (fail-closed). It rides private Codex Desktop internals, so
run `codex_ipc_revalidate.mjs` on your own machine before first use and after every Desktop
update.

`handoff_to_codex.sh --ipc <conversationId> "task"` writes the file-drop first (so the fallback is
always ready), then injects the pickup line into the live Desktop GUI thread via the Desktop app's
IPC router named pipe (`\\.\pipe\codex-ipc`, `thread-follower-start-turn`). This route is built on
**private Codex Desktop internals** and can break in any Codex Desktop update; revalidate with
`codex_ipc_revalidate.mjs` (and, if needed, a controlled `codex_ipc_write_proof.mjs` run) after
updates.

Every `--ipc` send reports exactly one result:

- `gui-delivered` — the Desktop renderer accepted the turn. Silent and instant when the target
  thread is already loaded in the app. Loaded threads typically stay deliverable across repeated
  sends, but ownership can lapse (app restart, renderer eviction) — the wrapper then simply
  auto-loads again, so a lapse costs one extra auto-load, never a failure.
- `gui-unowned` — the thread exists but no renderer took ownership. Before reporting this, the
  wrapper auto-loads the thread through the app's own `codex://threads/<conversationId>` deep link
  and retries: it saves the operator's foreground window, fires the link, snaps focus back
  automatically (~100–150 ms), and polls ~30 s. The auto-load is foreground-aware — it defers
  (does nothing visible) while Codex itself is the foreground window, because the in-app thread
  view cannot be restored; it proceeds once the operator switches away, or reports `gui-unowned`
  after ~2 min. Success after auto-load leaves one disclosed residue: the Codex background window
  is left with the target thread selected.
- `failed-closed` — the target is missing or archived (refused before any deep link fires), or the
  router/pipe itself failed (app closed, timeout, protocol drift) — with the client's actual
  diagnostics printed instead of suppressed.

No click is normally required when the target thread is already renderer-owned, or when Codex is
not the foreground app and the wrapper can safely auto-load the target (focus restore is verified;
a failed verification is reported as a WARNING rather than staying silent). If Codex IS the
foreground app and the target thread is unowned, the default policy defers rather than changing
the visible Codex view — foreground recovery then requires explicit switch authorization (below)
or a future proven restore path. The file-drop **envelope** is preserved in every outcome; the
**pickup line** is printed only when the failure is proven pre-send. After an ambiguous
post-attempt result (`confirmation=unknown`) pickup is suppressed and resending is forbidden.

#### Foreground policy (`--foreground-policy`, EXPERIMENTAL)

When the target is unowned and Codex itself is the foreground window, the wrapper applies one of
three policies (flag overrides the `CODEX_IPC_FOREGROUND_POLICY` env default of `defer`):

- `defer` (default): never navigate the visible Codex app. The helper waits up to ~2 min for the
  operator to switch away, then reports `gui-unowned -- reason=codex-foreground-deferred`.
- `switch`: with `--ack-foreground-switch` (or the standing-approval env, printed on every send),
  navigate the visible Codex app straight to the target and deliver. Disclosed residue: the
  visible Codex app REMAINS on the target thread. Without acknowledgement: refused
  (`failed-closed -- reason=foreground-switch-unacknowledged`) — before any live IPC, with the
  file-drop already written.
- `restore-if-known`: FAIL-CLOSED this milestone (`gui-unowned -- reason=foreground-restore-unproven`).
  Restoring the Windows foreground handle is not restoring the in-app selected thread, and no
  read-only selected-thread authority exists yet; a syntactically valid restore UUID is not proof.

An unidentifiable foreground process is treated conservatively: it defers and is never
auto-switched. Windows may also route `codex://threads/<id>` through a Codex window the wrapper
cannot predict, so success is judged by owner acceptance, never by assumptions about which visible
window moved.

Result lines are machine-parseable:
`RESULT: gui-delivered|gui-unowned|failed-closed -- reason=<token> -- confirmation=<token>`.
On an accepted send, `confirmation` carries one bounded rollout-observation token:
`rollout-hit` (the exact dispatch pickup was observed in a rollout user message — proves
admission only, never completion or reply-file success), `rollout-pending` (an authoritative
candidate was readable/parseable but no pickup was observed within the bounded budget), or
`rollout-unavailable` (observation could not determine a result). Observation failures never
reclassify an accepted send and never trigger an automatic resend; re-inspect the thread tail
when delivery certainty matters.

Autoload helper exit codes: `0` deep-link permitted/completed (or dry-run equivalent), `1` link
fired but focus restore unverified, `2` foreground-Codex (or unidentifiable foreground) deferral,
`4` restore authority unproven, `5` switch without acknowledgement. The wrapper maps every code
explicitly; unrecognized codes fail closed.

The auto-load helper (`codex_ipc_autoload.ps1`) and focus snapback are **Windows-only** and depend
on `powershell.exe` plus Win32 foreground-window APIs. On other platforms — or when the helper is
unavailable — the wrapper still polls, and on failure reports `gui-unowned` with the manual
`codex://threads/<id>` remediation plus the file-drop fallback.

### Removed in v0.1.8: headless `--exec` (and `--app` / `--open`)

The CLI-backed modes were removed in v0.1.8. The wrapper no longer invokes the `codex` binary on
any path, and there is no headless execution path. Delivery is the default file-drop handoff or
live `--ipc` GUI injection.

## Read-only inspection surfaces

- `codex_ipc_session_inspect.mjs` — one thread's state-DB row plus rollout JSONL tail, with
  heuristic activity signals (mid-turn detection). Opens SQLite `readOnly:true`.
- `codex_ipc_thread_locator.mjs` — candidate conversationIds for a workspace/project from the
  Desktop thread index. Candidates are discovery, not send authority.
- `codex_ipc_snapshot.mjs` — config/state-DB evidence (hashes, marker counts) around a controlled
  write; also a pure-JSON `--compare` mode.
- `codex_ipc_probe.mjs` / `codex_ipc_owner_probe.mjs` — transport/framing research tools; dry-run
  by default, non-mutating methods only.
- `codex_ipc_revalidate.mjs` — static/presence checks; pipe connection only with
  `--allow-live-ipc-read` (sends `initialize` only).
- `codex_ipc_contract_audit.mjs` — static requirement matrix from the bundled skill files.

All of these send no prompts and write no SQLite. The orchestrating tools
(`codex_ipc_revalidate.mjs`, `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`) resolve
their sibling scripts relative to their own directory, so they work from any cwd in both the
plugin/repo layout and a standalone install.
