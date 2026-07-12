#!/usr/bin/env bash
# Runtime preflight gate (NEXT-STEPS §5 / Phase-1). Asserts that the Node runtime the
# release gates will use can import node:sqlite and is a supported version, and PINS the
# exact Node executable + flags for the runner to reuse. Refuse (nonzero) if the probe
# fails so Phase-2+ gates never run on a runtime that silently blocks the SQLite path.
#
# Supported: Node >= 22.5 (node:sqlite import unflagged), OR an older 22.x/23.x that can
# import node:sqlite only with --experimental-sqlite. Anything else is refused.
#
# On success (run directly) prints eval-able assignments:
#     PREFLIGHT_NODE_BIN=<path>
#     PREFLIGHT_NODE_FLAGS=<flags-or-empty>
#     PREFLIGHT_NODE_VERSION=<x.y.z>
# When sourced, call preflight_runtime and read the same-named shell variables.
set -uo pipefail

preflight_runtime() {
  PREFLIGHT_NODE_BIN=""; PREFLIGHT_NODE_FLAGS=""; PREFLIGHT_NODE_VERSION=""
  local node_bin ver major minor
  node_bin="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  if [ -z "$node_bin" ]; then
    echo "PREFLIGHT FAIL: node executable not found on PATH" >&2
    return 1
  fi
  ver="$("$node_bin" -p 'process.versions.node' 2>/dev/null || true)"
  if [ -z "$ver" ]; then
    echo "PREFLIGHT FAIL: unable to read node version from '$node_bin'" >&2
    return 1
  fi
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  case "$major" in ''|*[!0-9]*) echo "PREFLIGHT FAIL: unparseable node version '$ver'" >&2; return 1;; esac

  # Determine the flag set that makes `import('node:sqlite')` succeed.
  local flags="__unset__"
  if "$node_bin" -e 'await import("node:sqlite")' >/dev/null 2>&1; then
    flags=""
  elif "$node_bin" --experimental-sqlite -e 'await import("node:sqlite")' >/dev/null 2>&1; then
    flags="--experimental-sqlite"
  fi
  if [ "$flags" = "__unset__" ]; then
    echo "PREFLIGHT FAIL: node:sqlite could not be imported (node $ver) with or without --experimental-sqlite" >&2
    return 1
  fi

  # Version gate.
  if [ "$major" -lt 22 ]; then
    echo "PREFLIGHT FAIL: node $ver < 22.x; node:sqlite unsupported" >&2
    return 1
  fi
  if [ -z "$flags" ]; then
    # Unflagged import: require >= 22.5 (node:sqlite landed unflagged in 22.5).
    if [ "$major" -eq 22 ] && [ "$minor" -lt 5 ]; then
      echo "PREFLIGHT FAIL: node $ver imports node:sqlite unflagged but is < 22.5 (unexpected)" >&2
      return 1
    fi
  else
    # Flagged path is only sanctioned on the older 22.x/23.x line.
    if [ "$major" -gt 23 ]; then
      echo "PREFLIGHT FAIL: node $ver needed --experimental-sqlite yet is newer than 23.x (unexpected)" >&2
      return 1
    fi
  fi

  PREFLIGHT_NODE_BIN="$node_bin"
  PREFLIGHT_NODE_FLAGS="$flags"
  PREFLIGHT_NODE_VERSION="$ver"
  echo "PREFLIGHT OK: node=$ver bin=$node_bin sqlite-import=ok flags='${flags:-<none>}'" >&2
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  preflight_runtime || exit 1
  printf 'PREFLIGHT_NODE_BIN=%s\n' "$PREFLIGHT_NODE_BIN"
  printf 'PREFLIGHT_NODE_FLAGS=%s\n' "$PREFLIGHT_NODE_FLAGS"
  printf 'PREFLIGHT_NODE_VERSION=%s\n' "$PREFLIGHT_NODE_VERSION"
fi
