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
# Win32_Process (ProcessId+ParentProcessId+Name+CreationDate, positive-PID table) attributes every
# node.exe — including node spawned by node, which MSYS ps cannot see — whose Win32 parent
# chain reaches that closure. Global / pre-existing node is never counted (it is not a
# descendant). FAIL-CLOSED: if enumeration fails, returns an unparseable snapshot, or
# omits the runner's own PID (impossible for a live shell), the run ABORTS with GATE ERROR
# (exit 3) — an owned count of 0 is never fabricated from a failed measurement.
# KNOWN LIMITATION (documented, NOT covered): an owned node whose intermediate parents
# already exited (orphan/reparent; or rejected Windows PID reuse breaking a chain) can no longer be
# attributed by ancestry and escapes the bound. Windows MSYS anchors are sampled before/after
# CIM using /proc identity continuity. Node attribution depending on a vanished or changing
# sampled anchor/intermediate fails measurement; only certified identities enter cleanup.
#
# Usage:
#   run_release_gates.sh                 # preflight + 13 suites + text/docs/manifest/safety/contract
#   run_release_gates.sh [suite ...]     # named suites + same unskippable outer gates
#   run_release_gates.sh --no-safety [suite ...]  # skip safety only
#   run_release_gates.sh --self-test-monitor      # exclusive watchdog self-test
# Set IPC_GATE_LOG_DIR to a new private directory to retain complete child/enum evidence.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="$(command -v bash)"

# The outer manifest and safety gates invoke Git. Clear every inherited Git selector,
# redirection, and trace sink here so the complete release battery cannot write through an
# ambient GIT_TRACE* path or inspect a caller-selected repository.
for _git_var in $(compgen -e); do
  [[ "${_git_var^^}" == GIT_* ]] && unset "$_git_var"
done
for _git_var in $(compgen -e); do
  [[ "${_git_var^^}" == GIT_* ]] \
    && { echo "GATE ABORT: could not clear inherited Git variable $_git_var" >&2; exit 2; }
done
unset _git_var
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_ATTR_NOSYSTEM=1 GIT_PAGER=cat GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0

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
#   * test_reply_view.sh ~453s  (historical measurement from when T23 nested test_ipc; current
#                                T23 uses a bounded wrapper/viewer seam)
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
RUNNER_WINPID=""
RUNNER_CREATED=""
RUNNER_MSYS_START=""

