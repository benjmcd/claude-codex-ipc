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
#       the runner must abort nonzero instead of degrading to a silent 0-measurement.
#   T5  active monitor timeout: the exclusive runner self-test captures, kills, and reaps
#       a descendant, emits named diagnostics, and returns within its bound.
#
# Hermetic: all state under mktemp dirs; every node process spawned here is short-lived
# and reaped on exit; no transport roots, no IPC, no installed-root access. Enumeration
# outages are injected via PATH shims (Windows: powershell.exe; POSIX: ps). On Windows,
# every runner invocation additionally gets a no-op taskkill shim so a runner that
# mis-scopes foreign PIDs as "owned" cannot kill processes this fixture does not own.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$TDIR/run_release_gates.sh"
[ -f "$RUNNER" ] || { echo "FAIL: runner not found at $RUNNER"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH (required by runner preflight)"; exit 1; }

is_windows() { case "$(uname -s 2>/dev/null)" in *NT*|*MINGW*|*MSYS*|*CYGWIN*) return 0;; *) return 1;; esac; }

WORK="$(mktemp -d)"
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
# Shim dir A (safe): no-op taskkill only, so a mis-scoping runner cannot kill foreign PIDs.
# Shim dir B (broken): the enumeration entry point always fails.
# Shim dir C (flagged): the enumeration entry point delegates to the real binary until
#                       $SHIM_FAIL_FLAG exists, then fails — simulates a mid-run outage.
# On Windows, B and C also carry the no-op taskkill copy.
SHIM_SAFE="$WORK/shim_safe"; SHIM_BROKEN="$WORK/shim_broken"; SHIM_FLAGGED="$WORK/shim_flagged"
mkdir -p "$SHIM_SAFE" "$SHIM_BROKEN" "$SHIM_FLAGGED"

if is_windows; then
  ENUM_BIN="powershell.exe"
  REAL_ENUM="$(command -v powershell.exe)"
  printf '#!/bin/sh\nexit 0\n' > "$SHIM_SAFE/taskkill"
  chmod +x "$SHIM_SAFE/taskkill"
  cp "$SHIM_SAFE/taskkill" "$SHIM_BROKEN/taskkill"
  cp "$SHIM_SAFE/taskkill" "$SHIM_FLAGGED/taskkill"
else
  ENUM_BIN="ps"
  REAL_ENUM="$(command -v ps)"
  # POSIX kill is a shell builtin and cannot be PATH-shimmed; T2/T3/T4 node processes are
  # short-lived and fixture-owned, so a mis-scoping kill can only hit fixture sleepers.
fi

printf '#!/bin/sh\necho "shim: enumeration disabled by fixture" >&2\nexit 1\n' > "$SHIM_BROKEN/$ENUM_BIN"
chmod +x "$SHIM_BROKEN/$ENUM_BIN"

cat > "$SHIM_FLAGGED/$ENUM_BIN" <<EOF
#!/bin/sh
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
if [ "$T3RC" -ne 0 ] && grep -q "owned real-Node peak" "$T3OUT"; then
  t_pass "T3 gate FAILed on owned peak breach (rc=$T3RC)"
else
  t_fail "T3 expected gate FAIL with 'owned real-Node peak' breach; got rc=$T3RC"
  sed 's/^/    T3| /' "$T3OUT"
fi

# ---- T4: mid-suite enumeration outage must abort, never measure 0 --------------------------
echo "== T4: mid-suite enumeration outage must fail closed =="
T4OUT="$WORK/t4.out"
T4FLAG="$WORK/t4.flag"
rm -f "$T4FLAG"
: > "$T4OUT"
PATH="$SHIM_FLAGGED:$PATH" SHIM_FAIL_FLAG="$T4FLAG" "$BASH" "$RUNNER" --no-safety "$WORK/sentinel_idle8.sh" >"$T4OUT" 2>&1 &
T4PID=$!
if wait_for_pattern "$T4OUT" "== running" 90; then
  sleep 1
  : > "$T4FLAG"
else
  echo "  (warn) runner never reached '== running'; T4 will fail on its assertions"
fi
wait "$T4PID"; T4RC=$?
if [ "$T4RC" -ne 0 ] && grep -q "GATE ERROR" "$T4OUT" && grep -qi "enumerat" "$T4OUT"; then
  t_pass "T4 runner aborted mid-suite (rc=$T4RC) with explicit enumeration error"
else
  t_fail "T4 expected nonzero rc + explicit 'GATE ERROR ... enumeration' abort; got rc=$T4RC"
  sed 's/^/    T4| /' "$T4OUT"
fi

# ---- T5: active outer-monitor timeout kills/reaps captured descendants --------------------
echo "== T5: active monitor timeout must kill/reap captured descendants =="
T5OUT="$WORK/t5.out"
T5T0=$SECONDS
PATH="$SHIM_SAFE:$PATH" "$BASH" "$RUNNER" --self-test-monitor >"$T5OUT" 2>&1
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
