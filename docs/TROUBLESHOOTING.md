# Troubleshooting

Skill-bundled quick reference:
[skills/ipc/references/troubleshooting.md](../skills/ipc/references/troubleshooting.md). This page
adds repo/install-level triage.

## Install issues

| Symptom | Cause / fix |
|---|---|
| `install.sh: refusing to overwrite existing install` | An `ipc` skill already exists at the target. Force replacement removes the entire existing target and provides no automatic backup or rollback. Run dry-run first and follow the preservation procedure in [INSTALL.md](INSTALL.md). |
| Installed but `/ipc` not found | Standalone target must be exactly `~/.claude/skills/ipc/` (or `%USERPROFILE%\.claude\skills\ipc\`). For plugin installs the invocation is `/codex-ipc:ipc`. Restart/reload Claude Code after installing. |
| Scripts fail with `\r: command not found` | CRLF line endings were introduced (editor or git config). The repo's `.gitattributes` forces LF for `*.sh`/`*.mjs`; re-checkout or `dos2unix` the scripts. |
| `Permission denied` running `.sh` | `bash path/to/script.sh` works regardless of the execute bit; or `chmod +x` the scripts. |

Before force replacement, run the matching preview: `./install.sh --dry-run --force` or `.\install.ps1 -DryRun -Force`.

## Runtime issues

| Symptom | Cause / fix |
|---|---|
| `node:sqlite is unavailable` | Inspection tools need Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`). Upgrade Node, or skip inspection — file-drop works without it. |
| `ERROR: --app/--open/--exec was removed in v0.1.8` | These CLI-backed modes were removed. Use the default file-drop handoff, or `--ipc <conversationId>` for live delivery — neither invokes the Codex CLI. |
| `mapfile: command not found` | The reply viewer needs bash ≥ 4; stock macOS bash is 3.2. `brew install bash` and run the script with the newer bash. |
| `reason=intended-host-not-running` | The read-only inventory did not find exactly one intended GUI host. The follower client did not run. Start or select the intended host outside this tool, or use the printed file-drop line there. |
| `reason=host-inventory-incomplete` / `other-desktop-host-running` | Identity evidence was unreadable, mixed, or duplicated. Close the unintended GUI host or restore readable process/package evidence; do not bypass the gate. |
| Helper reports `foreground-alternate-host` | A readable foreground `Codex` or `ChatGPT` executable did not match the intended host inventory. The helper refuses immediately under every foreground policy; inspect the current hosts and do not retry or bypass the gate. |
| The thread appears to belong to the wrong Desktop host | Treat that as a hypothesis, not a conclusion from diagnostics. Re-inspect the exact target and local state. The operator closes the wrong host and performs pickup in the intended host; opening the thread there only establishes a follower, and Retry creates another rollout page. Do not automate host lifecycle or resend from symptoms alone. |
| `reason=target-non-root` | The pre-send inspector found sub-agent, guardian-review, or other child evidence. It retains the envelope but prints no pickup or WAIT. `Target parent thread:` is guidance for a new root-target inspection, not permission to paste or retarget the refused envelope. |
| `reason=target-model-empty` | The stored thread model is null, empty, or whitespace. No send was attempted and the toolkit does not repair settings. Select a healthy root thread or repair the target in its intended Desktop host, then issue a new dispatch. |
| `reason=target-inspection-ambiguous` | Target existence, identity, archive state, root classification, or model safety could not be established from one trusted read-only snapshot. No send was attempted. Inspect the target; do not bypass or treat locator hints as authority. |
| Client says `--model/--effort require --ack-thread-settings-change` | Those direct-client values persist as stored-thread settings. Supply the acknowledgement only when the operator explicitly intends the change. Values empty after trimming are always rejected. The maintained wrapper omits both fields. |
| Goal-driven target already has an unfinished goal | Leave `--request-goal` off. Run `handoff_to_codex.sh --ipc <uuid> --deliver manual -- "<task>"` and have the operator paste its pickup line into the intended thread. A closed turn is not a prerequisite; expect `pending` until the named dispatch has its own completion evidence. Never call `turn/interrupt` or resend merely to manufacture an idle gap. |
| `--ipc` → `failed-closed` with pipe/connect errors | The host gate passed, but the private router attempt failed or drifted. Run `codex_ipc_revalidate.mjs`; suspect drift before suspecting the target. This is post-attempt ambiguity, so do not resend. |
| `reason=autoload-disabled` / `protocol-host-not-package` | Guarded recovery stopped because activation is off (the default), or the intended host is alternate and therefore never package-activated. The category does not independently prove current ownership. Use the printed file-drop line in the intended host. |
| `reason=autoload-policy-refused` | The helper's fresh activation gate refused. Current real-machine readers do not qualify package-update clearance or the effective protocol handler, so this is the expected result for an unowned real package thread even with `--autoload codex-uri`. Revalidation or historical proof does not override it. |
| `--ipc` → `gui-unowned` repeatedly | Neither `gui-unowned` nor `confirmation=not-attempted` alone authorizes pickup or retry. Pickup needs eligible target inspection and non-admission; eligible-target host refusals and exact no-client recovery retain the printed safe line. Confirm current target/host state before using it. Do not open the protocol URI manually to bypass the policy. |
| Early invalid foreground policy, missing switch acknowledgement, or `node-unavailable`; missing/archived/child/empty-model/ambiguous target | The envelope is retained without pickup or WAIT. Correct preparation and rerun inspection against a safe root target. Do not paste the refused envelope or edit its pickup to name another thread. |
| `confirmation=rollout-hit` | The exact dispatch pickup was observed in a rollout user message. This confirms admission only; inspect completion/reply state separately. |
| `confirmation=rollout-pending` | At least one authoritative rollout candidate was readable/parseable, but no pickup was observed within the bounded budget. Do not infer non-delivery or resend automatically; inspect current thread state first. |
| `confirmation=rollout-unavailable` | Observation could not make a determination because no authoritative candidate was usable or ambiguity/schema drift intervened. The accepted send remains `gui-delivered`; inspect current state without automatic resend. |
| Reply view shows `source=rollout-fallback` | The primary reply file was absent or unreadable at check time, so the viewer selected an exactly correlated completed rollout body. The two source bodies are not assumed equal; fallback is stdout-only. |
| Reply view shows `source=none` | Neither source yielded content. Use the visible `pending`, `unavailable`, `ambiguous`, or `unparseable` reason; no cache or reply file is synthesized. |
| Reply viewer exit 2 | No session id resolvable. Pass `--session <sid>` (the printed listing shows what exists). |
| Reply viewer exit 1 on `--since` | Malformed `find -newermt` spec — the viewer fails closed rather than reporting a false "0 replies". |
| Old envelopes disappeared | Retention pruning ran on a later dispatch. As of v0.1.8 pruning is OFF by default (`CODEX_IPC_RETENTION_DAYS` unset/empty/`0` = keep-only); it deletes only if you set an explicit positive integer. |
| Reply file never written (permission/sandbox denial) | Expected only when the separate reply-write attempt actually returns a permission/sandbox error. The producer first completes and inspects the full result, then attempts the reply write exactly once as a separate final action. A calculation, command-construction, or parse failure is not a denied write and must be reported as its actual failure. On an actual denial, the producer states it accurately and retains the full substantive result in the final agent message. On a known-UUID `--ipc` dispatch, `codex_ipc_wait --accept-rollout-fallback` certifies named-dispatch completion and `replySource=rollout-fallback` but intentionally emits no body; retrieve and render the body with the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer. Display is capped at 4096 bytes by default; if truncation is reported, rerun with a sufficient `--max-bytes`. Flagless/filedrop do not auto-recover. The inspector's stored `sandboxPolicy`/`approvalMode` are advisory only (`permissionProfileAdvisory`) and never predict reply-writability. |

