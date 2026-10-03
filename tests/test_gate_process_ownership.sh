#!/usr/bin/env bash
# Fixture: owned-Node process-bound trust in tests/run_release_gates.sh (v0.1.7 A0/F2).
#
# The runner's process bound is only meaningful if (a) "owned" node processes are
# attributed by ancestry to THIS runner (not by a global before/after snapshot), and
# (b) an enumeration outage can never be silently measured as "0 owned". This fixture
# pins both properties and evidence retention with six monitor checks:
#
#   T1  startup fail-closed: with process enumeration broken before any suite runs,
#       the runner must ERROR nonzero, never emit RELEASE GATES: PASS off a silent
#       0-measurement.
#   T2  ancestry discrimination: node processes that are NOT descendants of the runner
#       (spawned here by the fixture, as siblings of the runner, while a suite is
#       running) must NOT count toward the bound; the gate must PASS.
#   T3  descendant detection (blindness guard): 3 concurrent node processes spawned
#       INSIDE a suite MUST be counted and breach the peak bound (limit 2), failing
#       the gate. Guards against an implementation that always measures 0.
#   T4  mid-suite fail-closed: if enumeration starts failing while a suite is running,
#       the runner must abort nonzero, terminate/reap its named direct suite child,
#       and never degrade to a silent 0-measurement.
#   T5  active monitor timeout: the exclusive runner self-test captures, force-kills, and
#       reaps a TERM-resistant descendant, emits named diagnostics, and returns within bound.
#   T6  ordinary child failure retains every output byte and its independent exit status.
#
# Hermetic: runtime state is temporary and evidence is retained separately; every node process is short-lived
# and reaped on exit; no transport roots, no IPC, no installed-root access. Enumeration
# outages are injected via PATH shims (Windows: powershell.exe; POSIX: ps). On Windows,
# T1-T4/T6 invocations additionally get an identity-cleanup no-op shim so a runner that
# mis-scopes foreign PIDs as "owned" cannot kill processes this fixture does not own.
# T5 must use real identity-bound cleanup because killing/reaping its owned descendant is
# the behavior under test.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$TDIR/run_release_gates.sh"
[ -f "$RUNNER" ] || { echo "FAIL: runner not found at $RUNNER"; exit 1; }

