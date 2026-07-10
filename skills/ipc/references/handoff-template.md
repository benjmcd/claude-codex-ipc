# Handoff / delegation template

A reusable schema so a delegated lane — a subagent, a Codex session via `/ipc`, or a parallel Claude session — is self-contained and needs no follow-up steering. Fill every field; if one is genuinely N/A, write "N/A" rather than leaving it blank.

Per the `/ipc` workspace-scoping rule, place the FILLED handoff inside the associated repo/worktree (never in a global temp / Downloads / Desktop path). This file is the blank reference schema, not a filled handoff.

- **Objective:** the outcome that defines success, in one sentence.
- **Scope fence:** exactly what is in scope.
- **Non-goals:** what is explicitly out of scope / must not be touched.
- **Boundaries & safety:** which files/dirs/worktrees the agent may modify; what it must not; "ask before acting outside <workspace>."
- **Canonical sources of truth:** the live-authority files/state to read first; distinguish them from mirrors or handoff-local copies.
- **Isolation:** the worktree path + branch this lane owns. Confirm no other active session owns it before starting.
- **Done-criteria:** concrete, checkable completion conditions (tests pass, artifacts produced, gates cleared).
- **Verification:** how the work will be checked, and by whom — a separate review lane, not self-approval. Also specify the MECHANICAL self-checks the worker must run and attach evidence for (greps for required/absent phrases, hashes, counts, exit codes): a delegated reviewer told only "your output will be cross-checked" tends to settle at topic-level granularity, while forced mechanical checks surface clause-level omissions.
- **Constraints:** model/effort for SUBAGENTS the lane may deploy — name exact model IDs AND
  effort levels, and require both to be set EXPLICITLY on EVERY subagent spawn, never left to
  the app's global default (an omitted model silently inherits the operator's `config.toml`
  default, which may be outside the authorized roster — observed in production). The target
  thread's own model, reasoning,
  sandbox policy, and approval mode are never changed by dispatch — the turn runs under whatever
  the thread is already set to. Narrowest-correct-change; no-delete/archive-instead; no
  co-author attribution; current phase (audit / plan / implement).
- **Completion contract:** self-verification/self-validation is mandatory and runs BEFORE the
  reply is written; the reply (file and/or final message) is the LAST act of the turn — no work,
  amendment, or re-verification may follow it. If a post-reply amendment ever becomes
  unavoidable, supersede explicitly: state `REPLY-SUPERSEDED` as the FIRST LINE of a final
  message (the harvester's marker detection is first-line exact-token by design) and overwrite
  the same dispatch's reply file. KNOWN LIMITATION: reply viewing is file-primary by design, so
  if the overwrite is blocked (e.g. sandboxed turn), the superseding content is visible only via
  thread inspection (the final message), not via the reply viewer — a dispatcher acting on a
  supersession signal must re-inspect the thread, not re-read the file. Dispatcher side: a reply
  artifact's existence alone is NOT completion — classify the lane done only when the reply
  exists AND the dispatch's OWN turn (the turn whose `user_message` carries this dispatch's task
  marker; correlate by `turn_id` when present) reached `task_complete` without being superseded
  by a newer `task_started` before its terminal. Never borrow a later, unrelated turn's terminal
  to certify an earlier dispatch. `turn_aborted` on that turn is terminal-failed regardless of
  reply existence (surface it, do not wait). Read-only inspection parsing event types (never
  substring greps). A reply file observed while its turn is still open, or whose turn was
  superseded, is provisional. One delegation = one reply; app-driven turns after the reply (goal
  checks and similar) are supersession territory, found by re-inspection.
- **Context:** the minimum background needed, plus links to prior state/worklog. Keep it minimal but sufficient.
