#!/usr/bin/env bash
# Fixture: owned-Node process-bound trust in tests/run_release_gates.sh (v0.1.7 A0/F2).
#
# The runner's process bound is only meaningful if (a) "owned" node processes are
# attributed by ancestry to THIS runner (not by a global before/after snapshot), and
# (b) an enumeration outage can never be silently measured as "0 owned". This fixture
# pins both properties with five checks:
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
#
# Hermetic: all state under mktemp dirs; every node process spawned here is short-lived
# and reaped on exit; no transport roots, no IPC, no installed-root access. Enumeration
# outages are injected via PATH shims (Windows: powershell.exe; POSIX: ps). On Windows,
# T1-T4 runner invocations additionally get an identity-cleanup no-op shim so a runner that
# mis-scopes foreign PIDs as "owned" cannot kill processes this fixture does not own.
# T5 must use real identity-bound cleanup because killing/reaping its owned descendant is
# the behavior under test.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$TDIR/run_release_gates.sh"
[ -f "$RUNNER" ] || { echo "FAIL: runner not found at $RUNNER"; exit 1; }

# Pure, table-driven checks use the very same classifier as live enumeration. This
# mode exits before temporary files, enumeration, child launch, or any cleanup.
CLASSIFIER_ONLY=0
if [ "${1:-}" = --classifier-only ] && [ "$#" -eq 1 ]; then CLASSIFIER_ONLY=1; fi
run_classifier_cases() (
  source "$RUNNER"
  RUNNER_PID=100
  RUNNER_WINPID=1000
  RUNNER_CREATED=20261001000000000000
  local base=$'PS PID PPID PGID WINPID TTY UID STIME COMMAND\nPS 100 1 100 1000 ? 1 00:00 bash\nCIM SELF 9000\nCIM 9000 1000 powershell.exe 20261001000009000000\nCIM 1000 0 bash.exe 20261001000000000000'
  local names=() expected=() inputs=() pins=() times=() cutoffs=()
  add_case() {
    names+=("$1"); expected+=("$2"); inputs+=("$3")
    pins+=("${4:-1000}"); times+=("${5:-20261001000000000000}")
    cutoffs+=("${6-20261001000008000000}")
  }
  add_case empty-owned '' "$base"
  add_case zero-root '' "$base"$'\nPS 200 100 100 0 ? 1 00:01 <defunct>\nCIM 3000 0 node.exe 20261001000002000000'
  add_case missing-root '' "$base"$'\nPS 200 100 100 2000 ? 1 00:01 bash\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case stale-root ERROR "$base"$'\nPS 200 100 100 2000 ? 1 00:01 bash\nCIM 2000 0 bash.exe 20260930235959000000\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case recycled-parent '' "$base"$'\nCIM 2000 1000 bash.exe 20261001000004000000\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case older-candidate '' "$base"$'\nCIM 3000 1000 node.exe 20260930235959000000'
  add_case status-prefix 3000 "$base"$'\nPS I 200 100 100 2000 ? 1 00:01 bash\nCIM 2000 0 bash.exe 20261001000001000000\nCIM 3000 2000 node.exe 20261001000002000000'
  add_case status-defunct '' "$base"$'\nPS Z 200 100 100 0 ? 1 00:01 <defunct>\nCIM 3000 0 node.exe 20261001000002000000'
  add_case replacement-root ERROR "$base"$'\nPS 200 100 100 2000 ? 1 00:01 bash\nCIM 2000 0 node.exe 20261001000008000001'
  add_case cutoff-equality ERROR "$base"$'\nPS 200 100 100 2000 ? 1 00:01 bash\nCIM 2000 0 node.exe 20261001000008000000'
  add_case defunct-replacement '' "$base"$'\nPS I 200 100 100 2000 ? 1 00:01 <defunct>\nCIM 2000 0 node.exe 20261001000008000001'
  add_case missing-cutoff ERROR "$base" 1000 20261001000000000000 ''
  add_case malformed-cutoff ERROR "$base" 1000 20261001000000000000 not-a-cutoff
  add_case valid-mapped-root 2000 "$base"$'\nPS 200 100 100 2000 ? 1 00:01 node\nCIM 2000 7777 node.exe 20261001000001000000'
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
  add_case msys-exec 3000 "$base"$'\nPS 200 100 100 2000 ? 1 00:04 bash\nPS 300 200 100 3000 ? 1 00:02 node\nCIM 2000 0 bash.exe 20261001000004000000\nCIM 3000 7777 node.exe 20261001000002000000'
  add_case windows-cycle ERROR "$base"$'\nCIM 2000 2001 bash.exe 20261001000002000000\nCIM 2001 2000 node.exe 20261001000002000000'
  add_case msys-cycle ERROR "$base"$'\nPS 200 201 100 2000 ? 1 00:01 bash\nPS 201 200 100 2001 ? 1 00:01 bash'
  local i out rc got failed=0
  for i in "${!names[@]}"; do
    RUNNER_WINPID="${pins[$i]}"; RUNNER_CREATED="${times[$i]}"
    out="$(printf '%s\n' "${inputs[$i]}" | classify_windows_process_rows 0 "${cutoffs[$i]}")"; rc=$?
    got="$(printf '%s\n' "$out" | awk '$1 != "RUNNER" && tolower($2) == "node.exe" { print $1 }' | sort -n | paste -sd ' ' -)"
    if { [ "${expected[$i]}" = ERROR ] && [ "$rc" -ne 0 ] && [[ "$out" == ENUM_ERROR:* ]] && [[ "$out" != *$'\n'* ]]; } \
      || { [ "${expected[$i]}" != ERROR ] && [ "$rc" -eq 0 ] && [ "$got" = "${expected[$i]}" ] && [[ "$out" == RUNNER\ * ]]; }; then
      echo "PASS: classifier ${names[$i]}"
    else
      echo "FAIL: classifier ${names[$i]} rc=$rc expected=${expected[$i]} got=$got output=$out"
      failed=$((failed + 1))
    fi
  done
  [ "$failed" -eq 0 ] || return 1
  echo "process classifier: ALL PASS (${#names[@]} cases)"
)
run_classifier_cases || exit 1
[ "$CLASSIFIER_ONLY" -eq 0 ] || exit 0
command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH (required by runner preflight)"; exit 1; }

