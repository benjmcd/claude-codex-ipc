# Compatibility matrix

Per-feature support, dependencies, stability, live-state impact, and fallback behavior.

## Current feature matrix

Current-host confidence requires validate-only revalidation; live proof remains separately authorized.

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
| Dependencies | bash ≥ 4 (macOS ships bash 3.2 — `brew install bash`), GNU `find`/`sort`/`stat`/`date` (GNU coreutils; on macOS install `findutils`/`coreutils` or run in a GNU userland); Node.js is optional for rollout-derived fallback, while primary reply-file viewing remains available without it |
| Stability | **Stable**, read-only by contract (never writes/locks/creates) |
| Touches live Desktop state | No |
| Source precedence | A readable regular non-symlink per-dispatch `*.reply.md` is primary; only when it is absent or unreadable may an exactly correlated completed rollout provide stdout-only fallback; otherwise `source=none` is visible |

Rollout observation/fallback requires the requested thread ID to own the selected physical rollout.
If Desktop remaps that target ID to a differently owned physical rollout, the tools return
`unavailable` rather than infer an untrusted alias. File-primary replies and the preserved file-drop
envelope remain available.

## Session inspector (`codex_ipc_session_inspect.mjs`)

| | |
|---|---|
| Supported OS | Anywhere Codex Desktop state exists locally (typically Windows/macOS) |
| Dependencies | Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`); local `~/.codex/state_5.sqlite` + `~/.codex/sessions/` |
| Stability | Stable, read-only (`readOnly:true`); schema-tolerant column selection, but the Desktop schema itself may drift |
| Touches live Desktop state | No (read-only) |
| Fallback | Clear runtime error if `node:sqlite` is missing; file-drop continues to work |

## Rollout reader (`codex_ipc_rollout_reader.mjs`) — producer-format coupling

The reader parses a file format the Codex app owns and changes without notice, so its tolerance to
producer drift is itself a compatibility surface:

| Producer shape | Reader behaviour |
|---|---|
| `item_completed` wrapper, item class in the named set | Parsed. `AgentMessage`/`UserMessage` are promoted to their semantic types; every other named class is lifecycle-inert. The named set is pinned to a corpus census re-derived at each release cut, so it is a dated observation, not a permanent grammar. `FunctionCallOutput` (written whenever a thread uses the app's own thread-delegation tool) and `Plan` are named explicitly. |
| `item_completed` wrapper, unnamed item class, no body/role field | **Inert but logged.** Not promoted, no text/phase/role exposed, not retained for correlation, turn unaffected; an `unknown-item-class` diagnostic names the class. A newly introduced item class therefore does not break existing threads. |
| `item_completed` wrapper, unnamed item class carrying `content`, `text`, `phase` or `role`, or with invalid outer identity | Fails closed as `schema-drift`, now naming the class in `itemType`. The reader will not certify a turn containing a record that might hold an unread body or speaker. |
| `item_completed` wrapper with **no** item class, or a non-string one | Fails closed as `schema-drift` with `itemType` `null`. A missing class is not an unknown class: an inert admission is acceptable only because it is logged under the class it names, and this record has no name to log. |
| `item_completed` wrapper whose item class is a case or separator variant of a named class (`agent_message`, `agentmessage`, `Command_Execution`) | Fails closed as `schema-drift` naming the variant. The reader's item classes and semantic types differ from each other by exactly case and separator, so a variant spelling is a producer mis-spelling of a known class, not a new one. |
| Fork with `forked_from_id` **and** `subagent_history_start_ordinal` | Full producer-ordinal contract: contiguous ordinals from zero, `event_msg/thread_settings_applied` at the boundary. Any violation fails closed. |
| Fork with `forked_from_id`, no boundary field, no top-level `ordinal` | Read as an unforked rollout, whole file in scope. Both the Codex CLI in use on 2026-09-01 and its successor version have been observed writing this shape; it is the majority shape **among forks** - 1,200 of the 1,390 retained rollout files whose first record is a fork, out of 6,145 retained rollout files in all, measured 2026-09-03T02:42:28Z - so it is a current-producer concern, not a legacy one. |
| Fork declaring a top-level `ordinal` while omitting the boundary field | Fails closed: drift inside the contract's own grammar. |

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
| Fallback | File-drop envelope is written first in every outcome; its pickup line is printed only when structured evidence proves no follower was admitted. `confirmation=not-attempted` does not imply that no router request occurred. After an ambiguous post-attempt result (`confirmation=unknown`) pickup is suppressed — do not resend |

## `codex://` autoload + PowerShell focus restore (`codex_ipc_autoload.ps1`)

