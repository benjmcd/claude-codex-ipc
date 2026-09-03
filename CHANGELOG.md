# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- IPC send and recovery paths now normalize UUID inputs, classify client and inspector results from
  exact structured fields, and keep ambiguous post-attempt outcomes non-retryable. Negative bounded
  inspection is diagnostic only: it cannot prove non-admission or authorize a resend.
- Rollout-derived observation and completion now bind physical owner/path identity, fork scope,
  consumed cursor bytes/state, semantic roles, dispatch marker, turn, terminal body, and schema
  integrity. Duplicate dispatch IDs, stale or conflicting reply evidence, untrusted target-to-rollout
  remaps, and unsupported pagination/alias ambiguity fail visibly instead of borrowing completion.
  Multiple distinct final records certify only when one nonempty terminal body copy matches exactly
  one final; missing or nonmatching terminal evidence remains unavailable.
- Unknown `item_completed` item classes are now inert but logged instead of poisoning their turn.
  A class outside the named set is never promoted, never exposes text/phase/role, is never retained
  for correlation, and emits an `unknown-item-class` diagnostic naming the class. It still fails
  closed as `schema-drift` when the item itself carries a body- or role-bearing field
  (`content`, `text`, `phase`, `role`) or when the record's outer identity is invalid, and the
  `schema-drift` diagnostic now names the class in `itemType`. `FunctionCallOutput` - written
  whenever a thread uses the app's own thread-delegation tool - and `Plan` are named explicitly in
  the inert set. The named set is pinned to a dated corpus census re-derived at each release cut.
  Previously any such record made its whole turn ambiguous, so an ordinary working thread that had
  delegated could not be observed, waited on, harvested, or dispatched to, despite a real
  `task_complete` carrying a non-empty final body.
- The fork ordinal contract now applies only where the producer declares it. A rollout whose first
  record carries `forked_from_id` with neither `subagent_history_start_ordinal` nor a top-level
  `ordinal` declares no ordinal stream, so it is admitted and read as an unforked rollout. Every
  declared-contract check is unchanged, and a first record declaring an `ordinal` while omitting
  the boundary field still fails closed. **Forked threads were affected, and this is not a
  historical class:** nine such rollouts were written on 2026-09-01 by the Codex CLI then in use, a
  tenth on 2026-09-03 by the successor CLI version, and 1,200 retained rollouts regress under the
  previous behaviour today. For those threads the observer reported `rollout-unavailable`, the
  waiter returned `unavailable` before it could reach an existing reply file, harvest returned
  `unavailable`, and the write-proof preflight returned a non-overridable `ambiguous`.
- A turn the boundary machine did not close can no longer be projected complete or certifiable. The
  dispatch projection now applies the marker proof's own predicate: a snapshot carrying a terminal
  but not `closed` returns unavailable with the snapshot's diagnostics. Previously a malformed line
  arriving while no turn was open opened a turn whose integrity window was too narrow to see that
  parse error, so a turn-less `task_complete` could serve a body as certified while the activity
  projection of the same parse reported `ambiguous`.
- When the terminal body copy resolves several distinct final bodies to one, the resolution is now
  disclosed instead of erased: `finalMessageCount` reports the true number of distinct logical
  finals, and the certifying path emits a `terminal-copy-disambiguated` diagnostic carrying the
  terminal line, the turn id and that count, and no body text. `multiple-final-message-bodies`
  stays reserved for turns that refuse. Selection itself is unchanged.
- The wrapper's live-failure branches now print the router's own response in full instead of the
  first twenty lines of the client document. The client pretty-prints `response` after the echoed
  request, so the previous clip ended inside the request echo and never showed why a send failed.
  The echoed request, which carries the dispatch transport path and task text, is deliberately not
  printed.
- `codex_ipc_write_proof.mjs` now projects the router's structured follower-response error token
  as `send.responseError` (`null` when absent) beside `send.responseType` in the live proof
  receipt. Previously only the harness's 500-character clipped command summary reached the
  receipt, so a router error such as `no-client-found` could be unrecoverable after the fact.
  Diagnostic projection only: send, certification, polling, and no-resend behavior are unchanged.
- These changes are covered by sanitized hermetic tests and offline gates only. No fresh live IPC
  proof, installed-root propagation, release, or deployment is claimed.
- Documentation and repository gates now enforce the UTF-8/LF text policy and documentation
  contracts. Intentional Unicode is retained. Primary dispatch behavior did not change, no fresh
  live proof was performed, and no release or installed propagation is implied.
- Current recovery documentation supersedes older dated shorthand that described a blocked reply
  as recovered through `codex_ipc_wait --accept-rollout-fallback`. The waiter certifies
  named-dispatch completion and `replySource=rollout-fallback` but intentionally emits no body;
  the existing read-only dual-source `scripts/codex_ipc_replies.sh` viewer retrieves and renders
  it. Display is capped at 4096 bytes by default; if truncation is reported, rerun with a
  sufficient `--max-bytes`. The one-attempt, no-substitute, no-resend producer protocol,
  delivery/refusal behavior, and waiter/viewer recovery-tool control flow are unchanged;
  generated payload guidance bytes intentionally change, and older release entries remain as
  historical context.
- Public-readiness hardening makes the repository safety scan fail closed, documents private
  vulnerability reporting, and runs CI with read-only permissions and commit-pinned official
  actions.
- Before public visibility, Git object history and annotated tags were re-created to remove
  personal mailbox metadata. Release names and content intent remain unchanged, but commit and
  tag object IDs necessarily change; private rollback mappings remain outside the public repo.
