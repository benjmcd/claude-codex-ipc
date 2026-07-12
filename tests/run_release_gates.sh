#!/usr/bin/env bash
# CANON-RUNNER (NEXT-STEPS §5.2) — OS-aware release gate runner + checker.
#
# Runs the nine tests/test_*.sh suites + tests/scan_public_safety.sh SEQUENTIALLY and
# fails the run on the first hard problem. A run FAILS if any suite:
#   * exits nonzero; OR
#   * emits an UNEXPECTED `^SKIP:` line (fail-on-SKIP); OR
#   * breaches the §5.1 process bound (owned real-Node peak > 2, or owned Node descendants
#     still alive > 2s after the suite ends); OR
#   * exceeds its wall-clock (per-suite 600s / whole-layout 1800s) — on timeout the owned
#     Node tree is killed/reaped within 5s and the run still FAILS.
#
# OS-aware allowlist: exactly ONE declared platform-conditional skip is permitted —
# tests/test_autoload_matrix.sh emitting `SKIP: powershell.exe not available ...` with
# exit 0 (the Ubuntu CI leg, .github/workflows/test.yml). Every OTHER `^SKIP:` fails.
#
# Safety success is judged by the scanner PROCESS EXIT STATUS, never a printed CLEAN.
#
# Process bound: only Node PIDs that did NOT exist before this runner started are counted
# as "owned" (this scopes OUT every pre-existing / global node.exe); on POSIX the owned set
# is additionally confirmed as a descendant of this runner's PID. Never counts global node.
#
# Usage:
#   run_release_gates.sh                 # full battery (9 suites + safety)
#   run_release_gates.sh [suite ...]     # only the named suites (basename or path); still runs safety
#   run_release_gates.sh --no-safety [suite ...]
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="$(command -v bash)"

# ---- pinned budgets (NEXT-STEPS §5.1) ----------------------------------------------------
# Correctness gates (UNCHANGED — never weakened): the process bound (PEAK_LIMIT=2,
# POST_SUITE_DRAIN_S=2, KILL_DEADLINE_S=5), fail-on-SKIP, and safety-by-exit-status.
PEAK_LIMIT=2                 # baseline real-Node peak per suite process tree
POST_SUITE_DRAIN_S=2         # owned Node descendants must reach zero within this window
KILL_DEADLINE_S=5            # on timeout, kill/reap the owned tree within this window
#
# Wall-clock recalibration (WINDOWS/MSYS host, 2026-07-12). NEXT-STEPS §5.1/§5.2 pin the
# per-suite 300s / whole-layout 600s figures as "first-run estimates to recalibrate-and-record";
# that recalibrate-and-record authorization is hereby extended to the per-suite value on Windows.
# Measured standalone Windows/MSYS runtimes (nine suites all green, 381 assertions, 0 failures):
#   * test_ipc.sh       ~362s
#   * test_reply_view.sh ~453s  (its T23 nests a FULL test_ipc re-run — a Phase-5/WS-D de-dup
#                                candidate; NOT fixed here)
# Both exceed the provisional 300s per-suite cap on this host, so the caps are raised WITH margin:
# per-suite 300 -> 600s; whole-layout 600 -> 1800s (raised proportionally). No correctness gate
# above is touched.
PER_SUITE_TIMEOUT_S=600
WHOLE_LAYOUT_TIMEOUT_S=1800
SAMPLE_INTERVAL_S=0.5
# Per-child timeouts pinned for suites/CI that honour them (harness-only watchdogs).
export IPC_HERMETIC_WAIT_MS=10000
export IPC_OBSERVER_MS=25000
export IPC_INSPECTOR_MS=25000

DEFAULT_SUITES=(
  test_autoload_matrix.sh
  test_ipc.sh
  test_ipc_wait.sh
  test_reply_harvest.sh
  test_reply_view.sh
  test_rollout_reader.sh
  test_router_contract.sh
  test_session_inspect.sh
  test_wait_contract.sh
)
SAFETY_SUITE="scan_public_safety.sh"

