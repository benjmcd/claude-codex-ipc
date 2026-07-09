# claude-codex-ipc

Controlled Claude Code → Codex handoff: file-backed dispatch/reply correlation as the stable core,
with optional, experimental, guarded delivery straight into a Codex Desktop GUI thread.

Ships as a Claude Code plugin (`codex-ipc`) containing one skill (`ipc`), which also installs
standalone.

## What this is

- A **file-backed handoff channel**: each dispatch writes a unique, atomically-created
  `<dispatchId>.task.md` under a machine-local root keyed per
  `(Claude sessionId, conversationId, dispatchId)`; Codex writes a correlated
  `<dispatchId>.reply.md` back. Concurrent sessions/threads are isolated by construction.
- A **reply viewer** (`codex_ipc_replies.sh`): read-only, newest-first consolidated view of
  replies. Never authoritative, never writes.
- **Read-only Codex state inspection** (where supported): session inspector, thread locator, and
  snapshot tools that open Codex Desktop's SQLite state `readOnly:true` and read rollout JSONL.
- An **optional, experimental live delivery route** into a Codex Desktop GUI thread via the app's
  private IPC named pipe, requiring an explicit conversation UUID, with dry-run-first tooling,
  explicit acknowledgement flags, and validation/revalidation harnesses.

## What this is NOT

- **Not MCP.** This is not a Model Context Protocol server or client.
- **Not an official OpenAI API.** The Desktop IPC route uses undocumented, private Codex Desktop
  internals that can change in any update. Nothing here is affiliated with or endorsed by OpenAI.
- **Not a production message broker.** It is plaintext files plus (optionally) a local named pipe,
  with no queueing guarantees, no delivery SLAs, and no multi-user security model.

## Status of the two halves

| | Stable core | Experimental extras |
|---|---|---|
| What | File-backed dispatch/reply, reply viewer, read-only inspection | Desktop named-pipe injection, `codex://` autoload, focus snapback |
| Depends on | bash, coreutils (Node for inspection) | Private Codex Desktop internals, Windows, PowerShell |
| After a Codex Desktop update | Unaffected | **Assume broken until revalidated** (`codex_ipc_revalidate.mjs`) |

**Live Desktop IPC was validated at a point in time** (2026-07-08): the write-proof harness plus
the default `defer` and `switch`+`--ack-foreground-switch` delivery paths were exercised against
operator-owned Codex Desktop threads, with delivery confirmed out-of-band via the reply loop (the
wrapper itself still reports `confirmation=not-checked` by design — see below). `restore-if-known`
remains unvalidated (fail-closed by design). Treat this as a point-in-time proof against private
Desktop internals: revalidate on your own machine with `codex_ipc_revalidate.mjs` (and, if needed,
`codex_ipc_write_proof.mjs`) before relying on it, and re-revalidate after every Codex Desktop
update.

## Install

### As a Claude Code plugin (recommended)

Local/dev usage (no marketplace metadata is shipped yet):

```bash
claude plugin add /path/to/claude-codex-ipc   # or your Claude Code version's equivalent
```

Invoke as `/codex-ipc:ipc`.

### Standalone skill

