#!/usr/bin/env bash
# CANON-RUNNER (NEXT-STEPS §5.2) — OS-aware release gate runner + checker.
#
# Runs runtime preflight, all DEFAULT_SUITES (currently thirteen), text/docs/manifest,
# safety, and static-contract gates SEQUENTIALLY. A run records every hard problem and FAILS
# if any monitored child:
#   * exits nonzero; OR
#   * emits an UNEXPECTED `^SKIP:` line (fail-on-SKIP); OR
#   * breaches the §5.1 process bound (owned real-Node peak > 2, or owned descendants
#     still alive > 2s after the suite ends); OR
#   * exceeds its wall-clock (per-suite 600s / whole-layout 1800s) — on timeout the owned
#     descendant tree is killed/reaped within 5s and the run still FAILS.
#
# OS-aware allowlist: exactly ONE declared platform-conditional skip is permitted —
# tests/test_autoload_matrix.sh emitting `SKIP: powershell.exe not available ...` with
# exit 0 (the Ubuntu CI leg, .github/workflows/test.yml). Every OTHER `^SKIP:` fails.
#
# Safety success is judged by the scanner PROCESS EXIT STATUS, never a printed CLEAN.
#
# Process bound (fail-closed ancestry ownership): all owned descendants are held for bounded
# kill/reap custody; Node descendants alone count toward peak <=2. A process is owned only
# if its parent chain reaches this runner's PID. POSIX: `ps -e -o pid=,ppid=,comm=`
# + a PPID walk. Windows: MSYS `ps -e` builds the runner's descendant closure in MSYS pid
# space (Win32 parent links break at MSYS fork/exec stubs, so a raw Win32 PPID walk cannot
# span bash-to-bash boundaries) and maps each member to its Windows PID; Get-CimInstance
# Win32_Process (ProcessId+ParentProcessId+Name, full table) then attributes every
# node.exe — including node spawned by node, which MSYS ps cannot see — whose Win32 parent
# chain reaches that closure. Global / pre-existing node is never counted (it is not a
# descendant). FAIL-CLOSED: if enumeration fails, returns an unparseable snapshot, or
# omits the runner's own PID (impossible for a live shell), the run ABORTS with GATE ERROR
# (exit 3) — an owned count of 0 is never fabricated from a failed measurement.
# KNOWN LIMITATION (documented, NOT covered): an owned node whose intermediate parents
# already exited (orphan/reparent; or Windows PID reuse breaking a chain) can no longer be
# attributed by ancestry and escapes the bound.
#
# Usage:
#   run_release_gates.sh                 # preflight + 13 suites + text/docs/manifest/safety/contract
#   run_release_gates.sh [suite ...]     # named suites + same unskippable outer gates
#   run_release_gates.sh --no-safety [suite ...]  # skip safety only
#   run_release_gates.sh --self-test-monitor      # exclusive watchdog self-test
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
# Historical calibration measured the then-nine standalone suites (all green, 381 assertions, 0 failures):
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
  test_git_context_bound.sh
  test_ipc.sh
  test_ipc_wait.sh
  test_payload_mirror_parity.sh
  test_reply_harvest.sh
  test_reply_view.sh
  test_retention_sweep.sh
  test_rollout_reader.sh
  test_router_contract.sh
  test_session_inspect.sh
  test_uninstall_guard.sh
  test_wait_contract.sh
)
SAFETY_SUITE="scan_public_safety.sh"

RUN_SAFETY=1
SELF_TEST_MONITOR=0
ORIGINAL_ARGC=$#
SUITES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-safety) RUN_SAFETY=0; shift ;;
    --self-test-monitor)
      [ "$ORIGINAL_ARGC" -eq 1 ] || { echo "GATE ABORT: --self-test-monitor is exclusive" >&2; exit 2; }
      SELF_TEST_MONITOR=1; shift ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SUITES+=("$1"); shift ;;
  esac
done
[ "${#SUITES[@]}" -gt 0 ] || SUITES=("${DEFAULT_SUITES[@]}")

is_windows() { case "$(uname -s 2>/dev/null)" in *NT*|*MINGW*|*MSYS*|*CYGWIN*) return 0;; *) return 1;; esac; }