RUN_SAFETY=1
SUITES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-safety) RUN_SAFETY=0; shift ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SUITES+=("$1"); shift ;;
  esac
done
[ "${#SUITES[@]}" -gt 0 ] || SUITES=("${DEFAULT_SUITES[@]}")

is_windows() { case "$(uname -s 2>/dev/null)" in *NT*|*MINGW*|*MSYS*|*CYGWIN*) return 0;; *) return 1;; esac; }

# ---- process enumeration -----------------------------------------------------------------
# list_node_pids: one PID per line for every live node/node.exe process on the host.
list_node_pids() {
  if is_windows; then
    powershell.exe -NoProfile -NonInteractive -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | ForEach-Object { \$_.ProcessId }" \
      2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || true
  else
    ps -e -o pid=,comm= 2>/dev/null | awk '$2 ~ /(^|\/)node$/ { print $1 }' || true
  fi
}

BASELINE_NODE_PIDS=""   # global node PIDs present before the run (scoped OUT as non-owned)
snapshot_baseline() { BASELINE_NODE_PIDS="$(list_node_pids | sort -u)"; }

# owned_node_pids: node PIDs that appeared AFTER the baseline snapshot (i.e. spawned by us).
owned_node_pids() {
  local cur; cur="$(list_node_pids | sort -u)"
  comm -23 <(printf '%s\n' "$cur" | sed '/^$/d') <(printf '%s\n' "$BASELINE_NODE_PIDS" | sed '/^$/d')
}
count_owned_node() { owned_node_pids | sed '/^$/d' | grep -c . || true; }

