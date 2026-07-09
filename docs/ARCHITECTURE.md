# Architecture

Repo-level overview. The authoritative operational detail ships with the skill itself in
[skills/ipc/references/architecture.md](../skills/ipc/references/architecture.md) so it is present
in standalone installs too; this page orients a repo reader.

## Layout

```
claude-codex-ipc/
  .claude-plugin/plugin.json     plugin manifest (plugin name: codex-ipc)
  skills/ipc/                    CANONICAL skill source (skill name: ipc)
    SKILL.md                     operational contract (manual-trigger only)
    scripts/                     the toolkit (bash wrapper + Node tools + PS1 autoload helper)
    references/                  bundled deep docs (architecture, security model, troubleshooting,
                                 handoff template)
    examples/                    synthetic payload example + quickstart commands
  tests/                         hermetic harnesses + public-safety scan (repo-only; not installed)
  docs/                          repo-level docs (this page, install, compatibility, troubleshooting)
  install.sh/.ps1, uninstall.*   standalone-install helpers
  .github/workflows/test.yml     CI: syntax, hermetic tests, safety scans (no live IPC)
```

## Core design: keyed file transport

One dispatch = one unique task file + one correlated reply file:

```
${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSessionId>/<conversationId|filedrop>/<dispatchId>.task.md
                                                                            /<dispatchId>.reply.md
```

- Atomic create (temp file + rename), never a shared mutable file → concurrent Claude sessions and
  Codex threads cannot cross-talk or clobber.
- Reply correlation is exact via `dispatchId`.
- Works from any cwd; no git repo required (git context is optional payload enrichment).
- Bounded retention: envelopes are pruned opportunistically on the next dispatch after
  `CODEX_IPC_RETENTION_DAYS` (default 7; 0 disables).

## Delivery routes on top of the transport

1. **File-drop (default, stable):** operator pastes one printed pickup line into their Codex
   session. Zero dependencies beyond bash; zero effect on other sessions.
2. **`--ipc` live injection (optional, EXPERIMENTAL, Windows):** after writing the file-drop, the
   wrapper injects the pickup line into the renderer-owned Desktop thread over the app's private
   named-pipe router; unowned threads are auto-loaded via the app's own `codex://threads/<id>`
   deep link with focus snapback. Result taxonomy: `gui-delivered | gui-unowned | failed-closed`.
   Built on private internals — revalidate after every Codex Desktop update.
3. **`--exec` headless (optional):** `codex exec resume` writes only rollout JSONL, invisible to
   the Desktop GUI; explicitly not an `/ipc` fallback.

## Inspection and validation surfaces (all read-only)

- `codex_ipc_session_inspect.mjs` — thread row + rollout tail + mid-turn heuristics.
- `codex_ipc_thread_locator.mjs` — candidate discovery for new-session mode (never send
  authority).
- `codex_ipc_snapshot.mjs` — config/DB hashing for before/after isolation evidence.
- `codex_ipc_revalidate.mjs` — post-update validate-only checks (pipe connect only with
  `--allow-live-ipc-read`, sending `initialize` only).
- `codex_ipc_write_proof.mjs` — dry-run-first controlled live-write proof (inspect → revalidate →
  snapshot → one marker send → poll → snapshot → compare); live path gated behind
  `--send --ack-live-write [--allow-any-thread]`.
- `codex_ipc_contract_audit.mjs` — static requirement matrix over the bundled skill files.

## Design invariants

- Explicit conversation UUID per live send; no heuristic write targeting.
- File-drop fallback precedes and survives every live attempt.
- SQLite is opened `readOnly:true` everywhere; no config/account/plugin/archive mutation.
- Transcript disclosure is opt-in (`CODEX_IPC_INCLUDE_TRANSCRIPT=1`).
- No authorized thread id ships in the code (`CODEX_IPC_AUTHORIZED_TEST_THREAD` is
  operator-supplied).
- Tools self-locate siblings by script directory → any-cwd operation in plugin, repo, and
  standalone layouts.
