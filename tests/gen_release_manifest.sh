#!/usr/bin/env bash
# Deterministic release-manifest generator + checker (NEXT-STEPS §5 CANON-MANIFEST).
#
# Emits immutable manifests whose rows are EXACTLY:
#     gitMode<TAB>sha256<TAB>relativePath
# LC_ALL=C sorted by relativePath, UTF-8, LF line endings.
#
# Two row sources:
#   * git-ref sets (base/final × runtime/overlay): gitMode is the git index/tree mode
#     (100644 / 100755) as the canonical POSIX exec-bit; sha256 is the content hash of the
#     blob AT THE REF, so the manifest is frozen to that commit and immune to working-tree
#     additions (e.g. the Phase-1 files added on top of BASE_SHA).
#   * installed-root inventories: real on-disk files under a copy of the skill. Windows
#     roots record gitMode as "N/A" (POSIX mode not-applicable, git records 100644 while
#     Git Bash reports 0755 under core.filemode=false) and compare on relativePath + sha256.
#
# The runtime file-set replicates install.sh's allowlist (SKILL.md, scripts/, references/,
# examples/) minus dotfiles / *.bak* / *.task.md / *.reply.md / *.log / *.tmp. The overlay
# file-set = runtime + tests/. Phase 1 freezes ONLY the base pair (base-runtime=24,
# base-overlay=37) plus the three installed-root inventories; the final-* pair is a Phase-4
# artifact frozen at the tested commit.
#
# Usage:
#   gen_release_manifest.sh gen   --set  <base-runtime|base-overlay|final-runtime|final-overlay> [--ref <sha>] --out <file>
#   gen_release_manifest.sh gen   --root <dir>                                                                 --out <file>
#   gen_release_manifest.sh check --set  <...> [--ref <sha>] --file <file>
#   gen_release_manifest.sh check --root <dir>               --file <file>
#   gen_release_manifest.sh freeze     # (re)generate all frozen base+root manifests + SHA256SUMS
#   gen_release_manifest.sh check-all  # re-verify every frozen manifest + its recorded sha256
set -uo pipefail

BASE_SHA="0fbd517fcfbe7c20d34f3ca96eb14624868961f2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$REPO_ROOT/release/manifests"

# Installed-root map (kept as $HOME-relative literals; never expanded into any committed file).
root_dir_for() {
  case "$1" in
    root-claude) printf '%s\n' "$HOME/.claude/skills/ipc" ;;
    root-agents) printf '%s\n' "$HOME/.agents/skills/ipc" ;;
    root-codex)  printf '%s\n' "$HOME/.codex/skills/ipc" ;;
    *) return 1 ;;
  esac
}

die() { echo "ERROR: $*" >&2; exit 2; }

# ---- file-set membership (mirrors install.sh allowlist semantics) ------------------------
in_scope() { # in_scope <repo-relative-path> <runtime|overlay>
  local p="$1" scope="$2" runtime=0
  case "$p" in
    */.*) return 1 ;;                                            # dot-segment
    *.bak|*.bak-*|*.task.md|*.reply.md|*.log|*.tmp) return 1 ;;  # generated/backup state
  esac
  case "$p" in
    skills/ipc/SKILL.md|skills/ipc/scripts/*|skills/ipc/references/*|skills/ipc/examples/*)
      runtime=1 ;;
  esac
  if [ "$scope" = runtime ]; then
    [ "$runtime" -eq 1 ]
  else
    [ "$runtime" -eq 1 ] && return 0
    case "$p" in tests/*) return 0 ;; esac
    return 1
  fi
}

# ---- row emitters ------------------------------------------------------------------------
emit_ref_manifest() { # emit_ref_manifest <ref> <runtime|overlay>
  local ref="$1" scope="$2" meta path mode obj rest sha
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || die "ref not found: $ref"
  while IFS=$'\t' read -r meta path; do
    [ -n "$path" ] || continue
    in_scope "$path" "$scope" || continue
    mode="${meta%% *}"
    rest="${meta#* }"        # "blob <obj>"
    obj="${rest#* }"
    sha="$(git -C "$REPO_ROOT" cat-file blob "$obj" | sha256sum | cut -d' ' -f1)"
    printf '%s\t%s\t%s\n' "$mode" "$sha" "$path"
  done < <(git -C "$REPO_ROOT" ls-tree -r "$ref") | LC_ALL=C sort -t"$(printf '\t')" -k3,3
}

emit_root_manifest() { # emit_root_manifest <root-dir>
  local root="$1" f rel sha
  [ -d "$root" ] || die "installed root not found: $root"
  ( cd "$root" && find . -type f 2>/dev/null ) | while IFS= read -r f; do
    rel="${f#./}"
    case "/$rel" in */.*) continue ;; esac
    sha="$(sha256sum "$root/$rel" | cut -d' ' -f1)"
    printf 'N/A\t%s\t%s\n' "$sha" "$rel"
  done | LC_ALL=C sort -t"$(printf '\t')" -k3,3
}