# Pure, table-driven checks use the same stat parser and classifiers as live enumeration. This
# mode exits before temporary files, enumeration, child launch, or any cleanup.
CLASSIFIER_ONLY=0
CLEANUP_ONLY=0
CAPTURE_ONLY=0
if [ "${1:-}" = --classifier-only ] && [ "$#" -eq 1 ]; then CLASSIFIER_ONLY=1; fi
if [ "${1:-}" = --cleanup-only ] && [ "$#" -eq 1 ]; then CLEANUP_ONLY=1; fi
if [ "${1:-}" = --capture-only ] && [ "$#" -eq 1 ]; then CAPTURE_ONLY=1; fi
run_classifier_cases() (
  source "$RUNNER"
  # Retained read-only local record: Git-for-Windows MSYS 3.6.6-1cdd4371.
  local retained='1927 (cat) R 1 1927 1927 0 -1 0 2551 2551 0 0 31 15 31 15 20 0 0 0 84028164 5758976 1469 1413120'
  local parser_names=(retained spaces nested trailing last-close truncated invalid-start mismatched-pid unknown-state)
  local parser_rows=("$retained" "${retained/\(cat\)/(node child)}" "${retained/\(cat\)/(node (child))}"
    "${retained/\(cat\)/(node child)))}" "${retained/\(cat\)/(node) child))}"
    "${retained/84028164 5758976 1469 1413120/}" "${retained/84028164/not-a-start}" "$retained" "${retained/ R / Q }")
  local parser_pids=(1927 1927 1927 1927 1927 1927 1927 1928 1927)
  local parser_expected=('1927 R 1 84028164' '1927 R 1 84028164' '1927 R 1 84028164'
    '1927 R 1 84028164' '1927 R 1 84028164' ERROR ERROR ERROR ERROR)
  local i rc got failed=0
  for i in "${!parser_names[@]}"; do
    parse_msys_stat "${parser_pids[$i]}" "${parser_rows[$i]}"; rc=$?
    got="$MSYS_STAT_PID $MSYS_STAT_STATE $MSYS_STAT_PPID $MSYS_STAT_START"
    if { [ "$rc" -eq 0 ] && [ "$got" = "${parser_expected[$i]}" ]; } \
      || { [ "$rc" -ne 0 ] && [ "${parser_expected[$i]}" = ERROR ]; }; then
      echo "PASS: stat parser ${parser_names[$i]}"
    else
      echo "FAIL: stat parser ${parser_names[$i]} rc=$rc got=$got"; failed=$((failed + 1))
    fi
  done
  stat_record() {
    local fields=() suffix="${retained#*') '}"
    read -r -a fields <<<"$suffix"
    fields[0]="$3"; fields[1]="$2"; fields[19]="$4"
    printf '%s (node child) %s\n' "$1" "${fields[*]}"
  }
  local stat_r stat_s stat_dead stat_start stat_parent
  stat_r="$(stat_record 200 100 R 84028166)"; stat_s="$(stat_record 200 100 S 84028166)"
  stat_dead="$(stat_record 200 100 Z 84028166)"; stat_start="$(stat_record 200 100 S 84028167)"
  stat_parent="$(stat_record 200 999 S 84028166)"
  local endpoint_names=(state-change unknown-state dead winpid-change start-change ppid-change invalid-winpid invalid-stat)
  local endpoint_stat2=("$stat_s" "${stat_s/ S / Q }" "$stat_dead" "$stat_s" "$stat_start" "$stat_parent" "$stat_s" "${stat_s/84028166/bad}")
  local endpoint_win2=(2000 2000 2000 2001 2000 2000 0 2000)
  local endpoint_expected=('LIVE 200 100 84028166 2000' 'MALFORMED 200' 'DEAD 200' 'TRANSITION 200' 'LIVE 200 100 84028166 2000' 'TRANSITION 200' 'MALFORMED 200' 'MALFORMED 200')
  for i in "${!endpoint_names[@]}"; do
    got="$(classify_msys_endpoint 200 "$stat_r" 2000 "${endpoint_stat2[$i]}" "${endpoint_win2[$i]}")"
    if [ "$got" = "${endpoint_expected[$i]}" ]; then echo "PASS: endpoint ${endpoint_names[$i]}"
    else echo "FAIL: endpoint ${endpoint_names[$i]} got=$got"; failed=$((failed + 1)); fi
  done
  RUNNER_PID=100
  RUNNER_WINPID=1000
  RUNNER_CREATED=20261001000000000000
  RUNNER_MSYS_START=84028164
  local base=$'PS PID PPID PGID WINPID TTY UID STIME COMMAND\nPS 100 1 100 1000 ? 1 00:00 bash\nPS 101 100 100 1001 ? 1 00:01 bash\nPRE LIVE 100 1 84028164 1000\nPOST LIVE 100 1 84028164 1000\nPRE LIVE 101 100 84028165 1001\nPOST LIVE 101 100 84028165 1001\nCIM SELF 9000\nCIM 9000 1001 powershell.exe 20261001000009000000\nCIM 1001 1000 bash.exe 20261001000001000000\nCIM 1000 0 bash.exe 20261001000000000000'
  local mapped=$'\nPS 200 100 100 2000 ? 1 00:02 node\nPRE LIVE 200 100 84028166 2000\nPOST LIVE 200 100 84028166 2000\nCIM 2000 7777 node.exe 20261001000002000000'
  local names=() expected=() inputs=() pins=() times=() starts=()
  add_case() {
    local input="$3" early
    # Existing shapes declare the late population. Mirror it only for an unchanged
    # early identity baseline; bracketing/churn cases supply their own early table.
    if [[ "$input" != *CIM_PRE\ * ]]; then
      early="$(printf '%s\n' "$input" | awk '$1 == "CIM" { $1 = "CIM_PRE"; print }')"
      input+=$'\n'"$early"
    fi
    names+=("$1"); expected+=("$2"); inputs+=("$input")
    pins+=("${4:-1000}"); times+=("${5:-20261001000000000000}")
    starts+=("${6-84028164}")
  }
  add_case empty-owned '' "$base"
  add_case zero-root '' "$base"$'\nPS 200 100 100 0 ? 1 00:01 <defunct>\nPRE DEAD 200\nPOST DEAD 200\nCIM 3000 0 node.exe 20261001000002000000'
  add_case unavailable-root '' "$base"$'\nPS 200 100 100 2000 ? 1 00:01 bash\nPRE MISSING 200\nPOST MISSING 200\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case stale-root ERROR "$base${mapped/20261001000002000000/20260930235959000000}"
  add_case recycled-parent '' "$base"$'\nCIM 2000 1000 bash.exe 20261001000004000000\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case older-candidate '' "$base"$'\nCIM 3000 1000 node.exe 20260930235959000000'
  add_case status-prefix 2000 "$base${mapped/PS 200/PS I 200}"
  add_case status-defunct '' "$base"$'\nPS Z 200 100 100 0 ? 1 00:01 <defunct>\nPRE DEAD 200\nPOST DEAD 200\nCIM 3000 0 node.exe 20261001000002000000'
  add_case before-msys-reads 2000 "$base${mapped/20261001000002000000/20261001000008000001}"
  add_case defunct-replacement ERROR "$base${mapped/00:02 node/00:02 <defunct>}"
  add_case valid-mapped-root 2000 "$base$mapped"
  local state_pre state_post state_mapped
  state_pre="$(classify_msys_endpoint 200 "$stat_r" 2000 "$stat_s" 2000)"
  state_post="$(classify_msys_endpoint 200 "$stat_s" 2000 "$stat_r" 2000)"
  state_mapped="${mapped/PRE LIVE 200 100 84028166 2000/PRE $state_pre}"
  state_mapped="${state_mapped/POST LIVE 200 100 84028166 2000/POST $state_post}"
  add_case state-changes-count 2000 "$base$state_mapped"
  add_case ps-pre-winpid-mismatch ERROR "$base${mapped/PRE LIVE 200 100 84028166 2000/PRE LIVE 200 100 84028166 2001}"
  add_case ps-parent-mismatch ERROR "$base${mapped/PS 200 100/PS 200 999}"
  add_case winpid-change ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/POST LIVE 200 100 84028166 2001}"
  add_case start-change 2000 "$base${mapped/POST LIVE 200 100 84028166/POST LIVE 200 100 84028167}"
  local opaque_mapped="${mapped//84028166/9007199254740992}"
  add_case opaque-start-change 2000 "$base${opaque_mapped/POST LIVE 200 100 9007199254740992/POST LIVE 200 100 9007199254740993}"
  add_case ppid-change ERROR "$base${mapped/POST LIVE 200 100/POST LIVE 200 999}"
  add_case pre-missing ERROR "$base${mapped/PRE LIVE 200 100 84028166 2000/PRE MISSING 200}"
  add_case post-missing ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/POST MISSING 200}"
  add_case pre-dead ERROR "$base${mapped/PRE LIVE 200 100 84028166 2000/PRE DEAD 200}"
  add_case post-dead ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/POST DEAD 200}"
  add_case transition ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/POST TRANSITION 200}"
  add_case missing-pre-record ERROR "$base${mapped/PRE LIVE 200 100 84028166 2000/}"
  add_case missing-post-record ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/}"
  add_case duplicate-pre-record ERROR "$base$mapped"$'\nPRE LIVE 200 100 84028166 2000'
  add_case duplicate-post-record ERROR "$base$mapped"$'\nPOST LIVE 200 100 84028166 2000'
  local unavailable=$'\nPS 200 100 100 2000 ? 1 00:02 bash\nPRE LIVE 200 100 84028166 2000\nPOST MISSING 200'
  add_case unrelated-unavailable '' "$base$unavailable"
  local uncertain_shell="$base$unavailable"$'\nCIM 2000 7777 bash.exe 20261001000002000000'
  add_case uncertain-non-node '' "$uncertain_shell"
  add_case node-behind-uncertain-shell ERROR "$uncertain_shell"$'\nCIM 3000 2000 node.exe 20261001000003000000'
  add_case unrelated-missing-pre-record ERROR "$base${unavailable/PRE LIVE 200 100 84028166 2000/}"
  add_case unrelated-missing-post-record ERROR "$base${unavailable/POST MISSING 200/}"
  local foreign_unavailable="${unavailable/PS 200 100/PS 200 999}"
  foreign_unavailable="${foreign_unavailable/PRE LIVE 200 100/PRE LIVE 200 999}"
  add_case foreign-unavailable-candidate '' "$base$foreign_unavailable"$'\nCIM 2000 7777 node.exe 20261001000002000000'
  add_case alternative-windows-path 2000 "$base${mapped/POST LIVE 200 100 84028166 2000/POST TRANSITION 200}"$'\nCIM 7777 1000 bash.exe 20261001000001000000'
  add_case unreadable ERROR "$base${mapped/POST LIVE 200 100 84028166 2000/POST MALFORMED 200}"
  add_case stable-missing-cim ERROR "$base${mapped/CIM 2000 7777 node.exe 20261001000002000000/}"
  add_case unavailable-intermediate ERROR "$base$unavailable"$'\nPS 300 200 100 3000 ? 1 00:03 node\nPRE LIVE 300 200 84028167 3000\nPOST LIVE 300 200 84028167 3000\nCIM 3000 7777 node.exe 20261001000003000000'
  add_case three-behind-unavailable ERROR "$base$unavailable"$'\nCIM 2000 7777 bash.exe 20261001000002000000\nCIM 3000 2000 node.exe 20261001000003000000\nCIM 3001 2000 node.exe 20261001000003000000\nCIM 3002 2000 node.exe 20261001000003000000'
  add_case runner-pre-missing ERROR "${base/PRE LIVE 100 1 84028164 1000/PRE MISSING 100}"
  add_case runner-post-change '' "${base/POST LIVE 100 1 84028164/POST LIVE 100 1 84028165}"
  add_case runner-start-diagnostic '' "$base" 1000 20261001000000000000 84028165
  add_case enum-owner-missing ERROR "${base/POST LIVE 101 100 84028165 1001/POST MISSING 101}"
  add_case enum-owner-start-diagnostic '' "${base/POST LIVE 101 100 84028165 1001/POST LIVE 101 100 84028166 1001}"
  local invalid_book="${base/PS 101 100/PS 101 150}"
  invalid_book="${invalid_book/PRE LIVE 101 100/PRE LIVE 101 150}"
  invalid_book="${invalid_book/POST LIVE 101 100/POST LIVE 101 150}"
  add_case invalid-bookkeeping ERROR "$invalid_book"$'\nPS 150 100 100 3000 ? 1 00:01 bash\nPRE MISSING 150\nPOST MISSING 150\nCIM 3000 1000 node.exe 20261001000002000000'
  add_case microsecond-pin ERROR "$base" 1000 20261001000000000001
  add_case microsecond-duplicate ERROR "$base"$'\nCIM 1000 0 bash.exe 20261001000000000001'
  add_case microsecond-parent '' "$base"$'\nCIM 2000 1000 bash.exe 20261001000002000001\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case malformed-ps ERROR "$base"$'\nPS I 200 100 100 broken ? 1 00:01 bash'
  add_case conflicting-ps ERROR "$base"$'\nPS 100 1 100 2000 ? 1 00:00 bash'
  add_case missing-runner ERROR "${base/PS 100 1 100 1000 ? 1 00:00 bash/}"
  add_case zero-runner ERROR "${base/PS 100 1 100 1000/PS 100 1 100 0}"
  add_case missing-runner-cim ERROR "${base/CIM 1000 0 bash.exe 20261001000000000000/}"
  add_case changed-runner-pid ERROR "$base" 1001
  add_case changed-runner-time ERROR "$base" 1000 20260930235959000000
  add_case missing-timestamp ERROR "${base/CIM 1000 0 bash.exe 20261001000000000000/CIM 1000 0 bash.exe}"
  add_case malformed-timestamp ERROR "${base/20261001000000000000/not-a-time}"
  add_case invalid-utc-date ERROR "${base/20261001000000000000/20260230000000000000}"
  add_case conflicting-cim ERROR "$base"$'\nCIM 1000 0 bash.exe 20261001000001000000'
  add_case three-descendants '3000 3001 3002' "$base"$'\nCIM 3000 1000 node.exe 20261001000001000000\nCIM 3001 3000 node.exe 20261001000002000000\nCIM 3002 3001 node.exe 20261001000003000000'
  # The logical MSYS child predates its logical parent after exec-style remapping.
  # Both remain newer than the runner; applying Windows chronology here loses 3000.
  add_case msys-exec 3000 "$base"$'\nPS 200 100 100 2000 ? 1 00:04 bash\nPS 300 200 100 3000 ? 1 00:02 node\nPRE LIVE 200 100 84028166 2000\nPOST LIVE 200 100 84028166 2000\nPRE LIVE 300 200 84028167 3000\nPOST LIVE 300 200 84028167 3000\nCIM 2000 0 bash.exe 20261001000004000000\nCIM 3000 7777 node.exe 20261001000002000000'
  add_case windows-cycle ERROR "$base"$'\nCIM 2000 2001 bash.exe 20261001000002000000\nCIM 2001 2000 node.exe 20261001000002000000'
  add_case msys-cycle ERROR "$base"$'\nPS 200 201 100 2000 ? 1 00:01 bash\nPS 201 200 100 2001 ? 1 00:01 bash\nPRE LIVE 200 201 84028166 2000\nPOST LIVE 200 201 84028166 2000\nPRE LIVE 201 200 84028167 2001\nPOST LIVE 201 200 84028167 2001\nCIM 2000 0 bash.exe 20261001000001000000\nCIM 2001 0 bash.exe 20261001000001000000'
  # Field-22 drift changes no Windows identity. Retain the diagnostic but certify
  # mapped anchors with both snapshots, including runner + child drifting together.
  local drift="${base/POST LIVE 100 1 84028164/POST LIVE 100 1 84028163}"
  add_case runner-child-drift 2000 "$drift${mapped/POST LIVE 200 100 84028166/POST LIVE 200 100 84028165}"
  local early_base early_mapped changed='ENUM_ERROR:stable MSYS Win32 identity changed during collection'
  early_base="$(printf '%s\n' "$base" | awk '$1 == "CIM" { $1 = "CIM_PRE"; print }')"
  early_mapped="$(printf '%s\n' "$base$mapped" | awk '$1 == "CIM" { $1 = "CIM_PRE"; print }')"
  add_case anchor-birth-change "$changed" "$base$mapped"$'\n'"${early_mapped/20261001000002000000/20261001000002000001}"
  add_case anchor-parent-change "$changed" "$base$mapped"$'\n'"${early_mapped/CIM_PRE 2000 7777/CIM_PRE 2000 7778}"
  add_case anchor-name-change "$changed" "$base$mapped"$'\n'"${early_mapped/CIM_PRE 2000 7777 node.exe/CIM_PRE 2000 7777 bash.exe}"
  add_case runner-birth-change "$changed" "$base"$'\n'"${early_base/20261001000000000000/20261001000000000001}"
  add_case enum-owner-birth-change "$changed" "$base"$'\n'"${early_base/20261001000001000000/20261001000001000001}"
  add_case missing-early-anchor 'ENUM_ERROR:stable MSYS identity absent from early Win32 snapshot' "$base$mapped"$'\n'"$early_base"
  add_case missing-early-self 'ENUM_ERROR:early enumerator absent from Win32 snapshot' "$base"$'\n'"${early_base/CIM_PRE SELF 9000/}"
  # Native-only processes may be born or exit between snapshots. Count exactly the
  # late population, never its union with early rows or its intersection with them.
  add_case late-native-node 3000 "$base"$'\nCIM 3000 1000 node.exe 20261001000002000000\n'"$early_base"
  add_case early-native-node '' "$base"$'\n'"$early_base"$'\nCIM_PRE 3000 1000 node.exe 20261001000002000000'
  add_case population-churn '3001 3002' "$base"$'\nCIM 3001 1000 node.exe 20261001000003000000\nCIM 3002 1000 node.exe 20261001000004000000\n'"$early_base"$'\nCIM_PRE 3000 1000 node.exe 20261001000002000000\nCIM_PRE 3002 1000 node.exe 20261001000004000000'
  # Exec can settle between PS and the early snapshot. Only the bracketed PRE
  # identity may confer ownership; the old PS alias stays uncertain.
  local exec_mapped=$'\nPS 200 100 100 2000 ? 1 00:02 bash\nPRE LIVE 200 100 84028166 2001\nPOST LIVE 200 100 84028166 2001\nCIM 2000 7777 bash.exe 20261001000002000000\nCIM 2001 2000 node.exe 20261001000003000000'
  local exec_early late_only remap_error='ENUM_ERROR:candidate MSYS ancestry continuity unavailable'
  exec_early="$(printf '%s\n' "$base$exec_mapped" | awk '$1 == "CIM" { $1 = "CIM_PRE"; print }')"
  late_only="${exec_early/CIM_PRE 2001 2000 node.exe 20261001000003000000/}"
  add_case exec-remap-native 2001 "$base$exec_mapped"
  add_case exec-remap-msys 2001 "$base${exec_mapped/CIM 2000 7777 bash.exe 20261001000002000000/}"
  add_case exec-remap-intermediate 3000 "$base${exec_mapped/CIM 2001 2000 node.exe/CIM 2001 2000 bash.exe}"$'\nPS 300 200 100 3000 ? 1 00:04 node\nPRE LIVE 300 200 84028167 3000\nPOST LIVE 300 200 84028167 3000\nCIM 3000 8888 node.exe 20261001000004000000'
  add_case exec-remap-alias-node "$remap_error" "$base$exec_mapped"$'\nCIM 3000 2000 node.exe 20261001000004000000'
  add_case exec-remap-late-only "$remap_error" "$base$exec_mapped"$'\n'"$late_only"
  add_case exec-remap-late-shell '' "$base${exec_mapped/CIM 2001 2000 node.exe/CIM 2001 2000 bash.exe}"$'\n'"$late_only"
  add_case exec-remap-runner 'ENUM_ERROR:runner MSYS continuity unavailable' "${base//84028164 1000/84028164 1002}"$'\nCIM 1002 0 bash.exe 20261001000000000000'
  add_case exec-remap-enum-owner 'ENUM_ERROR:enumeration-owner MSYS continuity unavailable' "${base//84028165 1001/84028165 1003}"$'\nCIM 1003 1000 bash.exe 20261001000001000000'
  add_case exec-remap-birth-change "$remap_error" "$base$exec_mapped"$'\n'"${exec_early/CIM_PRE 2001 2000 node.exe 20261001000003000000/CIM_PRE 2001 2000 node.exe 20261001000003000001}"
  add_case exec-remap-parent-change "$remap_error" "$base$exec_mapped"$'\n'"${exec_early/CIM_PRE 2001 2000/CIM_PRE 2001 8888}"
  add_case exec-remap-name-change "$remap_error" "$base$exec_mapped"$'\n'"${exec_early/CIM_PRE 2001 2000 node.exe/CIM_PRE 2001 2000 bash.exe}"
  add_case exec-remap-ps-parent "$remap_error" "$base${exec_mapped/PS 200 100/PS 200 999}"
  local foreign_exec="${exec_mapped/PS 200 100/PS 200 999}"
  foreign_exec="${foreign_exec//LIVE 200 100/LIVE 200 999}"
  add_case exec-remap-foreign '' "$base$foreign_exec"
  local out
  for i in "${!names[@]}"; do
    RUNNER_WINPID="${pins[$i]}"; RUNNER_CREATED="${times[$i]}"
    RUNNER_MSYS_START="${starts[$i]}"
    out="$(printf '%s\n' "${inputs[$i]}" | classify_windows_process_rows 101)"; rc=$?
    got="$(printf '%s\n' "$out" | awk '$1 != "RUNNER" && tolower($2) == "node.exe" { print $1 }' | sort -n | paste -sd ' ' -)"
    if { [ "${expected[$i]}" = ERROR ] && [ "$rc" -ne 0 ] && [[ "$out" == ENUM_ERROR:* ]] && [[ "$out" != *$'\n'* ]]; } \
      || { [[ "${expected[$i]}" == ENUM_ERROR:* ]] && [ "$rc" -ne 0 ] && [ "$out" = "${expected[$i]}" ]; } \
      || { [ "${expected[$i]}" != ERROR ] && [ "$rc" -eq 0 ] && [ "$got" = "${expected[$i]}" ] && [[ "$out" == RUNNER\ * ]]; }; then
      echo "PASS: classifier ${names[$i]}"
    else
      echo "FAIL: classifier ${names[$i]} rc=$rc expected=${expected[$i]} got=$got output=$out"
      failed=$((failed + 1))
    fi
  done
  [ "$failed" -eq 0 ] || return 1
  echo "process classifier/parser: ALL PASS (${#names[@]} ownership, ${#parser_names[@]} parser, ${#endpoint_names[@]} endpoint cases)"
)
[ "$CLEANUP_ONLY" -eq 1 ] || run_classifier_cases || exit 1
[ "$CLASSIFIER_ONLY" -eq 0 ] || exit 0
command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH (required by runner preflight)"; exit 1; }

