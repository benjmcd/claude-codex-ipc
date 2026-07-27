#!/usr/bin/env bash
# Standalone uninstaller: removes the ipc skill from the user's Claude skills directory.
# Safe by default: --dry-run prints the exact deletion list; real runs ask for
# confirmation unless --yes.
set -euo pipefail

usage() {
    cat <<EOF
Usage: ./uninstall.sh [--dry-run] [--yes] [--target <dir>]

  --dry-run       Print exactly what would be deleted, then exit.
  --yes           Skip the confirmation prompt.
  --target <dir>  Override the install target. Default: \$HOME/.claude/skills/ipc
EOF
}

DRY_RUN=0; YES=0
TARGET="${HOME}/.claude/skills/ipc"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift;;
        --yes) YES=1; shift;;
        --target) TARGET="${2:?--target requires a directory}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1;;
    esac
done

if [[ ! -e "$TARGET" ]]; then
    echo "Nothing to do: no install at \"${TARGET}\"."
    exit 0
fi

# Resolved-path guard, mirroring install.sh's --force guard. The marker check below is
# NOT sufficient on its own: this repository's own skills/ipc carries `name: ipc`, so a
# marker-only uninstaller would recursively delete the canonical source tree (or a
# worktree copy) if it were named as --target.
SRC_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TGT_REAL="$(cd "$TARGET" 2>/dev/null && pwd -P || echo "$TARGET")"
HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
case "$TGT_REAL" in
    "$SRC_REAL"|"$SRC_REAL"/*|"$HOME_REAL"|/|/[A-Za-z]|"")
        echo "ERROR: refusing dangerous --target \"${TARGET}\"." >&2
        echo "It resolves inside this source tree, to \$HOME, or to a filesystem root." >&2
        exit 1
        ;;
esac

# Sanity guard: only ever delete a directory that actually looks like this skill.
if [[ ! -f "${TARGET}/SKILL.md" ]] || ! grep -q '^name: ipc$' "${TARGET}/SKILL.md" 2>/dev/null; then
    echo "ERROR: \"${TARGET}\" does not look like an installed ipc skill (no matching SKILL.md)." >&2
    echo "Refusing to delete it. Remove it manually if you are sure." >&2
    exit 1
fi

echo "Deletion plan (everything under the install target):"
find "$TARGET" -type f | LC_ALL=C sort | while IFS= read -r f; do
    echo "    delete: \"${f}\""
done
echo "    delete: \"${TARGET}\" (directory)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "Dry run: nothing was deleted."
    exit 0
fi

if [[ "$YES" -ne 1 ]]; then
    printf 'Proceed? [y/N] '
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Aborted; nothing was deleted."; exit 1; }
fi

rm -rf -- "$TARGET"
echo "Removed \"${TARGET}\"."
