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
#   gen_release_manifest.sh check-all [--no-roots]
#                                      # re-verify every frozen manifest + its recorded sha256,
#                                      # then cross-check the manifests against each other
#   gen_release_manifest.sh cross-check
#                                      # the cross-manifest agreement checks alone (host-free)
#
# check-all --no-roots omits ONLY the re-derivation of the three installed-root inventories.
# Those describe host-local directories (~/.claude, ~/.agents, ~/.codex) that do not exist on
# a CI runner, so re-deriving them there is not merely inconvenient, it is undefined. The
# committed BYTES of root-*.manifest are still verified, because the MANIFEST-SHA256SUMS.txt
# check below is unconditional and covers every manifest file. What --no-roots gives up is the
# "manifest still matches the installed copy" claim, which only a real host can make.
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

frozen_targets() { # frozen_targets [--no-roots]
  # name<TAB>kind<TAB>value<TAB>ref  (ref is used only by set kinds; base sets ignore
  # it and use BASE_SHA, final sets require it). The final pair is pinned to the tested
  # release commit recorded in release/manifests/FINAL_REF so check-all re-derives and
  # verifies them against that exact ref instead of leaving them unchecked.
  local with_roots=1
  [ "${1:-}" = "--no-roots" ] && with_roots=0
  printf 'base-runtime\tset\tbase-runtime\t\n'
  printf 'base-overlay\tset\tbase-overlay\t\n'
  if [ "$with_roots" -eq 1 ]; then
    printf 'root-claude\troot\t%s\t\n' "$(root_dir_for root-claude)"
    printf 'root-agents\troot\t%s\t\n' "$(root_dir_for root-agents)"
    printf 'root-codex\troot\t%s\t\n'  "$(root_dir_for root-codex)"
  fi
  local final_ref=""
  [ -f "$MANIFEST_DIR/FINAL_REF" ] && final_ref="$(tr -d ' \t\r\n' < "$MANIFEST_DIR/FINAL_REF")"
  if [ -n "$final_ref" ]; then
    printf 'final-runtime\tset\tfinal-runtime\t%s\n' "$final_ref"
    printf 'final-overlay\tset\tfinal-overlay\t%s\n' "$final_ref"
  fi
}

