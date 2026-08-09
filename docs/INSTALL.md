# Installation

Two supported shapes. Both use `skills/ipc/` as the single source; nothing else in the repo is
required at runtime.

## A. Claude Code plugin (recommended)

The repo is plugin-shaped: `.claude-plugin/plugin.json` + `skills/ipc/`, but it ships no marketplace
metadata and does not claim persistent marketplace installation.

`claude --plugin-dir /path/to/claude-codex-ipc` is a session-local plugin-development launch whose invocation is `/codex-ipc:ipc` for that Claude session.

```bash
claude --plugin-dir /path/to/claude-codex-ipc
```

This command is current-version guidance verified against the currently tested Claude Code CLI,
not an eternal external-CLI compatibility guarantee. Pull repository updates before starting the
session-local development launch again.

> **Windows path-length note:** clone to a short path (e.g. `C:\dev\claude-codex-ipc`) and
> run `git config core.longpaths true` after cloning — deeply nested locations (cloud-synced
> user folders, future `worktrees/`) can exceed the legacy 260-char limit otherwise. Avoid
> cloud-synced folders for git working trees generally (sync engines race git on `.git` locks).

## B. Standalone skill

Copies `skills/ipc/` to your user skills directory:

- Unix-like / Git Bash: `~/.claude/skills/ipc/`
- Windows: `%USERPROFILE%\.claude\skills\ipc\`

Use the bundled installers — they are dry-run-capable, refuse destructive overwrite without an
explicit flag, copy only the skill source (never local/generated state), and handle paths with
spaces:

```bash
./install.sh --dry-run          # print exactly what would be copied, then stop
./install.sh                    # install; refuses if the target exists
./install.sh --dry-run --force
./install.sh --force
./uninstall.sh --dry-run        # print exactly what would be deleted
./uninstall.sh                  # asks for confirmation unless --yes
```

PowerShell equivalents:

```powershell
.\install.ps1 -DryRun
.\install.ps1
.\install.ps1 -DryRun -Force
.\install.ps1 -Force
.\uninstall.ps1 -DryRun
.\uninstall.ps1                 # refuses without -Yes (non-interactive by design; use -DryRun to preview)
```

- Invocation: `/ipc`
- Update: re-run `install` with `--force` / `-Force`.

## Force replacement and rollback

`--force` / `-Force` removes the entire existing target before copying.
Local modifications and unlisted residue are not preserved.
There is no automatic backup, transaction, or rollback.
Run dry-run first.
Preserve the current target outside the target path or retain a known source ref before force.
Rollback means installing from that preserved or known source, not an automatic command.
`CODEX_IPC_ROOT` transport files are separate and neither migrated nor cleaned by installer replacement.

## Runtime dependencies (by feature)

| Feature | Needs |
|---|---|
| File-drop handoff, primary reply-file viewing | bash + coreutils (Git Bash on Windows). Nothing else. |
| Bounded rollout confirmation and rollout-derived reply fallback | Node.js (built-ins only). Optional: primary reply-file viewing remains available without Node. |
| Read-only inspection (inspector/locator/snapshot) | Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`) |
| Live Desktop IPC (`--ipc`) | Windows, Node.js, Codex Desktop running; PowerShell for auto-load |

See [COMPATIBILITY.md](COMPATIBILITY.md) for the full matrix.