is_windows() { case "$(uname -s 2>/dev/null)" in *NT*|*MINGW*|*MSYS*|*CYGWIN*) return 0;; *) return 1;; esac; }

# Evidence is intentionally outside WORK and is never removed by fixture cleanup.
if [ "${IPC_GATE_LOG_DIR+x}" = x ]; then
  EVIDENCE="$IPC_GATE_LOG_DIR"
  [ -n "$EVIDENCE" ] && (umask 077; mkdir -- "$EVIDENCE") || exit 1
else
  EVIDENCE="$(mktemp -d)" && [ -n "$EVIDENCE" ] && [ -d "$EVIDENCE" ] || exit 1
fi
echo "retained process-ownership evidence: $EVIDENCE"
WORK="$(mktemp -d)" && [ -n "$WORK" ] && [ -d "$WORK" ] \
  || { echo "FAIL: could not create process-ownership temporary directory" >&2; exit 1; }
SLEEPER_PIDS=()
cleanup() {
  local p
  for p in "${SLEEPER_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  for p in "${SLEEPER_PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILN=0
t_pass() { echo "PASS: $1"; }
t_fail() { echo "FAIL: $1"; FAILN=$((FAILN + 1)); }

# Exercise the actual Windows cleanup body with throwing .NET members. Only its
# process factory is replaced; no real PID lookup, enumeration or kill can occur.
run_cleanup_cases() (
  is_windows || return 0
  local real_ps body factory='[Diagnostics.Process]::GetProcessById(' fake script
  local scenario mode selection key expected rc calls work_win
  real_ps="$(command -v powershell.exe)" && [ -x "$real_ps" ] || return 1
  body="$(awk '
    /^    # IPC_GATE_IDENTITY_CLEANUP / { active=1; found++ }
    active && /^POWERSHELL$/ { active=0; next }
    active { print }
    END { if (found != 1 || active) exit 1 }
  ' "$RUNNER")" || return 1
  [ "$(printf '%s\n' "$body" | grep -Fo "$factory" | wc -l)" -eq 1 ] || return 1
  body="${body/"$factory"/'[IpcFake.Registry]::GetProcessById('}"
  if printf '%s\n' "$body" | grep -Eq 'Diagnostics.Process\]::|Stop-Process|Get-CimInstance|Get-Process|taskkill'; then return 1; fi
  IFS= read -r -d '' fake <<'FAKE' || true
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
namespace IpcFake {
  public static class Registry {
    public static Proc GetProcessById(int pid) {
      if (pid != 4242) throw new ArgumentException("unknown synthetic PID");
      return new Proc();
    }
  }
  public class Proc : IDisposable {
    bool killed;
    string Scenario { get { return Environment.GetEnvironmentVariable("IPC_FAKE_CASE"); } }
    void Log(string value) { File.AppendAllText(Environment.GetEnvironmentVariable("IPC_FAKE_LOG"), value + "\n"); }
    public IntPtr Handle { get {
      if (Scenario == "handle-denied") throw new Win32Exception(5);
      if (Scenario == "handle-exited") throw new InvalidOperationException("Process has exited.");
      if (Scenario == "handle-unknown") throw new Win32Exception(6);
      if (Scenario == "handle-zero") return IntPtr.Zero;
      return new IntPtr(123);
    } }
    public DateTime StartTime { get { return new DateTime(2026,10,1,0,0,0,DateTimeKind.Utc); } }
    public bool HasExited { get {
      if (Scenario.StartsWith("handle-")) {
        Log("UNEXPECTED_PROBE"); throw new InvalidOperationException("Handle acquisition must not reopen by PID.");
      }
      if (killed && Scenario == "probe-error") throw new Win32Exception(6);
      return killed && (Scenario == "exited" || Scenario == "other-error");
    } }
    public void Kill() { Log("KILL"); killed = true; throw new Win32Exception(Scenario == "other-error" ? 6 : 5); }
    public void Dispose() { Log("DISPOSE"); }
  }
}
'@
FAKE
  script="$fake"$'\n'"$body"
  work_win="$(cygpath -w "$WORK")" || return 1
  for selection in exited:kill alive:kill probe-error:kill handle-denied:kill other-error:kill \
    handle-exited:kill handle-unknown:kill handle-zero:kill \
    handle-exited:live handle-denied:live handle-unknown:live handle-zero:live; do
    scenario="${selection%:*}"; mode="${selection#*:}"
    key="$scenario.$mode"
    expected=1
    case "$scenario" in exited|handle-exited) expected=0;; esac
    printf '4242 20261001000000000000\n' \
      | TEMP="$work_win" TMP="$work_win" IPC_GATE_CLEANUP_MODE="$mode" \
        IPC_FAKE_CASE="$scenario" IPC_FAKE_LOG="$work_win\\cleanup-$key.calls" \
        "$real_ps" -NoProfile -NonInteractive -Command "$script" \
        >"$EVIDENCE/cleanup-$key.out" 2>"$EVIDENCE/cleanup-$key.err"
    rc=$?
    cp "$WORK/cleanup-$key.calls" "$EVIDENCE/cleanup-$key.calls" || return 1
    calls="$(tr -d '\r' <"$EVIDENCE/cleanup-$key.calls")"
    case "$scenario" in
      handle-*) [ "$calls" = DISPOSE ] || return 1;;
      *) [ "$calls" = $'KILL\nDISPOSE' ] || return 1;;
    esac
    [ ! -s "$EVIDENCE/cleanup-$key.out" ] || return 1
    if [ "$rc" -eq "$expected" ] && {
      { [ "$expected" -eq 0 ] && [ ! -s "$EVIDENCE/cleanup-$key.err" ]; } ||
      { [ "$expected" -eq 1 ] && grep -q '^Identity cleanup failed:' "$EVIDENCE/cleanup-$key.err"; }
    }; then echo "PASS: identity cleanup $selection"
    else echo "FAIL: identity cleanup $selection rc=$rc expected=$expected"; return 1; fi
  done
)
run_cleanup_cases || exit 1
[ "$CLEANUP_ONLY" -eq 0 ] || exit 0

