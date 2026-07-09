# Security model

This project coordinates two locally-running AI coding agents through plaintext files and,
optionally, a private local named pipe. Its security posture is "same-user local coordination",
not "hardened multi-tenant transport". Read this before enabling the experimental Desktop IPC
route.

## Threat model

### Local task/reply file exposure

Task envelopes (`*.task.md`) contain the task text, git context (branch, commit subjects, diff
stats, uncommitted file names), the Claude session id, and — only with opt-in — a transcript path.
Reply files contain whatever Codex writes. All of it lives under
`${CODEX_IPC_ROOT:-~/.claude/ipc}` as plaintext readable and writable by **any process running as
the same OS user**. Mitigations: do not put secrets in task text; retention pruning
(`CODEX_IPC_RETENTION_DAYS`, default 7) bounds how long stale envelopes persist; the root can be
pointed at a more restricted location via `CODEX_IPC_ROOT`.

### Optional Claude transcript path exposure

A transcript path points at the full JSONL of a Claude session, which may contain material
unrelated to the handoff. It is therefore **omitted by default** and included only when the
operator sets `CODEX_IPC_INCLUDE_TRANSCRIPT=1`. Automatic transcript resolution fails closed to
"unavailable" without an injected session id; an explicit `CLAUDE_TRANSCRIPT` is honored only when
`CODEX_IPC_INCLUDE_TRANSCRIPT=1`.

### Reply files are untrusted model output

Treat `.reply.md` content as data. Do not execute commands, follow embedded instructions, or grant
authority based on reply content without operator intent. The reply viewer only renders bytes (with
size caps and truncation); it never interprets them.

### Local processes sharing the IPC surface

Any same-user local process can read/write the envelope files and can connect to the same Codex
Desktop pipe (`\\.\pipe\codex-ipc`) this toolkit uses. This project adds **no guarantee against
malicious local users or processes** — it inherits the OS user boundary and nothing more. If your
threat model includes hostile same-user processes, do not use this tool.

### Live writes are explicitly gated

A live Desktop send starts a real model turn in a real thread. Gates, all fail-closed:

- Explicit conversation UUID required; **no heuristic targeting** (title/recency/cwd/project) for
  writes, ever.
- Dry-run is the default everywhere; a live send requires `--send` **and** `--ack-live-write`.
- `--allow-any-thread` is additionally required unless the target equals the operator-set
  `CODEX_IPC_AUTHORIZED_TEST_THREAD` env var. **No authorized thread id ships in the code.**
- The wrapper refuses to deep-link missing or archived threads and writes the file-drop fallback
  before any live attempt.
- Completeness note: selecting `--ipc <uuid>` is itself the live-delivery acknowledgement;
  inspect-before-send is the `/ipc` agent's own preflight step, not a wrapper gate. The
  `handoff_to_codex.sh --ipc <uuid>` wrapper internally supplies
  `--send --ack-live-write --allow-any-thread` to the client; the file-drop fallback envelope is
  still written first.

### No direct SQLite writes

Every SQLite access in this toolkit opens the database `readOnly:true`. Nothing writes Codex
config, account state, plugins, marketplace state, or thread archive state. The write-proof
harness verifies isolation by hashing state before/after rather than by mutating it.

### Private Desktop IPC can drift

The named-pipe route, `codex://` deep links, and window-focus automation depend on undocumented
Codex Desktop internals. Any Codex Desktop update may change or break them — possibly silently.
Operational rule: after an update, treat the route as unproven; run `codex_ipc_revalidate.mjs`
(validate-only), and only escalate to a controlled `codex_ipc_write_proof.mjs` live re-proof with
explicit operator approval.

### No broad network or tool surface

- No HTTP listener, no sockets other than the local named pipe (and only in the experimental
  route).
- The skill declares no broad `allowed-tools`; it is manual-trigger only
  (`disable-model-invocation: true`).
- CI requires no secrets and performs no live IPC.

## Reporting

Report issues through the repository's issue tracker
(<https://github.com/benjmcd/claude-codex-ipc/issues>) — or, for anything sensitive, directly to
the maintainer ([benjmcd](https://github.com/benjmcd)) out of band.