## Sandboxed thread rollout fallback

Thread-bound manual preparation keeps the ordinary UUID/reply correlation without contacting the
Desktop pipe or PowerShell:

```bash
skills/ipc/scripts/handoff_to_codex.sh --ipc <uuid> --deliver manual -- "<task>"
```

Paste the printed pickup and run the printed `WAIT:` command. When the reply file is absent but the
named dispatch has a certifiable final message, the waiter returns `done` with
`replySource=rollout-fallback`; render it with
`skills/ipc/scripts/codex_ipc_replies.sh --session <sid> -c <uuid> --rollout-path <inspector-page>`.
The public root remains `~/.claude/ipc`. Pointing `CODEX_IPC_ROOT` at a directory the target can
write is an operator configuration choice, and every participant must use that same explicit root;
the tool never hard-codes a replacement or predicts writability from stored sandbox settings.

## Completion / wait triage (`codex_ipc_wait`)

`codex_ipc_wait` prints exactly one of six tokens on stdout: `done`, `aborted`, `superseded`,
`reply-missing`, `pending`, `unavailable`. A bounded wait is
`node skills/ipc/scripts/codex_ipc_wait.mjs --thread <uuid> --dispatch <dispatchId> --reply-path
<path> --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000`. `done` certifies the
**named dispatch's own turn**, never current thread idleness. Flagless (no
`--accept-rollout-fallback`) is the legacy file-primary contract. Exit-code-driven callers may add
the opt-in `--status-exit-codes` (`done=0`, `pending=2`, `aborted=3`, `superseded=4`,
`reply-missing=5`, `unavailable=6`; usage errors stay exit 1 with no token); without it every
determination exits 0.

