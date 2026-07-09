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
- **Constraints:** model/effort; narrowest-correct-change; no-delete/archive-instead; no co-author attribution; current phase (audit / plan / implement).
- **Context:** the minimum background needed, plus links to prior state/worklog. Keep it minimal but sufficient.
