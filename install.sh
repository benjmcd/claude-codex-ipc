#!/usr/bin/env bash
# Standalone installer: copies skills/ipc/ to the user's Claude skills directory.
# Safe by default: --dry-run prints the exact plan; overwriting an existing install
# requires --force; local/generated state is never copied.
set -euo pipefail

usage() {
    cat <<EOF
Usage: ./install.sh [--dry-run] [--force] [--target <dir>]

  --dry-run       Print exactly what would be copied (and deleted under --force), then exit.
  --force         Replace an existing install at the target (prints what is deleted first).
  --target <dir>  Override the install target. Default: \$HOME/.claude/skills/ipc

Copies only the skill source (SKILL.md, scripts/, references/, examples/). Never copies
backups (*.bak*), generated task/reply envelopes, logs, caches, or node_modules.
EOF
}

DRY_RUN=0; FORCE=0
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills/ipc"
TARGET="${HOME}/.claude/skills/ipc"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift;;
        --force) FORCE=1; shift;;
        --target) TARGET="${2:?--target requires a directory}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1;;
    esac
done

[[ -f "${SRC_ROOT}/SKILL.md" ]] || { echo "ERROR: skill source not found at \"${SRC_ROOT}\" (run from the repo root)." >&2; exit 1; }

# Enumerate what would be copied: ALLOWLISTED skill source only (SKILL.md, scripts/,
# references/, examples/). A sibling state dir (e.g. .omc/, .claude/) written into the
# tree by local tooling is therefore never even in scope. The dot-segment filter below
# is applied to the SRC_ROOT-RELATIVE path only — never to the absolute path — so a
# repo cloned under a dotted ancestor (~/.claude/plugins/...) still installs fine.
ALLOWED_ROOTS=()
for sub in SKILL.md scripts references examples; do
    [[ -e "$SRC_ROOT/$sub" ]] && ALLOWED_ROOTS+=("$SRC_ROOT/$sub")
done
FILES=()
while IFS= read -r f; do
    rel="${f#"$SRC_ROOT"/}"
    case "/$rel" in */.*) continue;; esac
    FILES+=("$f")
done < <(
    find "${ALLOWED_ROOTS[@]}" -type f \
        ! -name '*.bak' ! -name '*.bak-*' \
        ! -name '*.task.md' ! -name '*.reply.md' \
        ! -name '*.log' ! -name '*.tmp' \
        ! -path '*/node_modules/*' ! -path '*/.git/*' \
        | LC_ALL=C sort
)
[[ "${#FILES[@]}" -gt 0 ]] || { echo "ERROR: nothing to install (no files found under \"${SRC_ROOT}\")." >&2; exit 1; }

echo "Install plan:"
echo "  source : \"${SRC_ROOT}\""
echo "  target : \"${TARGET}\""
echo "  files  : ${#FILES[@]}"
for f in "${FILES[@]}"; do
    echo "    copy: \"${f#"$SRC_ROOT"/}\""
done

if [[ -e "$TARGET" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        echo "  delete (then replace): \"${TARGET}\" and everything under it"
    else
        echo ""
        echo "ERROR: refusing to overwrite existing install at \"${TARGET}\"." >&2
        echo "Re-run with --force to replace it (a --dry-run --force shows what is deleted)." >&2
        exit 1
    fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "Dry run: nothing was copied or deleted."
    exit 0
fi

if [[ -e "$TARGET" ]]; then
    rm -rf -- "$TARGET"
fi
mkdir -p -- "$TARGET"
for f in "${FILES[@]}"; do
    rel="${f#"$SRC_ROOT"/}"
    mkdir -p -- "$TARGET/$(dirname "$rel")"
    cp -p -- "$f" "$TARGET/$rel"
done

echo ""
echo "Installed ${#FILES[@]} files to \"${TARGET}\". Invoke as /ipc in Claude Code."