| Token | Cause / remediation |
|---|---|
| `done` | The named dispatch's own turn reached `task_complete`. This is named-dispatch lifecycle completion, NOT proof the thread is idle now, the reply path exists, or the substantive result satisfies the task. Source-aware callers read `replySource` / the `reply-source` diagnostic, open the dual-source viewer, and inspect the returned body against the task's done-criteria. |
| `pending` | No determination yet (single-shot, or budget expired with the turn still open). Wait longer or re-inspect; do not resend. |
| `reply-missing` | Only a genuinely absent reply is eligible for waiter rollout fallback. A present-but-invalid reply returns `reply-missing` without consulting rollout fallback. An absent reply with no certifiable rollout body exhausts the eligible sources. Inspect its diagnostics/thread; do not re-harvest, auto-resend, or hand-roll rollout/report-file polling. resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker. |
| `aborted` | The dispatch's own turn ended in `turn_aborted` (any reply is unverified). Surface it; do not wait. resuming the goal in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification requires a NEW dispatch with a new marker. |
| `superseded` | A newer `task_started` opened before the dispatch turn's terminal. A later, unrelated terminal never certifies it; issue a NEW dispatch if the goal still matters. |
| `unavailable` | No authoritative rollout candidate, or rollout/reply-scan ambiguity / schema failure. Re-inspect the thread; never infer non-delivery or auto-resend. Also returned whenever the turn boundary machine did not mark the turn `closed`, even if a terminal record is present: a turn whose integrity the machine could not establish is never certified. |

## Rollout diagnostics you may see

The waiter emits detail as `WAIT_DIAGNOSTIC` on stderr; the harvester emits
`ROLLOUT_DIAGNOSTIC`. The reply viewer forwards the two named diagnostics below. These are
correlated facts, not proof of host ownership or permission to retry.

| Diagnostic | Meaning |
|---|---|
| `turn-error` | The dispatch's own `task_complete` or `turn_aborted` ended with no assistant output. For `task_complete`, only `error.message` may appear, capped at 512 UTF-8 bytes; sibling fields are discarded. Abort carries no excerpt. The fact does not add a waiter token or change source selection. |
| `turn-model-state` | The latest matching `turn_context` before the terminal reported `empty`, `null`, or `invalid` model state. Raw values and unrelated turns are never included. Missing or valid nonempty model state emits no diagnostic. |
| `unknown-item-class` | An `item_completed` wrapper named an item class outside the reader's dated named set. Informational only: the record is inert, the turn is unaffected, and the class is named in `itemType`. Report it so the census can be re-derived; the named set is pinned to a corpus census re-derived at each release cut. |
| `schema-drift` with an `itemType` | One of three things about an unnamed item class: it carried a body- or role-bearing field (`content`, `text`, `phase`, `role`); the record's outer turn/thread identity was invalid; or the class is only a case or separator variant of a named one (`agent_message` for `AgentMessage`), which is a producer mis-spelling rather than a new class. In each case the reader could not rule out an unread body or speaker, so it fails the turn closed by design. |
| `schema-drift` with `itemType` `null` | The `item_completed` wrapper named no item class at all, or named one that was not a string. This is a missing class, not an unknown one: there is no name to log, so it can never be admitted as inert. Fails the turn closed by design. |
| `unknown-envelope-type` | A top-level record named an envelope type outside the reader's dated named set and declared no `payload.type`. Informational only: the record is inert, the turn is unaffected, and the type is named in `envelopeType`. It is emitted once per occurrence, so the diagnostics carry the count. Report it so the census can be re-derived; the named set is pinned to a corpus census re-derived at each release cut. |
| `schema-drift` whose `envelopeType` is outside the named set | An unnamed top-level envelope that could not be admitted as inert: it declared a `payload.type`, which makes it an unknown envelope/payload **pair** rather than an unknown envelope; or it carried a `payload.item`; or its payload was present but was not a plain object; or the payload carried `content`, `text`, `message`, `last_agent_message`, `phase` or `role`; or the record's owner identity was invalid. In each case the reader could not rule out an unread body or speaker, so it fails the turn closed by design. A record whose top-level `type` is missing or not a string reports `envelopeType` `null` and fails closed for the same reason as a missing item class: there is no name to log. |
| `terminal-copy-disambiguated` | The turn carried more than one distinct final body and the non-empty `task_complete.last_agent_message` matched exactly one of them, which was served. `finalMessageCount` reports the true number of distinct finals. This is disclosure on a certifying path, not a failure; it carries no body text. |
| `multiple-final-message-bodies` | Distinct final bodies that the terminal copy could **not** resolve. The turn refuses. |