is_windows() { case "$(uname -s 2>/dev/null)" in *NT*|*MINGW*|*MSYS*|*CYGWIN*) return 0;; *) return 1;; esac; }

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
printf '%s\n' "$$" >"${T4_SENTINEL_PIDFILE:?}"
sleep 8
exit 0
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
T1OUT="$WORK/t1.out"
PATH="$SHIM_BROKEN:$PATH" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_quick.sh" >"$T1OUT" 2>&1
T1RC=$?
if [ "$T1RC" -ne 0 ] && grep -q "GATE ERROR" "$T1OUT" && grep -qi "enumerat" "$T1OUT"; then
  t_pass "T1 runner failed closed (rc=$T1RC) with explicit enumeration error"
else
  t_fail "T1 expected nonzero rc + explicit 'GATE ERROR ... enumeration' message; got rc=$T1RC"
  sed 's/^/    T1| /' "$T1OUT"
fi

# ---- T2: sibling (non-descendant) node processes must not count ----------------------------
echo "== T2: unrelated node processes must not count toward the bound =="
T2OUT="$WORK/t2.out"
: > "$T2OUT"
PATH="$SHIM_SAFE:$PATH" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_idle12.sh" >"$T2OUT" 2>&1 &
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
if [ "$T2RC" -eq 0 ] && grep -q "RELEASE GATES: PASS" "$T2OUT"; then
  t_pass "T2 gate PASSed with 3 unrelated node processes alive during the suite"
else
  t_fail "T2 expected PASS (unrelated node must not be counted); got rc=$T2RC"
  sed 's/^/    T2| /' "$T2OUT"
fi

# ---- T3: descendant node processes MUST count (blindness guard) ----------------------------
echo "== T3: suite-spawned node processes must breach the peak bound =="
T3OUT="$WORK/t3.out"
PATH="$SHIM_SAFE:$PATH" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_spawn3.sh" >"$T3OUT" 2>&1
T3RC=$?
if [ "$T3RC" -ne 0 ] && grep -q "owned-node-peak" "$T3OUT"; then
  t_pass "T3 gate FAILed on owned peak breach (rc=$T3RC)"
else
  t_fail "T3 expected gate FAIL with 'owned-node-peak' breach; got rc=$T3RC"
  sed 's/^/    T3| /' "$T3OUT"
fi

# ---- T4: mid-suite enumeration outage must abort, never measure 0 --------------------------
echo "== T4: mid-suite enumeration outage must fail closed =="
T4OUT="$WORK/t4.out"
T4FLAG="$WORK/t4.flag"
T4CHILD_FILE="$WORK/t4-child.pid"
: > "$T4OUT"
PATH="$SHIM_FLAGGED:$PATH" SHIM_FAIL_FLAG="$T4FLAG" T4_SENTINEL_PIDFILE="$T4CHILD_FILE" \
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
if [ -n "$T4CHILD" ] && ! kill -0 "$T4CHILD" 2>/dev/null \
   && grep -qF "ENUM ABORT: direct suite child $T4CHILD reaped" "$T4OUT"; then
  T4_REAPED=1
fi
if [ "$T4_READY" -eq 1 ] && [ "$T4_INJECTED" -eq 1 ] && [ "$T4RC" -ne 0 ] \
   && [ "$T4_REAPED" -eq 1 ] \
   && grep -q "GATE ERROR" "$T4OUT" && grep -qi "enumerat" "$T4OUT" \
   && grep -qF "mid-child sample, sentinel_idle8.sh" "$T4OUT" \
   && grep -q "shim: simulated mid-run enumeration outage" "$T4OUT"; then
  t_pass "T4 runner aborted named sentinel (rc=$T4RC), direct child $T4CHILD gone/reaped"
else
  t_fail "T4 expected named-sentinel readiness + outage + direct-child reap + explicit enumeration abort; readiness=$T4_READY injected=$T4_INJECTED reaped=$T4_REAPED child=$T4CHILD rc=$T4RC"
  sed 's/^/    T4| /' "$T4OUT"
fi

# ---- T5: active outer-monitor timeout kills/reaps captured descendants --------------------
echo "== T5: active monitor timeout must force-kill/reap a TERM-resistant descendant =="
T5OUT="$WORK/t5.out"
T5T0=$SECONDS
"$BASH" "$RUNNER" --self-test-monitor >"$T5OUT" 2>&1
T5RC=$?
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

echo ""
if [ "$FAILN" -eq 0 ]; then
  echo "test_gate_process_ownership: ALL PASS (5 checks)"
  exit 0
fi
echo "test_gate_process_ownership: $FAILN of 5 checks FAILED"
exit 1