Copy `skills/ipc/` to your Claude skills directory (`~/.claude/skills/ipc/` or
`%USERPROFILE%\.claude\skills\ipc\`) — the bundled installers do exactly this and nothing else:

```bash
./install.sh --dry-run     # show what would be copied
./install.sh               # install (refuses to overwrite without --force)
```

```powershell
.\install.ps1 -DryRun
.\install.ps1
```

Invoke as `/ipc`. See [docs/INSTALL.md](docs/INSTALL.md) for details and uninstall.

## Quickstart

### 1. File-drop handoff (stable core)

```bash
skills/ipc/scripts/handoff_to_codex.sh "review src/parser.js for edge cases"
```

Paste the printed `read "<task path>" and proceed` line into your Codex session. Codex writes its
reply to the printed per-dispatch reply path.

### 2. Explicit Codex Desktop conversation handoff (experimental)

Requires the target thread's conversation UUID — there is deliberately **no** guessing of targets
from title, recency, cwd, or project name:

```bash
node skills/ipc/scripts/codex_ipc_session_inspect.mjs --thread <conversation-id> --tail-events 20
skills/ipc/scripts/handoff_to_codex.sh --ipc <conversation-id> "run the failing test and fix it"
```

The wrapper writes the file-drop first, so a failed live delivery always leaves a working manual
pickup line.

### 3. Reply viewing

```bash
skills/ipc/scripts/codex_ipc_replies.sh                   # current session, newest first
skills/ipc/scripts/codex_ipc_replies.sh --list-sessions
skills/ipc/scripts/codex_ipc_replies.sh -c <conversation-id> -n 5
```

## Configuration

All configuration is environment variables; nothing is required for the default file-drop path.

| Variable | Default | Effect |
|---|---|---|
| `CODEX_IPC_ROOT` | `~/.claude/ipc` | Transport root for task/reply envelopes |
| `CODEX_IPC_RETENTION_DAYS` | `7` | Prune envelopes/replies older than N days on each dispatch (`0` disables) |
| `CODEX_IPC_INCLUDE_TRANSCRIPT` | unset | `1` includes the Claude transcript path in the payload (default: omitted) |
| `CODEX_IPC_AUTHORIZED_TEST_THREAD` | unset | Optional operator-owned test thread UUID exempt from `--allow-any-thread` |
| `CODEX_MODEL` | unset | `--exec` model pin; passed only when set |
| `CODEX_REASONING_EFFORT` | unset | `--exec` reasoning pin / advisory note; used only when set |
| `CODEX_SESSION_ID` | unset | Target session for `--exec`/`--open` |
| `CODEX_IPC_FOREGROUND_POLICY` | `defer` | `--ipc` foreground policy: `defer`\|`switch`\|`restore-if-known` (flag overrides) |
| `CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL` | unset | `1` = standing acknowledgement for `switch` (printed on every send; prefer per-invocation `--ack-foreground-switch`) |
| `CODEX_IPC_POLL_DEADLINE_S` / `CODEX_IPC_POLL_INTERVAL_S` | `30` / `2` | Auto-load retry poll window/interval (test knobs) |
| `IPC_TOOLKIT_ROOT` | unset | Manual toolkit-root override (fallback only; the bundled scripts self-locate) |

`--ipc` results are machine-parseable:
`RESULT: gui-delivered|gui-unowned|failed-closed -- reason=<token> -- confirmation=<token>`.
Foreground-policy grammar:
`--ipc <conversationId> [--foreground-policy defer|switch|restore-if-known] [--ack-foreground-switch] [--] "<task>"`
(`switch` visibly navigates the Codex app and requires the acknowledgement; `restore-if-known` is
fail-closed this milestone; delivery confirmations are `not-checked` until bounded rollout
observation ships in a follow-up milestone).

## Feature / platform matrix

Summary (full matrix with dependencies and fallbacks in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)):

| Feature | Windows | Linux/macOS | Stability | Touches live Desktop state |
|---|---|---|---|---|
| File-drop handoff | ✅ | ✅ | Stable | No |
| Reply viewer | ✅ | ✅ (needs bash ≥ 4 + GNU coreutils/findutils) | Stable | No |
| Session inspector / thread locator / snapshot | ✅ | ✅ (needs Node.js with `node:sqlite` support: ≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`) | Stable, read-only | No (read-only) |
| Desktop named-pipe IPC (`--ipc`) | ✅ | ❌ (Windows pipe path) | **Experimental** | Yes (starts a real turn) |
| `codex://` autoload + focus restore | ✅ (PowerShell) | ❌ | **Experimental** | Yes (loads a thread in the app) |
| Headless `codex exec` (`--exec`) | ✅ | ✅ (needs Codex CLI) | Optional | No GUI effect (rollout only) |

## Safety model

- Explicit target UUID required for any live Desktop send; no heuristic target selection, ever.
- Dry-run is the default for the IPC client, probes, and write-proof harness; live writes require
  `--send --ack-live-write` (plus `--allow-any-thread` unless the target equals your own
  `CODEX_IPC_AUTHORIZED_TEST_THREAD`). **No authorized thread id ships with the code.**
- File-drop fallback is written before any live attempt and preserved in every outcome.
- All SQLite access is `readOnly:true`; nothing writes Codex config/account/plugin/archive state;
  no HTTP listener; no broad `allowed-tools` in the skill.
- Transcript path disclosure is opt-in (`CODEX_IPC_INCLUDE_TRANSCRIPT=1`).

Full threat model: [SECURITY.md](SECURITY.md).

## Failure modes

- `--ipc` reports exactly one of `gui-delivered` / `gui-unowned` / `failed-closed`, always with
  the file-drop pickup line preserved. `failed-closed` prints the client's real diagnostics.
- Mid-turn sends can be silently dropped by the Desktop router even when it reports success —
  the skill's rule is to inspect first and re-inspect after sending when delivery matters.
- Missing `node:sqlite` fails with a clear error naming the requirement; file-drop still works.
- The reply viewer fails closed (exit 1) on malformed input or enumeration failure rather than
  reporting a false "0 replies".

More: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Testing

Hermetic test harnesses (no Codex Desktop, no Claude state, no network; live delivery is stubbed):

```bash
bash tests/test_ipc.sh
bash tests/test_reply_view.sh
```

CI runs the same tests plus syntax checks (`bash -n`, `node --check`) and public-safety grep scans
on ubuntu and windows runners: [.github/workflows/test.yml](.github/workflows/test.yml).

## Known limitations

- The live Desktop route is Windows-only and version-fragile by nature (private internals).
- GUI delivery cannot set a thread's model/reasoning effort; those are renderer-controlled.
- Retention pruning is opportunistic (runs on the next dispatch), not a scheduled sweep.
- The reply channel trusts the local machine: any same-user process can read/write the envelope
  files.
- `codex exec` handoffs never appear in the Desktop GUI (separate storage).

## Release status

**Pre-release. Blockers before any public publication:**

1. **License not chosen** — [LICENSE.md](LICENSE.md) is a placeholder; `plugin.json` says
   `UNLICENSED`.
2. Maintainer identity/repository URL are `<TODO>` placeholders in
   [.claude-plugin/plugin.json](.claude-plugin/plugin.json).
3. Live Desktop IPC is point-in-time validated only (2026-07-08; see "Status of the two halves")
   and rides private Codex Desktop internals — re-run `codex_ipc_revalidate.mjs` before each
   release and after any Codex Desktop update. `restore-if-known` and bounded rollout observation
   remain unimplemented/experimental.