# Pure Git-for-Windows /proc stat parser. The comm field may contain spaces or
# parentheses; consume through its last closing ") " before indexing the suffix.
# Field 22 (suffix token 20) is retained as opaque decimal text, never clock-converted.
parse_msys_stat() {
  local expected="$1" record="$2" suffix fields=()
  MSYS_STAT_PID="" MSYS_STAT_STATE="" MSYS_STAT_PPID="" MSYS_STAT_START=""
  [[ "$record" =~ ^([1-9][0-9]*)[[:space:]]+\(.*\)[[:space:]](.*)$ ]] || return 1
  MSYS_STAT_PID="${BASH_REMATCH[1]}"; suffix="${BASH_REMATCH[2]}"
  [ "$MSYS_STAT_PID" = "$expected" ] || return 1
  read -r -a fields <<<"$suffix"
  [ "${#fields[@]}" -ge 20 ] || return 1
  # Known /proc live states R/S/D/T/t/W/K/P/I and dead states Z/X/x; unknown states fail closed.
  [[ "${fields[0]}" =~ ^[RSDTtWKPIZXx]$ && "${fields[1]}" =~ ^[0-9]+$ && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
  MSYS_STAT_STATE="${fields[0]}"; MSYS_STAT_PPID="${fields[1]}"; MSYS_STAT_START="${fields[19]}"
}

unreadable_msys_endpoint() {
  if [ -d "/proc/$2" ]; then printf '%s MALFORMED %s\n' "$1" "$2"
  else printf '%s MISSING %s\n' "$1" "$2"; fi
}

# Pure endpoint classifier, shared with fixtures that exercise state and identity churn.
classify_msys_endpoint() {
  local p="$1" stat1="$2" win1="$3" stat2="$4" win2="$5" pid1 parent1 start1 state1
  if ! parse_msys_stat "$p" "$stat1"; then printf 'MALFORMED %s\n' "$p"; return; fi
  pid1="$MSYS_STAT_PID"; parent1="$MSYS_STAT_PPID"; start1="$MSYS_STAT_START"; state1="$MSYS_STAT_STATE"
  if ! parse_msys_stat "$p" "$stat2"; then printf 'MALFORMED %s\n' "$p"; return; fi
  if [[ "$state1" == [ZXx] || "$MSYS_STAT_STATE" == [ZXx] ]]; then
    printf 'DEAD %s\n' "$p"; return
  fi
  if [[ ! "$win1" =~ ^[1-9][0-9]*$ || ! "$win2" =~ ^[1-9][0-9]*$ ]]; then
    printf 'MALFORMED %s\n' "$p"; return
  fi
  if [ "$pid1" != "$MSYS_STAT_PID" ] || [ "$parent1" != "$MSYS_STAT_PPID" ] \
    || [ "$start1" != "$MSYS_STAT_START" ] || [ "$win1" != "$win2" ]; then
    printf 'TRANSITION %s\n' "$p"; return
  fi
  printf 'LIVE %s %s %s %s\n' "$p" "$parent1" "$start1" "$win1"
}

# Builtins only: each PS-listed logical PID is read stat1 -> winpid1 -> stat2 -> winpid2.
# A phase emits one explicit availability result; changing R/S is not identity churn.
collect_msys_endpoints() {
  local phase="$1" table="$2" line fields=() p stat1 stat2 win1 win2 key leaf read_rc failed
  local -A listed=()
  while IFS= read -r line; do
    read -r -a fields <<<"$line"
    if [[ "${fields[0]:-}" =~ ^[A-Z]$ ]]; then fields=("${fields[@]:1}"); fi
    p="${fields[0]:-}"
    [[ "$p" =~ ^[1-9][0-9]*$ ]] && listed["$p"]=1
  done <<<"$table"
  for p in "${!listed[@]}"; do
    stat1=""; stat2=""; win1=""; win2=""
    failed=0
    for key in stat1 win1 stat2 win2; do
      read_rc=unattempted
      if [ "$failed" -eq 0 ]; then
        leaf=stat; [[ "$key" == win* ]] && leaf=winpid
        printf 'READ %s %s %s\n' "$phase" "$p" "$key" >&8 || return 2
        read_msys_endpoint_value "$key" "$p" "$leaf" 2>&8; read_rc=$?
        [ "$read_rc" -eq 0 ] || [ -n "${!key}" ] || failed=1
      fi
      # NUL framing retains each original read value without shell evaluation.
      printf '%s\0' "$phase" "$p" "$key" "$read_rc" "${!key}" >&7 || return 2
    done
    if [ "$failed" -ne 0 ]; then unreadable_msys_endpoint "$phase" "$p"; continue; fi
    printf '%s ' "$phase"
    classify_msys_endpoint "$p" "$stat1" "$win1" "$stat2" "$win2"
  done
}

read_msys_endpoint_value() { IFS= read -r "$1" <"/proc/$2/$3"; }

# Pure classifier shared by live enumeration and deterministic ownership fixtures.
# Input: PS <raw MSYS row>; PRE/POST <status> <pid> [<ppid> <start> <winpid>];
# CIM SELF <pid>; CIM <pid> <ppid> <name> <UTC creation>.
# UTC identities use yyyyMMddHHmmssffffff (the common CIM/.NET microsecond precision).
classify_windows_process_rows() {
  awk -v me="$RUNNER_PID" -v enummsys="${1:-0}" \
      -v pinnedpid="$RUNNER_WINPID" -v pinnedtime="$RUNNER_CREATED" -v pinnedstart="$RUNNER_MSYS_START" '
    function fail(s) { error = s }
    function positive(s) { return s ~ /^[0-9]+$/ && s + 0 > 0 }
    function timestamp(s,yr,mo,day,days) {
      if (length(s) != 20 || s !~ /^[0-9]+$/) return 0
      yr = substr(s,1,4)+0; mo = substr(s,5,2)+0; day = substr(s,7,2)+0
      days = (mo == 2 ? 28 + (yr%4 == 0 && (yr%100 != 0 || yr%400 == 0)) :
              (mo == 4 || mo == 6 || mo == 9 || mo == 11 ? 30 : 31))
      return yr > 0 && mo >= 1 && mo <= 12 && day >= 1 && day <= days &&
             substr(s,9,2)+0 < 24 && substr(s,11,2)+0 < 60 && substr(s,13,2)+0 < 60
    }
    function before(a,b) { return ("t" a) < ("t" b) }
    function same(a,b) { return ("t" a) == ("t" b) }
    function stable(p,a,b) {
      a = "PRE" SUBSEP p; b = "POST" SUBSEP p
      return !mdead[p] && estate[a] == "LIVE" && estate[b] == "LIVE" &&
             same(eparent[a],eparent[b]) && same(estart[a],estart[b]) && same(ewin[a],ewin[b]) &&
             same(eparent[a],mppid[p]) && same(ewin[a],mwin[p])
    }
    $1 == "PS" {
      i = 2; status = ""
      if ($i ~ /^[A-Z]$/) { status = $i; i++ } # optional MSYS status prefix
      if ($i == "PID") next
      p = $i; parent = $(i+1); win = $(i+3)
      if (NF < i+7 || !positive(p) || parent !~ /^[0-9]+$/ ||
          $(i+2) !~ /^[0-9]+$/ || win !~ /^[0-9]+$/) {
        fail("malformed MSYS process row"); next
      }
      dead = (status == "Z" || $NF == "<defunct>")
      if (p in mppid && (mppid[p] != parent || mwin[p] != win || mdead[p] != dead)) {
        fail("conflicting MSYS process row"); next
      }
      mppid[p] = parent; mwin[p] = win; mdead[p] = dead; next
    }
    $1 == "PRE" || $1 == "POST" {
      if (!positive($3) || !($3 in mppid) ||
          ($2 != "LIVE" && $2 != "DEAD" && $2 != "MISSING" && $2 != "TRANSITION" && $2 != "MALFORMED") ||
          ($2 == "LIVE" && (NF != 6 || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || !positive($6))) ||
          ($2 != "LIVE" && NF != 3)) {
        fail("malformed MSYS endpoint record"); next
      }
      key = $1 SUBSEP $3
      if (++ecount[key] != 1) {
        fail("duplicate MSYS endpoint record"); next
      }
      if ($2 == "MALFORMED") fail("malformed or unreadable MSYS endpoint")
      estate[key] = $2; eparent[key] = $4; estart[key] = $5; ewin[key] = $6; next
    }
    $1 == "CIM" && $2 == "SELF" {
      if (NF != 3 || !positive($3) || (enumself != "" && enumself != $3))
        fail("malformed or conflicting enumeration identity")
      enumself = $3; next
    }
    $1 == "CIM" {
      if (NF != 5 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || !timestamp($5)) {
        fail("malformed Win32 process identity"); next
      }
      if ($2 in wppid && (wppid[$2] != $3 || wname[$2] != $4 || !same(wtime[$2],$5))) {
        fail("conflicting Win32 process row"); next
      }
      wppid[$2] = $3; wname[$2] = $4; wtime[$2] = $5; next
    }
    NF { fail("unexpected process row") }
    END {
      runner = (me in mwin ? mwin[me] : "")
      if (!(me in mppid) || !stable(me)) fail("runner MSYS continuity unavailable")
      if (!positive(enummsys) || !(enummsys in mppid) || !stable(enummsys))
        fail("enumeration-owner MSYS continuity unavailable")
      for (p in mppid) {
        if (ecount["PRE" SUBSEP p] != 1 || ecount["POST" SUBSEP p] != 1)
          fail("missing or duplicate MSYS endpoint record")
        if (stable(p) && !(mwin[p] in wppid)) fail("stable MSYS identity absent from Win32 snapshot")
      }
      if (!positive(enumself) || !(enumself in wppid))
        fail("enumerator absent from Win32 snapshot")
      if (error != "") { print "ENUM_ERROR:" error; exit 1 }
      created = wtime[runner]; runnerstart = estart["PRE" SUBSEP me]
      if ((pinnedpid != "" || pinnedtime != "" || pinnedstart != "") &&
          (runner != pinnedpid || !same(created,pinnedtime) || !same(runnerstart,pinnedstart)))
        fail("runner identity changed across samples")
      # Logical MSYS edges can span fork/exec stubs; they have no time ordering.
      for (p in mppid) {
        cur = p; hit = 0; walk++
        while (cur in mppid) {
          if (seen[cur] == walk) { fail("MSYS parent cycle"); break }
          seen[cur] = walk
          if (!stable(cur)) break # Unavailable logical intermediates cannot confer ownership.
          if (cur == me) { hit = 1; break }
          cur = mppid[cur]
        }
        win = mwin[p]
        if (hit && positive(win) && win in wppid) {
          if (before(wtime[win],created))
            fail("ambiguous MSYS mapped process identity")
          else root[win] = 1
        }
      }
      # Preserve possible runner paths through uncertain sampled edges, without certifying
      # any identity. PS and available endpoint parents are evidence of possible ownership.
      possible[me] = 1
      do {
        changed = 0
        for (p in mppid) {
          a = "PRE" SUBSEP p; b = "POST" SUBSEP p
          if (!(p in possible) && (mppid[p] in possible ||
              (estate[a] == "LIVE" && eparent[a] in possible) ||
              (estate[b] == "LIVE" && eparent[b] in possible))) {
            possible[p] = 1; changed = 1
          }
        }
      } while (changed)
      for (p in possible) {
        a = "PRE" SUBSEP p; b = "POST" SUBSEP p
        if (positive(mwin[p]) && !(mwin[p] in root)) uncertain[mwin[p]] = 1
        if (positive(ewin[a]) && !(ewin[a] in root)) uncertain[ewin[a]] = 1
        if (positive(ewin[b]) && !(ewin[b] in root)) uncertain[ewin[b]] = 1
      }
      if (!(mwin[enummsys] in root)) fail("enumeration owner has no certified runner path")
      cur = enummsys; walk++
      while (cur in mppid && cur != me) {
        if (seen[cur] == walk) { fail("MSYS bookkeeping cycle"); break }
        seen[cur] = walk
        win = mwin[cur]
        if (!stable(cur) || !(win in root)) break
        book[win] = 1
        cur = mppid[cur]
      }
      for (w in wname) {
        if (before(wtime[w],created)) continue
        cur = w; owned = 0; bookkeeping = 0; ambiguous = 0; walk++
        while (cur in wppid) { # Existence must precede root membership.
          if (seen[cur] == walk) { fail("Win32 parent cycle"); break }
          seen[cur] = walk
          if (cur in book) { bookkeeping = 1; break }
          if (cur in root) { owned = 1; break }
          if (cur in uncertain) ambiguous = 1
          parent = wppid[cur]
          if (!positive(parent) || !(parent in wppid)) break
          # A parent created later than its child is a recycled PID, not ancestry.
          if (before(wtime[cur],wtime[parent])) break
          cur = parent
        }
        if (ambiguous && !owned && !bookkeeping && tolower(wname[w]) == "node.exe")
          fail("candidate MSYS ancestry continuity unavailable")
        if (owned && !bookkeeping && w != runner && w != enumself)
          output[w] = w " " wname[w] " " wtime[w]
      }
      if (error != "") { print "ENUM_ERROR:" error; exit 1 }
      print "RUNNER", runner, created, runnerstart
      for (w in output) print output[w]
    }'
}

# Only successful sample scratch is reused. A failed/incomplete sample is never
# overwritten; the next index is selected with builtins, without an archival child.
begin_enum_capture() {
  local index prior stage
  IFS= read -r index <"$RUNDIR/enum-next" && [[ "$index" =~ ^[0-9]+$ ]] || return 2
  ENUM_FILE="$RUNDIR/enum-$index"
  if [ -f "$ENUM_FILE.status" ]; then
    IFS= read -r prior <"$ENUM_FILE.status" || return 2
    if [ "$prior" != 0 ]; then
      index=$((index + 1)); ENUM_FILE="$RUNDIR/enum-$index"
      printf '%s\n' "$index" >"$RUNDIR/enum-next" || return 2
    fi
  fi
  printf 'incomplete\n' >"$ENUM_FILE.status" || return 2
  for stage in ps ps.err pre pre.err cim cim.err post post.err input output classifier.err endpoints endpoint.err; do
    : >"$ENUM_FILE.$stage" || return 2
  done
}

finish_enum_capture() {
  local result="$1" capture_rc=0
  printf 'context=%s\nrunner_pid=%s\nrunner_winpid=%s\nrunner_created=%s\nrunner_msys_start=%s\nenum_owner_pid=%s\nPS=%s\nPRE=%s\nCIM=%s\nPOST=%s\nCLASSIFIER=%s\n' \
    "${ENUM_CONTEXT:-unspecified}" "$RUNNER_PID" "$RUNNER_WINPID" "$RUNNER_CREATED" "$RUNNER_MSYS_START" "$enum_owner_pid" \
    "$ps_rc" "$pre_rc" "$cim_rc" "$post_rc" "$classifier_rc" >"$ENUM_FILE.meta" || capture_rc=2
  [ "$capture_rc" -eq 0 ] && printf '%s\n' "$result" >"$ENUM_FILE.status" || capture_rc=2
  if [ "$capture_rc" -ne 0 ]; then
    echo "CAPTURE ERROR: incomplete enumeration evidence at $ENUM_FILE" >&2
    [ "$result" -ne 0 ] || result=2
  fi
  if [ "$result" -ne 0 ]; then
    printf 'enumeration evidence: %s (context=%s)\n' "$ENUM_FILE" "${ENUM_CONTEXT:-unspecified}" >&2
  fi
  return "$result"
}

enum_collection_error() {
  printf '%s\n' "$1" >"$ENUM_FILE.output" || echo "CAPTURE ERROR: enumeration diagnostic incomplete" >&2
  printf '%s\n' "$1"
  finish_enum_capture 1
}

owned_process_rows() {
  local enum_owner_pid="$BASHPID" ENUM_FILE ps_rc=unattempted pre_rc=unattempted
  local cim_rc=unattempted post_rc=unattempted classifier_rc=unattempted result out
  if ! begin_enum_capture; then
    echo "CAPTURE ERROR: could not acquire enumeration scratch" >&2
    return 2
  fi
  if is_windows; then
    local pstab cimtab pretab posttab
    # Layer 1: MSYS process table (PID PPID PGID WINPID ... after a header line).
    ps -e >"$ENUM_FILE.ps" 2>"$ENUM_FILE.ps.err"; ps_rc=$?
    if [ "$ps_rc" -ne 0 ]; then
      enum_collection_error "ENUM_ERROR:MSYS ps enumeration failed (nonzero exit)"; return $?
    fi
    pstab="$(<"$ENUM_FILE.ps")" || {
      echo 'CAPTURE ERROR: original PS output unreadable' >&2; finish_enum_capture 2; return $?;
    }
    collect_msys_endpoints PRE "$pstab" >"$ENUM_FILE.pre" 2>"$ENUM_FILE.pre.err" \
      7>"$ENUM_FILE.endpoints" 8>"$ENUM_FILE.endpoint.err"; pre_rc=$?
    if [ "$pre_rc" -ne 0 ]; then
      if [ "$pre_rc" -eq 2 ]; then
        echo "CAPTURE ERROR: MSYS PRE collection incomplete" >&2
        finish_enum_capture 2; return $?
      fi
      enum_collection_error "ENUM_ERROR:MSYS PRE identity collection failed"; return $?
    fi
    pretab="$(<"$ENUM_FILE.pre")" || {
      echo 'CAPTURE ERROR: original PRE output unreadable' >&2; finish_enum_capture 2; return $?;
    }
    # Layer 2: all positive Win32 PIDs, including non-node intermediaries. PID 0 is
    # a sentinel with no usable identity; neither it nor absent parents are roots.
    # Normalize whitespace in names to retain strict token framing. Failure is NOT swallowed.
    powershell.exe -NoProfile -NonInteractive -Command "\$ErrorActionPreference='Stop'; 'SELF {0}' -f \$PID; Get-CimInstance Win32_Process | Where-Object { \$_.ProcessId -gt 0 } | ForEach-Object { '{0} {1} {2} {3}' -f \$_.ProcessId, \$_.ParentProcessId, (\$_.Name -replace '\\s','_'), \$_.CreationDate.ToUniversalTime().ToString('yyyyMMddHHmmssffffff',[Globalization.CultureInfo]::InvariantCulture) }" \
      >"$ENUM_FILE.cim" 2>"$ENUM_FILE.cim.err"; cim_rc=$?
    if [ "$cim_rc" -ne 0 ]; then
      enum_collection_error "ENUM_ERROR:Win32_Process enumeration failed (powershell.exe nonzero exit)"; return $?
    fi
    collect_msys_endpoints POST "$pstab" >"$ENUM_FILE.post" 2>"$ENUM_FILE.post.err" \
      7>>"$ENUM_FILE.endpoints" 8>>"$ENUM_FILE.endpoint.err"; post_rc=$?
    if [ "$post_rc" -ne 0 ]; then
      if [ "$post_rc" -eq 2 ]; then
        echo "CAPTURE ERROR: MSYS POST collection incomplete" >&2
        finish_enum_capture 2; return $?
      fi
      enum_collection_error "ENUM_ERROR:MSYS POST identity collection failed"; return $?
    fi
    posttab="$(<"$ENUM_FILE.post")" || {
      echo 'CAPTURE ERROR: original POST output unreadable' >&2; finish_enum_capture 2; return $?;
    }
    cimtab="$(<"$ENUM_FILE.cim")" || {
      echo 'CAPTURE ERROR: original CIM output unreadable' >&2; finish_enum_capture 2; return $?;
    }
    cimtab="${cimtab//$'\r'/}"
    {
      printf '%s\n' "$pstab" | awk '{ print "PS", $0 }' &&
      printf '%s\n' "$pretab" &&
      printf '%s\n' "$cimtab" | awk 'NF { print "CIM", $0 }' &&
      printf '%s\n' "$posttab"
    } >"$ENUM_FILE.input" || { echo 'CAPTURE ERROR: classifier input unavailable' >&2; finish_enum_capture 2; return $?; }
    classify_windows_process_rows "$enum_owner_pid" <"$ENUM_FILE.input" >"$ENUM_FILE.output" 2>"$ENUM_FILE.classifier.err"
    classifier_rc=$?
  else
    local tab
    sh -c 'printf "SELF %s\n" "$$"; exec ps -e -o pid=,ppid=,comm=' >"$ENUM_FILE.ps" 2>"$ENUM_FILE.ps.err"; ps_rc=$?
    if [ "$ps_rc" -ne 0 ]; then
      enum_collection_error "ENUM_ERROR:ps enumeration failed (nonzero exit)"; return $?
    fi
    tab="$(<"$ENUM_FILE.ps")" || {
      echo 'CAPTURE ERROR: original PS output unreadable' >&2; finish_enum_capture 2; return $?;
    }
    if ! printf '%s\n' "$tab" | awk -v me="$RUNNER_PID" '$1==me{f=1} END{exit f?0:1}'; then
      enum_collection_error "ENUM_ERROR:runner pid $RUNNER_PID absent from ps snapshot (enumeration untrustworthy)"; return $?
    fi
    printf '%s\n' "$tab" >"$ENUM_FILE.input" || { echo 'CAPTURE ERROR: classifier input unavailable' >&2; finish_enum_capture 2; return $?; }
    awk -v me="$RUNNER_PID" -v enum="$enum_owner_pid" '
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
      }' <"$ENUM_FILE.input" >"$ENUM_FILE.output" 2>"$ENUM_FILE.classifier.err"
    classifier_rc=$?
  fi
  result=0; [ "$classifier_rc" -eq 0 ] || result=1
  # A failed read must not become an empty owned set or mark this scratch reusable.
  out="$(<"$ENUM_FILE.output")" || {
    echo 'CAPTURE ERROR: original classifier output unreadable' >&2
    [ "$result" -ne 0 ] || result=2
    finish_enum_capture "$result"; return $?
  }
  finish_enum_capture "$result"; result=$?
  printf '%s\n' "$out"
  return "$result"
}

owned_descendant_pids() {
  local out rc
  out="$(owned_process_rows)"; rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
  if is_windows; then
    printf '%s\n' "$out" | awk '$1 != "RUNNER" && NF == 3 { print $1, $3 }'
  else
    printf '%s\n' "$out" | awk 'NF >= 2 { print $1 }'
  fi
}

owned_node_pids() {
  local out rc
  out="$(owned_process_rows)"; rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; return "$rc"; }
  printf '%s\n' "$out" | awk '$1 != "RUNNER" && NF >= 2 && tolower($2) ~ /(^|\/)node(\.exe)?$/ { print $1 }'
}