# Exercise the production capture path with the existing synthetic ownership shapes.
# Only these function-local input providers are replaced; no /proc or runtime is seeded.
run_capture_cases() (
  source "$RUNNER"
  RUNDIR="$EVIDENCE/synthetic"
  mkdir "$RUNDIR" || return 1
  printf '0\n' >"$RUNDIR/enum-next"
  RUNNER_PID=100; RUNNER_WINPID=1000
  RUNNER_CREATED=20261001000000000000; RUNNER_MSYS_START=84028164
  is_windows() { return 0; }
  ps() {
    printf 'PS\n' >>"$RUNDIR/steps"
    printf '100 1 100 1000 ? 1 00:00 bash\n%s 100 100 1001 ? 1 00:01 bash\n200 100 100 2000 ? 1 00:02 bash\n' "$enum_owner_pid"
  }
  powershell.exe() {
    cim_calls=$((cim_calls + 1))
    printf 'CIM\n' >>"$RUNDIR/steps"
    printf 'SELF 9000\n9000 1001 powershell.exe 20261001000009000000\n1000 0 bash.exe 20261001000000000000\n1001 1000 bash.exe 20261001000001000000\n'
    if [ "$capture_case" = late-live-node ]; then
      printf '2000 2999 node.exe 20261001000002000000\n2999 1000 bash.exe 20261001000001500000\n'
    elif [[ "$capture_case" != late-* ]] || [ "$cim_calls" -eq 1 ]; then
      printf '2000 7777 bash.exe 20261001000002000000\n3000 2000 node.exe 20261001000003000000\n'
    fi
  }
  unreadable_msys_endpoint() { printf '%s MISSING %s\n' "$1" "$2"; }
  read_msys_endpoint_value() {
    local target="$1" pid="$2" parent=100 start=84028165 win=1001
    if [ "$pid" -eq 100 ] && [ "$target" = stat1 ]; then
      printf '%s\n' "$phase" >>"$RUNDIR/steps"
    fi
    if [ "$pid" -eq 100 ]; then parent=1; start=84028164; win=1000; fi
    if [ "$pid" -eq 200 ]; then
      start=84028166; win=2000
      if { [ "$capture_case" = late-exit ] || [ "$capture_case" = late-live-node ]; } \
        && [ "$cim_calls" -ge 2 ]; then
        echo 'synthetic endpoint exit after population' >&2; return 1
      fi
      if [ "$capture_case" = continuity ] && [ "$phase" = POST ]; then
        echo 'synthetic original endpoint read failure' >&2; return 1
      fi
      if [ "$capture_case" = malformed ] && [ "$3" = stat ]; then
        printf -v "$target" '%s' 'identical malformed stat'; return 0
      fi
    fi
    if [ "$3" = winpid ]; then printf -v "$target" '%s' "$win"
    else
      local fields=() suffix='S 1 1927 1927 0 -1 0 2551 2551 0 0 31 15 31 15 20 0 0 0 84028164 5758976 1469 1413120'
      read -r -a fields <<<"$suffix"; fields[1]="$parent"; fields[19]="$start"
      printf -v "$target" '%s (node child) %s' "$pid" "${fields[*]}"
    fi
  }
  local capture_case index=0 out rc replay_rc owner raw=() j found expected cim_calls=0 sample
  for capture_case in continuity malformed; do
    ENUM_CONTEXT="synthetic $capture_case"
    cim_calls=0
    : >"$RUNDIR/steps" || return 1
    out="$(owned_process_rows)"; rc=$?
    [ "$(<"$RUNDIR/steps")" = $'PS\nCIM\nPRE\nCIM\nPOST' ] || return 1
    printf '%s\n' "$out" >"$RUNDIR/$capture_case.out"
    [ "$rc" -eq 1 ] || return 1
    expected='candidate MSYS ancestry continuity unavailable'
    [ "$capture_case" != malformed ] || expected='malformed or unreadable MSYS endpoint'
    [ "$out" = "ENUM_ERROR:$expected" ] || return 1
    owner="$(sed -n 's/^enum_owner_pid=//p' "$RUNDIR/enum-$index.meta")"
    classify_windows_process_rows "$owner" <"$RUNDIR/enum-$index.input" >"$RUNDIR/$capture_case.replay"; replay_rc=$?
    [ "$replay_rc" -eq 1 ] && cmp -s "$RUNDIR/$capture_case.out" "$RUNDIR/$capture_case.replay" || return 1
    cmp -s "$RUNDIR/$capture_case.out" "$RUNDIR/enum-$index.output" || return 1
    grep -q '^CLASSIFIER=1$' "$RUNDIR/enum-$index.meta" || return 1
    grep -q '^CIM_PRE=0$' "$RUNDIR/enum-$index.meta" && grep -q '^CIM=0$' "$RUNDIR/enum-$index.meta" || return 1
    mapfile -d '' -t raw <"$RUNDIR/enum-$index.endpoints"
    found=0
    for ((j=0; j<${#raw[@]}; j+=5)); do
      [ "${raw[j]}" = POST ] && [ "${raw[j+1]}" = 200 ] || continue
      if [ "$capture_case" = malformed ] && [[ "${raw[j+2]}" == stat* ]]; then
        [ "${raw[j+3]}" = 0 ] && [ "${raw[j+4]}" = 'identical malformed stat' ] || return 1
        found=$((found + 1))
      elif [ "$capture_case" = continuity ] && [ "${raw[j+2]}" = stat1 ]; then
        [ "${raw[j+3]}" = 1 ] && [ -z "${raw[j+4]}" ] || return 1
        found=2
      fi
    done
    [ "$found" -eq 2 ] || return 1
    echo "PASS: retained $capture_case original input/raw reads replay the same classifier failure"
    index=$((index + 1))
  done
  # The first failed sample remains byte-for-byte available after a second failure.
  cmp -s "$RUNDIR/continuity.out" "$RUNDIR/enum-0.output" || return 1
  grep -q 'synthetic original endpoint read failure' "$RUNDIR/enum-0.endpoint.err" || return 1
  # Deterministic population churn: a confirmed later disappearance is not a live
  # provider omission. Neither case reads /proc or enumerates an actual process.
  for capture_case in late-exit late-omission late-live-node; do
    ENUM_CONTEXT="synthetic $capture_case"; cim_calls=0
    : >"$RUNDIR/steps" || return 1
    out="$(owned_process_rows)"; rc=$?
    sample="$(<"$RUNDIR/enum-next")"
    printf '%s\n' "$out" >"$RUNDIR/$capture_case.out"
    printf '%s\n' "$rc" >"$RUNDIR/$capture_case.rc"
    cp "$RUNDIR/enum-$sample.input" "$RUNDIR/$capture_case.input" || return 1
    cp "$RUNDIR/enum-$sample.meta" "$RUNDIR/$capture_case.meta" || return 1
    cp "$RUNDIR/steps" "$RUNDIR/$capture_case.steps" || return 1
    [ "$(<"$RUNDIR/steps")" = $'PS\nCIM\nPRE\nCIM\nPOST' ] || return 1
    expected='RUNNER 1000 20261001000000000000 84028164'
    if [ "$capture_case" = late-omission ]; then
      expected='ENUM_ERROR:stable MSYS identity absent from Win32 snapshot'
      [ "$rc" -eq 1 ] && [ "$out" = "$expected" ] || return 1
    elif [ "$capture_case" = late-exit ]; then
      [ "$rc" -eq 0 ] && [ "$out" = "$expected" ] || return 1
    else
      expected+=$'\n2000 node.exe 20261001000002000000\n2999 bash.exe 20261001000001500000'
      [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | sort)" = "$(printf '%s\n' "$expected" | sort)" ] || return 1
    fi
    echo "PASS: retained $capture_case population and endpoint classification"
  done
  # A capture write failure crosses count -> owned-node -> owned-rows substitutions.
  RUNDIR="$EVIDENCE/write-failure"; mkdir "$RUNDIR" "$RUNDIR/enum-0.meta" || return 1
  printf '0\n' >"$RUNDIR/enum-next"
  capture_case=healthy
  out="$(count_owned_node)"; rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] || return 1
  echo 'PASS: successful enumeration with failed capture propagates infrastructure status 2'
  # Opening a child log is checked in the parent, before the child's sentinel can run.
  mkdir "$RUNDIR/monitor-1.log" || return 1
  LAYOUT_T0=$SECONDS
  run_monitored 'log-open fixture' "$BASH_BIN" -c ': >"$1"' _ "$RUNDIR/child.called"; rc=$?
  [ "$rc" -eq 2 ] && [ "$INFRA_FAILURE" -eq 1 ] && [ ! -e "$RUNDIR/child.called" ] || return 1
  echo 'PASS: failed child-log open prevents launch and marks infrastructure failure'
  # Preserve the original bytes but make the newly introduced output reread fail.
  # This seam never enumerates or signals a real process and does not delete evidence.
  classify_windows_process_rows() {
    if [ "$original_rc" -eq 0 ]; then printf 'RUNNER 1000 20261001000000000000 84028164\n'
    else printf 'ENUM_ERROR:synthetic original classification failure\n'; fi
    mv -- "$ENUM_FILE.output" "$ENUM_FILE.original" || return 1
    return "$original_rc"
  }
  local original_rc wanted
  for original_rc in 0 1; do
    RUNDIR="$EVIDENCE/read-failure-$original_rc"; mkdir "$RUNDIR" || return 1
    printf '0\n' >"$RUNDIR/enum-next"
    ENUM_CONTEXT="synthetic output read failure after classifier rc=$original_rc"
    out="$(count_owned_node 2>"$RUNDIR/count.err")"; rc=$?
    wanted=2; [ "$original_rc" -eq 0 ] || wanted=1
    printf '%s\n' "$rc" >"$RUNDIR/count.rc"
    [ "$rc" -eq "$wanted" ] && [ -z "$out" ] || return 1
    grep -q 'CAPTURE ERROR: original classifier output unreadable' "$RUNDIR/count.err" || return 1
    grep -q "^CLASSIFIER=$original_rc$" "$RUNDIR/enum-0.meta" || return 1
    [ "$(<"$RUNDIR/enum-0.status")" = "$wanted" ] && [ -s "$RUNDIR/enum-0.original" ] || return 1
    echo "PASS: output read failure propagates rc=$wanted with original classifier rc=$original_rc preserved"
  done
)
run_capture_cases >"$EVIDENCE/capture.out" 2>&1; CAPTURE_RC=$?
printf '%s\n' "$CAPTURE_RC" >"$EVIDENCE/capture.rc"
if [ "$CAPTURE_RC" -eq 0 ]; then t_pass 'original failure replay and capture-error propagation'
else t_fail 'original failure replay or capture-error propagation'; fi
cat "$EVIDENCE/capture.out"
[ "$CAPTURE_ONLY" -eq 0 ] || exit "$CAPTURE_RC"

wait_for_pattern() { # <file> <grep-pattern> <timeout-s>
  local f="$1" pat="$2" t="$3" i=0
  while [ "$i" -lt $((t * 4)) ]; do
    grep -q "$pat" "$f" 2>/dev/null && return 0
    sleep 0.25; i=$((i + 1))
  done
  return 1
}

# ---- sentinel suites (stand-ins for the nine real suites; runner accepts paths) -----------
cat > "$WORK/sentinel_quick.sh" <<'EOF'
#!/usr/bin/env bash
: >"${STARTUP_SENTINEL_FILE:?}"
sleep 2
exit 0
EOF
cat > "$WORK/sentinel_idle12.sh" <<'EOF'
#!/usr/bin/env bash
sleep 12
exit 0
EOF
cat > "$WORK/sentinel_idle8.sh" <<'EOF'
#!/usr/bin/env bash
printf 'outage early stdout\n'
printf 'outage early stderr\n' >&2
for ((i=1; i<=36; i++)); do printf 'outage line %02d\n' "$i"; done
printf '%s\n' "$$" >"${T4_SENTINEL_PIDFILE:?}"
sleep 8
exit 0
EOF
cat > "$WORK/sentinel_nonzero.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ordinary early stdout\n'
printf 'ordinary early stderr\n' >&2
for ((i=1; i<=36; i++)); do printf 'ordinary line %02d\n' "$i"; done
exit 17
EOF
cat > "$WORK/sentinel_spawn3.sh" <<'EOF'
#!/usr/bin/env bash
pids=()
for i in 1 2 3; do
  node -e 'setTimeout(()=>{}, 6000)' &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
exit 0
EOF
chmod +x "$WORK"/sentinel_*.sh

# ---- PATH shims ----------------------------------------------------------------------------
# Shim dir A (safe): no-op Windows cleanup, so mis-scoping cannot kill foreign PIDs.
# Shim dir B (broken): the enumeration entry point always fails.
# Shim dir C (flagged): the enumeration entry point delegates to the real binary until
#                       $SHIM_FAIL_FLAG exists, then fails — simulates a mid-run outage.
# On Windows, C also blocks cleanup while forwarding enumeration.
SHIM_SAFE="$WORK/shim_safe"; SHIM_BROKEN="$WORK/shim_broken"; SHIM_FLAGGED="$WORK/shim_flagged"
mkdir -p "$SHIM_SAFE" "$SHIM_BROKEN" "$SHIM_FLAGGED"

if is_windows; then
  ENUM_BIN="powershell.exe"
  REAL_ENUM="$(command -v powershell.exe 2>/dev/null || true)"
else
  ENUM_BIN="ps"
  REAL_ENUM="$(command -v ps 2>/dev/null || true)"
  # POSIX kill is a shell builtin and cannot be PATH-shimmed; T2/T3/T4 node processes are
  # short-lived and fixture-owned, so a mis-scoping kill can only hit fixture sleepers.
fi
if [ -z "$REAL_ENUM" ] || [ ! -x "$REAL_ENUM" ]; then
  echo "FAIL: process enumeration prerequisite unavailable: $ENUM_BIN did not resolve to an executable via command -v"
  exit 1
fi

if is_windows; then
  cat > "$SHIM_SAFE/$ENUM_BIN" <<EOF
#!/bin/sh
case "\$*" in *IPC_GATE_IDENTITY_CLEANUP*) exit 0;; esac
exec "$REAL_ENUM" "\$@"
EOF
  chmod +x "$SHIM_SAFE/$ENUM_BIN"
fi

printf '#!/bin/sh\necho "shim: enumeration disabled by fixture" >&2\nexit 1\n' > "$SHIM_BROKEN/$ENUM_BIN"
chmod +x "$SHIM_BROKEN/$ENUM_BIN"

cat > "$SHIM_FLAGGED/$ENUM_BIN" <<EOF
#!/bin/sh
case "\$*" in *IPC_GATE_IDENTITY_CLEANUP*) exit 0;; esac
if [ -n "\${SHIM_FAIL_FLAG:-}" ] && [ -e "\$SHIM_FAIL_FLAG" ]; then
  echo "shim: simulated mid-run enumeration outage" >&2
  exit 1