Path aliases are deliberately narrow: inspector accepts `CODEX_IPC_SESSIONS_ROOT`; waiter accepts
that alias plus `CODEX_IPC_ROLLOUT_PATH`; observer accepts both aliases and explicit
`--sessions-root`/`--rollout-path`; harvester retains both aliases. A corresponding explicit flag wins over a
nonempty environment value, then the existing default/discovery applies. `CODEX_HOME` is not an
alias. The locator's `--since-*` filters are discovery aids over current timestamps; reset/revert
can make an older thread match, so inspect the selected target before any delivery.

For an explicit page outside the default sessions tree, supply its complete containing sessions
root, not just its date directory. Observer/waiter take `--sessions-root`; set
`CODEX_IPC_SESSIONS_ROOT` for inspector/harvester/viewer. The wrapper passes inspector
`rollout.sessionsRoot` to the observer and printed WAIT. A page path alone cannot establish the
scope needed to discover successors across dates, so an omitted or mismatched root refuses
certification.

Forked threads whose first record carries `forked_from_id` with no
`subagent_history_start_ordinal` and no top-level `ordinal` are read as ordinary rollouts. If such
a thread previously returned `rollout-unavailable` from the observer, `unavailable` from the waiter
and harvester, and a non-overridable `ambiguous` from the write-proof preflight, that is the
behaviour this release changes; re-run the read rather than resending.

## Test issues

| Symptom | Cause / fix |
|---|---|
| `tests/test_ipc.sh` fails at git-dependent checks | The harness creates its own throwaway repo; it needs `git` on PATH (identity is set locally by the harness). |
| Tests pass locally, CI safety scan fails | You introduced a private-looking pattern (personal path, real-looking UUID, key-like string). See `tests/scan_public_safety.sh` for the exact patterns. |
| `test_reply_view.sh` T12 fails on macOS | The viewer and harness assume GNU `find`/`date`. Run in a GNU userland (Linux CI image or Git Bash). |

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

## After a Codex Desktop update

1. `node skills/ipc/scripts/codex_ipc_revalidate.mjs --thread <conversation-id>` (validate-only).
2. Inspect `checks.hostPolicy`: it is the current send-eligibility authority. A refusal suppresses
   the optional live read. If it passes and drift is suspected, `--allow-live-ipc-read --timeout-ms
   1500` re-proves router framing (sends `initialize` only).
3. Only with explicit operator approval: controlled live re-proof via
   `codex_ipc_write_proof.mjs --thread <id> --marker <unique> --send --ack-live-write
   --allow-any-thread` against a thread you own.
4. `desktopVersionHint` is diagnostic only; it does not grant host or activation eligibility.
   Check **host identity** explicitly: an update may change the GUI process/executable name
   without changing the package family. Known case (2026-07-09): the GUI became `ChatGPT.exe`
   under the unchanged `OpenAI.Codex` package family, which broke name-only foreground
   detection until the identity check became path/package based. `revalidate`'s
   `desktopVersionHint` reports the package identity and the positively-identified GUI
   (`guiIdentified:false` means the GUI could not be identified — treat foreground safety as
   unproven, keep to file-drop, and run the hermetic matrix `tests/test_autoload_matrix.sh`). Even a
   green revalidation or controlled write proof does not qualify package-update clearance or the
   effective protocol handler for activation.