cmd_freeze() {
  mkdir -p "$MANIFEST_DIR"
  local name kind val ref out
  while IFS=$'\t' read -r name kind val ref; do
    out="$MANIFEST_DIR/$name.manifest"
    generate_to_stdout "$kind" "$val" "$ref" > "$out"
    echo "froze $(wc -l < "$out" | tr -d ' ') rows -> release/manifests/$name.manifest"
  done < <(frozen_targets)
  # Self-hash every manifest that actually exists (the final pair is present only after
  # a release ref is recorded); glob keeps the list correct without hard-coding names.
  ( cd "$MANIFEST_DIR" && sha256sum ./*.manifest > MANIFEST-SHA256SUMS.txt )
  echo "recorded self-hashes -> release/manifests/MANIFEST-SHA256SUMS.txt"
}

# ---- committed-manifest cross-checks (host-independent; pure text) -----------------------
# Every check above verifies ONE manifest against ONE source. Nothing verified that the seven
# agree with EACH OTHER, so a root manifest regenerated from a half-propagated root, an
# asymmetric propagation, or a stray file in one root and not another was invisible to every
# gate. These checks read only committed bytes, so they also run on CI, including under
# --no-roots (which drops only the re-derivation from host directories a runner does not have).
#
# SCOPE NOTE -- deliberate, and load-bearing. Root manifests are regenerated at PROPAGATION
# time, never at release/rebind time. That is repo precedent, stated verbatim in the 6ca3ae2
# and f40183d release commits ("root-* are byte-unchanged: the installed host roots still hold
# v0.1.8 and were not propagated by this patch"). Between a release and its propagation the
# roots therefore hold the PREVIOUS release's bytes BY DESIGN. A check demanding that
# root-codex hashes equal final-runtime hashes would be red for that entire window and would be
# switched off within a week -- precisely the trap a "regenerate at HEAD and diff" design would
# have set for the final-* pair. So the hash equivalence GATED here is the one that holds in
# both states: the three roots against each other, which are always propagated together. The
# root-versus-release correspondence is measured and REPORTED, and never gates.
#
# The three fixture rows below are the sole declared hash exceptions: the installed copies are
# CRLF on disk while git stores them LF, so their sha256 cannot equal the blob hash. The
# exception set is asserted in BOTH directions, so it cannot silently grow or rot.
DECLARED_ROOT_HASH_EXCEPTIONS='tests/fixtures/rollout/rollout-basic-11111111-1111-4111-8111-111111111111.jsonl
tests/fixtures/rollout/rollout-nested-22222222-2222-4222-8222-222222222222.jsonl
tests/fixtures/rollout/rollout-superseded-33333333-3333-4333-8333-333333333333.jsonl'

cmd_cross_check() {
  local rc=0 tmp t need n
  [ $# -eq 0 ] || die "cross-check: takes no arguments (got '$1')"
  for need in root-claude root-agents root-codex final-runtime base-overlay; do
    [ -f "$MANIFEST_DIR/$need.manifest" ] || {
      echo "CROSS FAIL: release/manifests/$need.manifest missing; cross-checks cannot run" >&2
      return 1
    }
  done
  t="$(printf '\t')"
  tmp="$(mktemp -d)"

  # C1 -- the two overlay roots are one inventory.
  if cmp -s "$MANIFEST_DIR/root-claude.manifest" "$MANIFEST_DIR/root-agents.manifest"; then
    echo "CROSS OK: root-claude.manifest and root-agents.manifest are byte-identical"
  else
    echo "CROSS FAIL: root-claude.manifest and root-agents.manifest diverged" >&2; rc=1
  fi

  # path<TAB>sha projections. Root paths are skill-relative; runtime paths carry skills/ipc/.
  awk -F"$t" -v OFS="$t" '{p=$3; sub(/^skills\/ipc\//,"",p); print p,$2}' \
    "$MANIFEST_DIR/final-runtime.manifest" | LC_ALL=C sort > "$tmp/final.map"
  awk -F"$t" -v OFS="$t" '{print $3,$2}' "$MANIFEST_DIR/root-codex.manifest"   | LC_ALL=C sort > "$tmp/codex.map"
  awk -F"$t" -v OFS="$t" '{print $3,$2}' "$MANIFEST_DIR/root-claude.manifest"  | LC_ALL=C sort > "$tmp/claude.map"
  awk -F"$t" -v OFS="$t" '{print $3,$2}' "$MANIFEST_DIR/base-overlay.manifest" | LC_ALL=C sort > "$tmp/base.map"

  # C2 -- root-codex carries exactly the runtime allowlist, by path.
  if LC_ALL=C comm -3 <(cut -f1 "$tmp/final.map") <(cut -f1 "$tmp/codex.map") | grep -q .; then
    echo "CROSS FAIL: root-codex path set differs from final-runtime (modulo the skills/ipc/ prefix):" >&2
    LC_ALL=C comm -3 <(cut -f1 "$tmp/final.map") <(cut -f1 "$tmp/codex.map") >&2; rc=1
  else
    echo "CROSS OK: root-codex carries exactly the $(wc -l < "$tmp/codex.map" | tr -d ' ') final-runtime paths"
  fi

  # C3 -- the roots agree with each other on every shared path (version-independent: all three
  # roots are propagated in one act, so this must hold whichever release they hold).
  n=$(LC_ALL=C join -t"$t" -j 1 "$tmp/codex.map" "$tmp/claude.map" \
        | awk -F"$t" '$2!=$3{print $1}' | grep -c . )
  if [ "$n" -eq 0 ]; then
    echo "CROSS OK: root-codex and root-claude agree on all $(wc -l < "$tmp/codex.map" | tr -d ' ') shared paths (hashes)"
  else
    echo "CROSS FAIL: root-codex and root-claude disagree on $n shared path(s):" >&2
    LC_ALL=C join -t"$t" -j 1 "$tmp/codex.map" "$tmp/claude.map" | awk -F"$t" '$2!=$3{print "  "$1}' >&2
    rc=1
  fi

  # C4 -- root-claude's extra rows are retained overlay residue: every one is a base-overlay
  # path, and their hashes match base-overlay except exactly the declared CRLF fixtures.
  LC_ALL=C comm -13 <(cut -f1 "$tmp/codex.map") <(cut -f1 "$tmp/claude.map") > "$tmp/extra.paths"
  LC_ALL=C join -t"$t" -j 1 "$tmp/extra.paths" "$tmp/claude.map" > "$tmp/extra.map"
  if [ "$(wc -l < "$tmp/extra.paths" | tr -d ' ')" -ne "$(wc -l < "$tmp/extra.map" | tr -d ' ')" ]; then
    echo "CROSS FAIL: internal: could not resolve every extra root-claude path to a hash" >&2; rc=1
  fi
  if LC_ALL=C comm -23 "$tmp/extra.paths" <(cut -f1 "$tmp/base.map") | grep -q .; then
    echo "CROSS FAIL: root-claude carries path(s) present in neither final-runtime nor base-overlay:" >&2
    LC_ALL=C comm -23 "$tmp/extra.paths" <(cut -f1 "$tmp/base.map") | sed 's/^/  /' >&2; rc=1
  else
    echo "CROSS OK: all $(wc -l < "$tmp/extra.paths" | tr -d ' ') extra root-claude paths are base-overlay paths"
  fi
  LC_ALL=C join -t"$t" -j 1 "$tmp/extra.map" "$tmp/base.map" \
    | awk -F"$t" '$2!=$3{print $1}' | LC_ALL=C sort > "$tmp/exceptions.actual"
  printf '%s\n' "$DECLARED_ROOT_HASH_EXCEPTIONS" | LC_ALL=C sort > "$tmp/exceptions.declared"
  if LC_ALL=C comm -3 "$tmp/exceptions.declared" "$tmp/exceptions.actual" | grep -q .; then
    echo "CROSS FAIL: root-claude's hash exceptions against base-overlay are not the declared set:" >&2
    LC_ALL=C comm -3 "$tmp/exceptions.declared" "$tmp/exceptions.actual" >&2; rc=1
  else
    echo "CROSS OK: root-claude's residue matches base-overlay except exactly the $(wc -l < "$tmp/exceptions.declared" | tr -d ' ') declared CRLF fixtures"
  fi

  # C5 -- REPORT ONLY (see SCOPE NOTE): how the roots stand against the current release.
  n=$(LC_ALL=C join -t"$t" -j 1 "$tmp/codex.map" "$tmp/final.map" \
        | awk -F"$t" '$2!=$3{print $1}' | grep -c . )
  if [ "$n" -eq 0 ]; then
    echo "CROSS NOTE: installed roots are IN SYNC with final-runtime (all paths+hashes match)"
  else
    echo "CROSS NOTE: installed roots are PROPAGATION-PENDING against final-runtime -- $n of $(wc -l < "$tmp/codex.map" | tr -d ' ') row(s) differ (expected between a release and its propagation):"
    LC_ALL=C join -t"$t" -j 1 "$tmp/codex.map" "$tmp/final.map" | awk -F"$t" '$2!=$3{print "  "$1}'
  fi

  rm -rf "$tmp"
  return $rc
}

cmd_check_all() {
  local rc=0 name kind val ref final_ref="" roots_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-roots) roots_arg=--no-roots; shift ;;
      *) die "check-all: unknown arg '$1'" ;;
    esac
  done
  # Fail closed if a final manifest exists on disk but FINAL_REF does not: a missing
  # FINAL_REF would otherwise make frozen_targets silently omit the final-* semantic
  # checks, so a drifted final manifest could pass unverified.
  [ -f "$MANIFEST_DIR/FINAL_REF" ] \
    && final_ref="$(tr -d ' \t\r\n' < "$MANIFEST_DIR/FINAL_REF")"
  if { [ -f "$MANIFEST_DIR/final-runtime.manifest" ] || [ -f "$MANIFEST_DIR/final-overlay.manifest" ]; } \
     && [ -z "$final_ref" ]; then
    echo "CHECK FAIL: final-*.manifest present but release/manifests/FINAL_REF is missing/empty/whitespace-only; cannot verify them against the release commit" >&2
    rc=1
  fi
  while IFS=$'\t' read -r name kind val ref; do
    if [ "$kind" = set ] && [ -n "$ref" ]; then
      cmd_check --set "$val" --ref "$ref" --file "$MANIFEST_DIR/$name.manifest" || rc=1
    else
      cmd_check --"$kind" "$val" --file "$MANIFEST_DIR/$name.manifest" || rc=1
    fi
  done < <(if [ -n "$roots_arg" ]; then frozen_targets --no-roots; else frozen_targets; fi)
  [ -n "$roots_arg" ] && echo "NOTE: installed-root inventories not re-derived (--no-roots); their committed bytes are still hash-verified below"
  if [ -f "$MANIFEST_DIR/MANIFEST-SHA256SUMS.txt" ]; then
    if ( cd "$MANIFEST_DIR" && sha256sum -c MANIFEST-SHA256SUMS.txt ) >/dev/null 2>&1; then
      echo "CHECK OK: recorded manifest self-hashes match"
    else
      echo "CHECK FAIL: recorded manifest self-hashes drifted" >&2; rc=1
    fi
  else
    echo "CHECK FAIL: MANIFEST-SHA256SUMS.txt missing" >&2; rc=1
  fi
  # Cross-manifest agreement. Pure text over committed bytes, so it runs in BOTH modes --
  # --no-roots does not weaken it, because it never touches a host directory.
  cmd_cross_check || rc=1
  return $rc
}

main() {
  [ $# -ge 1 ] || die "usage: gen_release_manifest.sh <gen|check|freeze|check-all> ..."
  local sub="$1"; shift
  case "$sub" in
    gen)         cmd_gen "$@" ;;
    check)       cmd_check "$@" ;;
    freeze)      cmd_freeze "$@" ;;
    check-all)   cmd_check_all "$@" ;;
    cross-check) cmd_cross_check "$@" ;;
    *) die "unknown subcommand '$sub'" ;;
  esac
}

main "$@"