# count_owned_node: prints the owned count on success; on enumeration failure prints the
# ENUM_ERROR reason to stderr and returns 1 (capture failure: 2). Callers fail closed.
count_owned_node() {
  local out rc
  out="$(owned_node_pids)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 2 ]; then
      printf '%s\n' "$out" | grep '^ENUM_ERROR:' >&2 || echo "ENUM_ERROR:unknown enumeration failure" >&2
    fi
    return "$rc"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | grep -c . || true
}

count_owned_descendants() {
  local out rc
  out="$(owned_descendant_pids)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 2 ]; then
      printf '%s\n' "$out" | grep '^ENUM_ERROR:' >&2 || echo "ENUM_ERROR:unknown enumeration failure" >&2
    fi
    return "$rc"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | grep -c . || true
}

reap_direct_child() {
  local spid="${1:-}" k0
  if [ -n "$spid" ]; then
    k0=$SECONDS
    # $spid is the direct child returned by this shell, not inferred ancestry.
    kill "$spid" 2>/dev/null || true
    while kill -0 "$spid" 2>/dev/null && [ $((SECONDS - k0)) -lt "$POST_SUITE_DRAIN_S" ]; do sleep 0.2; done
    if kill -0 "$spid" 2>/dev/null; then kill -KILL "$spid" 2>/dev/null || true; fi
    k0=$SECONDS
    while kill -0 "$spid" 2>/dev/null && [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do sleep 0.2; done
    if kill -0 "$spid" 2>/dev/null; then
      echo "  ENUM ABORT: direct suite child $spid still alive; bounded reap failed" >&2
    else
      wait "$spid" 2>/dev/null || true
      echo "  ENUM ABORT: direct suite child $spid reaped" >&2
    fi
  fi
}

# enum_abort: fail the whole run closed when the owned set cannot be measured.
# enum_abort <context> [suite-child-pid]
enum_abort() {
  local ctx="$1" spid="${2:-}"
  reap_direct_child "$spid"
  echo "GATE ERROR: owned-Node enumeration failed ($ctx); the process bound cannot be measured — failing closed (exit 3). Suite child processes may need manual cleanup." >&2
  exit 3
}

measurement_abort() {
  local rc="$1" ctx="$2" spid="${3:-}"
  [ "$rc" -eq 2 ] || enum_abort "$ctx" "$spid"
  reap_direct_child "$spid"
  echo "GATE ABORT: required evidence capture failed ($ctx); incomplete evidence (exit 2)" >&2
  exit 2
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
  if is_windows; then
    captured_windows_processes kill "$pids"
    return $?
  fi
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    kill -TERM "$pid" 2>/dev/null || true
  done
}

# Carry PID + CreationDate through cleanup. Opening Handle binds this Process object
# to one kernel process; StartTime and Kill use that retained handle, even after PID reuse.
# A replacement is neither terminated nor reported as a survivor of the captured set.
captured_windows_processes() {
  local mode="$1" identities="$2" cleanup_script
  IFS= read -r -d '' cleanup_script <<'POWERSHELL' || true
    # IPC_GATE_IDENTITY_CLEANUP (fixture shim distinguishes cleanup from enumeration)
    $ErrorActionPreference = "Stop"
    $mode = $env:IPC_GATE_CLEANUP_MODE
    if ($mode -ne "kill" -and $mode -ne "live") { throw "Invalid cleanup mode" }
    $rows = @([Console]::In.ReadToEnd() -split "\r?\n" | Where-Object { $_ -ne "" })
    foreach ($row in $rows) {
      if ($row -notmatch "^[1-9][0-9]* [0-9]{20}$") { throw "Malformed captured identity" }
    }
    $failed = $false
    foreach ($row in $rows) {
      $fields = $row -split " "
      $proc = $null
      try {
        try { $proc = [Diagnostics.Process]::GetProcessById([int]$fields[0]) }
        catch [Management.Automation.MethodInvocationException] {
          if ($_.Exception.InnerException -is [ArgumentException]) { continue }
          throw
        }
        $handle = $proc.Handle
        if ($proc.HasExited) { continue }
        $created = $proc.StartTime.ToUniversalTime().ToString("yyyyMMddHHmmssffffff",[Globalization.CultureInfo]::InvariantCulture)
        if ($created -ne $fields[1]) { continue }
        if ($mode -eq "kill") { $proc.Kill() }
        if (-not $proc.HasExited) { $row }
      } catch [InvalidOperationException] {
        if ($null -eq $proc -or -not $proc.HasExited) {
          [Console]::Error.WriteLine("Identity cleanup failed: " + $_.Exception.Message)
          $failed = $true
        }
      } catch {
        [Console]::Error.WriteLine("Identity cleanup failed: " + $_.Exception.Message)
        $failed = $true
      } finally { if ($null -ne $proc) { $proc.Dispose() } }
    }
    if ($failed) { exit 1 }
    exit 0
POWERSHELL
  printf '%s\n' "$identities" \
    | IPC_GATE_CLEANUP_MODE="$mode" powershell.exe -NoProfile -NonInteractive -Command "$cleanup_script" \
    | tr -d '\r'
}

# Prints the retained POSIX PID subset that is still present. Timeout cleanup sends KILL to
# each captured survivor at most once, then observes this original set so a reparented
# descendant cannot disappear from ancestry accounting and produce a false clean result.
live_captured_posix_pids() {
  local pids="$1" pid
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) continue;; esac
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
  done
  return 0
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
MONITOR_LAST_CAPTURED_RESIDUAL=""
MONITOR_LAST_RESIDUAL=0
record_fail() { FAILURES+=("$1"); echo "  GATE FAIL: $1"; }

# run_monitored <label> <argv...>
run_monitored() {
  local label="$1"; shift
  local logf logfd spid peak=0 owned t0 rc=0 timed_out=0 deadline remaining ENUM_CONTEXT
  local d0 drained=0 residual captured="" captured_residual="" live_captured="" reasons=() skips sl text k0 pid skip_lines=()
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
  printf '  child log: %s -> %s\n' "$label" "$logf"
  if ! printf '%s\t%s\n' "$label" "$logf" >>"$RUNDIR/children"; then
    record_fail "$label: rc=2 child log mapping unavailable; child not launched"
    INFRA_FAILURE=1; return 2
  fi
  if ! exec {logfd}>"$logf"; then
    record_fail "$label: rc=2 child log unavailable; child not launched"
    INFRA_FAILURE=1; return 2
  fi
  "$@" >&"$logfd" 2>&1 &
  spid=$!
  exec {logfd}>&-
  t0=$SECONDS
  while kill -0 "$spid" 2>/dev/null; do
    ENUM_CONTEXT="mid-child sample, $label"
    owned="$(count_owned_node)" || measurement_abort "$?" "$ENUM_CONTEXT" "$spid"
    [ "$owned" -gt "$peak" ] && peak="$owned"
    if [ $((SECONDS - t0)) -ge "$deadline" ]; then
      timed_out=1; rc=124
      ENUM_CONTEXT="timeout snapshot, $label"
      captured="$(owned_descendant_pids)" || measurement_abort "$?" "$ENUM_CONTEXT" "$spid"
      echo "  MONITOR TIMEOUT: $label after ${deadline}s; captured descendant(s): ${captured:-<none>}" >&2
      k0=$SECONDS
      if is_windows; then
        if ! kill_owned_tree "$captured" >/dev/null; then
          reasons+=("identity-cleanup-failed")
        fi
        while [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do
          captured_residual="$(captured_windows_processes live "$captured")" \
            || enum_abort "captured identity recheck, $label" "$spid"
          [ -z "$captured_residual" ] && ! kill -0 "$spid" 2>/dev/null && break
          sleep 0.2
        done
        captured_residual="$(captured_windows_processes live "$captured")" \
          || enum_abort "captured identity residual, $label" "$spid"
        if kill -0 "$spid" 2>/dev/null; then
          reasons+=("suite-child-unreaped")
        else
          wait "$spid" 2>/dev/null || true
        fi
      else
        kill_owned_tree "$captured" || true
        kill "$spid" 2>/dev/null || true
        live_captured="$(live_captured_posix_pids "$captured")"
        for pid in $live_captured; do kill -KILL "$pid" 2>/dev/null || true; done
        if kill -0 "$spid" 2>/dev/null; then kill -KILL "$spid" 2>/dev/null || true; fi
        wait "$spid" 2>/dev/null || true
        while [ $((SECONDS - k0)) -lt "$KILL_DEADLINE_S" ]; do
          captured_residual="$(live_captured_posix_pids "$captured")"
          [ -z "$captured_residual" ] && break
          sleep 0.2
        done
        captured_residual="$(live_captured_posix_pids "$captured")"
      fi
      break
    fi
    sleep "$SAMPLE_INTERVAL_S"
  done
  if [ "$timed_out" -eq 0 ]; then wait "$spid"; rc=$?; fi

  d0=$SECONDS
  while [ $((SECONDS - d0)) -lt "$POST_SUITE_DRAIN_S" ]; do
    ENUM_CONTEXT="post-child drain, $label"
    residual="$(count_owned_descendants)" || measurement_abort "$?" "$ENUM_CONTEXT"
    if [ "$residual" -eq 0 ]; then drained=1; break; fi
    sleep 0.25
  done
  ENUM_CONTEXT="post-child residual, $label"
  residual="$(count_owned_descendants)" || measurement_abort "$?" "$ENUM_CONTEXT"
  if [ "$residual" -ne 0 ]; then kill_owned_tree || true; fi

  [ "$rc" -eq 0 ] || reasons+=("child-exit=$rc")
  [ "$peak" -le "$PEAK_LIMIT" ] || reasons+=("owned-node-peak=$peak>${PEAK_LIMIT}")
  if [ "$drained" -ne 1 ] || [ "$residual" -ne 0 ]; then
    reasons+=("owned-descendant-residual=$residual>${POST_SUITE_DRAIN_S}s")
  fi
  if [ -n "$captured_residual" ]; then
    reasons+=("captured-descendant-residual=${captured_residual//$'\n'/,}>${KILL_DEADLINE_S}s")
  fi
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

  MONITOR_LAST_RC="$rc"
  MONITOR_LAST_TIMEOUT="$timed_out"
  MONITOR_LAST_CAPTURED="$captured"
  MONITOR_LAST_CAPTURED_RESIDUAL="$captured_residual"
  MONITOR_LAST_RESIDUAL="$residual"
  if [ "${#reasons[@]}" -gt 0 ]; then
    if [ "$MONITOR_EXPECT_TIMEOUT" -eq 1 ] && [ "$timed_out" -eq 1 ] && [ "$residual" -eq 0 ] && [ -z "$captured_residual" ] && [ "${#reasons[@]}" -eq 1 ]; then
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
    'trap "" TERM; sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' _ "$pidfile"
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
  [ -z "$MONITOR_LAST_CAPTURED_RESIDUAL" ] || { echo "SELF-TEST-MONITOR FAIL: captured descendant residual" >&2; return 1; }
  [ "$MONITOR_LAST_RESIDUAL" -eq 0 ] || { echo "SELF-TEST-MONITOR FAIL: residual descendants" >&2; return 1; }
  [ $((SECONDS - t0)) -le $((MONITOR_TIMEOUT_S + KILL_DEADLINE_S + POST_SUITE_DRAIN_S + 3)) ] \
    || { echo "SELF-TEST-MONITOR FAIL: bounded return exceeded" >&2; return 1; }
  echo "SELF-TEST-MONITOR PASS: active timeout; captured descendant killed/reaped; bounded return"
  return 0
}

# ---- main --------------------------------------------------------------------------------
# Allows fixtures to load the production classifier without enumeration or process control.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

if [ "${IPC_GATE_LOG_DIR+x}" = x ]; then
  RUNDIR="$IPC_GATE_LOG_DIR"
  [ -n "$RUNDIR" ] && (umask 077; mkdir -- "$RUNDIR") \
    || { echo "GATE ABORT: IPC_GATE_LOG_DIR must be a new writable directory under an existing parent" >&2; exit 2; }
  echo "retained gate evidence: $RUNDIR"
else
  RUNDIR="$(mktemp -d)" && [ -n "$RUNDIR" ] && [ -d "$RUNDIR" ] \
    || { echo "GATE ABORT: could not create runner temporary directory" >&2; exit 2; }
  trap 'rm -rf "$RUNDIR"' EXIT
fi
printf '0\n' >"$RUNDIR/enum-next" || { echo 'GATE ABORT: runner evidence directory is unwritable' >&2; exit 2; }
LAYOUT_T0=$SECONDS

echo "=== release gate runner ==="
# Fail-closed self-check: owned-Node enumeration must work BEFORE any suite runs; a broken
# enumerator must never let a suite pass against a fabricated 0-measurement.
if is_windows; then
  ENUM_CONTEXT="startup identity pin"
  RUNNER_SNAPSHOT="$(owned_process_rows)" || measurement_abort "$?" "$ENUM_CONTEXT"
  read -r _runner_tag RUNNER_WINPID RUNNER_CREATED RUNNER_MSYS_START \
    <<<"$(printf '%s\n' "$RUNNER_SNAPSHOT" | awk '$1 == "RUNNER" { print }')"
  [[ "$_runner_tag" == RUNNER && "$RUNNER_WINPID" =~ ^[1-9][0-9]*$ && "$RUNNER_CREATED" =~ ^[0-9]{20}$ && "$RUNNER_MSYS_START" =~ ^[0-9]+$ ]] \
    || enum_abort "startup identity pin malformed"
  readonly RUNNER_WINPID RUNNER_CREATED RUNNER_MSYS_START
fi
ENUM_CONTEXT="startup self-check"
SELFTEST_OWNED="$(count_owned_node)" || measurement_abort "$?" "$ENUM_CONTEXT"
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