- The public-safety gate now rejects shallow or empty Git history and requires syntactically valid
  GitHub no-reply formats in raw author, committer, and annotated-tag headers across every
  commit reachable from publishable local/origin branch or tag refs, plus the explicit PR head
  supplied by CI (with GitHub's service identity allowed as a committer only). Provider-generated
  synthetic merge commits are excluded. This is a privacy-format check, not account or commit
  authentication. The repository-only safeguard changes no IPC runtime behavior, supplies no
  fresh live IPC proof, and implies no installed-root propagation.

## [0.1.13] — 2026-08-05

Normal dispatch control flow and operational output did not change; effect-free --version changed to 0.1.13.

### Changed — the handoff template reports large payloads by reference (O6-A, broadened)

- The template's completion contract governed *when* a reply is written but said nothing about
  *how much* of a large result to put in it, so producers transcribed material that already
  existed on disk. The new **Reply evidence format** field generalizes the rule past replies to a
  payload of **any** kind — long evidence blocks, diffs, file dumps, command logs: report the
  path, the **base anchor** it is measured against (base commit SHA, or a pre-image hash where
  nothing is committed), the **post-image SHA-256**, and a stat/summary line, plus a byte-bounded
  inline excerpt large enough to judge the result.

- **The escape hatch stays explicit**, because the case that needs it is observed, not
  hypothetical: full inline content is still correct when the payload **is** the deliverable, or
  when no on-disk artifact exists to point at — the denied reply write, where a sandbox or
  worktree boundary blocked the write and the final agent message is the only carrier. Narrowing
  that would have converted a documented recovery path into a contract violation.

- The clause is placed as a **new field** rather than an edit to the completion contract, so the
  REQ-018 phrases the contract audit greps byte-for-byte (`Denied reply write`, `attempt to write
  the printed reply path exactly once`, `the full substantive result`) are untouched by
  construction. `codex_ipc_contract_audit.mjs` stays **19/19 evidenced** with a requirements block
  that diffs empty against the pre-change run.

### Changed — SKILL.md prefers the capped reply viewer for reply reading

- A new invariant: read replies through `scripts/codex_ipc_replies.sh`, which caps each body at
  `--max-bytes` (4096 B default) and, on truncation, prints the full reply path — so the
  escalation target is already in front of the reader. Open the raw `.reply.md` only when grading
  or verification needs byte-exact content. This changes no authority ordering: the reply file
  remains primary and the view remains a read-only derived projection.

### Fixed — two owner-verifier findings

- **F-3 (`handoff_to_codex.sh`, ambiguous-send branch).** The stderr hint prints a full inspector
  invocation, and the question was whether it should carry `--summary`. **It should not**, and the
  reason is now a comment at the call site instead of tacit. Measured with the real inspector over
  a synthetic rollout carrying the exact injected pickup line: the line is 160 chars, `--summary`
  re-truncates each tail item to 120, and the cut lands **inside the conversationId** — the
  trailing dispatch id, the only token that answers *"was it THIS envelope?"*, is dropped
  (`dispatch id present in FULL: true / in SUMMARY: false`). `--summary` also clamps the hint's
  requested 5-event tail to 3. Selection and candidate fields do survive the projection, but they
  are not what disambiguates a resend; on a short transport root the id would survive and on the
  default root it does not, and a check that is silently useful only sometimes is worse than a
  verbose one in the branch whose whole purpose is resolving ambiguity.

- **F-4 (SKILL.md, `CODEX_IPC_GIT_CONTEXT`).** The doc claimed "any unrecognized value
  soft-resolves to `bounded` **with one stderr note**". The empty string never reaches that
  branch: `${CODEX_IPC_GIT_CONTEXT:-bounded}` substitutes the default for unset **and** empty
  alike, so an empty value resolves silently. Fixed in the wording, not the code — emitting a note
  for empty would make an unset-equivalent value noisy for no gain.

### Measurement provenance and the escalation trigger

- **AC0 figures are the program's Stage-0 baseline, cited here and not re-derived by this
  release:** **32.3% / 11.6%**, with **0 of 4** diff-bearing replies read through the capped
  viewer. The derivation lives in the program record.

- **This clause is prose, and prose is not a control.** The named FUTURES trigger: if verbatim
  large payloads keep appearing in replies after this clause ships, escalate from instruction to
  **a script-enforced cap** — the same progression the git-context sections took in v0.1.11, where
  advisory wording was replaced by an actual bound. Recurrence is the trigger; a single violation
  is not.

- **Token-figure discipline is unchanged from v0.1.12:** this entry introduces no token counts,
  and any magnitude quoted anywhere in this project remains an `o200k_base` **proxy**, never a
  Claude count. Byte ratios and token ratios are not interconvertible.

## [0.1.12] — 2026-08-05

**No default-behavior change.** Unlike v0.1.11, nothing about the shipped default output moves
here: `codex_ipc_session_inspect.mjs` with no new flag emits the same bytes it emitted at
`6cd5653`. The new `--summary` flag is opt-in at the call site, and the only call site changed is
the `/ipc` preflight documented in `skills/ipc/SKILL.md`.

### Added — `codex_ipc_session_inspect.mjs --summary`, the preflight projection

- The `/ipc` preflight read the inspector's **entire** result object — a full 20-item rollout
  tail with 600-char texts per item, the session_meta item, two open-ended count maps, the
  boundary snapshot, and an **unbounded** candidate array that an ambiguous thread serializes
  **twice** (`rollout.candidates` and `rollout.ambiguousCandidates` are the same array object).
  Almost none of that is named by the SKILL.md paragraph that tells the agent what to read.

  `--summary` prints the projection instead: the fields SKILL.md actually mandates, plus a
  bounded 3-item rollout tail, a bounded 5-element candidate list, and the ambiguity/precondition
  fields (`selection.status`/`.reason`/`.authority`/`.path`/`.candidateCount`/`.aliasCount`,
  `candidatesAmbiguous`, `primary.parsedOk`). The **true** candidate total is never lost — it
  stays at `selection.candidateCount`, and the omitted count is `candidateCount − length`, so the
  cap invents no field.

- **The projection is a field SUBSET, not a second computation.** For any argv `A`, `A --summary`
  projects the same object `A` produces: every path exists at the identical path in the default
  output and every shared scalar leaf carries the identical value, with three declared bounded
  carve-outs (`recentItems` length and 5-of-7 keys; the candidate arrays' length and 3-of-6 keys;
  the tail texts' 120-char re-truncation). Two structural rules keep that honest rather than
  merely asserted: `--summary` sets exactly **one boolean** in `parseArgs`, and `projectSummary()`
  **never receives `opts`** — a function that cannot see the parsing parameters is incapable of
  shifting one. `--tail-events`, `--max-text-chars`, `--db`, `--sessions-root` and `--thread` all
  keep their meaning, `readOnly: true` is untouched, and `ok`/the exit code are computed upstream.

  The 120-char re-truncation reuses the existing `truncate()`, which normalizes whitespace and
  then slices the **original** characters, so `truncate(truncate(s, 600), 120) === truncate(s, 120)`
  — the mini-tail text equals what `--max-text-chars 120` would emit **without** `maxTextChars`
  ever changing. `tests/test_session_inspect.sh` proves that against a real
  `--max-text-chars 120` run rather than against the derivation alone.

- **Measured, not estimated** (`tests/test_session_inspect.sh` scenarios 27–28, same-run
  baselines): a 34-line rollout with mixed text sizes at `--tail-events 20` gives **2,918 B of
  16,175 B (18%)**; a 12-candidate ambiguous thread gives **3,960 B of 18,811 B (21%)**.

  The acceptance bars are **ratios (≤40% non-ambiguous, ≤50% ambiguous), not absolute byte
  counts.** That is an amendment: the design dossier originally set 4,000 B / 6,000 B bars, and a
  dual adversarial measurement audit found they were round numbers with no decision-need
  derivation sitting at 8–10% margins — margins that could have forced cuts into the two safety
  amendments (the bounded tail and the bounded candidate list) to satisfy an arbitrary number.
  A ratio is tied to the savings claim itself, is immune to fixture-size drift, and is
  tokenizer-independent. The rule that came with it: never cut a SKILL.md-mandated field, the
  mini-tail, or the bounded candidate list — a breach with those intact means re-choose the bar.

- **Token magnitudes are an `o200k_base` proxy, measured with `tiktoken`, not a Claude count.**
  On the same fixture: full 16,092 B / 3,604 tok, summary 2,875 B / 861 tok. Note that the
  **token** ratio (23.9%) is worse than the **byte** ratio (17.9%): the dropped material is
  repetitive and tokenizes densely, so a byte saving overstates the token saving. Quote the byte
  ratio, or quote the token ratio as a proxy — do not convert one into the other.

- SKILL.md's preflight fence, `skills/ipc/examples/quickstart.md` and the README quickstart now
  pass `--summary`. A flag nobody invokes saves nothing, so adoption is gated inside the same
  acceptance criterion as the flag. **Line-number note for anything citing SKILL.md:** the new
  paragraph is inserted after the field-mandate paragraph so `SKILL.md:121-139` (the field
  mandate itself, cited by the plan, the addendum and the living record) does **not** renumber.
  Everything from `### Send rule` onward shifts **+7** (`:141` → `:148`), and the new
  `## Payload git context` section adds a further +19 below it.

### Documented — `CODEX_IPC_GIT_CONTEXT` on both operator-read surfaces

- v0.1.11 made bounded git context the default and `CODEX_IPC_GIT_CONTEXT=full` its rollback, but
  documented the knob only in the README table and a source comment. It was absent from
  `skills/ipc/SKILL.md` and from `handoff_to_codex.sh --help` — the two surfaces an operator or
  agent actually reads at the moment they need it. Both now carry it: SKILL.md gains a
  `## Payload git context` section covering `bounded`/`full`/soft-resolve and the 102,400 B
  advisory, and `--help` gains a `GIT CONTEXT` block. The sole rollback switch for a
  default-behavior change should not be discoverable only by reading the source.

### Changed — test hardening (no runtime effect)

- `bound_git_section()` carries a comment stating the condition under which its ≤ `max` guarantee
  holds (`max >= reserve`, ~130 B at realistic totals) and that the three shipped caps clear
  `reserve` by roughly 30×, so the degenerate clamp branch is unreachable in production. Comment
  only; the function is byte-for-byte unchanged.

- `tests/test_git_context_bound.sh`: every fixture commit subject is now multibyte-dense, and a
  new assertion (2g) proves the recent-commits truncation boundary actually falls **between two
  non-ASCII commit subjects**. Previously the fixture's only non-ASCII lived in file paths, so in
  the one section whose content is commit subjects the UTF-8 assertion had nothing to catch. The
  suite header now states the roles explicitly and non-reversibly: **2e (whole-line) is the
  deterministic catcher, 2f (UTF-8) is a backstop that fires only when the cut lands inside a
  multibyte sequence.** A new leg (7) re-runs the bound at git's **default** `core.quotepath`,
  where `git status --short` C-escapes non-ASCII paths and the boundary lands elsewhere; the
  other legs pin `core.quotepath=false` on purpose, which is the harder input but not the
  configuration real operators run.

- `tests/test_session_inspect.sh` grows from 25 to 36 assertions (scenarios 24–30). Scenario 24
  is the one worth naming: it diffs the **default** emit against the `6cd5653` inspector across
  12 (fixture × window) pairs at `--tail-events 1/5/20`, byte for byte, under exactly **one**
  declared normalization (`generatedAt`, which is per-run by construction). That is not
  ceremony — `handoff_to_codex.sh` greps the literal pretty-printed `"ok": false` / `"ok": true`
  / `"archived": 1` out of a `--tail-events 1` inspector run, and any whitespace drift in the
  default emit turns the unowned-thread auto-load into a fail-closed refusal. Scenario 24 also
  asserts `6cd5653` **rejects** `--summary`, so "identical default" is not vacuously true.

  Output stays pretty-printed at indent 2. Compact re-serialization of the summary was measured
  (−24.9% tokens, 214 tok/invocation on the fixture above) and deliberately **not** adopted:
  indent 0 would break those three literal greps, making a future default-flip a two-file change
  with a fail-closed failure mode in the middle.

## [0.1.11] — 2026-08-05

**This release CHANGES DEFAULT BEHAVIOR.** The conservative *"No runtime behavior changes"*
framing used for v0.1.9 and v0.1.10 does not apply and must not be reused here. From this tag on,
every dispatch payload's three git-context sections are **bounded by default**. A dispatch from a
dirty tree will carry a truncated `## Uncommitted changes` / `## Files changed vs <main>` /
`## Commits on this branch` section where it previously carried the whole thing, and the file-drop
success path can now write to **stderr**, which it never did before. `CODEX_IPC_GIT_CONTEXT=full`
restores the previous payload byte-for-byte and is the supported rollback.

### Changed — git-context sections are bounded by default (`CODEX_IPC_GIT_CONTEXT`)

- The payload's `RECENT_COMMITS`, `DIFF_STAT` and `UNCOMMITTED` sections were interpolated raw,
  with no ceiling. This was **disclosed twice and deliberately deferred** — v0.1.9's notes call it
  *"dormant, not fixed"* and v0.1.10 repeats the deferral — with an in-repo measured instance of
  **230,175 B** of git context in a single dispatch, 97.16% of that session's stored envelope
  bytes. Measured against the operator's own transport corpus it was not dormant at all: it fired
  on **194 of 454** stored packets, continuously, through 2026-08-04.

  `CODEX_IPC_GIT_CONTEXT` now gates it. `bounded` (**the default**) caps each section —
  `GIT_CONTEXT_RECENT_COMMITS_MAX=4096`, `GIT_CONTEXT_DIFF_STAT_MAX=4096`,
  `GIT_CONTEXT_UNCOMMITTED_MAX=8192` bytes, notice included — and appends an in-section notice
  naming bytes kept, bytes total, lines omitted, and the **local** command that recovers the rest.
  `full` disables the cap and reproduces the pre-0.1.11 payload byte-for-byte. There is no `none`
  value: a heading that silently vanishes is exactly the failure this change exists to prevent.
  An unrecognized value **soft-resolves** to `bounded` with one stderr note and an unchanged exit
  code — the same never-refuse shape `CODEX_IPC_INCLUDE_TRANSCRIPT` already has.

  The caps are **chosen ceilings, not derived ones**. The clean-tree corpus maximum of 12,198 B is
  a whole-packet figure and was deliberately not reused as a section cap.

- **The truncation is done in-shell on an already-captured variable, and this is the whole
  engineering content of the change.** The obvious implementation — `git … | head -c N` — is a
  silent-corruption bug in this script: `set -euo pipefail` turns the SIGPIPE that a short-reading
  `head` sends git into a nonzero pipeline status, which fires the wrapper's `||` fallback chains.
  `RECENT_COMMITS` would fall through to `git log --oneline -8` (all history, not branch-only) and
  `DIFF_STAT` to `git diff --stat HEAD` (working tree, not vs the merge target): **different-but-
  plausible content no reader could distinguish from the intended output.** `UNCOMMITTED` would
  fall through to `""`, and its `${UNCOMMITTED:+…}` gate then **deletes the `## Uncommitted
  changes` heading entirely** — the packet would not show an empty section, it would show no
  evidence a dirty tree ever existed. Truncation therefore happens in `bound_git_section()`, which
  has no git process on any pipeline's write end, cuts at a **line boundary** under a byte cap
  (`local LC_ALL=C` gives `${#s}` and `${s:0:n}` byte rather than character semantics), and
  reserves the notice's own bytes so the returned section never exceeds its cap.

- **Falsifier discharged, by existence proof.** The bound is only safe if a receiving Codex session
  can re-run git at its own `WORKDIR` and recover what was trimmed. Nobody had shown that.
  Reply `~/.claude/ipc/2414bbfd-*/019f6ad7-9a72-*/1784297537-2035-da826d37908e277c.reply.md`
  reports, in its "Final Git and cleanup state" section, in-sandbox `git status` branch output and
  `git diff --check main..HEAD` executed by the receiver in its own workspace. That corpus is
  operator-private and unreachable from CI, so the citation — not a test — is the record. Note the
  exact command evidenced is `git diff --check`, not the `git diff --stat` the sections carry.

- `skills/ipc/examples/example-dispatch-payload.md` is **unchanged and correct**: bounding adds no
  heading and removes none, the notice is body text, and the example was generated against a clean
  tree. `tests/test_payload_mirror_parity.sh` now pins `CODEX_IPC_GIT_CONTEXT` explicitly in both
  renders (unset for minimal, `full` for maximal) per its own stated contract that every knob the
  payload reads is pinned, and stays green under both.

### Added — two non-fatal payload advisories (stderr only)

- A dispatch whose payload reaches **102,400 B** now prints one stderr warning naming the byte
  count, the largest git-context section, the task-text size, and **local** remedies only
  (`git commit` / `git stash`, or the `CODEX_IPC_GIT_CONTEXT` knob). It never suggests
  re-dispatching or asking the dispatcher: by the time it fires, the operator running the wrapper
  *is* the dispatcher. The threshold is not arbitrary — **0 of 454** stored packets fall between
  100 KB and 200 KB, so it produces no false positive anywhere in the observed corpus. This option
  saves **zero bytes** by construction; it routes the operator to the only remedy that actually
  moves a 200 KB mean, which no code change delivers.

- A task that embeds a **whole prior handoff** (both the `# Handoff from Claude Code -> Codex`
  title and a `## How to use this file` section) now warns as well. A task merely mentioning
  "handoff", or quoting **one** marker, does not. This is a warning and not a refusal on purpose:
  envelope-publication-before-foreground-validation is a deliberate invariant this project has
  twice chosen to keep, a refusal firing after the envelope write would save nothing, and one
  firing before it would modify that invariant.

- **Both advisories are stderr-only, non-fatal, and leave the exit code and stdout untouched** —
  asserted by `cmp` on stdout between the warning and non-warning paths. But note the real
  consequence: the file-drop success path previously wrote **nothing** to stderr, and now can. A
  consumer that treats any stderr as failure, or merges `2>&1` and parses the combined stream,
  will observe a change.

### Added — `tests/test_git_context_bound.sh` (DEFAULT_SUITES is now thirteen)

Builds an oversized dirty git fixture in `mktemp` (`HOME` and `CODEX_IPC_ROOT` both redirected into
it; file-drop only, never `--ipc`) and asserts 29 conditions: the three caps hold; the
`## Uncommitted changes` heading is present **and** its body carries real status entries; each
notice's omitted-line count matches fixture truth; every kept line is a **whole** line of the real
`git status` output; the payload is valid UTF-8 end to end; `full` reproduces both the raw sections
and — against the pre-bounding wrapper rendered from commit `2855e52` — the whole payload
byte-for-byte modulo the per-dispatch nonce and timestamp; an unrecognized env value soft-resolves;
and both advisories fire, and fail to fire, where they should.

Verified non-vacuous: forcing `UNCOMMITTED` empty after bounding (the exact shape the SIGPIPE
fallback produces) fails 6 assertions; deleting the line-boundary retreat fails the whole-line
assertion. Recorded honestly in the suite header: the UTF-8 assertion did **not** fire under that
second mutation — a raw byte cut only splits a character when the boundary lands inside one, which
is fixture-dependent. The whole-line assertion is the deterministic catcher; UTF-8 is a backstop.

### Added — cross-manifest agreement checks (`gen_release_manifest.sh cross-check`)

Each frozen manifest was verified against **one** source and never against the others, so an
asymmetric propagation, a root manifest built from a half-propagated root, or a stray file in one
root and not another passed every gate. `check-all` now also cross-checks the committed bytes:
`root-claude` ≡ `root-agents`; `root-codex`'s path set equals `final-runtime`'s modulo the
`skills/ipc/` prefix (24/24); the three roots agree on every shared path's **hash**; and
`root-claude`'s 13 extra rows are all `base-overlay` paths whose hashes match except **exactly**
the three declared CRLF fixtures, asserted in both directions so the exception set cannot rot.
Pure text over committed files, so it runs under `--no-roots` on CI too.

One correspondence is deliberately **reported and not gated**: `root-codex` hashes against
`final-runtime`. Root manifests are regenerated at *propagation* time, never at release time — repo
precedent stated verbatim in the `6ca3ae2` and `f40183d` release commits — so between a release and
its propagation the roots hold the previous release's bytes **by design**. Gating that would be red
for the whole window and switched off within a week, the same trap a "regenerate at `HEAD` and
diff" design would have set for the `final-*` pair. It prints `IN SYNC` or `PROPAGATION-PENDING`
with the differing rows. At this tag it reads PROPAGATION-PENDING for one row
(`scripts/handoff_to_codex.sh`); the three installed roots still hold v0.1.10 and are **not**
propagated by this release.

### Fixed — factual correction to the `2855e52` entry below

The v0.1.11-adjacent entry below ("Two invariants that existed only as convention are now gated on
CI") states *"46 overlay rows there against 48 at `HEAD` today"*. **The correct figure is 49, not
48** — re-derived with `gen_release_manifest.sh gen --set final-overlay --ref 2855e52`. The
historical text is left as written; this line is the correction. The point it was making (that the
`final-*` pair does not track `HEAD` between releases) is unaffected.

### Token-cost note (measured, not estimated)

Figures in this entry are bytes. Where they are converted, the measured ratio on this corpus is
**~3.5 B/token**, not the ~4 B/token rule of thumb: the 466,606 B payload class is **≈131.7k
tokens**, where bytes-over-four would have said ≈116.7k. Do not divide bytes by four for this
content.

### Deliberately not changed

- **No propagation.** The three installed roots (`~/.claude`, `~/.agents`, `~/.codex`) still hold
  v0.1.10 and are untouched by this release; propagation is a separate act under separate
  authority, after independent verification. `root-*.manifest` are therefore byte-unchanged, per
  the precedent set by `6ca3ae2` and `f40183d`.
- **No retention change**, and no change to the `--ipc` route, the reply contract, or any REQ anchor.
- At the time of this release, `v0.1.8`, `v0.1.9` and `v0.1.10` stayed exactly where they were.
  The later privacy rewrite disclosed under `[Unreleased]` necessarily re-created tag objects.

---

*Everything below this rule was staged as `[Unreleased]` before the 0.1.11 cut and ships in this
release: the two CI gates added by `2855e52`, and the uninstaller dangerous-target guards and their
sentinels. Section headings are as originally written.*

### Added

- **Two invariants that existed only as convention are now gated on CI.** Both were
  verifiable by hand and neither was ever verified by a machine, so nothing distinguished
  "still true" from "nobody looked".

  *Release-manifest integrity.* `tests/gen_release_manifest.sh check-all` re-derives the
  frozen manifests from their pinned refs and verifies `MANIFEST-SHA256SUMS.txt`. It had
  never run on CI once — the only evidence it passed was a human saying so. It now runs on
  both platforms. The obvious mechanism (regenerate at `HEAD`, `git diff --exit-code`) would
  have been **wrong**: the `final-*` pair is deliberately frozen at the commit recorded in
  `release/manifests/FINAL_REF` and does not track `HEAD` between releases (46 overlay rows
  there against 48 at `HEAD` today, by design until a release rebinds it), so that gate would
  have been red permanently and been disabled within a week. The check re-derives each
  manifest against **its own** pinned ref instead, which is red only on real drift.

  A new `check-all --no-roots` omits the three installed-root inventories, which describe
  host-local directories (`~/.claude`, `~/.agents`, `~/.codex`) that do not exist on a
  runner. Their committed bytes are still hash-verified — the `MANIFEST-SHA256SUMS.txt`
  check is unconditional and covers every manifest file. What CI gives up is the "manifest
  still matches the installed copy" claim, which only a real host can make; local
  `check-all` is unchanged and still checks all seven.

  This also required `fetch-depth: 0` on the checkout. The default depth-1 clone contains
  neither `BASE_SHA` nor `FINAL_REF`, so the step would have died `ref not found`.

  *Rendered-payload / example mirror parity.* `tests/test_payload_mirror_parity.sh` renders a
  real file-drop payload from a throwaway git fixture (`mktemp`, with `HOME` and
  `CODEX_IPC_ROOT` both redirected into it; never `--ipc`, no Codex process, no Desktop) and
  diffs its `## ` headings against `skills/ipc/examples/example-dispatch-payload.md`. That
  example claims to mirror what the wrapper emits and nothing enforced the claim; either side
  could gain, lose or rename a section silently. A minimal render must match the example
  exactly in both directions; a maximal render (dirty worktree, every optional env set) must
  be a superset whose extras are all declared in the suite's allowlist together with the
  variable that gates them — currently `## Uncommitted changes` (`UNCOMMITTED`) and
  `## Suggested reasoning effort` (`CODEX_REASONING_EFFORT`). Each declared heading is also
  asserted absent from the minimal render, so a conditional section that quietly became
  unconditional fails here rather than drifting into the docs.

  Comparison is on rendered text by construction: two headings interpolate `${MAIN_BRANCH}`,
  so grepping the wrapper for heading literals cannot decide parity. The suite is in
  `DEFAULT_SUITES` (now twelve) and on both CI legs.

### Fixed

- **CI has been red on both platforms since `46cbd9b`, and the bash sentinel was the cause.**
  `tests/test_uninstall_guard.sh` hardcoded one machine's checkout layout, so it failed 6/12 on
  `ubuntu-latest` and 1/12 on `windows-latest`. Because it gates the job, **every step after it
  was SKIPPED on every run since `46cbd9b`** — the static contract audit, the public-safety scan,
  both installer dry-runs, and the PowerShell sentinel `46cbd9b` had just added. That sentinel
  therefore never executed on CI once, which is the same class of gap it was written to close.

  Three assertion classes encoded Windows path semantics with no precondition check:
  the MSYS drive-root mount (`/c`), the admin-share UNC spellings, and the case-insensitivity
  bypass. On a case-sensitive POSIX filesystem those spellings name nothing, so `uninstall.sh`
  short-circuits at `rc=0 "Nothing to do"` on its not-present check — *before* the guard is
  reached. Fail-closed and safe, but not a refusal, and asserting one there measures the
  filesystem rather than the guard. Each now probes its own precondition and skips loudly.

  The single Windows failure was the **UNC respelling of the source tree**, and it was a defect
  in the test rather than a bypass of the guard. The target was built as `//localhost/c$` plus
  `$ROOT` with a leading `/c` stripped — correct only for a checkout under `C:`. On the runner
  (`$ROOT=/d/a/...`) the strip was a no-op and the result was a `c$`-share path naming a
  `d`-drive location, a string that exists nowhere. The UNC form is now derived from `$ROOT`'s
  own drive letter and probed for reachability, matching the treatment `6cadd4e` already applied
  to the PowerShell leg. Where the spelling resolves, the `//*/*` arm refuses it as designed;
  no guard behavior is changed by this commit and no guard gap was found.

  Skip notes print as `  (SKIP: ...)`, never `^SKIP:` at column 0, which
  `tests/run_release_gates.sh` treats as a hard gate failure outside its one allowlisted skip.
  Windows loses no coverage: 17/17 still assert on an NTFS checkout.

  Also corrected: the suite header claimed UNC behavior was "not constructible hermetically
  without elevation" alongside junctions. UNC is constructible and is now asserted; the junction
  half was separately wrong and is restated (`mklink /J` needs no elevation, so the
  ancestor-reparse arm is testable and simply is not tested yet).

- **`tests/run_release_gates.sh` mis-stated its own suite count** in two header comments
  ("currently ten", "currently 10") while `DEFAULT_SUITES` has listed eleven since
  `test_uninstall_guard.sh` was added. Comments only; no behavior change.

- **Fourth and fifth guard bypasses, and the process defect behind all of them.** The
  dangerous-target guard was bypassable in two further spellings, both live until this change:
  a **forward-slash UNC** target (`//localhost/c$/dev/.../skills/ipc`) produced a full deletion
  plan over the canonical source tree at exit 0, because the previous fix refused only targets
  whose resolved path began `\\` and `Resolve-Path` returns forward slashes for that input; and a
  **trailing dot** on the leaf or on any ancestor segment (`...\skills\ipc.`,
  `...\claude-codex-ipc.\skills\ipc`) defeated the equality and prefix arms, because Windows
  strips trailing dots when resolving while the string comparison does not.

  All four historical bypasses share one root cause: **the guard canonicalized with a weaker
  primitive than the deleter acts through.** `Resolve-Path().ProviderPath` preserves trailing
  dots and spaces and preserves forward-slash UNC form. Both PowerShell guards now canonicalize
  with `(Get-Item -LiteralPath ... -Force).FullName`, which is filesystem-backed and collapses
  every one of those spellings; all denylist arms are unchanged. Measured across the six
  confirmed hostile spellings: `Resolve-Path` catches 4/6, `Get-Item` catches 6/6. Deliberately
  **not** `[System.IO.Path]::GetFullPath`, which resolves a relative path against the process
  CWD rather than the PowerShell location. `uninstall.sh`/`install.sh` reach no deletion plan for
  any of these spellings and are unchanged — though for several of them bash *short-circuits* at
  `rc=0 "Nothing to do"` because MSYS cannot resolve the string at all, rather than *refusing* at
  `rc=1`. Fail-closed and safe, but not the same thing as a refusal, and the two shells therefore
  diverge in exit code for the same input.

  `install.ps1 -Force` had **no reparse-point arm at all** despite ending in the same
  `Remove-Item -Recurse` that `uninstall.ps1` guards; added for parity.

  **The process defect:** `tests/test_uninstall_guard.sh` existed and passed while the PowerShell
  guard was bypassable three separate times, and CI's PowerShell leg ran only a happy-path
  dry-run that cannot detect a bypass. A green bash run was never evidence about PowerShell.

### Known not closed — recorded, not implied away

These defeat every string comparison in all four scripts and are named in the guards' own
comments rather than left to be rediscovered:

- **`subst` / `net use` drive-letter aliasing** — `subst Z: C:\dev\repo` then `-Target Z:\...`.
- **A junction or symlink in an ANCESTOR directory** — the reparse arms test only the target itself.
  Note the bash suite's header claims junctions are "not constructible hermetically without
  elevation"; that is true of symlinks but false of directory junctions (`mklink /J`), so this arm
  is testable and simply is not tested yet.
- **Invoking the scripts themselves via a UNC or `\\?\` path.** This de-canonicalizes the guard's
  *source anchor* rather than its target, so a canonical `-Target` stops matching the prefix test.
  Measured: `powershell -File \\localhost\c$\dev\...\uninstall.ps1 -DryRun -Target C:\dev\...\skills\ipc`
  and the `\\?\C:\...` form both reach a deletion plan; `bash //localhost/c$/.../uninstall.sh`
  likewise. Three fix rounds hardened the target operand; the anchor was never in scope, and the
  `Get-Item` swap does not close it (it does not collapse a UNC anchor to its local form).
  A **dotted** script path (`C:\dev\repo.\uninstall.ps1`) is **not** in this set — the `Get-Item`
  swap does collapse it and the guard refuses correctly. An earlier draft of this entry listed it
  as open; that was wrong.
- **`install.sh --force` / `install.ps1 -Force` do not protect worktree copies.** Both anchor on
  `<repo>/skills/ipc` rather than the repo root, so
  `--force --target <repo>/worktrees/<wt>/skills/ipc` reaches a delete-then-replace plan while both
  *uninstallers* refuse the same path. Measured in both shells. Asymmetric and pre-existing; the
  earlier entry above claiming worktree copies are covered is accurate for the uninstallers only.

Closing these requires filesystem-identity comparison (volume serial + file id), not path
canonicalization. Judged disproportionate here: every supported install target is a local path
under the user profile, the guard protects a git-tracked and pushed tree, and reaching any of
these requires deliberately aliasing one's own machine.

- **Uninstallers no longer accept a destructive target.** `uninstall.sh` and `uninstall.ps1` guarded
  only on a `SKILL.md` containing `name: ipc`. This repository's own `skills/ipc` satisfies that
  marker, as do both worktree copies, so naming one as `--target`/`-Target` reached
  `rm -rf`/`Remove-Item -Recurse`. Both now carry a resolved-path guard, refusing before the marker
  check any target that resolves to this source tree or any descendant, to
  `$HOME`/`$env:USERPROFILE`, or to a filesystem/UNC root.

  This guard took **three attempts**; both earlier ones are recorded here rather than quietly
  amended, because each failed the same way — the guard was bypassable by respelling the path.

  *Attempt 1* was case-**sensitive**. It was modelled on the `--force` arm at `install.sh:79-91`
  (as of `f929e53`; the line range now holds the corrected block), whose `case` comparison is
  case-sensitive — but this is a Windows tool on NTFS, where `C:/DEV/...` and `C:/dev/...` are the
  same directory, and `pwd -P` normalizes the drive letter while preserving directory-name case. A
  one-character case change walked through both the guard and the marker check.
  `install.ps1:67-70` had used `OrdinalIgnoreCase` all along; the claim that the new guard
  "mirrored" it was false and is retracted.

  *Attempt 2* fixed case in both shells and added a `//*/*` UNC arm to the **bash** guards only. A
  UNC respelling of a local path (`\\localhost\c$\dev\...`) resolves to itself, so it matched
  neither the source-prefix test nor the root test and was not a reparse point — it walked the
  entire PowerShell guard and printed a deletion plan over the canonical source tree. Both
  PowerShell guards now refuse any target beginning `\\`, matching the bash arm.

  Current state, both shells: refuse before the marker check any target resolving to this source
  tree or any descendant, to `$HOME`/`$env:USERPROFILE`, to a filesystem root, or to any UNC path.
  `uninstall.ps1` additionally uses `-LiteralPath` on its existence check (a wildcard target
  previously passed the glob check then died on a null) and refuses reparse points, because
  `Resolve-Path` does not resolve junctions.

  **Known remaining gap, not fixed here:** `uninstall.ps1` tests only whether the target *itself*
  is a reparse point, so a junction in an *ancestor* directory still defeats the path comparisons
  and is stopped only by the marker check. bash is immune (`pwd -P` resolves). Also unfixed: the
  installers compute their source root as `<repo>/skills/ipc` rather than the repo root, so they
  accept a worktree copy as a `--force`/`-Force` target where the uninstallers refuse it.

### Added

- **`tests/test_uninstall_guard.ps1`** — the PowerShell half, wired into the Windows CI leg. 17
  assertions covering canonical, case, backslash UNC, forward-slash UNC, trailing dot on leaf and
  on ancestor, user profile, drive root, plus the over-block guards. Landed **red** first: it
  reported 5 failures against the then-live guards, and those are exactly the bypasses the
  primitive swap closes. Grades on **exit code plus refusal banner**, never on stdout shape —
  `install.ps1` prints its plan line before the guard runs, so output-shape grading silently
  mis-scores. One harness note preserved in the file: `$ErrorActionPreference = 'Stop'` turns a
  child's stderr into a terminating error and kills the suite on the *first successful refusal*,
  so the invocation helper scopes it to `Continue`.

- **`tests/test_uninstall_guard.sh`** — first test coverage of the uninstallers, registered in both
  `run_release_gates.sh` and `.github/workflows/test.yml` so it actually gates a PR. 17 assertions on
  a host with worktrees and installed roots present; a fresh clone runs fewer and says so, because
  sections 3 and 4 iterate whatever exists. Every invocation is `--dry-run`, so the suite itself can
  delete nothing. Covers refusal of the source tree (plain, dot-segment, trailing slash), `$HOME`,
  filesystem and drive roots, UNC respellings, both worktree copies, and — the reason it exists —
  **case variants**. It asserts against `uninstall.sh` only; the PowerShell guard is not covered by
  any suite, and that gap is what let attempt 2's UNC bypass through. Verified
  non-vacuous: disabling the fix makes 3 assertions fail, printing a deletion plan over the real
  source tree. The absence of any uninstaller test is why the case-sensitivity class was invisible.
- **`docs/COMPATIBILITY.md` autoload row** said `gui-unowned`/`failed-closed` outcomes come with a
  file-drop line. A post-autoload retry can end
  `failed-closed -- reason=retry-ambiguous-outcome -- confirmation=unknown`, where the pickup line is
  deliberately suppressed. This was an eighth surface of the same overclaim v0.1.9 and v0.1.10
  corrected elsewhere — including one already-corrected line in this same file.
- **README status line** reported `v0.1.8`; it is now `v0.1.10`.

## [0.1.10] — 2026-07-27

> Post-tag correction (record only; the tag is not moved): the "Added" note below describes the new
> assertion as covering "the pickup line". It forbids the **banner**
> (`FALLBACK -- file-drop is ready`), not the operator command on the following runtime line
> (`read "<envelope>" and proceed`). The assertion is real and was verified non-vacuous, but a
> reworded banner would let a retained operator command pass. Read it as partial coverage of the
> no-resend invariant, not full coverage. The `retry-ambiguous-outcome` branch has no test at all.



Follow-on patch to v0.1.9. Adds a goal-setting instruction to every dispatch payload, removes the
last surviving false-fallback string, and puts the release line's central invariant under test for
the first time. Cut as a new immutable tag; `v0.1.8` and `v0.1.9` are not moved.

### Added

- **Dispatch payloads now instruct the receiver to set a `/goal` before starting work.** The
  generated "How to use this file" preamble reads "Read the **Task** below, set your `/goal` to a
  concise summary of it, then complete it in the associated workspace at:". Applies to every
  wrapper-generated dispatch, file-drop and `--ipc` alike, since both consume the same payload
  heredoc. `skills/ipc/examples/example-dispatch-payload.md` carries the identical change — that
  file is manifest-covered, and letting it drift is the stale-mirror defect class v0.1.9 was cut to
  close.
- **First test coverage for the no-resend invariant.** `tests/test_router_contract.sh`'s
  `run_wrapper_case` takes an optional fifth argument naming text that must NOT appear in the
  wrapper's output; the `unknown` and `malformed` cases now assert the pickup line
  (`FALLBACK -- file-drop is ready`) is absent. Until now nothing anywhere asserted that a
  `confirmation=unknown` outcome suppresses pickup — the behavior this release line is named for.
  The assertion was verified non-vacuous: arming it on the `no-client` case, where the pickup line
  is legitimately printed, makes it fail.

### Fixed

- **The last false-fallback string.** The invalid-UUID diagnostic said the mechanism "falls back to
  file-drop on any failure" — the sole tracked survivor of the overclaim v0.1.9 removed from five
  documentation surfaces and a code comment, and doubly wrong at that exit because no envelope has
  been written yet. It now states that nothing was written for the invocation and to rerun with a
  valid conversationId or omit `--ipc`. `git grep "falls back to file-drop"` now matches only this
  changelog line, which quotes the removed phrase.
- **`handoff-template.md` preamble vs conditional field.** "Fill every field" contradicted the
  relayed-authority field v0.1.9 added, which says to omit it entirely when inapplicable. The
  preamble now reads "Fill every applicable field" and states that conditional fields are omitted.
- **`--version` and `.claude-plugin/plugin.json` are both `0.1.10`.** Nothing binds them mechanically;
  they are moved together by checklist. Noted so the next bump does not strand one.

### Deliberately not changed

- **Installed roots are still not propagated.** `~/.claude`, `~/.agents`, and `~/.codex` continue to
  hold v0.1.8 bytes. The Claude `/ipc` route loads the source checkout
  (`~/.claude/commands/ipc.md`), so it runs this release immediately; the installed copies are
  reached only by a Codex-side skill invocation, of which the session history contains none.
  Propagation is a separate owner decision — `install --force` deletes each target before copying
  the 24-file allowlist, which would remove 13 files / 193,121 bytes of test residue per root.
- Envelope-before-foreground-validation ordering, unbounded Git context enrichment (dormant, not
  fixed), zero-byte reply certification, and unbound explicit `--reply-path` all remain as disclosed
  in v0.1.9.
- `docs/TROUBLESHOOTING.md:23`, the help/version branch's lack of contract-audit coverage, and the
  wait-hint doc divergence remain open and are recorded here rather than silently carried.

## [0.1.9] — 2026-07-27

Documentation-coherence patch. **No runtime behavior changes** except one new effect-free
`-h`/`--help`/`--version` branch and one added flag in a printed hint. Cut as a new immutable tag;
the `v0.1.8` tag is not moved.

### Fixed — contradictory instruction surfaces

- **Ambiguous-send pickup guidance (5 surfaces + 1 code comment).** `README.md`,
  `docs/COMPATIBILITY.md`, `skills/ipc/SKILL.md`, `references/architecture.md`, and
  `references/troubleshooting.md` all stated that the file-drop pickup line is preserved or printed
  in *every* outcome. The runtime deliberately suppresses it after an ambiguous post-attempt result
  (`confirmation=unknown`), which is the core defect this release line is named for. An operator
  following the docs could paste the envelope after an admitted turn and duplicate execution. All
  five now distinguish the **envelope** (always preserved) from the **pickup line** (printed only on
  a proven pre-send failure). `troubleshooting.md` splits its `failed-closed` row into the
  `not-attempted` and `unknown` cases. The wrapper's own header comment, which said "Falls back to
  file-drop on failure", is corrected to match its body.
- **Stored thread policy read two ways in one file.** `SKILL.md` said stored
  `approvalMode`/`sandboxPolicy` are advisory and "MUST NOT ... be read as a reply-writability
  prediction", then later told the agent to pick a different thread when a stored `managed` sandbox
  was present. The second passage is corrected: a stored `managed` sandbox is not a reason to avoid
  a target. A blocked reply write is expected and is recovered via
  `codex_ipc_wait --accept-rollout-fallback`. "Choose another thread" is reserved for
  inspector-proven conditions — missing, archived, identity-mismatched.
- **Stale observation-budget comment.** `handoff_to_codex.sh` documented a default of `8000` ms;
  the runtime default is `20000` ms (`codex_ipc_rollout_observe.mjs`).

### Added

- **`-h` / `-?` / `--help` and `-v` / `--version`**, answered and exited before transport-root
  resolution, Git inspection, retention, or envelope publication. `guard_task` rejects only `--*`,
  so single-dash `-h`/`-v` were previously accepted as file-drop task text and published a junk
  envelope. `--help`/`--version` already failed cleanly; this makes both forms standard and
  effect-free.
- **`--status-exit-codes` in the printed `WAIT:` hint.** The flag already shipped; the hint omitted
  it, so a caller composing `node wait... && next` received exit 0 on `reply-missing` and proceeded
  as if the delegation had completed. Composed commands now fail closed.
- **Relayed-authority labeling convention** in `references/handoff-template.md` (conditional field,
  included only when a handoff forwards someone else's authorization) with a one-line pointer in
  `SKILL.md`. Forwarded owner text stays labeled relayed with its source, is not rewritten into
  first-person owner voice, and cannot override a trusted instruction the receiver already holds.
  This is a **labeling convention, not a control** — the transport cannot authenticate human intent
  or decide instruction precedence.

### Deliberately not changed

- Envelope publication still precedes foreground-policy validation. This is the documented
  file-drop-first invariant, not a defect.
- Automatic Git context enrichment is unchanged from v0.1.7/v0.1.8 and remains unbounded. Under a
  dirty repository it previously produced a measured 230,175-byte context block per dispatch
  (97.16% of stored envelope bytes in that session). Current harm is negligible on a clean tree, so
  this is **dormant, not fixed**, and re-arms on any dispatch from a dirty repo.
- Zero-byte reply files still certify `done` when the dispatch's own turn reached `task_complete`
  un-superseded, and an explicit `--reply-path` is still trusted without basename binding. Both were
  reviewed and deliberately retained this cycle.

## [0.1.8] — 2026-07-24

> Post-tag correction: the first v0.1.8 cut shipped correct runtime code but stale docs
> (still instructing the removed `--app`/`--open`/`--exec` modes and a "default 7"
> retention value), plus an octal-value validation hole, a GNU-only `ln -T`, a test seam
> that could suppress an executed dispatch, and a final-manifest bound to the wrong commit.
> An independent adversarial audit found these; all are fixed and the tag was moved to the
> corrected commit. See "Fixed after audit" below.

Identity: **No Codex CLI / No Ambiguous Resend.** Live `--ipc` GUI delivery, the
completion-wait contract, and reply harvesting are unchanged and remain the primary
path; this release removes the CLI-backed modes and closes two data-safety defects in
the daily-use wrapper. It supersedes the abandoned file-drop-only `v018-nocli` line,
which removed live delivery entirely and is not a release candidate.

### Removed
- `--app`, `--open`, and `--exec` modes and the `need_codex` helper. Each removed flag
  now exits non-zero with a replacement hint **before** any transport-root read, envelope
  write, or child launch. `--ipc` and the default file-drop path are unchanged. The
  wrapper no longer invokes the `codex` binary on any path; `codex_ipc_revalidate.mjs`
  no longer spawns `codex --version` (it reports the no-CLI invariant instead).

### Changed
- **Retention is keep-only by default.** `CODEX_IPC_RETENTION_DAYS` now defaults to
  never-delete: unset, empty, and exact `0` all mean keep-only, and pruning requires an
  explicit positive integer. Previously the default was 7, so a caller that never
  mentioned retention silently age-deleted transport envelopes — including replies
  nobody had harvested. A non-canonical value (negative, decimal, junk) is now rejected
  loudly before any envelope write instead of silently skipping the sweep. Retention is
  **not** a confidentiality control and is documented as such; plaintext persists
  indefinitely by default (SECURITY.md).
- **Create-once publication.** The envelope writer no longer publishes with `mv -f`
  (which could silently clobber a pre-existing, possibly in-flight envelope). It links
  the destination and fails loudly on collision, rejects a directory/symlink already at
  the path, distinguishes a genuine collision from an environmental link failure, and
  never reports a post-publication cleanup failure as a dispatch failure.
- **No ambiguous resend.** The follower request is written before its response is
  awaited, so a timeout, closed pipe, or protocol drift may leave a task already
  admitted. Such outcomes are now classified `confirmation=unknown` and do not print a
  pickup/resend line; the autoload retry poll retries only on an authoritative
  `no-client-found` and otherwise terminates as `retry-ambiguous-outcome`.

### Tests / CI
- `tests/test_retention_sweep.sh` is now gated in both CI and the local release runner
  (it previously ran nowhere); made hermetic against an inherited retention value; and
  asserts the keep-only default. The static contract audit is now a local release gate,
  not CI-only. A create-once collision/regression test was added. Final release
  manifests are regenerated at the tested commit and are now covered by `check-all`.

### Fixed after audit
- **Docs vs runtime:** removed every remaining `--app`/`--open`/`--exec` instruction from
  `SKILL.md`, `README.md`, `docs/{ARCHITECTURE,COMPATIBILITY,INSTALL,TROUBLESHOOTING}.md`,
  and `references/{architecture,troubleshooting}.md` (following one reached the wrapper and
  exited 64). Corrected the "default 7" retention text to keep-only in the docs that lagged.
- **Retention validation:** a leading-zero value (`08`/`09`) passed a bare `^[0-9]+$` then
  threw a Bash octal error that silently skipped the sweep while still publishing. Values
  are now `^(0|[1-9][0-9]*)$` compared in base-10; any non-canonical value exits 64 before
  any envelope write.
- **Portability:** `atomic_write` no longer uses GNU-only `ln -T`; it uses portable plain
  `ln` on BSD/macOS. A follow-on audit found that the destination pre-check alone did not
  close a raced-directory interleaving; the post-link hardening is recorded below.
- **Test seam:** `_TEST_SOURCE_ONLY` is honored only when the script is sourced and exactly
  `1`; an executed wrapper ignores it, so an inherited value cannot silently exit 0 without
  dispatching. New `test_ipc.sh` and `test_retention_sweep.sh` sections guard both fixes.
- **Manifests:** `gen_release_manifest.sh check-all` fails closed if a final manifest exists
  but `FINAL_REF` is missing; the final pair is regenerated at the tested commit and the
  release commit touches no runtime/overlay file, so `FINAL_REF` stays tag-accurate.
- **Release gate:** `scan_public_safety.sh` excludes nested `worktrees/` (separate checkouts),
  so `run_release_gates.sh` passes from a primary checkout that has sibling worktrees.

### Hardened after audit-chain review
- **Create-once post-link verification:** after a successful portable `ln`, `atomic_write`
  now verifies that the exact destination is a regular file. If a directory races into
  place and `ln` succeeds inside it, the staging and inner hard-links are removed and the
  publication fails closed instead of reporting a false success.
- **Final-ref fail-closed check:** `gen_release_manifest.sh check-all` now parses
  `FINAL_REF` with the same whitespace stripping used by manifest enumeration. Missing,
  empty, and whitespace-only markers all fail closed while final manifests exist.
- **Release-document consistency:** the README status footer now reports v0.1.8; the
  release runner's header and every usage form now describe all ten `DEFAULT_SUITES`,
  the conditional safety scan, and the always-run contract audit; its older nine-suite
  timing figure is labelled historical. The retention test's seven-day wording now
  describes an explicit opt-in contract.
- **Worktree-path test stability:** the autoload matrix now collapses PowerShell's
  host-width-dependent diagnostic whitespace before fixed-token matching. Long required
  worktree paths no longer split `must be a UUID` across lines and produce a false red;
  the exit-code and message-content checks are unchanged.

## [0.1.7] — 2026-07-12

Defect tranche superseding v0.1.6. **Known issues in v0.1.6:** v0.1.6 shipped with all four
defects fixed below, including a release-gate process bound that could pass vacuously — the
v0.1.6 RC-PASS process-bound figures are therefore unreliable. Do not install or propagate
v0.1.6; it is superseded by 0.1.7.

### Fixed
- Release-gate process-bound trust (F2/A0): the "owned Node" accounting in
  `tests/run_release_gates.sh` was a bare before/after set difference of global node PID
  snapshots — no parent-PID logic (the header claimed a descendant confirmation that did not
  exist) — and the Windows enumeration path swallowed failures, so a broken enumerator silently
  measured an owned peak/residual of 0 and the process bound passed vacuously. Ownership is now
  fail-closed descendant-of-runner PID ancestry (POSIX: PPID chains to the runner; Windows: the
  runner's MSYS descendant closure mapped to Win32 PIDs and walked through the full
  `Win32_Process` parent table, catching node-spawned node that MSYS `ps` cannot see). An
  enumeration failure aborts the run with GATE ERROR (exit 3) instead of fabricating zero, at
  startup, mid-suite sampling, and post-suite drain. Documented residual: a node process whose
  intermediate parents already exited escapes ancestry attribution. Pinned by the new hermetic
  `tests/test_gate_process_ownership.sh` fixture (not part of the pinned nine-suite battery).
- In-window schema drift on a completed turn (F1/A4): the turn-boundary accumulator applied
  schema-drift attribution only to turns still open at `finish()`, so a completed turn with
  in-window drift kept a `closed` snapshot — the inspector and the write-proof pre-send gate
  certified a turn the dispatch lifecycle projection refused over the same records
  (`unavailable`, schema-drift). Drift arriving while a turn is open now poisons that turn at
  push time: inspector `turnActivity` degrades to `ambiguous` and `codex_ipc_write_proof.mjs`
  refuses the send, not overridable by `--allow-mid-turn` (fail closed on ambiguity).
- Retention-sweep silent data loss (WS-7): the opportunistic sweep in `handoff_to_codex.sh`
  deleted transport files by age alone, so an aged UNREPLIED `*.task.md` — an outstanding
  dispatch that was never answered — was silently destroyed once it crossed the retention
  horizon. An aged task is now deleted only on positive proof that its same-dispatch
  `*.reply.md` exists (pairing decided before any reply is deleted, so aged pairs still sweep
  in one run); an unreplied task is retained regardless of age, pairing ambiguity errs toward
  retention, and a failed task deletion is reported to stderr rather than suppressed
  (reply/empty-dir deletion failures remain suppressed and err toward retention). New hermetic
  survival suite `tests/test_retention_sweep.sh`.

### Changed
- `tests/test_reply_view.sh` (F3/T23) no longer re-runs the entire `tests/test_ipc.sh`
  transport suite inside itself — the standalone gated `test_ipc.sh` run in the same battery
  already delivers that whole-suite guarantee, and the nested rerun pushed the suite past the
  legitimate 600s per-suite cap on a loaded host. T23 is now a direct wrapper→viewer
  envelope-seam contract check (the one interaction the rerun never exercised): one hermetic
  wrapper dispatch must produce the keyed on-disk envelope layout, and the viewer must
  enumerate it as awaiting-primary and render the reply once it lands at the advertised path.
  Suite runtime ~150s versus the 400–1400s observed with the nested rerun; the per-suite cap
  is NOT raised.

## [0.1.6] — 2026-07-12

### Added
- One shared turn-boundary state machine, `createTurnBoundaryAccumulator()`, in
  `codex_ipc_rollout_reader.mjs`: an I/O-free, text-free accumulator that emits immutable per-turn
  snapshots (eight boundary fields) and alone owns start/terminal/id binding, supersession, and
  parser/schema-gap attribution. `createDispatchCorrelator` (A1 dispatch correlation) and
  `summarizeThreadActivity` (A4 thread activity, consumed later) are thin projections over it.
- `codex_ipc_wait.mjs` opt-in `--accept-rollout-fallback` (D2): when the reply file is genuinely
  absent, a completed own turn whose verified rollout body matches its terminal certifies `done`
  with `replySource=rollout-fallback` (one stderr `WAIT_DIAGNOSTIC reply-source`; stdout stays one
  token; the recovered body is never emitted). Flagless v0.1.6 stays file-primary and byte-identical.
- `codex_ipc_wait.mjs` opt-in `--status-exit-codes` (A6, D4): maps the determination to a frozen
  exit code (`done=0`, `pending=2`, `aborted=3`, `superseded=4`, `reply-missing=5`, `unavailable=6`;
  usage errors stay exit 1 with no token). The token stays the sole stdout line. Flagless mode is
  unchanged and byte-identical: every determination exits 0. Documented in `SKILL.md` and both
  troubleshooting surfaces.
- Inspector `turnActivity` (A4): `codex_ipc_session_inspect.mjs` feeds the FULL rollout parse stream
  (not the clipped display tail) into the shared `createTurnBoundaryAccumulator` and adds an additive
  `activitySignals.turnActivity` (`open`/`closed`/`ambiguous`) via the pure `summarizeThreadActivity`
  projection. Summarized lifecycle items gain an additive `turnId`. `maybeMidTurn` values/fields are
  byte-compatible; the `conclusion` now derives from `turnActivity`; `terminalState` stays historical.

### Changed
- Consolidated the two duplicated correlation reducers onto the single boundary machine: removed
  `correlateDispatchWindow` (reader) and `classifyDispatch` (wait). Correlation now also allows a
  later same-`turn_id` user message (ordered fallback stays ambiguous) and rejects a non-null
  `agent_message.turn_id` that disagrees with its enclosing turn — extending the A-05 fail-closed
  class without reopening it.
- Producer denied-reply protocol (A5): the handoff scaffold, `SKILL.md`, `handoff-template.md`, and
  the example payload now state that a denied reply write is expected — self-verify, attempt the
  reply once, and on denial put the full substantive result in the final agent message (no
  retry/escalation). `codex_ipc_contract_audit.mjs` locks these bytes.
- Marker-proof completion is turn-scoped (A4, fixes A-04): the `codex_ipc_rollout_reader.mjs`
  marker proof (`pollRolloutForMarker`/`inspectRolloutMarker`) migrated onto the shared
  turn-boundary accumulator as a named consumer, so a `task_complete` certifies the agent marker
  only when it closes the SAME turn that carried it. The old pure line-order relation returned a
  cross-turn false-positive proof (agent marker in turn 1, `task_complete` in turn 2).
- Write-proof pre-send gate (A4): `codex_ipc_write_proof.mjs` now requires `turnActivity==="closed"`;
  `--allow-mid-turn` overrides an `open` turn only, never `ambiguous` (fail closed on ambiguity).
- Completion waiter on every easy path (A3): README Quickstart, `skills/ipc/examples/quickstart.md`,
  `docs/TROUBLESHOOTING.md`, `skills/ipc/references/troubleshooting.md`, and `SKILL.md` now show a
  bounded `codex_ipc_wait --accept-rollout-fallback` with all six tokens and the named-dispatch-
  completion-vs-thread-idleness distinction, and carry the verbatim OQ-4 caveat ("resuming the goal
  in a fresh, unmarked turn will NOT re-certify the original dispatch id; machine re-certification
  requires a NEW dispatch with a new marker.") on every recovery surface. The `handoff_to_codex.sh`
  wrapper prints one POSIX-escaped `WAIT:` line before the final `RESULT:` on the two accepted live
  `--ipc` success branches only (D3); file-drop/exec/failure never print it. `codex_ipc_contract_audit.mjs`
  gains REQ-019 enforcing the easy-path references and the verbatim OQ-4 caveat.
- Stored-policy preflight demoted to advisory (A2): `codex_ipc_session_inspect.mjs` now emits an
  additive `permissionProfileAdvisory` sibling of `approvalMode`/`sandboxPolicy` (names/values
  unchanged) marking the stored `threads.sandbox_policy`/`threads.approval_mode` columns as
  `source:"stored-thread-row"`, `mayDifferFromEffectiveTurn:true`, `mustNotGateDispatch:true`,
  `predictsReplyWritability:false`. The false "these predict whether an injected turn can write its
  reply file / preflight before delegating" guidance is corrected across `SKILL.md` and both
  troubleshooting surfaces (which gain a denied-reply-write row pointing to
  `codex_ipc_wait --accept-rollout-fallback`); a dated correction is appended to the
  `docs/COMPATIBILITY.md` host-identity/permission ledger without rewriting the historical rows.

### Fixed
- `tests/test_wait_contract.sh` probed only the repo layout, so from an installed skill root it
  reported `SKIP: codex_ipc_wait.mjs absent` and exited 0 while the tool sat one directory away.
  It now uses the dual-layout probe every other suite uses (landed after the v0.1.5 tag; `fc54ce1`).
- Transport-root containment (A-02) and wrong-turn reply attribution (A-05), fixed post-v0.1.5 at
  `0fbd517` and first shipped in this release. A-02: `CLAUDE_SESSION_ID` became a path segment
  under `CODEX_IPC_ROOT`, so a `../escape` id wrote the envelope outside the transport root and
  still exited 0; the wrapper now requires one safe segment and fails closed rather than sanitizing
  a rewritten id (which would silently split a session's channel in two). A-05: the shared
  correlator accepted a `user_message` whose `turn_id` disagreed with its enclosing turn, so the
  harvester/viewer could serve that turn's final answer for this dispatch; the guard that
  `codex_ipc_wait` already applied now lives in the shared correlation authority so every consumer
  refuses.

## [0.1.5] — 2026-07-10

Makes the delegation completion contract mechanically checkable, and surfaces the per-thread
settings a dispatcher needs before delegating.

### Added
- `skills/ipc/scripts/codex_ipc_wait.mjs`: the sanctioned dispatcher-side completion check.
  Correlates a dispatch to its OWN turn (task-marker `user_message`, `turn_id`-primary) and emits
  exactly one token — `done` (reply file present AND that turn reached `task_complete`
  un-superseded), `aborted` (that turn ended in `turn_aborted`, regardless of reply), `superseded`
  (a newer turn opened before its terminal — never certified by a later, unrelated terminal),
  `reply-missing`, `pending`, or `unavailable`. Single-shot by default; `--budget-ms` bounds an
  optional in-process poll. Read-only, Node built-ins only, no `node:sqlite`, no daemon.
  A reply file's existence alone was never completion — dispatchers previously hand-rolled this
  check and got it wrong.
- `tests/test_ipc_wait.sh` (unit) and `tests/test_wait_contract.sh` (black-box conformance suite
  authored independently from the contract text, with a negative self-test proving a wrong
  implementation fails it). Both wired into CI.
- `codex_ipc_session_inspect.mjs` surfaces the thread's stored `approvalMode` and `sandboxPolicy`
  (schema-tolerant, fail-visible parse), so a dispatcher can preflight whether an injected turn
  will be able to write its reply file before delegating.

### Changed
- `skills/ipc/SKILL.md` and `references/handoff-template.md` document the completion contract's
  mechanical checker, the rollout identity precondition for explicit `--rollout-path`, and the
  rules that dispatch never alters a target thread's model/reasoning/sandbox/approval and that
  subagent model+effort must be set explicitly on every spawn.

## [0.1.4] — 2026-07-10

Post-v0.1.3 hardening: adversarial-review follow-ups plus the R3 router-contract drift sentinel.

### Added
- `tests/test_router_contract.sh`: hermetic router-contract drift sentinel — snapshots the
  `initialize` / `thread-follower-start-turn` request shapes via the client's dry-run CLI and
  classifies canned `no-client-found` / acceptance / malformed responses through the wrapper's
  stubbed-transport path, so a Desktop update that drifts the private contract turns CI red
  before a live failure does. Sentineled vs excluded facets documented in the suite header.
- `tests/test_session_inspect.sh`: hermetic session-inspector suite (temp fixture state; never
  touches `~/.codex`; self-skips without `node:sqlite`).
- Reply viewer/harvester surface a visible advisory when a correlated turn's final message
  starts with `REPLY-SUPERSEDED` while a readable reply file exists (file stays primary;
  machine-consumed output shapes unchanged).

### Changed
- `CODEX_IPC_OBSERVE_BUDGET_MS` default raised `8000` → `20000` ms, informed by a read-only
  census of real dispatch→pickup latencies (auto-load recoveries dominate the tail; census is
  same-machine and mostly idle-thread — documented caveat, still a bounded one-shot cap).
- `codex_ipc_session_inspect.mjs`: `turn_aborted` now has terminal parity wherever
  `task_complete` was treated as terminal (additive output fields; existing fields unchanged);
  rollout candidate discovery canonicalizes Windows `\\?\` aliases, dedupes to physical
  identity, and surfaces genuine multi-candidate ambiguity additively instead of silently
  selecting the first candidate (DB-designated rollout remains the higher authority).
- Harvest/observe diagnostics hex-escape C0/C1/ESC bytes before reaching stderr (stdout token
  and body contracts unchanged).

### Fixed
- Session-inspector mid-turn inference no longer misreports an aborted turn as still active.

## [0.1.3] — 2026-07-09

M2 milestone: dual-source reply harvesting and bounded rollout confirmation, built and verified
by two isolated implementation lanes against the final verified spec (GO_WITH_CONDITIONS; all
gating conditions resolved at integration).

### Added
- Bounded post-acceptance rollout confirmation for both live-send success branches:
  `rollout-hit`, `rollout-pending`, or `rollout-unavailable`. Accepted sends remain
  `gui-delivered`; observation failures map to unavailable without resend.
- Hermetic rollout-reader and dual-source reply-harvest suites are syntax-checked and run on both
  CI matrix legs.

### Changed
- Reply viewing is file-primary with an exactly correlated, read-only rollout fallback when the
  primary is absent or unreadable. Source labels are explicit and fallback text remains
  stdout-only.
- Current-facing README, skill, architecture, compatibility, install, and troubleshooting guidance
  now documents M2 confirmation and dual-source reply semantics.

### Fixed
- Auto-load retry deadline/interval knobs now reject zero or malformed values, warn visibly, and
  fall back to documented positive defaults.
- Corrected the host-identity ledger's refuted universal follower-sandbox claim and the README's
  stale v0.1.1 status line.

## [0.1.2] — 2026-07-09

Host-identity compatibility patch for the 2026-07-09 Codex/ChatGPT Windows app merge: the Codex
Desktop GUI now runs as `ChatGPT.exe` under the unchanged `OpenAI.Codex` package family. Transport
surfaces (`\\.\pipe\codex-ipc`, `codex://`, router methods, `~/.codex` state, RESULT taxonomy,
exit codes) are unaffected and unchanged.

### Added
- `tests/test_autoload_matrix.sh`: hermetic behavioral matrix for `codex_ipc_autoload.ps1` —
  runs the real script under `-DryRun` with mocked foreground identity across
  legacy-Codex / merged-host / other-ChatGPT / ambiguous / unknown × defer / switch /
  restore-if-known; skips cleanly where `powershell.exe` is absent; asserts process hygiene.
  Wired into CI.
- `codex_ipc_autoload.ps1`: `-MockForegroundPath` test hook (used only when
  `-MockForegroundProcess` is supplied; inert in production).
- `docs/COMPATIBILITY.md`: "Host-identity ledger" section with the 2026-07-09 entry.

### Fixed
- **Foreground safety failed open on the merged host** (`codex_ipc_autoload.ps1`): detection was
  name-only (`^(?i)codex$`), so the ChatGPT-branded Codex GUI was classified "known non-Codex"
  and an unowned-thread handoff could fire `codex://` while the operator was in the visible app —
  under every policy. Identity is now positive: legacy `Codex` process name, or `ChatGPT` name
  with executable path under `WindowsApps\OpenAI.Codex_*` (ACL-protected, not name-spoofable).
  A `ChatGPT`-named foreground with unreadable path is ambiguous and defers (fail closed). A
  distinct ChatGPT-family app with a readable non-Codex path keeps the original
  deep-link + snapback behavior. Exit codes, action records, and policy semantics unchanged.
- **`desktopVersionHint` misattributed the Desktop after the rename**
  (`codex_ipc_revalidate.mjs`): `Get-Process -Name Codex` now matched the headless
  `resources\codex.exe` app-server child. The hint (still informational, never gating) now
  reports the `OpenAI.Codex` package identity/version and positively identifies the GUI under
  the package install location, explicitly rejecting `resources\codex.exe`, with an honest
  `guiIdentified:false` when no GUI is found.

## [0.1.1] — 2026-07-09

Post-release hardening from an exhaustive dual-lane audit, verified by a multi-agent workflow.
No breaking changes.

### Added
- CI now runs `install.ps1`/`uninstall.ps1` `-DryRun` on the Windows runner (runtime coverage,
  not just PowerShell parsing).

### Changed
- Docs reconciled with the wrapper's live-send model: `handoff_to_codex.sh --ipc <uuid>` treats
  the explicit UUID as the live-delivery acknowledgement and supplies the client's
  `--send --ack-live-write --allow-any-thread` internally; inspect-before-send is the `/ipc`
  agent's preflight step, not a wrapper gate (README, SECURITY, SKILL.md, contract audit REQ-006
  relabeled as static guidance).
- `codex_ipc_probe.mjs` now defaults to dry-run; live pipe connection requires the explicit
  `--allow-live-ipc-read` flag (`codex_ipc_revalidate.mjs` updated to pass it through).
- Clarified transcript disclosure (automatic resolution fails closed without an injected session
  id; explicit `CLAUDE_TRANSCRIPT` honored only under `CODEX_IPC_INCLUDE_TRANSCRIPT=1`) and the
  local-file threat model (same-user processes can read **and modify** envelope files).
- Contract audit REQ-016 now covers the `gui-unowned` result taxonomy; `test_ipc.sh` asserts no
  `/ipc` path invokes `codex exec` (making the REQ-017 no-headless note verifiable).

### Fixed
- **Installers refuse a destructive `--force`**: `install.sh`/`install.ps1` now reject a
  `--target` that is the source tree, `$HOME`, a filesystem/drive root, or any directory that is
  not an existing ipc-skill install — closing an `rm -rf`/`Remove-Item` data-loss footgun.
- Retention sweep in `handoff_to_codex.sh` refuses to run against a dangerous `CODEX_IPC_ROOT`
  (`$HOME`, `/`, drive root).
- Numeric CLI flags across the `.mjs` tools now reject malformed values (e.g. `10junk`) instead
  of silently truncating them.
- Public-safety scan no longer wholesale-excludes the CI workflow file, so a leak elsewhere in it
  would be caught.
- `codex_ipc_revalidate.mjs` reports the real absolute Codex state-file paths instead of
  skill-relative garbage (`codexStateFiles` diagnostics).
- `codex_ipc_owner_probe.mjs` now requires `--ack-live-write` alongside `--send`.

## [0.1.0] — 2026-07-09

First public release of the `ipc` skill as the `codex-ipc` plugin.

### Added
- **Foreground policy for `--ipc`** (experimental, Windows): default `defer` (never navigate the
  visible Codex app; explicit `codex-foreground-deferred` subreason), opt-in
  `--foreground-policy switch --ack-foreground-switch` (delivers by navigating the visible app to
  the target — disclosed residue), fail-closed `restore-if-known`. Machine-parseable results
  (`RESULT: <top> -- reason=<token> -- confirmation=<token>`), positive-proof target inspection
  before any deep link (ambiguity refuses), total autoload exit-code handling (unknown codes fail
  closed), dry-run/mock test hooks in the autoload helper, and poll timing knobs. Bounded rollout
  observation and dispatch idempotency markers are deferred to a follow-up milestone
  (`confirmation=not-checked` until then).
- Plugin-first repo layout: canonical skill source at `skills/ipc/`, plugin manifest at
  `.claude-plugin/plugin.json`, hermetic tests at `tests/`, docs, installers, and CI.
- `CODEX_IPC_INCLUDE_TRANSCRIPT=1` opt-in gate: Claude transcript paths are no longer included in
  handoff payloads by default.
- `CODEX_IPC_AUTHORIZED_TEST_THREAD` environment variable: replaces the previous built-in
  authorized test thread id; no thread id ships with the code.
- `CODEX_MODEL` environment variable for opt-in `--exec` model pinning.
- Graceful runtime error when `node:sqlite` is unavailable (inspection tools); file-drop mode
  works without it.
- Script-dir-relative sibling resolution in the orchestrating tools (`codex_ipc_revalidate.mjs`,
  `codex_ipc_write_proof.mjs`, `codex_ipc_contract_audit.mjs`) so they run from any cwd.
- QA infrastructure: hermetic transport tests extended 33→70 assertions (foreground-policy,
  inspection-ambiguity, taxonomy, transcript-opt-in coverage) with dual-layout probes so the same
  test files run in both the repo and installed-skill layouts; contract audit extended to 17
  requirements (REQ-012..017: conservative policy default, ack-gated switch,
  file-drop-before-policy-failure, positive inspection proof, parser-compatible taxonomy,
  no-headless); revalidate gained a PowerShell parser check (skip-if-absent); CI gained a
  Windows-guarded PowerShell parse step.

### Changed
- `codex_ipc_write_proof.mjs`: the DB-byte marker count (`markerIncreased`) is now diagnostics
  only, not a pass/fail conjunct — current Codex Desktop stores message text only in the rollout
  JSONL (verified live), which the harness's rollout probe already checks with strictly stronger
  evidence (agent marker acknowledgement + `task_complete`).
- `--exec` no longer defaults model/reasoning-effort pins; they are passed only when
  `CODEX_MODEL` / `CODEX_REASONING_EFFORT` are set.
- `codex_ipc_snapshot.mjs` now requires `--thread` in snapshot mode (no default id).
- `codex_ipc_contract_audit.mjs` rewritten to audit the bundled skill files (the previous version
  depended on private dev-repo artifacts).
- SKILL.md split: deep background moved to `skills/ipc/references/` (architecture, security
  model, troubleshooting).

### Security
- Removed all personal paths, private conversation/thread ids, and machine-specific defaults from
  code, docs, examples, and tests.
- Hardened the public-safety scan with structural checks (tool-state directories such as
  `.omc`/`.claude`/`.codex`, and non-synthetic UUIDs embedded in file/dir names), and converted the
  installers from a filename denylist to a source allowlist (`SKILL.md`, `scripts/`, `references/`,
  `examples/` only) so locally generated state can never be copied or shipped.