| | |
|---|---|
| Supported OS | **Windows only** |
| Dependencies | `powershell.exe`, Win32 foreground-window APIs, Codex Desktop's `codex://` protocol handler |
| Stability | **Experimental** — UX-level automation over private behavior; foreground-policy-aware (default `defer` never navigates the visible Codex app; `switch` requires explicit acknowledgement; `restore-if-known` fail-closed; unidentifiable foreground defers). Foreground identity is positive (process name + `WindowsApps\OpenAI.Codex_*` executable path), covering the pre-merge `Codex.exe` GUI and the post-2026-07-09 `ChatGPT.exe` GUI; an ambiguous `ChatGPT`-named foreground (unreadable path) is gated as Codex and defers. Hermetic behavioral matrix: `tests/test_autoload_matrix.sh` |
| Exit codes | `0` deep-link done (or dry-run), `1` focus restore unverified, `2` deferred, `4` restore unproven, `5` switch unacknowledged — wrapper maps all; unknown codes fail closed |
| Touches live Desktop state | Yes — loads the target thread (background window on the default path; the VISIBLE window under authorized `switch` — disclosed residue) |
| Fallback | Wrapper reports `gui-unowned`/`failed-closed` with reason token and manual `codex://threads/<id>` remediation. The file-drop pickup line is printed only when structured evidence proves no follower was admitted (`confirmation=not-attempted`; an exact `no-client-found` request may still have occurred). A post-autoload retry can end `failed-closed -- reason=retry-ambiguous-outcome -- confirmation=unknown`; there the envelope is preserved but no pickup line is printed — do not resend |

## Removed in v0.1.8: `--app` / `--open` / `--exec`

The CLI-backed modes were removed in v0.1.8 ("No Codex CLI"). The wrapper no longer invokes the
`codex` binary on any path. Use the default file-drop handoff, or `--ipc <conversationId>` for live
Desktop delivery; there is no headless execution path in this tool.

## Validation tooling (`codex_ipc_revalidate.mjs`, `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`)

| | |
|---|---|
| Supported OS | Audit: anywhere Node runs. Revalidate/write-proof: Windows for the pipe/Desktop checks (non-Windows runs report those checks as failed/skipped) |
| Dependencies | Node.js; write-proof additionally needs the inspector chain (`node:sqlite`) and, for the live path, a running Codex Desktop |
| Stability | Stable tooling around experimental surfaces; write-proof live path is gated (`--send --ack-live-write [--allow-any-thread]`) and dry-run by default |
| Touches live Desktop state | Only the write-proof **live** path (one marker turn); everything else read-only |
| Fallback | Dry-run/static modes always available |
| Failure diagnosis | The write-proof receipt projects the router's own follower-response error token as `send.responseError` (`null` when absent) beside `send.responseType`, and the wrapper's failure branches print the router `response` in full. Neither is proof of anything: the router returns the same token for several distinct causes, so treat it as a starting point, not a diagnosis. |

## Dated historical evidence, not current certification

The following rows preserve dated observations and do not certify the current host. Observed Codex
Desktop host-identity changes affect foreground detection and validation.
"Codex Desktop" remains this project's stable label for the app hosting the private IPC surfaces,
whatever its current product branding.