# ---- process enumeration + ancestry ownership ---------------------------------------------
# Contract: owned_node_pids prints the owned node PID set (Windows PIDs on Windows, POSIX
# PIDs otherwise; one per line; possibly empty) and returns 0. On ANY enumeration or
# sanity failure it prints a single "ENUM_ERROR:<reason>" line and returns 1 — it never
# silently degrades to an empty set. Ownership = the process's parent chain reaches
# RUNNER_PID (see header for the per-OS mechanism and the orphaned-parent limitation).
RUNNER_PID=$$

owned_process_rows() {
  local enum_owner_pid="$BASHPID"
  if is_windows; then
    local pstab cimtab
    # Layer 1: MSYS process table (PID PPID PGID WINPID ... after a header line).
    if ! pstab="$(ps -e)"; then
      echo "ENUM_ERROR:MSYS ps enumeration failed (nonzero exit)"; return 1
    fi
    if ! printf '%s\n' "$pstab" | awk -v me="$RUNNER_PID" 'NR>1 && $1==me{f=1} END{exit f?0:1}'; then
      echo "ENUM_ERROR:runner pid $RUNNER_PID absent from MSYS ps snapshot (enumeration untrustworthy)"; return 1
    fi
    # Layer 2: full Win32 process table "ProcessId ParentProcessId Name" (NO name filter:
    # ancestry has to be walked through non-node intermediaries). Failure is NOT swallowed.
    if ! cimtab="$(powershell.exe -NoProfile -NonInteractive -Command "'SELF {0}' -f \$PID; Get-CimInstance Win32_Process | ForEach-Object { '{0} {1} {2}' -f \$_.ProcessId, \$_.ParentProcessId, \$_.Name }")"; then
      echo "ENUM_ERROR:Win32_Process enumeration failed (powershell.exe nonzero exit)"; return 1
    fi
    cimtab="$(printf '%s\n' "$cimtab" | tr -d '\r')"
    if ! printf '%s\n' "$cimtab" | grep -qE '^SELF [0-9]+$' || ! printf '%s\n' "$cimtab" | grep -qE '^[0-9]+ [0-9]+ .'; then
      echo "ENUM_ERROR:Win32_Process enumeration returned no parseable rows"; return 1
    fi
    {
      printf '%s\n' "$pstab" | awk 'NR>1 { print "PS", $1, $2, $4 }'
      printf '%s\n' "$cimtab" | awk '{ print "CIM", $1, $2, $3 }'
    } | awk -v me="$RUNNER_PID" -v enummsys="$enum_owner_pid" '
      $1 == "PS" { mppid[$2] = $3; mwin[$2] = $4; next }
      $1 == "CIM" && $2 == "SELF" { enumself = $3; next }
      $1 == "CIM" { wppid[$2] = $3; wname[$2] = $4; next }
      END {
        if (mwin[me] == "") { print "ENUM_ERROR:runner row in MSYS ps snapshot has no WINPID"; exit 1 }
        # (1) descendant closure of the runner in MSYS pid space -> Windows PID roots.
        for (p in mppid) {
          cur = p; d = 0; hit = 0
          while (d++ < 64) {
            if (cur == me) { hit = 1; break }
            if (!(cur in mppid)) break
            nxt = mppid[cur]; if (nxt == cur) break
            cur = nxt
          }
          if (hit && mwin[p] != "") root[mwin[p]] = 1
        }
        if (!(mwin[me] in wppid)) {
          print "ENUM_ERROR:runner winpid " mwin[me] " absent from Win32_Process snapshot"; exit 1
        }
        cur = enummsys; d = 0
        while (d++ < 64) {
          if (cur == me) break
          if (mwin[cur] != "") book[mwin[cur]] = 1
          if (!(cur in mppid)) break
          nxt = mppid[cur]; if (nxt == cur) break
          cur = nxt
        }
        # (2) every Win32 row whose parent chain reaches a closure root.
        for (w in wname) {
          cur = w; d = 0; owned = 0; bookkeeping = 0
          while (d++ < 64) {
            if (cur in book) { bookkeeping = 1; break }
            if (cur in root) { owned = 1; break }
            if (!(cur in wppid)) break            # parent exited: chain unresolvable (see limitation)
            nxt = wppid[cur]; if (nxt == cur) break
            cur = nxt
          }
          if (owned && !bookkeeping && w != mwin[me] && w != enumself) print w, wname[w]
        }
      }'
  else
    local tab
    if ! tab="$(sh -c 'printf "SELF %s\n" "$$"; exec ps -e -o pid=,ppid=,comm=')"; then
      echo "ENUM_ERROR:ps enumeration failed (nonzero exit)"; return 1
    fi
    if ! printf '%s\n' "$tab" | awk -v me="$RUNNER_PID" '$1==me{f=1} END{exit f?0:1}'; then
      echo "ENUM_ERROR:runner pid $RUNNER_PID absent from ps snapshot (enumeration untrustworthy)"; return 1
    fi
    printf '%s\n' "$tab" | awk -v me="$RUNNER_PID" -v enum="$enum_owner_pid" '
      $1 == "SELF" { enumself = $2; next }
      { ppid[$1] = $2; comm[$1] = $3 }
      END {
        cur = enum; d = 0
        while (d++ < 64) {
          if (cur == me) break
          book[cur] = 1
          if (!(cur in ppid)) break
          nxt = ppid[cur]; if (nxt == cur) break
          cur = nxt
        }
        for (p in comm) {
          cur = p; d = 0; hit = 0; bookkeeping = 0
          while (d++ < 64) {
            if (cur in book) { bookkeeping = 1; break }
            if (cur == me) { hit = 1; break }
            if (!(cur in ppid)) break             # parent exited: chain unresolvable (see limitation)
            nxt = ppid[cur]; if (nxt == cur) break
            cur = nxt
          }
          if (hit && !bookkeeping && p != me && p != enumself) print p, comm[p]
        }
      }'
  fi
}

