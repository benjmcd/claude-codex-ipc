# Compatibility matrix

Per-feature support, dependencies, stability, live-state impact, and fallback behavior.

"Experimental" means: built on undocumented Codex Desktop internals (named pipe framing, router
methods, `codex://` deep links, window focus APIs) that can change or break in **any** Codex
Desktop update, silently. Revalidate experimental features with
`codex_ipc_revalidate.mjs` after every update; escalate to a controlled
`codex_ipc_write_proof.mjs` re-proof only with explicit operator approval.

## File-drop handoff (`handoff_to_codex.sh`, default mode)

| | |
|---|---|
| Supported OS | Windows (Git Bash/MSYS/WSL), Linux, macOS |
| Dependencies | bash, coreutils (`find`, `mktemp`, `od` or `$RANDOM` fallback); git optional (payload enrichment only); `cygpath` optional (sed fallback) |
| Stability | **Stable core** |
| Touches live Desktop state | No |
| Fallback | Is itself the fallback for every other route |

## Reply viewer (`codex_ipc_replies.sh`)

| | |
|---|---|
| Supported OS | Windows (Git Bash/MSYS/WSL), Linux, macOS |
| Dependencies | bash ≥ 4 (macOS ships bash 3.2 — `brew install bash`), GNU `find`/`sort`/`stat`/`date` (GNU coreutils; on macOS install `findutils`/`coreutils` or run in a GNU userland) |
| Stability | **Stable**, read-only by contract (never writes/locks/creates) |
| Touches live Desktop state | No |
| Fallback | Read the per-dispatch `*.reply.md` files directly |

## Session inspector (`codex_ipc_session_inspect.mjs`)

| | |
|---|---|
| Supported OS | Anywhere Codex Desktop state exists locally (typically Windows/macOS) |
| Dependencies | Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`); local `~/.codex/state_5.sqlite` + `~/.codex/sessions/` |
| Stability | Stable, read-only (`readOnly:true`); schema-tolerant column selection, but the Desktop schema itself may drift |
| Touches live Desktop state | No (read-only) |
| Fallback | Clear runtime error if `node:sqlite` is missing; file-drop continues to work |

## Thread locator (`codex_ipc_thread_locator.mjs`)

Same row as the session inspector (same dependencies/stability). Output is candidate discovery
only — never send authority.

## Snapshot / isolation compare (`codex_ipc_snapshot.mjs`)

Same dependencies as the inspector for snapshot mode; `--compare` mode is pure JSON and needs no
`node:sqlite`. Read-only.

## Desktop named-pipe IPC (`--ipc`, `codex_ipc_client.mjs`, probes)

| | |
|---|---|
| Supported OS | **Windows only** (`\\.\pipe\codex-ipc`) |
| Dependencies | Node.js; Codex Desktop running; private router protocol (`initialize`, `thread-follower-start-turn`, uint32le framing) |
| Stability | **Experimental** — private internals; assume broken after any Desktop update until revalidated |
| Touches live Desktop state | **Yes** — a live send starts a real model turn in the target thread |
| Fallback | File-drop is written first and its pickup line is printed in every outcome |

## `codex://` autoload + PowerShell focus restore (`codex_ipc_autoload.ps1`)

| | |
|---|---|
| Supported OS | **Windows only** |
| Dependencies | `powershell.exe`, Win32 foreground-window APIs, Codex Desktop's `codex://` protocol handler |
| Stability | **Experimental** — UX-level automation over private behavior; foreground-policy-aware (default `defer` never navigates the visible Codex app; `switch` requires explicit acknowledgement; `restore-if-known` fail-closed; unidentifiable foreground defers). Foreground identity is positive (process name + `WindowsApps\OpenAI.Codex_*` executable path), covering the pre-merge `Codex.exe` GUI and the post-2026-07-09 `ChatGPT.exe` GUI; an ambiguous `ChatGPT`-named foreground (unreadable path) is gated as Codex and defers. Hermetic behavioral matrix: `tests/test_autoload_matrix.sh` |
| Exit codes | `0` deep-link done (or dry-run), `1` focus restore unverified, `2` deferred, `4` restore unproven, `5` switch unacknowledged — wrapper maps all; unknown codes fail closed |
| Touches live Desktop state | Yes — loads the target thread (background window on the default path; the VISIBLE window under authorized `switch` — disclosed residue) |
| Fallback | Wrapper reports `gui-unowned`/`failed-closed` with reason token, manual `codex://threads/<id>` remediation + file-drop line |