fi
exec "$REAL_ENUM" "\$@"
EOF
chmod +x "$SHIM_FLAGGED/$ENUM_BIN"

# ---- T1: startup fail-closed on broken enumeration ----------------------------------------
echo "== T1: broken enumeration at startup must fail closed =="
T1OUT="$EVIDENCE/t1.out"
PATH="$SHIM_BROKEN:$PATH" IPC_GATE_LOG_DIR="$EVIDENCE/t1-run" STARTUP_SENTINEL_FILE="$WORK/startup.called" \
  "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_quick.sh" >"$T1OUT" 2>&1
T1RC=$?
printf '%s\n' "$T1RC" >"$EVIDENCE/t1.rc"
ERROR_STAGE=ps; ERROR_KEY=PS
is_windows && { ERROR_STAGE=cim-pre; ERROR_KEY=CIM_PRE; }
if [ "$T1RC" -eq 3 ] && grep -q "GATE ERROR" "$T1OUT" && grep -qi "enumerat" "$T1OUT" \
   && ! grep -q 'RELEASE GATES: PASS' "$T1OUT" && [ ! -e "$WORK/startup.called" ] \
   && grep -q 'shim: enumeration disabled by fixture' "$EVIDENCE/t1-run/enum-0.$ERROR_STAGE.err" \
   && grep -q "^${ERROR_KEY}=1$" "$EVIDENCE/t1-run/enum-0.meta" \
   && grep -q '^CLASSIFIER=unattempted$' "$EVIDENCE/t1-run/enum-0.meta"; then
  t_pass "T1 runner failed closed (rc=$T1RC) with explicit enumeration error"