set_params() { # sets globals SET_REF / SET_SCOPE for a named --set
  case "$1" in
    base-runtime)  SET_REF="$BASE_SHA"; SET_SCOPE=runtime ;;
    base-overlay)  SET_REF="$BASE_SHA"; SET_SCOPE=overlay ;;
    final-runtime) SET_REF="${2:-}";    SET_SCOPE=runtime ;;
    final-overlay) SET_REF="${2:-}";    SET_SCOPE=overlay ;;
    *) die "unknown --set '$1'" ;;
  esac
  [ -n "$SET_REF" ] || die "--set $1 requires --ref <sha>"
}

generate_to_stdout() { # generate_to_stdout <selector-kind> <selector-value> <ref>
  case "$1" in
    set)  set_params "$2" "$3"; emit_ref_manifest "$SET_REF" "$SET_SCOPE" ;;
    root) emit_root_manifest "$2" ;;
    *) die "internal: bad selector kind $1" ;;
  esac
}

# ---- subcommands -------------------------------------------------------------------------
cmd_gen() {
  local kind="" val="" ref="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --set)  kind=set;  val="$2"; shift 2 ;;
      --root) kind=root; val="$2"; shift 2 ;;
      --ref)  ref="$2";  shift 2 ;;
      --out)  out="$2";  shift 2 ;;
      *) die "gen: unknown arg '$1'" ;;
    esac
  done
  [ -n "$kind" ] || die "gen: --set or --root required"
  [ -n "$out" ]  || die "gen: --out required"
  mkdir -p "$(dirname "$out")"
  generate_to_stdout "$kind" "$val" "$ref" > "$out"
  echo "wrote $(wc -l < "$out" | tr -d ' ') rows -> $out"
}

cmd_check() {
  local kind="" val="" ref="" file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --set)  kind=set;  val="$2"; shift 2 ;;
      --root) kind=root; val="$2"; shift 2 ;;
      --ref)  ref="$2";  shift 2 ;;
      --file) file="$2"; shift 2 ;;
      *) die "check: unknown arg '$1'" ;;
    esac
  done
  [ -n "$kind" ] || die "check: --set or --root required"
  [ -n "$file" ] || die "check: --file required"
  [ -f "$file" ] || die "check: frozen manifest not found: $file"
  local tmp; tmp="$(mktemp)"
  generate_to_stdout "$kind" "$val" "$ref" > "$tmp"
  if diff -u "$file" "$tmp" >/dev/null 2>&1; then
    echo "CHECK OK: $file ($(wc -l < "$file" | tr -d ' ') rows)"
    rm -f "$tmp"; return 0
  fi
  echo "CHECK FAIL: $file drifted from freshly generated manifest:" >&2
  diff -u "$file" "$tmp" >&2
  rm -f "$tmp"; return 1
}

frozen_targets() {
  # name<TAB>kind<TAB>value  (ref implied: base sets use BASE_SHA)
  printf 'base-runtime\tset\tbase-runtime\n'
  printf 'base-overlay\tset\tbase-overlay\n'
  printf 'root-claude\troot\t%s\n' "$(root_dir_for root-claude)"
  printf 'root-agents\troot\t%s\n' "$(root_dir_for root-agents)"
  printf 'root-codex\troot\t%s\n'  "$(root_dir_for root-codex)"
}

cmd_freeze() {
  mkdir -p "$MANIFEST_DIR"
  local name kind val out
  while IFS=$'\t' read -r name kind val; do
    out="$MANIFEST_DIR/$name.manifest"
    generate_to_stdout "$kind" "$val" "" > "$out"
    echo "froze $(wc -l < "$out" | tr -d ' ') rows -> release/manifests/$name.manifest"
  done < <(frozen_targets)
  ( cd "$MANIFEST_DIR" && sha256sum \
      base-runtime.manifest base-overlay.manifest \
      root-claude.manifest root-agents.manifest root-codex.manifest \
      > MANIFEST-SHA256SUMS.txt )
  echo "recorded self-hashes -> release/manifests/MANIFEST-SHA256SUMS.txt"
}

cmd_check_all() {
  local rc=0 name kind val
  while IFS=$'\t' read -r name kind val; do
    cmd_check --"$kind" "$val" --file "$MANIFEST_DIR/$name.manifest" || rc=1
  done < <(frozen_targets)
  if [ -f "$MANIFEST_DIR/MANIFEST-SHA256SUMS.txt" ]; then
    if ( cd "$MANIFEST_DIR" && sha256sum -c MANIFEST-SHA256SUMS.txt ) >/dev/null 2>&1; then
      echo "CHECK OK: recorded manifest self-hashes match"
    else
      echo "CHECK FAIL: recorded manifest self-hashes drifted" >&2; rc=1
    fi
  else
    echo "CHECK FAIL: MANIFEST-SHA256SUMS.txt missing" >&2; rc=1
  fi
  return $rc
}

main() {
  [ $# -ge 1 ] || die "usage: gen_release_manifest.sh <gen|check|freeze|check-all> ..."
  local sub="$1"; shift
  case "$sub" in
    gen)       cmd_gen "$@" ;;
    check)     cmd_check "$@" ;;
    freeze)    cmd_freeze "$@" ;;
    check-all) cmd_check_all "$@" ;;
    *) die "unknown subcommand '$sub'" ;;
  esac
}

main "$@"
