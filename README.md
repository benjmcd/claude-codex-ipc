# claude-codex-ipc

Controlled Claude Code → Codex handoff. Stable core: file-backed dispatch/reply correlation.
Optional extra: guarded, experimental delivery straight into a Codex Desktop GUI thread.
Ships as a Claude Code plugin (`codex-ipc`) with one skill (`ipc`); also installs standalone.

**Is:** per-dispatch task/reply files keyed by `(session, conversation, dispatch)` — isolated and
correlated by construction; a read-only, file-primary reply viewer with rollout-derived fallback;
read-only Codex state inspection; an explicit-UUID-only live delivery route with dry-run-first
tooling and revalidation harnesses.

**Is NOT:** not MCP; not an official OpenAI API (the Desktop route rides undocumented private
internals — unaffiliated with OpenAI); not a production message broker (plaintext files + a local
pipe; no queueing guarantees, no multi-user security model).

| | Stable core | Experimental extras |
|---|---|---|
| What | File-backed dispatch/reply, reply viewer, read-only inspection | Desktop named-pipe injection, `codex://` autoload, focus snapback |
| Depends on | bash, coreutils (Node optional for rollout fallback/inspection) | Private Codex Desktop internals, Windows, PowerShell |
| After a Codex Desktop update | Unaffected | **Assume broken until revalidated** (`codex_ipc_revalidate.mjs`) |

Live Desktop IPC was point-in-time validated (2026-07-08: write-proof harness, `defer` and
`switch`+ack paths, reply loop). `restore-if-known` is fail-closed/unvalidated. Revalidate on your
own machine before relying on it, and after every Codex Desktop update.

## Install

```bash
claude plugin add /path/to/claude-codex-ipc   # plugin → invoke as /codex-ipc:ipc
./install.sh --dry-run && ./install.sh        # standalone → invoke as /ipc  (PowerShell: .\install.ps1)
```

Details, uninstall, Windows notes: [docs/INSTALL.md](docs/INSTALL.md).

## Quickstart

```bash
# 1. File-drop (stable): paste the printed pickup line into your Codex session
skills/ipc/scripts/handoff_to_codex.sh "review src/parser.js for edge cases"

# 2. Live Desktop delivery (experimental): explicit UUID only — inspect first, then send
node skills/ipc/scripts/codex_ipc_session_inspect.mjs --thread <conversation-id> --tail-events 20
skills/ipc/scripts/handoff_to_codex.sh --ipc <conversation-id> "run the failing test and fix it"

# 3. Replies (read-only, newest first)
skills/ipc/scripts/codex_ipc_replies.sh

# 4. Wait for a NAMED dispatch to complete (bounded; opt-in rollout fallback)
node skills/ipc/scripts/codex_ipc_wait.mjs --thread <conversation-id> --dispatch <dispatchId> \
  --reply-path <printed .reply.md path> --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000
```