else
  t_fail "T1 expected exit 3, no child/PASS, retained original stderr and partial-stage status; got rc=$T1RC"
  sed 's/^/    T1| /' "$T1OUT"
fi

# ---- T2: sibling (non-descendant) node processes must not count ----------------------------
echo "== T2: unrelated node processes must not count toward the bound =="
T2OUT="$EVIDENCE/t2.out"
: > "$T2OUT"
PATH="$SHIM_SAFE:$PATH" IPC_GATE_LOG_DIR="$EVIDENCE/t2-run" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_idle12.sh" >"$T2OUT" 2>&1 &
T2PID=$!
if wait_for_pattern "$T2OUT" "== running" 90; then
  for i in 1 2 3; do
    node -e 'setTimeout(()=>{}, 8000)' >/dev/null 2>&1 &
    SLEEPER_PIDS+=($!)
  done
else
  echo "  (warn) runner never reached '== running'; T2 will fail on its assertions"
fi
wait "$T2PID"; T2RC=$?
printf '%s\n' "$T2RC" >"$EVIDENCE/t2.rc"
if [ "$T2RC" -eq 0 ] && grep -q "RELEASE GATES: PASS" "$T2OUT"; then
  t_pass "T2 gate PASSed with 3 unrelated node processes alive during the suite"