| Date | Observed change | IPC consequence |
|---|---|---|
| 2026-07-09 | GUI executable renamed `Codex.exe` → `ChatGPT.exe` ("ChatGPT desktop app, Codex mode"); package family unchanged (`OpenAI.Codex_2p2nqsd0c76g0`, observed at 26.707.3563.0); headless `resources\codex.exe` child unchanged; `codex://`, `\\.\pipe\codex-ipc`, router methods, and `~/.codex` state all unchanged | Name-only foreground detection failed open; fixed by positive path/package identity in `codex_ipc_autoload.ps1` (fail-closed on ambiguity) and a package-based `desktopVersionHint` in `codex_ipc_revalidate.mjs`. Transport unchanged — no client/pipe/scheme changes needed |
| 2026-07-09 (build 26.707.3748.0) | Managed restriction is **VERIFIED only for the two named `GPT-5.5` probe turns**: the old/restored-thread probe and the sender-labelled owned-thread probe. The universal follower-turn claim is **REFUTED** by same-build `GPT-5.6-sol` full-access pickup turns. The selecting condition is **UNPROVEN**: model, thread settings, and delivery route are confounded, and the rollouts contain no first-class route field | Reply-file write success is governed by the effective per-turn permission profile together with the thread `approval_policy`. In the verified managed turns, `on-request` permitted an approved outside-root write while `never` denied the equivalent write. Do not infer a turn's profile from follower status or route. Reply viewing remains file-primary, with read-only rollout fallback only when the primary is absent or unreadable; `/ipc` does not bypass the effective profile |
| 2026-07-10 (build 26.707.3748.0, controlled probe + storage inspection) | Selecting condition **RESOLVED**: injected follower turns run under the target thread's **stored per-thread agent settings** — the `threads.sandbox_policy` and `threads.approval_mode` columns in `~/.codex/state_5.sqlite` (GUI-controlled, mutable; `managed` policies carry per-thread writable-roots lists — workspace + per-thread visualizations dir, network restricted). Verified across 6 threads/3 model generations/both routes, including a cross cell that refuted the interim model-generation hypothesis (a `GPT-5.6-sol` thread with a then-managed stored policy ran managed; same-model threads with `{"type":"disabled"}` ran full-access). Model and workspace correlations in earlier samples were operator-configuration confounds. Also proven: the router **ignores `turnStartParams.model`** — the effective model is always the thread's (confirms the "renderer-controlled" rule) | **Preflight rule:** read the target thread's `sandbox_policy`/`approval_mode` (read-only, via the session inspector) before delegating — `disabled` ⇒ reply-file writes work anywhere; `managed` ⇒ writes succeed only under the policy's writable roots, or via operator approval when `approval_mode=on-request`. One probe turn also completed with **no output at all** (empty turn straight to `task_complete`) — the reply viewer's `source=none reason=unavailable` case observed live. Harvesting/eligibility stays trigger-agnostic in code regardless |
| 2026-07-12 (v0.1.6 A2 correction — supersedes the 2026-07-10 "Preflight rule" above, which is retained as history) | The stored `threads.sandbox_policy`/`threads.approval_mode` columns are the **stored thread row**, not the **effective next-turn `turn_context.sandbox_policy`**; they may differ from the turn that actually runs, and completion-time re-stamping was **observed evidence, not a stable timing contract**. The earlier "`disabled` ⇒ writes work anywhere / preflight before delegating" wording over-claimed a reliable **reply-write gate** the preflight surfaces cannot authoritatively provide before a turn starts | **Corrected rule:** the inspector now emits `permissionProfileAdvisory:{source:"stored-thread-row",mayDifferFromEffectiveTurn:true,mustNotGateDispatch:true,predictsReplyWritability:false}` alongside `approvalMode`/`sandboxPolicy` (names/values unchanged). Treat those columns as **advisory context only** — never a dispatch gate or reply-writability prediction. A blocked reply write is a **non-event**: the producer puts the full result in its final agent message and the dispatcher recovers it via `codex_ipc_wait --accept-rollout-fallback` (A1), never a policy gate |
| 2026-08-31 (current documentation clarification — supersedes only the recovery wording in the 2026-07-12 row above, which remains historical evidence) | The earlier row compressed waiter certification and body retrieval into one recovery step. The tools keep them separate: `codex_ipc_wait --accept-rollout-fallback` can certify the named dispatch and report `replySource=rollout-fallback`, but intentionally emits no recovered body | **Current rule:** retrieve and render the body with the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer. Display is capped at 4096 bytes by default; if truncation is reported, rerun with a sufficient `--max-bytes`. The producer's one-attempt, no-substitute, no-resend denied-write protocol, delivery/refusal behavior, and waiter/viewer recovery-tool control flow are unchanged; generated payload guidance bytes intentionally change |

### Verified live write-proof entries

| Date | Build proven | What was proven | Notes |
|---|---|---|---|
| 2026-07-09 | `OpenAI.Codex 26.707.3748.0` (post-merge, post-update), codex-ipc v0.1.2 | Operator-approved single-marker proof against an operator-designated idle thread: validate-only revalidation green; initialize-only router re-proof (uint32le framing, response received); live defer-while-foreground observed on the real code path (merged-host identity, exit 2, nothing fired); wrapper `--ipc` delivery on an unowned thread — `no-client-found` → `codex://` auto-load + focus snapback → `RESULT: gui-delivered -- reason=auto-loaded`; marker task confirmed in the correct thread's rollout, agent echoed the marker verbatim, `task_complete` logged, reply file written back through the correlation channel | `codex_ipc_write_proof.mjs` sends over the pipe directly and has **no unowned-thread auto-load recovery**: on an unloaded thread it fails closed at `no-client-found` (nothing delivered — verified). Load the thread first (wrapper auto-load or manual `codex://threads/<id>`), or use the wrapper for the delivery leg |