`codex_ipc_wait` prints exactly one of six tokens on stdout — `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. `done` certifies that the **named dispatch's own turn**
completed; it is never proof that the thread is idle now. With `--accept-rollout-fallback`,
`reply-missing` means the waiter already exhausted **both** body sources (reply file and rollout
store): inspect its diagnostics/thread rather than re-harvesting or hand-rolling a poll. On
`reply-missing`/`aborted`:
resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker.
After an accepted live `--ipc` send the wrapper prints a ready-to-run `WAIT:` line before its final
`RESULT:` line. Flagless (no `--accept-rollout-fallback`) is the legacy file-primary contract.

The wrapper always writes the file-drop **envelope** before any live attempt. The **pickup line** is
printed only when the failure is proven pre-send; after an ambiguous post-attempt result
(`confirmation=unknown`) the envelope is preserved but pickup is suppressed, because the turn may
already have been admitted and resending would duplicate it. Live results are machine-parseable:
`RESULT: gui-delivered|gui-unowned|failed-closed -- reason=<token> -- confirmation=<token>`.
After an accepted live send, confirmation is `rollout-hit` (the exact dispatch task basename was
observed in a rollout user message), `rollout-pending` (at least one authoritative candidate was
readable/parseable, but no pickup was observed within the bounded budget), or
`rollout-unavailable` (observation could not make a determination). These tokens
confirm at most rollout admission; they do not confirm completion or reply-file success, and
pending/unavailable do not trigger an automatic resend.
The reply viewer selects a readable regular non-symlink `.reply.md` as `source=reply-file`
before considering an exactly correlated completed rollout as `source=rollout-fallback`.
Fallback is stdout-only; it does not create a cache or reconstruct a reply file, and the two source
bodies are not assumed equal.
Foreground-policy grammar and full operational rules: [skills/ipc/SKILL.md](skills/ipc/SKILL.md).

## Configuration (all env vars; none required for file-drop)

| Variable | Default | Effect |
|---|---|---|
| `CODEX_IPC_ROOT` | `~/.claude/ipc` | Transport root for task/reply envelopes |
| `CODEX_IPC_RETENTION_DAYS` | `0` (keep-only) | Unset/empty/`0` never delete; a positive integer prunes envelopes older than N days on next dispatch |
| `CODEX_IPC_INCLUDE_TRANSCRIPT` | unset | `1` includes the Claude transcript path (default: omitted) |
| `CODEX_IPC_AUTHORIZED_TEST_THREAD` | unset | Operator-owned test thread UUID exempt from `--allow-any-thread` |
| `CODEX_IPC_FOREGROUND_POLICY` | `defer` | `--ipc` foreground policy: `defer`\|`switch`\|`restore-if-known` |
| `CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL` | unset | `1` = standing `switch` ack (printed every send; prefer the per-send flag) |
| `CODEX_IPC_POLL_DEADLINE_S` / `_INTERVAL_S` | `30` / `2` | Auto-load retry poll (test knobs) |
| `CODEX_IPC_OBSERVE_BUDGET_MS` | `20000` (measurement-informed) | Hard cap for post-acceptance rollout observation |
| `CODEX_IPC_OBSERVE_INTERVAL_MS` | observer default | Positive observation interval override; invalid values warn and fall back |
| `IPC_TOOLKIT_ROOT` | unset | Manual toolkit-root override (scripts self-locate otherwise) |

## Features / platforms

| Feature | Windows | Linux/macOS | Stability |
|---|---|---|---|
| File-drop handoff | ✅ | ✅ | Stable |
| Reply viewer | ✅ | ✅ (bash ≥ 4 + GNU coreutils; Node optional for rollout fallback) | Stable |
| Inspector / locator / snapshot | ✅ | ✅ (Node with `node:sqlite`, ≥ 22.5) | Stable, read-only |
| Desktop pipe IPC + `codex://` autoload | ✅ | ❌ | **Experimental**, touches live Desktop |

Dependencies and fallbacks per feature: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Safety

Explicit target UUID for every live send — no heuristic targeting, ever. Dry-run by default;
live writes need `--send --ack-live-write` (+`--allow-any-thread`) — except the
`handoff_to_codex.sh --ipc <uuid>` wrapper, where selecting the explicit UUID is itself the
acknowledgement and the wrapper supplies those client flags internally (see SECURITY.md
"Completeness note"); no authorized thread id ships.
All SQLite access `readOnly:true`; no config/account mutation; no HTTP listener; transcript
disclosure opt-in. Threat model: [SECURITY.md](SECURITY.md). Failure triage:
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Testing

```bash
bash tests/test_ipc.sh
bash tests/test_reply_view.sh
bash tests/test_rollout_reader.sh
bash tests/test_reply_harvest.sh   # all hermetic; no Codex/Claude state, no network
```

CI adds syntax checks and public-safety scans on ubuntu + windows:
[.github/workflows/test.yml](.github/workflows/test.yml).

## Limitations

Live route is Windows-only and version-fragile by nature. GUI delivery cannot set a thread's
model/reasoning (renderer-controlled). Envelope files trust the local machine (any same-user
process can read and modify them).

## Status

v0.1.8 · [MIT](LICENSE.md) · [benjmcd/claude-codex-ipc](https://github.com/benjmcd/claude-codex-ipc).
Re-run `codex_ipc_revalidate.mjs` after any Codex Desktop update. The live route and its bounded
rollout observation remain experimental; `restore-if-known` remains fail-closed/unvalidated.