else
  t_fail "T2 expected PASS (unrelated node must not be counted); got rc=$T2RC"
  sed 's/^/    T2| /' "$T2OUT"
fi

# ---- T3: descendant node processes MUST count (blindness guard) ----------------------------
echo "== T3: suite-spawned node processes must breach the peak bound =="
T3OUT="$EVIDENCE/t3.out"
PATH="$SHIM_SAFE:$PATH" IPC_GATE_LOG_DIR="$EVIDENCE/t3-run" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_spawn3.sh" >"$T3OUT" 2>&1
T3RC=$?
printf '%s\n' "$T3RC" >"$EVIDENCE/t3.rc"
if [ "$T3RC" -eq 1 ] && grep -q "owned-node-peak" "$T3OUT" \
   && ! grep -q 'GATE ERROR' "$T3OUT"; then
  t_pass "T3 gate FAILed on owned peak breach (rc=$T3RC)"
else
  t_fail "T3 expected gate FAIL with 'owned-node-peak' breach; got rc=$T3RC"
  sed 's/^/    T3| /' "$T3OUT"
fi

# ---- T4: mid-suite enumeration outage must abort, never measure 0 --------------------------
echo "== T4: mid-suite enumeration outage must fail closed =="
T4OUT="$EVIDENCE/t4.out"
T4FLAG="$WORK/t4.flag"
T4CHILD_FILE="$WORK/t4-child.pid"
: > "$T4OUT"
PATH="$SHIM_FLAGGED:$PATH" SHIM_FAIL_FLAG="$T4FLAG" T4_SENTINEL_PIDFILE="$T4CHILD_FILE" IPC_GATE_LOG_DIR="$EVIDENCE/t4-run" \
  "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_idle8.sh" >"$T4OUT" 2>&1 &