## Headless exec (`--exec`)

| | |
|---|---|
| Supported OS | Wherever the Codex CLI runs |
| Dependencies | `codex` CLI on PATH; optional `CODEX_MODEL` / `CODEX_REASONING_EFFORT` pins (passed only when set) |
| Stability | Optional; depends on the public-ish `codex exec` CLI surface |
| Touches live Desktop state | No GUI effect — writes rollout JSONL only, invisible to the Desktop app |
| Fallback | File-drop |

## Validation tooling (`codex_ipc_revalidate.mjs`, `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`)

| | |
|---|---|
| Supported OS | Audit: anywhere Node runs. Revalidate/write-proof: Windows for the pipe/Desktop checks (non-Windows runs report those checks as failed/skipped) |
| Dependencies | Node.js; write-proof additionally needs the inspector chain (`node:sqlite`) and, for the live path, a running Codex Desktop |
| Stability | Stable tooling around experimental surfaces; write-proof live path is gated (`--send --ack-live-write [--allow-any-thread]`) and dry-run by default |
| Touches live Desktop state | Only the write-proof **live** path (one marker turn); everything else read-only |
| Fallback | Dry-run/static modes always available |

## Host-identity ledger

Observed Codex Desktop host-identity changes that affect foreground detection and validation.
"Codex Desktop" remains this project's stable label for the app hosting the private IPC surfaces,
whatever its current product branding.

| Date | Observed change | IPC consequence |
|---|---|---|
| 2026-07-09 | GUI executable renamed `Codex.exe` → `ChatGPT.exe` ("ChatGPT desktop app, Codex mode"); package family unchanged (`OpenAI.Codex_2p2nqsd0c76g0`, observed at 26.707.3563.0); headless `resources\codex.exe` child unchanged; `codex://`, `\\.\pipe\codex-ipc`, router methods, and `~/.codex` state all unchanged | Name-only foreground detection failed open; fixed by positive path/package identity in `codex_ipc_autoload.ps1` (fail-closed on ambiguity) and a package-based `desktopVersionHint` in `codex_ipc_revalidate.mjs`. Transport unchanged — no client/pipe/scheme changes needed |
| 2026-07-09 (build 26.707.3748.0) | Desktop now applies a **managed restricted permission profile to IPC-injected follower turns** regardless of thread or global `danger-full-access`/`approval_policy=never` settings: read-anywhere, write only to the thread workspace + its visualizations dir, network off, commands run as the `codexsandboxoffline` sandbox user. Verified on both the auto-loaded and renderer-owned delivery paths (three probe turns, two threads); a pre-merge 2026-07-08 follower turn on the same machine ran `danger-full-access`, so this is new app-side hardening, not thread state. Thread `approval_policy` is still honored: `never` → no prompts, out-of-profile commands hard-fail; `on-request` → operator sees approval prompts | Task delivery, in-workspace execution, and chat replies are unaffected. The **reply-file leg breaks** when `~/.claude/ipc` is outside the thread workspace: `Set-Content` fails (access denied) on `never` threads, or requires manual operator approval on `on-request` threads. Mitigations: harvest replies read-only from the thread rollout (Claude-side), or use threads whose workspace covers the transport root. `/ipc` MUST NOT try to defeat the sandbox — it is the app's own policy for external clients |

### Verified live write-proof entries

| Date | Build proven | What was proven | Notes |
|---|---|---|---|
| 2026-07-09 | `OpenAI.Codex 26.707.3748.0` (post-merge, post-update), codex-ipc v0.1.2 | Operator-approved single-marker proof against an operator-designated idle thread: validate-only revalidation green; initialize-only router re-proof (uint32le framing, response received); live defer-while-foreground observed on the real code path (merged-host identity, exit 2, nothing fired); wrapper `--ipc` delivery on an unowned thread — `no-client-found` → `codex://` auto-load + focus snapback → `RESULT: gui-delivered -- reason=auto-loaded`; marker task confirmed in the correct thread's rollout, agent echoed the marker verbatim, `task_complete` logged, reply file written back through the correlation channel | `codex_ipc_write_proof.mjs` sends over the pipe directly and has **no unowned-thread auto-load recovery**: on an unloaded thread it fails closed at `no-client-found` (nothing delivered — verified). Load the thread first (wrapper auto-load or manual `codex://threads/<id>`), or use the wrapper for the delivery leg |
