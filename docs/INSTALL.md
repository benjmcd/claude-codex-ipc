# Installation

Two supported shapes. Both use `skills/ipc/` as the single source; nothing else in the repo is
required at runtime.

## A. Claude Code plugin (recommended)

The repo is plugin-shaped: `.claude-plugin/plugin.json` + `skills/ipc/`. For local/dev use, add
the repo directory as a plugin with your Claude Code version's plugin command (e.g.
`claude plugin add /path/to/claude-codex-ipc`). No marketplace metadata is shipped yet.

- Invocation: `/codex-ipc:ipc`
- Update: pull the repo; the plugin picks up the new files.
- Uninstall: remove the plugin via Claude Code's plugin management.

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
./install.sh --force            # replace an existing install (prints what is deleted)
./uninstall.sh --dry-run        # print exactly what would be deleted
./uninstall.sh                  # asks for confirmation unless --yes
```

PowerShell equivalents:

```powershell
.\install.ps1 -DryRun
.\install.ps1
.\install.ps1 -Force
.\uninstall.ps1 -DryRun
.\uninstall.ps1                 # refuses without -Yes (non-interactive by design; use -DryRun to preview)
```

- Invocation: `/ipc`
- Update: re-run `install` with `--force` / `-Force`.

## Runtime dependencies (by feature)

| Feature | Needs |
|---|---|
| File-drop handoff, reply viewer | bash + coreutils (Git Bash on Windows). Nothing else. |
| Read-only inspection (inspector/locator/snapshot) | Node.js with `node:sqlite` support (≥ 22.5; older 22.x/23.x lines may require `--experimental-sqlite`) |
| Live Desktop IPC (`--ipc`) | Windows, Node.js, Codex Desktop running; PowerShell for auto-load |
| `--app` / `--open` / `--exec` | Codex CLI on PATH |

See [COMPATIBILITY.md](COMPATIBILITY.md) for the full matrix.