T4PID=$!
T4_READY=0
T4_INJECTED=0
T4CHILD=""
T4_REAPED=0
if wait_for_pattern "$T4CHILD_FILE" '^[0-9][0-9]*$' 90; then
  T4CHILD="$(tr -d '\r\n' <"$T4CHILD_FILE")"
  [[ "$T4CHILD" =~ ^[1-9][0-9]*$ ]] && kill -0 "$T4CHILD" 2>/dev/null && T4_READY=1
fi
if [ "$T4_READY" -eq 1 ]; then
  if : > "$T4FLAG"; then
    T4_INJECTED=1
  else
    echo "  (warn) failed to create T4 outage flag; readiness=$T4_READY injected=$T4_INJECTED; T4 will fail on its assertions"
  fi
else
  echo "  (warn) named T4 sentinel was not observed alive; T4 will fail on its assertions"
fi
wait "$T4PID"; T4RC=$?
printf '%s\n' "$T4RC" >"$EVIDENCE/t4.rc"
if [ -n "$T4CHILD" ] && ! kill -0 "$T4CHILD" 2>/dev/null \
   && grep -qF "ENUM ABORT: direct suite child $T4CHILD reaped" "$T4OUT"; then
  T4_REAPED=1
fi
{ printf 'outage early stdout\noutage early stderr\n'; for ((i=1; i<=36; i++)); do printf 'outage line %02d\n' "$i"; done; } >"$EVIDENCE/t4.expected"
ERROR_STAGE=ps; ERROR_KEY=PS
if is_windows; then
  ERROR_STAGE=cim; ERROR_KEY=CIM
  if grep -q '^CIM_PRE=1$' "$EVIDENCE/t4-run/enum-0.meta"; then
    ERROR_STAGE=cim-pre; ERROR_KEY=CIM_PRE
  fi
fi
if [ "$T4_READY" -eq 1 ] && [ "$T4_INJECTED" -eq 1 ] && [ "$T4RC" -eq 3 ] \
   && [ "$T4_REAPED" -eq 1 ] \
   && grep -q "GATE ERROR" "$T4OUT" && grep -qi "enumerat" "$T4OUT" \
   && grep -qF "mid-child sample, sentinel_idle8.sh" "$T4OUT" \
   && ! grep -q 'RELEASE GATES: PASS' "$T4OUT" \
   && grep -q "shim: simulated mid-run enumeration outage" "$EVIDENCE/t4-run/enum-0.$ERROR_STAGE.err" \
   && grep -q "^${ERROR_KEY}=1$" "$EVIDENCE/t4-run/enum-0.meta" \
   && grep -q '^CLASSIFIER=unattempted$' "$EVIDENCE/t4-run/enum-0.meta" \
   && cmp -s "$EVIDENCE/t4.expected" "$EVIDENCE/t4-run/monitor-2.log"; then
  t_pass "T4 runner aborted named sentinel (rc=$T4RC), direct child $T4CHILD gone/reaped"
else
  t_fail "T4 expected named-sentinel readiness + outage + direct-child reap + explicit enumeration abort; readiness=$T4_READY injected=$T4_INJECTED reaped=$T4_REAPED child=$T4CHILD rc=$T4RC"
  sed 's/^/    T4| /' "$T4OUT"
fi

# ---- T5: active outer-monitor timeout kills/reaps captured descendants --------------------
echo "== T5: active monitor timeout must force-kill/reap a TERM-resistant descendant =="
T5OUT="$EVIDENCE/t5.out"
T5T0=$SECONDS
IPC_GATE_LOG_DIR="$EVIDENCE/t5-run" "$BASH" "$RUNNER" --self-test-monitor >"$T5OUT" 2>&1
T5RC=$?
printf '%s\n' "$T5RC" >"$EVIDENCE/t5.rc"
T5ELAPSED=$((SECONDS - T5T0))
if [ "$T5RC" -eq 0 ] \
   && [ "$T5ELAPSED" -le 15 ] \
   && grep -q "MONITOR TIMEOUT: self-test hanging child" "$T5OUT" \
   && grep -q "captured descendant(s):" "$T5OUT" \
   && grep -q "descendants killed/reaped" "$T5OUT" \
   && grep -q "SELF-TEST-MONITOR PASS: active timeout; captured descendant killed/reaped; bounded return" "$T5OUT"; then
  t_pass "T5 watchdog timed out actively, killed/reaped captured descendants, and returned in ${T5ELAPSED}s"
else
  t_fail "T5 expected rc=0 + timeout/capture/kill/reap/bounded diagnostics; got rc=$T5RC elapsed=${T5ELAPSED}s"
  sed 's/^/    T5| /' "$T5OUT"
fi

# ---- T6: ordinary nonzero child retains all bytes independently of peak failure -----------
T6OUT="$EVIDENCE/t6.out"
PATH="$SHIM_SAFE:$PATH" IPC_GATE_LOG_DIR="$EVIDENCE/t6-run" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_nonzero.sh" >"$T6OUT" 2>&1
T6RC=$?
printf '%s\n' "$T6RC" >"$EVIDENCE/t6.rc"
{ printf 'ordinary early stdout\nordinary early stderr\n'; for ((i=1; i<=36; i++)); do printf 'ordinary line %02d\n' "$i"; done; } >"$EVIDENCE/t6.expected"
if [ "$T6RC" -eq 1 ] && grep -qF 'sentinel_nonzero.sh: rc=17 child-exit=17' "$T6OUT" \
   && ! grep -Eq 'GATE ERROR|MONITOR TIMEOUT|owned-node-peak|RELEASE GATES: PASS' "$T6OUT" \
   && cmp -s "$EVIDENCE/t6.expected" "$EVIDENCE/t6-run/monitor-2.log"; then
  t_pass 'T6 ordinary exit 17 retained complete combined output after runner EXIT'
else
  t_fail "T6 expected runner exit 1, named child exit 17 and exact complete bytes; got rc=$T6RC"
  sed 's/^/    T6| /' "$T6OUT"
fi

# Reusing a prior evidence directory must fail before enumeration or sentinel launch.
sha256sum "$EVIDENCE/t1-run/"* >"$EVIDENCE/refusal.before"
IPC_GATE_LOG_DIR="$EVIDENCE/t1-run" STARTUP_SENTINEL_FILE="$WORK/refusal.called" \
  "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_quick.sh" >"$EVIDENCE/refusal.out" 2>&1
REFUSAL_RC=$?
printf '%s\n' "$REFUSAL_RC" >"$EVIDENCE/refusal.rc"
sha256sum "$EVIDENCE/t1-run/"* >"$EVIDENCE/refusal.after"
if [ "$REFUSAL_RC" -eq 2 ] && [ ! -e "$WORK/refusal.called" ] \
   && cmp -s "$EVIDENCE/refusal.before" "$EVIDENCE/refusal.after" \
   && ! grep -q '== running' "$EVIDENCE/refusal.out"; then
  t_pass 'existing evidence path refused unchanged before child launch'
else t_fail "existing evidence path was not safely refused (rc=$REFUSAL_RC)"; fi

echo ""
if [ "$FAILN" -eq 0 ]; then
  echo "test_gate_process_ownership: ALL PASS (6 monitor checks + capture checks)"
  exit 0
fi
echo "test_gate_process_ownership: $FAILN checks FAILED"
exit 1