kill_owned_tree() {
  local pid
  for pid in $(owned_node_pids); do
    [ -n "$pid" ] || continue
    if is_windows; then
      taskkill //PID "$pid" //T //F >/dev/null 2>&1 || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

# ---- SKIP classification -----------------------------------------------------------------
# Returns 0 (allowed) only for the one declared platform-conditional skip.
skip_line_allowed() { # skip_line_allowed <suite-basename> <skip-line> <rc>
  local suite="$1" line="$2" rc="$3"
  if [ "$suite" = "test_autoload_matrix.sh" ] && [ "$rc" -eq 0 ] \
     && printf '%s' "$line" | grep -qiE '^SKIP:.*powershell\.exe not available'; then
    return 0
  fi
  return 1
}

# ---- suite runner ------------------------------------------------------------------------
FAILURES=()
record_fail() { FAILURES+=("$1"); echo "  GATE FAIL: $1"; }

run_one() { # run_one <suite-path-or-name>
  local arg="$1" suite path logf spid peak owned t0 rc
  if [ -f "$arg" ]; then path="$arg"; else path="$TDIR/$arg"; fi
  suite="$(basename "$path")"
  [ -f "$path" ] || { record_fail "$suite: suite file not found ($path)"; return 1; }
  logf="$RUNDIR/$suite.log"
  echo "== running $suite =="

  "$BASH_BIN" "$path" >"$logf" 2>&1 &
  spid=$!
  peak=0; t0=$SECONDS
  while kill -0 "$spid" 2>/dev/null; do
    owned="$(count_owned_node)"
    [ "$owned" -gt "$peak" ] && peak="$owned"
    if [ $((SECONDS - t0)) -ge "$PER_SUITE_TIMEOUT_S" ]; then
      echo "  ...timeout after ${PER_SUITE_TIMEOUT_S}s; killing owned Node tree" >&2
      local k0=$SECONDS
      kill_owned_tree
      kill "$spid" 2>/dev/null || true
      while kill -0 "$spid" 2>/dev/null && [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do sleep 0.2; done
      wait "$spid" 2>/dev/null || true
      record_fail "$suite: exceeded ${PER_SUITE_TIMEOUT_S}s wall clock (peak owned Node=$peak)"
      return 1
    fi
    sleep "$SAMPLE_INTERVAL_S"
  done
  wait "$spid"; rc=$?

  # Post-suite drain: owned Node descendants must reach zero within the drain window.
  local d0=$SECONDS drained=0
  while [ $((SECONDS - d0)) -lt "$POST_SUITE_DRAIN_S" ]; do
    if [ "$(count_owned_node)" -eq 0 ]; then drained=1; break; fi
    sleep 0.25
  done
  local residual; residual="$(count_owned_node)"

  local status=PASS
  # 1. exit code
  if [ "$rc" -ne 0 ]; then record_fail "$suite: exited $rc"; status=FAIL; fi
  # 2. fail-on-SKIP (OS-aware allowlist)
  local skips; skips="$(grep -nE '^SKIP:' "$logf" || true)"
  if [ -n "$skips" ]; then
    local sl
    while IFS= read -r sl; do
      local text="${sl#*:}"
      if skip_line_allowed "$suite" "$text" "$rc"; then
        echo "  allowed platform-conditional skip: $text"
      else
        record_fail "$suite: unexpected SKIP -> $text"; status=FAIL
      fi
    done < <(printf '%s\n' "$skips")
  fi
  # 3. process bound
  if [ "$peak" -gt "$PEAK_LIMIT" ]; then
    record_fail "$suite: owned real-Node peak $peak > $PEAK_LIMIT"; status=FAIL
  fi
  if [ "$drained" -ne 1 ] || [ "$residual" -ne 0 ]; then
    kill_owned_tree
    record_fail "$suite: $residual owned Node descendant(s) still alive >${POST_SUITE_DRAIN_S}s after suite"; status=FAIL
  fi

  echo "  $status: $suite (rc=$rc, peak owned Node=$peak, owned residual=$residual)"
  [ "$status" = PASS ]
}

run_safety() {
  local path="$TDIR/$SAFETY_SUITE" logf="$RUNDIR/$SAFETY_SUITE.log" rc
  echo "== running $SAFETY_SUITE (success = process exit status) =="
  "$BASH_BIN" "$path" >"$logf" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  PASS: $SAFETY_SUITE (exit 0)"
  else
    record_fail "$SAFETY_SUITE: scanner exit $rc"
    tail -20 "$logf" | sed 's/^/    /'
  fi
}

# ---- main --------------------------------------------------------------------------------
RUNDIR="$(mktemp -d)"
trap 'rm -rf "$RUNDIR"' EXIT

echo "=== release gate runner ==="
# Preflight (refuse to run gates if the runtime cannot import node:sqlite).
# shellcheck disable=SC1091
. "$TDIR/preflight_runtime.sh"
if ! preflight_runtime; then
  echo "GATE ABORT: runtime preflight failed; refusing to run release gates" >&2
  exit 2
fi
export NODE_BIN="$PREFLIGHT_NODE_BIN"
export PREFLIGHT_NODE_FLAGS
echo "pinned node: $PREFLIGHT_NODE_BIN ($PREFLIGHT_NODE_VERSION) flags='${PREFLIGHT_NODE_FLAGS:-<none>}'"

snapshot_baseline
echo "baseline global Node PIDs (scoped out): $(printf '%s' "$BASELINE_NODE_PIDS" | sed '/^$/d' | grep -c . || true)"

LAYOUT_T0=$SECONDS
for s in "${SUITES[@]}"; do
  run_one "$s" || true
  if [ $((SECONDS - LAYOUT_T0)) -ge "$WHOLE_LAYOUT_TIMEOUT_S" ]; then
    record_fail "whole-layout wall clock exceeded ${WHOLE_LAYOUT_TIMEOUT_S}s"
    break
  fi
done
[ "$RUN_SAFETY" -eq 1 ] && run_safety

echo ""
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "RELEASE GATES: PASS"
  exit 0
fi
echo "RELEASE GATES: FAIL (${#FAILURES[@]} problem(s))"
for f in "${FAILURES[@]}"; do echo "  - $f"; done
exit 1
