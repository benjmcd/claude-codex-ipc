# Contributing

## Ground rules

1. **`skills/ipc/` is the canonical skill source.** Do not create duplicate copies of the skill
   elsewhere in the repo; docs link into it instead.
2. **Safety invariants are not negotiable.** Any change must preserve: explicit-UUID targeting for
   live sends (no heuristics), dry-run-by-default with `--send --ack-live-write` gating,
   file-drop-first fallback, `readOnly:true` SQLite access, opt-in transcript disclosure, and no
   shipped authorized thread id. `tests/` and `codex_ipc_contract_audit.mjs` encode most of these —
   keep them green and extend them with your change.
3. **No private/local content.** No personal filesystem paths, real conversation/session UUIDs,
   API keys, or machine-specific defaults in code, docs, examples, or tests. CI's public-safety
   scan (`tests/scan_public_safety.sh`) enforces a baseline; run it locally.
4. **Hermetic tests only.** Tests must not require Codex Desktop, the Codex CLI, Claude state,
   `node:sqlite`, or the network. Stub external binaries the way `tests/test_ipc.sh` does.

## Dev loop

```bash
# syntax
bash -n skills/ipc/scripts/handoff_to_codex.sh
bash -n skills/ipc/scripts/codex_ipc_replies.sh
for f in skills/ipc/scripts/*.mjs; do node --check "$f"; done

# behavior (hermetic)
bash tests/test_ipc.sh
bash tests/test_reply_view.sh

# public-safety scan
bash tests/scan_public_safety.sh

# static contract audit
node skills/ipc/scripts/codex_ipc_contract_audit.mjs
```

On Windows, run the above through Git Bash.

## Live-IPC changes

Changes to the experimental Desktop route (`codex_ipc_client.mjs`, autoload, probes) cannot be
proven by CI — CI never performs live IPC. If your change affects live behavior, say so in the PR,
describe the manual revalidation you ran (`codex_ipc_revalidate.mjs`, and
`codex_ipc_write_proof.mjs` against a thread you own), and update
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) if support/stability changed. Do not claim live
behavior works without having actually run it.

## Commit / PR hygiene

- Keep diffs minimal and focused; update docs in the same PR as behavior changes.
- Update `CHANGELOG.md` under the `[Unreleased]` heading.