owned_descendant_pids() {
  local out rc
  out="$(owned_process_rows)"; rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
  printf '%s\n' "$out" | awk 'NF >= 2 { print $1 }'
}

owned_node_pids() {
  local out rc
  out="$(owned_process_rows)"; rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
  printf '%s\n' "$out" | awk 'NF >= 2 && tolower($2) ~ /(^|\/)node(\.exe)?$/ { print $1 }'
}

# count_owned_node: prints the owned count on success; on enumeration failure prints the
# ENUM_ERROR reason to stderr and returns 1. Callers MUST treat rc!=0 as fatal (fail closed).
count_owned_node() {
  local out rc
  out="$(owned_node_pids)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep '^ENUM_ERROR:' >&2 || echo "ENUM_ERROR:unknown enumeration failure" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed '/^$/d' | grep -c . || true
}

count_owned_descendants() {
  local out rc
  out="$(owned_descendant_pids)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep '^ENUM_ERROR:' >&2 || echo "ENUM_ERROR:unknown enumeration failure" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed '/^$/d' | grep -c . || true
}

# enum_abort: fail the whole run closed when the owned set cannot be measured.
# enum_abort <context> [suite-child-pid]
enum_abort() {
  local ctx="$1" spid="${2:-}" k0
  if [ -n "$spid" ]; then
    kill "$spid" 2>/dev/null || true
    k0=$SECONDS
    while kill -0 "$spid" 2>/dev/null && [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do sleep 0.2; done
    if kill -0 "$spid" 2>/dev/null; then kill -KILL "$spid" 2>/dev/null || true; fi
    wait "$spid" 2>/dev/null || true
  fi
  echo "GATE ERROR: owned-Node enumeration failed ($ctx); the process bound cannot be measured — failing closed (exit 3). Suite child processes may need manual cleanup." >&2
  exit 3
}

kill_owned_tree() {
  local pid pids
  if [ "$#" -gt 0 ]; then
    pids="$1"
  else
    if ! pids="$(owned_descendant_pids)"; then
      echo "  WARN: cannot enumerate owned descendant tree for kill ($pids); nothing killed" >&2
      return 1
    fi
  fi
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    if is_windows; then
      taskkill //PID "$pid" //T //F >/dev/null 2>&1 || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

# ---- SKIP classification -----------------------------------------------------------------
# Returns 0 (allowed) only for the one declared platform-conditional skip.
# skip_line_allowed <suite-basename> <skip-line> <rc>
skip_line_allowed() {
  local suite="$1" line="$2" rc="$3"
  if [ "$suite" = "test_autoload_matrix.sh" ] && [ "$rc" -eq 0 ] && printf '%s' "$line" | grep -qiE '^SKIP:.*powershell\.exe not available'; then
    return 0
  fi
  return 1
}

# ---- suite runner ------------------------------------------------------------------------
FAILURES=()
INFRA_FAILURE=0
MONITOR_COUNTER=0
MONITOR_SUITE=""
MONITOR_TIMEOUT_S="$PER_SUITE_TIMEOUT_S"
MONITOR_EXPECT_TIMEOUT=0
MONITOR_LAST_RC=0
MONITOR_LAST_TIMEOUT=0
MONITOR_LAST_CAPTURED=""
MONITOR_LAST_RESIDUAL=0
record_fail() { FAILURES+=("$1"); echo "  GATE FAIL: $1"; }

# run_monitored <label> <argv...>
run_monitored() {
  local label="$1"; shift
  local logf spid peak=0 owned t0 rc=0 timed_out=0 deadline remaining
  local d0 drained=0 residual captured="" reasons=() skips sl text k0 skip_lines=()
  [ "$#" -gt 0 ] || { record_fail "$label: rc=2 empty argv"; INFRA_FAILURE=1; return 2; }
  MONITOR_COUNTER=$((MONITOR_COUNTER + 1))
  logf="$RUNDIR/monitor-$MONITOR_COUNTER.log"
  remaining=$((WHOLE_LAYOUT_TIMEOUT_S - (SECONDS - LAYOUT_T0)))
  if [ "$remaining" -le 0 ]; then
    record_fail "$label: rc=124 whole-layout wall clock exceeded ${WHOLE_LAYOUT_TIMEOUT_S}s"
    return 124
  fi
  deadline="$MONITOR_TIMEOUT_S"
  [ "$remaining" -lt "$deadline" ] && deadline="$remaining"
  echo "== running $label =="
  "$@" >"$logf" 2>&1 &
  spid=$!
  t0=$SECONDS
  while kill -0 "$spid" 2>/dev/null; do
    owned="$(count_owned_node)" || enum_abort "mid-child sample, $label" "$spid"
    [ "$owned" -gt "$peak" ] && peak="$owned"
    if [ $((SECONDS - t0)) -ge "$deadline" ]; then
      timed_out=1; rc=124
      captured="$(owned_descendant_pids)" || enum_abort "timeout snapshot, $label" "$spid"
      echo "  MONITOR TIMEOUT: $label after ${deadline}s; captured descendant(s): ${captured:-<none>}" >&2
      kill_owned_tree "$captured" || true
      kill "$spid" 2>/dev/null || true
      k0=$SECONDS
      while kill -0 "$spid" 2>/dev/null && [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do sleep 0.2; done
      if kill -0 "$spid" 2>/dev/null; then kill -KILL "$spid" 2>/dev/null || true; fi
      wait "$spid" 2>/dev/null || true
      break
    fi
    sleep "$SAMPLE_INTERVAL_S"
  done
  if [ "$timed_out" -eq 0 ]; then wait "$spid"; rc=$?; fi

  d0=$SECONDS
  while [ $((SECONDS - d0)) -lt "$POST_SUITE_DRAIN_S" ]; do
    residual="$(count_owned_descendants)" || enum_abort "post-child drain, $label"
    if [ "$residual" -eq 0 ]; then drained=1; break; fi
    sleep 0.25
  done
  residual="$(count_owned_descendants)" || enum_abort "post-child residual, $label"
  if [ "$residual" -ne 0 ]; then kill_owned_tree || true; fi

  [ "$rc" -eq 0 ] || reasons+=("child-exit=$rc")
  [ "$peak" -le "$PEAK_LIMIT" ] || reasons+=("owned-node-peak=$peak>${PEAK_LIMIT}")
  if [ "$drained" -ne 1 ] || [ "$residual" -ne 0 ]; then
    reasons+=("owned-descendant-residual=$residual>${POST_SUITE_DRAIN_S}s")
  fi
  if [ -n "$MONITOR_SUITE" ]; then
    skips="$(grep -nE '^SKIP:' "$logf" || true)"
    if [ -n "$skips" ]; then
      mapfile -t skip_lines <<<"$skips"
      for sl in "${skip_lines[@]}"; do
        text="${sl#*:}"
        if skip_line_allowed "$MONITOR_SUITE" "$text" "$rc"; then
          echo "  allowed platform-conditional skip: $text"
        else
          reasons+=("unexpected-SKIP=$text")
        fi
      done
    fi
  fi

  MONITOR_LAST_RC="$rc"
  MONITOR_LAST_TIMEOUT="$timed_out"
  MONITOR_LAST_CAPTURED="$captured"
  MONITOR_LAST_RESIDUAL="$residual"
  if [ "${#reasons[@]}" -gt 0 ]; then
    if [ "$MONITOR_EXPECT_TIMEOUT" -eq 1 ] && [ "$timed_out" -eq 1 ] && [ "$residual" -eq 0 ]; then
      echo "  MONITOR EXPECTED TIMEOUT: $label; descendants killed/reaped"
      return 124
    fi
    record_fail "$label: rc=$rc ${reasons[*]}"
    tail -30 "$logf" | sed 's/^/    /'
    [ "$rc" -eq 2 ] && INFRA_FAILURE=1
    return 1
  fi
  echo "  PASS: $label (rc=0, peak owned Node=$peak, owned residual=$residual)"
  return 0
}

# run_one <suite-path-or-name>
run_one() {
  local arg="$1" suite path rc
  if [ -f "$arg" ]; then path="$arg"; else path="$TDIR/$arg"; fi
  suite="$(basename "$path")"
  [ -f "$path" ] || { record_fail "$suite: suite file not found ($path)"; return 1; }
  MONITOR_SUITE="$suite"
  run_monitored "$suite" "$BASH_BIN" "$path"; rc=$?
  MONITOR_SUITE=""
  return "$rc"
}

run_monitor_self_test() {
  local pidfile="$RUNDIR/self-test-descendant.pid" t0=$SECONDS child
  MONITOR_TIMEOUT_S=2
  MONITOR_EXPECT_TIMEOUT=1
  run_monitored "self-test hanging child" "$BASH_BIN" -c \
    'sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' _ "$pidfile"
  local rc=$?
  MONITOR_EXPECT_TIMEOUT=0
  [ "$rc" -eq 124 ] || { echo "SELF-TEST-MONITOR FAIL: watchdog rc=$rc" >&2; return 1; }
  [ "$MONITOR_LAST_TIMEOUT" -eq 1 ] || { echo "SELF-TEST-MONITOR FAIL: timeout not observed" >&2; return 1; }
  [ -n "$MONITOR_LAST_CAPTURED" ] || { echo "SELF-TEST-MONITOR FAIL: timeout snapshot empty" >&2; return 1; }
  [ -s "$pidfile" ] || { echo "SELF-TEST-MONITOR FAIL: descendant pid not captured" >&2; return 1; }
  child="$(tr -d '\r\n' <"$pidfile")"
  case "$child" in ''|*[!0-9]*) echo "SELF-TEST-MONITOR FAIL: invalid descendant pid" >&2; return 1;; esac
  if kill -0 "$child" 2>/dev/null; then
    echo "SELF-TEST-MONITOR FAIL: captured descendant $child still alive" >&2; return 1
  fi
  [ "$MONITOR_LAST_RESIDUAL" -eq 0 ] || { echo "SELF-TEST-MONITOR FAIL: residual descendants" >&2; return 1; }
  [ $((SECONDS - t0)) -le $((MONITOR_TIMEOUT_S + KILL_DEADLINE_S + POST_SUITE_DRAIN_S + 3)) ] \
    || { echo "SELF-TEST-MONITOR FAIL: bounded return exceeded" >&2; return 1; }
  echo "SELF-TEST-MONITOR PASS: active timeout; captured descendant killed/reaped; bounded return"
  return 0
}

# ---- main --------------------------------------------------------------------------------
RUNDIR="$(mktemp -d)"
trap 'rm -rf "$RUNDIR"' EXIT
LAYOUT_T0=$SECONDS

echo "=== release gate runner ==="
# Fail-closed self-check: owned-Node enumeration must work BEFORE any suite runs; a broken
# enumerator must never let a suite pass against a fabricated 0-measurement.
SELFTEST_OWNED="$(count_owned_node)" || enum_abort "startup self-check"
echo "owned-Node scope: ancestry to runner pid $RUNNER_PID (fail-closed; nodes with an already-exited parent chain are NOT attributable — known limitation, see header)"
echo "owned-Node enumeration self-check: OK (owned now=$SELFTEST_OWNED)"

if [ "$SELF_TEST_MONITOR" -eq 1 ]; then
  run_monitor_self_test
  exit $?
fi

# Preflight is monitored too. It writes one strict NUL-framed record; no shell eval.
PREFLIGHT_RECORD="$RUNDIR/preflight.record"
run_monitored "runtime preflight" "$BASH_BIN" -c \
  'set -uo pipefail; source "$1"; preflight_runtime; printf "NODE\0%s\0FLAGS\0%s\0VERSION\0%s\0" "$PREFLIGHT_NODE_BIN" "$PREFLIGHT_NODE_FLAGS" "$PREFLIGHT_NODE_VERSION" >"$2"' \
  _ "$TDIR/preflight_runtime.sh" "$PREFLIGHT_RECORD"
if [ "$?" -ne 0 ]; then
  echo "GATE ABORT: runtime preflight failed; refusing to run release gates" >&2
  exit 2
fi
PREFLIGHT_FIELDS=()
mapfile -d '' -t PREFLIGHT_FIELDS <"$PREFLIGHT_RECORD"
if [ "${#PREFLIGHT_FIELDS[@]}" -ne 6 ] || [ "${PREFLIGHT_FIELDS[0]:-}" != NODE ] || [ "${PREFLIGHT_FIELDS[2]:-}" != FLAGS ] || [ "${PREFLIGHT_FIELDS[4]:-}" != VERSION ]; then
  echo "GATE ABORT: malformed runtime preflight record" >&2
  exit 2
fi
PREFLIGHT_NODE_BIN="${PREFLIGHT_FIELDS[1]}"
PREFLIGHT_NODE_FLAGS="${PREFLIGHT_FIELDS[3]}"
PREFLIGHT_NODE_VERSION="${PREFLIGHT_FIELDS[5]}"
if [ ! -x "$PREFLIGHT_NODE_BIN" ] || [[ "$PREFLIGHT_NODE_BIN" == *$'\n'* ]] || [[ "$PREFLIGHT_NODE_FLAGS" == *$'\n'* ]] || [[ "$PREFLIGHT_NODE_VERSION" == *$'\n'* ]] || [[ ! "$PREFLIGHT_NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { [ -n "$PREFLIGHT_NODE_FLAGS" ] && [ "$PREFLIGHT_NODE_FLAGS" != --experimental-sqlite ]; }; then
  echo "GATE ABORT: invalid runtime preflight record" >&2
  exit 2
fi
NODE_BIN="$PREFLIGHT_NODE_BIN"
NODE_FLAGS=()
[ -z "$PREFLIGHT_NODE_FLAGS" ] || NODE_FLAGS+=("$PREFLIGHT_NODE_FLAGS")
export NODE_BIN PREFLIGHT_NODE_FLAGS
echo "pinned node: $PREFLIGHT_NODE_BIN ($PREFLIGHT_NODE_VERSION) flags='${PREFLIGHT_NODE_FLAGS:-<none>}'"

for s in "${SUITES[@]}"; do
  run_one "$s" || true
  if [ $((SECONDS - LAYOUT_T0)) -ge "$WHOLE_LAYOUT_TIMEOUT_S" ]; then
    record_fail "whole-layout wall clock exceeded ${WHOLE_LAYOUT_TIMEOUT_S}s"
    break
  fi
done
run_monitored "text self-test" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --self-test
run_monitored "text index" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --source index
run_monitored "text worktree" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_text_integrity.mjs --source worktree
run_monitored "docs self-test" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_docs_quality.mjs --self-test
run_monitored "docs repository" "$NODE_BIN" "${NODE_FLAGS[@]}" tests/check_docs_quality.mjs
run_monitored "manifest" bash tests/gen_release_manifest.sh check-all --no-roots
[ "$RUN_SAFETY" -eq 1 ] && run_monitored "safety" bash tests/scan_public_safety.sh
run_monitored "contract" "$NODE_BIN" "${NODE_FLAGS[@]}" skills/ipc/scripts/codex_ipc_contract_audit.mjs

echo ""
if [ "$INFRA_FAILURE" -eq 1 ]; then
  echo "RELEASE GATES: INFRASTRUCTURE FAIL (${#FAILURES[@]} problem(s))"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 2
fi
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "RELEASE GATES: PASS"
  exit 0
fi
echo "RELEASE GATES: FAIL (${#FAILURES[@]} problem(s))"
for f in "${FAILURES[@]}"; do echo "  - $f"; done
exit 1
