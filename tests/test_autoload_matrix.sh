#!/usr/bin/env bash
# Hermetic behavioral matrix for codex_ipc_autoload.ps1 host-identity gating.
# Runs the REAL PowerShell script under -DryRun with mocked foreground identity
# (-MockForegroundProcess / -MockForegroundPath); never fires codex://, never
# touches focus. Windows-only by nature: skips cleanly when powershell.exe is
# absent (e.g. the ubuntu CI leg).
#
# Identity matrix under test (2026-07-09 ChatGPT/Codex host merge):
#   legacy GUI  : process 'Codex'  (any path)                      -> Codex-certain
#   merged GUI  : process 'ChatGPT' + path under WindowsApps\OpenAI.Codex_* -> Codex-certain
#   other-ChatGPT: process 'ChatGPT' + readable non-Codex path     -> known non-Codex
#   ambiguous   : process 'ChatGPT' + unreadable/empty path        -> gate (defer), fail closed
#   unknown     : process 'unknown' / unidentifiable               -> gate (defer), fail closed
# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill
# layout (tests/ inside the skill root, scripts/ as sibling).
set -u

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1SCRIPT=""
POLICYSCRIPT=""
for _cand in "$TDIR/../skills/ipc/scripts/codex_ipc_autoload.ps1" "$TDIR/../scripts/codex_ipc_autoload.ps1"; do
    [[ -f "$_cand" ]] && PS1SCRIPT="$_cand" && break
done
[[ -n "$PS1SCRIPT" ]] || { echo "FATAL: codex_ipc_autoload.ps1 not found in repo or installed layout" >&2; exit 1; }
for _cand in "$TDIR/../skills/ipc/scripts/codex_ipc_host_policy.ps1" "$TDIR/../scripts/codex_ipc_host_policy.ps1"; do
    [[ -f "$_cand" ]] && POLICYSCRIPT="$_cand" && break
done
[[ -n "$POLICYSCRIPT" ]] || { echo "FATAL: codex_ipc_host_policy.ps1 not found in repo or installed layout" >&2; exit 1; }

if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "SKIP: powershell.exe not available (helper is Windows-only); matrix not applicable on this host"
    exit 0
fi

# Windows path for -File (powershell.exe does not grok /c/... MSYS paths).
if command -v cygpath >/dev/null 2>&1; then
    PS1WIN="$(cygpath -w "$PS1SCRIPT")"
    POLICYWIN="$(cygpath -w "$POLICYSCRIPT")"
else
    PS1WIN="$PS1SCRIPT"
    POLICYWIN="$POLICYSCRIPT"
fi

UUID="00000000-0000-4000-8000-000000000000"
CODEX_PATH='C:\Program Files\WindowsApps\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
CLASSIC_PATH='C:\Program Files\WindowsApps\OpenAI.ChatGPT-Desktop_1.2026.100.0_x64__9x9x9x9x9x9x9\app\ChatGPT.exe'

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

POLICY_ROOT="$(mktemp -d)" && [[ -n "$POLICY_ROOT" && -d "$POLICY_ROOT" ]] \
    || { echo "FATAL: could not create policy fixture root" >&2; exit 1; }
trap 'rm -rf "$POLICY_ROOT"' EXIT

echo "== P. shared policy defaults =="
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
if [[ $POLICY_RC -eq 0 ]] && printf '%s' "$POLICY_OUT" | node -e '
let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { text += chunk; });
process.stdin.on("end", () => {
  try {
    const value = JSON.parse(text);
    const exact = value?.schemaVersion === 1 && value?.ok === true &&
      value?.purpose === "configuration" &&
      value?.configuration?.autoload?.value === "off" &&
      value?.configuration?.autoload?.source === "default" &&
      value?.configuration?.intendedHost?.kind === "package" &&
      value?.configuration?.intendedHost?.source === "default";
    process.exit(exact ? 0 : 1);
  } catch { process.exit(1); }
});
'; then
    ok "default configuration is autoload off with package intended host"
else
    no "default shared policy configuration (rc=$POLICY_RC; out: $(printf '%s' "$POLICY_OUT" | head -c 300))"
fi

# assert_policy <expected-rc> <label> <node predicate>
# The predicate receives the parsed report as `value` and must evaluate truthy.
assert_policy(){
    local want_rc="$1" label="$2" predicate="$3"
    if [[ $POLICY_RC -eq $want_rc ]] && POLICY_PREDICATE="$predicate" printf '%s' "$POLICY_OUT" | \
      POLICY_PREDICATE="$predicate" node -e '
let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { text += chunk; });
process.stdin.on("end", () => {
  try {
    const value = JSON.parse(text);
    const predicate = new Function("value", `return Boolean(${process.env.POLICY_PREDICATE});`);
    process.exit(predicate(value) ? 0 : 1);
  } catch { process.exit(1); }
});
'; then
        ok "$label"
    else
        no "$label (rc=$POLICY_RC want=$want_rc; out: $(printf '%s' "$POLICY_OUT" | head -c 300))"
    fi
}

echo "== Q. shared policy configuration resolution =="
cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"codex-uri"}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q1 partial descriptor uses per-field default" '
  value.ok === true && value.configuration.valid === true &&
  value.configuration.autoload.value === "codex-uri" &&
  value.configuration.autoload.source === "descriptor" &&
  value.configuration.intendedHost.kind === "package" &&
  value.configuration.intendedHost.source === "default" &&
  value.configuration.descriptor.status === "loaded"'

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"off","intendedHost":{"kind":"alternate","executable":"C:\\Alt\\Host\\ChatGPT.exe"}}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q2 alternate descriptor is accepted" '
  value.ok === true && value.configuration.intendedHost.kind === "alternate" &&
  value.configuration.intendedHost.executable === "C:\\Alt\\Host\\ChatGPT.exe" &&
  value.configuration.intendedHost.source === "descriptor"'

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"off","intendedHost":{"kind":"package"}}
JSON
POLICY_OUT="$(CODEX_IPC_AUTOLOAD=codex-uri CODEX_IPC_INTENDED_HOST='C:\Env\Host.exe' \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q3 environment overrides descriptor per field" '
  value.configuration.autoload.value === "codex-uri" &&
  value.configuration.autoload.source === "environment" &&
  value.configuration.intendedHost.kind === "alternate" &&
  value.configuration.intendedHost.executable === "C:\\Env\\Host.exe" &&
  value.configuration.intendedHost.source === "environment"'

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=codex-uri CODEX_IPC_INTENDED_HOST='C:\Env\Host.exe' \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" \
    -Autoload off -IntendedHost 'C:\Flag\Host.exe' 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q4 flags override environment per field" '
  value.configuration.autoload.value === "off" &&
  value.configuration.autoload.source === "flag" &&
  value.configuration.intendedHost.kind === "alternate" &&
  value.configuration.intendedHost.executable === "C:\\Flag\\Host.exe" &&
  value.configuration.intendedHost.source === "flag"'

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=off CODEX_IPC_INTENDED_HOST=package \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" \
    -Autoload codex-uri 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q5 precedence is independent for each field" '
  value.configuration.autoload.value === "codex-uri" &&
  value.configuration.autoload.source === "flag" &&
  value.configuration.intendedHost.kind === "package" &&
  value.configuration.intendedHost.source === "environment"'

policy_must_refuse(){
    local label="$1" token="$2"
    assert_policy 1 "$label" \
      "value.ok === false && value.error.reason === \"host-policy-invalid\" && value.error.message.includes(\"$token\")"
}

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" -Autoload off 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q6 malformed descriptor refuses despite flag" "descriptor"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":2}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q7 unsupported descriptor schema refuses" "schemaVersion"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"surprise":true}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q8 unknown descriptor key refuses" "unknown key"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"sometimes"}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q9 malformed descriptor autoload refuses" "autoload"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"intendedHost":{"kind":"alternate"}}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q10 alternate descriptor requires executable" "executable"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"intendedHost":{"kind":"package","executable":"C:\\Wrong.exe"}}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q11 package descriptor rejects executable override" "executable"

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1}
JSON
POLICY_OUT="$(CODEX_IPC_AUTOLOAD=invalid CODEX_IPC_INTENDED_HOST=package \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" -Autoload off 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q12 malformed lower-priority environment refuses" "CODEX_IPC_AUTOLOAD"

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=off CODEX_IPC_INTENDED_HOST=relative.exe \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q13 relative intended host refuses" "absolute"

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=off CODEX_IPC_INTENDED_HOST='C:relative.exe' \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q14 drive-relative intended host refuses" "absolute"

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=off CODEX_IPC_INTENDED_HOST='\root-relative.exe' \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q15 root-relative intended host refuses" "absolute"

POLICY_OUT="$(CODEX_IPC_AUTOLOAD=off CODEX_IPC_INTENDED_HOST='C:/Alt/Host/ChatGPT.exe' \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q16 intended host path is normalized before comparison" '
  value.configuration.intendedHost.kind === "alternate" &&
  value.configuration.intendedHost.executable === "C:\\Alt\\Host\\ChatGPT.exe"'

cat > "$POLICY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"intendedHost":{"kind":"alternate","executable":"C:\\Alt\\Höst\\ChatGPT.exe"}}
JSON
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "Q17 UTF-8 descriptor content is preserved" '
  value.configuration.intendedHost.executable === "C:\\Alt\\Höst\\ChatGPT.exe"'

rm -f "$POLICY_ROOT/host-policy.json"
mkdir "$POLICY_ROOT/host-policy.json"
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot "$POLICY_ROOT" 2>&1)"; POLICY_RC=$?
policy_must_refuse "Q18 unreadable descriptor refuses" "descriptor"
rmdir "$POLICY_ROOT/host-policy.json"

echo "== R. shared policy send inventory =="
MOCK_PACKAGE='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":101,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe"},{"pid":102,"parentPid":101,"name":"codex.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\resources\\codex.exe"},{"pid":103,"parentPid":1,"name":"notepad.exe","executable":"C:\\Windows\\notepad.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_PACKAGE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R1 package-only inventory is send eligible" '
  value.ok === true && value.purpose === "send" && value.sendEligible === true &&
  value.inventory.complete === true && value.inventory.coverage === "mock" &&
  value.inventory.guiHosts.length === 1 && value.inventory.guiHosts[0].classification === "package" &&
  value.inventory.guiHosts[0].matchesIntended === true &&
  value.inventory.appServers.length === 1 && value.inventory.appServers[0].pid === 102 &&
  value.activationEligible === false'

MOCK_ALTERNATE='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":201,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_ALTERNATE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R2 declared alternate inventory is send eligible" '
  value.sendEligible === true && value.configuration.intendedHost.kind === "alternate" &&
  value.inventory.guiHosts.length === 1 && value.inventory.guiHosts[0].classification === "alternate" &&
  value.inventory.guiHosts[0].matchesIntended === true'

MOCK_OTHER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":301,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.ChatGPT-Desktop_1.2026.100.0_x64__9x9x9x9x9x9x9\\app\\ChatGPT.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_OTHER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R3 undeclared GUI refuses send" '
  value.sendEligible === false && value.sendReasons.includes("other-desktop-host-running") &&
  value.sendReasons.includes("intended-host-not-running") &&
  value.inventory.guiHosts[0].classification === "other"'

MOCK_MIXED='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":401,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe"},{"pid":402,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_MIXED" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R4 mixed GUI identities refuse send" '
  value.sendEligible === false && value.sendReasons.includes("other-desktop-host-running") &&
  value.inventory.guiHosts.length === 2'

MOCK_UNKNOWN='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":501,"parentPid":1,"name":"ChatGPT.exe","executable":null}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_UNKNOWN" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R5 unreadable candidate identity makes inventory incomplete" '
  value.sendEligible === false && value.inventory.complete === false &&
  value.sendReasons.includes("host-inventory-incomplete") &&
  value.inventory.guiHosts[0].classification === "unknown"'

MOCK_FAILED='{"complete":false,"packageRootsComplete":false,"packageRoots":[],"errors":["access-denied"],"processes":[]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_FAILED" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R6 failed enumeration refuses send" '
  value.sendEligible === false && value.inventory.complete === false &&
  value.inventory.errors.includes("access-denied") &&
  value.sendReasons.includes("host-inventory-incomplete")'

MOCK_EMPTY='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_EMPTY" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R7 empty complete inventory reports intended host absent" '
  value.sendEligible === false && value.inventory.complete === true &&
  value.sendReasons.length === 1 && value.sendReasons[0] === "intended-host-not-running"'

MOCK_DUPLICATE='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":601,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe"},{"pid":602,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_DUPLICATE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R8 multiple intended GUI mains refuse ambiguous cardinality" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.sendReasons.includes("other-desktop-host-running")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -MockInventoryJson "$MOCK_PACKAGE" 2>&1)"; POLICY_RC=$?
policy_must_refuse "R9 mock inventory is rejected without DryRun" "DryRun"

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson '{bad-json' 2>&1)"; POLICY_RC=$?
policy_must_refuse "R10 malformed mock inventory refuses" "inventory"

MOCK_ORPHAN_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":701,"parentPid":1,"name":"codex.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\resources\\codex.exe","commandLine":"codex.exe app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_ORPHAN_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R11 orphan app server cannot stand in for a GUI host" '
  value.sendEligible === false && value.inventory.guiHosts.length === 0 &&
  value.inventory.appServers.length === 1 &&
  value.sendReasons.includes("intended-host-not-running")'

MOCK_NESTED_ALTERNATE='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":711,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":712,"parentPid":711,"name":"ChatGPT.exe","executable":"C:\\Alt\\Nested\\ChatGPT.exe","commandLine":"ChatGPT.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_NESTED_ALTERNATE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R12 parentage cannot hide a nested second GUI identity" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_RENDERER_CHILD='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":721,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":722,"parentPid":721,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe","commandLine":"ChatGPT.exe --type=renderer"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_RENDERER_CHILD" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R13 proven Electron child is not counted as a second GUI" '
  value.sendEligible === true && value.inventory.guiHosts.length === 1 &&
  value.inventory.appServers.length === 1'

MOCK_UNKNOWN_CHILD_ROLE='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":731,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":732,"parentPid":731,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\ChatGPT.exe","commandLine":null}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_UNKNOWN_CHILD_ROLE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R14 unreadable same-executable child role fails inventory closed" '
  value.sendEligible === false && value.inventory.complete === false &&
  value.sendReasons.includes("host-inventory-incomplete")'

MOCK_RENAMED_PACKAGE='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0"],"errors":[],"processes":[{"pid":741,"parentPid":1,"name":"RenamedDesktop.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\RenamedDesktop.exe","commandLine":"RenamedDesktop.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_RENAMED_PACKAGE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R15 package-root identity catches a renamed GUI executable" '
  value.sendEligible === true && value.inventory.complete === true &&
  value.inventory.guiHosts.length === 1 &&
  value.inventory.guiHosts[0].classification === "package" &&
  value.inventory.guiHosts[0].matchesIntended === true'

MOCK_RENAMED_UNQUALIFIED='{"complete":true,"packageRootsComplete":false,"packageRoots":[],"errors":["package-enumeration:denied"],"processes":[{"pid":751,"parentPid":1,"name":"RenamedDesktop.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\\app\\RenamedDesktop.exe","commandLine":"RenamedDesktop.exe"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun -MockInventoryJson "$MOCK_RENAMED_UNQUALIFIED" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R16 unresolved package-root identity fails inventory closed" '
  value.sendEligible === false && value.inventory.complete === false &&
  value.inventory.guiHosts.length === 1 &&
  value.inventory.guiHosts[0].classification === "unknown" &&
  value.sendReasons.includes("host-inventory-incomplete")'

MOCK_ALT_BASENAME_AMBIGUOUS='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":761,"parentPid":1,"name":"Host.exe","executable":"C:\\Alt\\Host.exe","commandLine":"Host.exe"},{"pid":762,"parentPid":1,"name":"Host.exe","executable":null,"commandLine":null}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host.exe' \
    -DryRun -MockInventoryJson "$MOCK_ALT_BASENAME_AMBIGUOUS" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R17 unreadable same-name alternate candidate fails inventory closed" '
  value.sendEligible === false && value.inventory.complete === false &&
  value.inventory.guiHosts.length === 2 &&
  value.inventory.guiHosts.some((item) => item.pid === 762 && item.classification === "unknown") &&
  value.sendReasons.includes("host-inventory-incomplete")'

echo "== S. shared policy activation decision =="
PKG_CLEAR='{"state":"clear","runningPackageFullName":"OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0","runningVersion":"26.707.3563.0","higherVersions":[],"evidence":"mock"}'
PKG_STAGED='{"state":"staged","runningPackageFullName":"OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0","runningVersion":"26.707.3563.0","higherVersions":["26.708.100.0"],"evidence":"mock"}'
PKG_UNKNOWN='{"state":"unknown","runningPackageFullName":null,"runningVersion":null,"higherVersions":[],"evidence":"mock"}'
REG_MATCHES='{"state":"matches","handler":"AppXcodex","packageFullName":"OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0","evidence":"mock"}'
REG_CONFLICT='{"state":"conflicting","handler":"Other.Handler","packageFullName":"OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0","evidence":"mock"}'
REG_UNKNOWN='{"state":"unknown","handler":null,"packageFullName":null,"evidence":"mock"}'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S1 package host with proven handler and clear staging is activation eligible" '
  value.sendEligible === true && value.activationEligible === true &&
  value.activationReasons.length === 0 && value.packageState.state === "clear" &&
  value.registration.state === "matches"'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload off -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S2 autoload off refuses activation without changing send eligibility" '
  value.sendEligible === true && value.activationEligible === false &&
  value.activationReasons.includes("autoload-disabled")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri \
    -IntendedHost 'C:\Alt\Host\ChatGPT.exe' -DryRun \
    -MockInventoryJson "$MOCK_ALTERNATE" -MockPackageJson "$PKG_UNKNOWN" \
    -MockRegistrationJson "$REG_UNKNOWN" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S3 alternate intended host is never protocol activated" '
  value.sendEligible === true && value.activationEligible === false &&
  value.activationReasons.includes("protocol-host-not-package")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_STAGED" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S4 staged update refuses activation" '
  value.activationEligible === false && value.activationReasons.includes("package-update-staged")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_UNKNOWN" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S5 unknown staged state refuses activation" '
  value.activationEligible === false && value.activationReasons.includes("package-update-unknown")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_CONFLICT" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S6 conflicting protocol handler refuses activation" '
  value.activationEligible === false && value.activationReasons.includes("protocol-registration-unproven") &&
  value.registration.state === "conflicting"'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_UNKNOWN" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S7 unknown protocol handler refuses activation" '
  value.activationEligible === false && value.activationReasons.includes("protocol-registration-unproven") &&
  value.registration.state === "unknown"'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_OTHER" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
assert_policy 0 "S8 send refusal also refuses activation" '
  value.sendEligible === false && value.activationEligible === false &&
  value.activationReasons.includes("send-ineligible")'

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
policy_must_refuse "S9 activation mocks are rejected without DryRun" "DryRun"

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose activation -IpcRoot "$POLICY_ROOT" -Autoload codex-uri -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson '{bad-json' \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; POLICY_RC=$?
policy_must_refuse "S10 malformed activation mock refuses" "package"

echo "== T. production activation evidence readers fail closed =="
EVIDENCE_PS1="$POLICY_ROOT/evidence-readers.ps1"
cat > "$EVIDENCE_PS1" <<'POWERSHELL'
param([Parameter(Mandatory = $true)][string]$PolicyPath)

. $PolicyPath
$ErrorActionPreference = 'Stop'
$script:PackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0'
$script:PackageFullName = 'OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0'
$script:Package = [pscustomobject]@{
    Name = 'OpenAI.Codex'
    PackageFullName = $script:PackageFullName
    PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
    Version = [version]'26.707.3563.0'
    InstallLocation = $script:PackageRoot
}
$script:Events = @()
$script:UserChoice = 'absent'
$script:Delegate = '{A56A841F-E974-45C1-8001-7E3F8A085917}'
$script:AppUserModelId = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$script:Handler = 'AppXfixture'

function Get-AppxPackage {
    param([string]$Name, [object]$ErrorAction)
    return $script:Package
}
function Get-WinEvent {
    param([hashtable]$FilterHashtable, [int]$MaxEvents, [object]$ErrorAction)
    return @($script:Events)
}
function Test-Path {
    param([string]$LiteralPath, [object]$ErrorAction)
    if ($LiteralPath -like '*\UrlAssociations\codex\UserChoice') {
        return $script:UserChoice -ne 'absent'
    }
    return $false
}
function Get-ItemProperty {
    param([string]$LiteralPath, [object]$ErrorAction)
    if ($LiteralPath -like '*\Capabilities\URLAssociations') {
        return [pscustomobject]@{ codex = $script:Handler }
    }
    if ($LiteralPath -like '*\UrlAssociations\codex\UserChoice') {
        $progId = if ($script:UserChoice -eq 'match') { $script:Handler } else { 'Other.Handler' }
        return [pscustomobject]@{ ProgId = $progId }
    }
    if ($LiteralPath -like '*\Shell\open\command') {
        return [pscustomobject]@{ DelegateExecute = $script:Delegate }
    }
    if ($LiteralPath -like '*\Shell\open') {
        return [pscustomobject]@{
            PackageId = $script:PackageFullName
            ContractId = 'Windows.Protocol'
            PackageRelativeExecutable = 'app\ChatGPT.exe'
            AppUserModelID = $script:AppUserModelId
        }
    }
    throw "unexpected registry read: $LiteralPath"
}
function New-FixtureEvent {
    param([int]$Minute, [string]$Operation, [string]$FullName)
    return [pscustomobject]@{
        TimeCreated = ([datetime]'2026-01-01T00:00:00Z').AddMinutes($Minute)
        Message = "Deployment $Operation operation Package $FullName"
    }
}
function Read-PackageState {
    param([string]$GuiExecutable)
    $inventory = [pscustomobject]@{
        guiHosts = @([pscustomobject]@{
            matchesIntended = $true
            executable = $GuiExecutable
        })
    }
    return Get-CodexIpcPackageState -Inventory $inventory
}

$expectedGui = Join-Path $script:PackageRoot 'app\ChatGPT.exe'
$currentRegister = New-FixtureEvent 1 'Register' $script:PackageFullName
$higherFullName = 'OpenAI.Codex_26.708.100.0_x64__2p2nqsd0c76g0'
$higherStage = New-FixtureEvent 2 'Stage' $higherFullName

$script:Events = @()
$empty = Read-PackageState $expectedGui
$script:Events = @($currentRegister)
$currentOnly = Read-PackageState $expectedGui
$script:Events = @($higherStage, $currentRegister)
$staged = Read-PackageState $expectedGui
$script:Events = @($currentRegister)
$wrongExecutable = Read-PackageState (Join-Path $script:PackageRoot 'other\ChatGPT.exe')

$packageState = [pscustomobject]@{
    state = 'clear'
    runningPackageFullName = $script:PackageFullName
}
$script:UserChoice = 'absent'
$candidateOnly = Get-CodexIpcProtocolRegistration -PackageState $packageState
$script:UserChoice = 'match'
$script:Delegate = 'NOT-A-CLSID'
$invalidDelegate = Get-CodexIpcProtocolRegistration -PackageState $packageState
$script:Delegate = '{A56A841F-E974-45C1-8001-7E3F8A085917}'
$script:UserChoice = 'conflict'
$conflictingChoice = Get-CodexIpcProtocolRegistration -PackageState $packageState

[pscustomobject][ordered]@{
    empty = $empty.state
    currentOnly = $currentOnly.state
    staged = $staged.state
    wrongExecutable = $wrongExecutable.state
    candidateOnly = $candidateOnly.state
    invalidDelegate = $invalidDelegate.state
    conflictingChoice = $conflictingChoice.state
} | ConvertTo-Json -Compress
POWERSHELL
if command -v cygpath >/dev/null 2>&1; then
    EVIDENCEWIN="$(cygpath -w "$EVIDENCE_PS1")"
else
    EVIDENCEWIN="$EVIDENCE_PS1"
fi
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$EVIDENCEWIN" \
    -PolicyPath "$POLICYWIN" 2>&1)"; POLICY_RC=$?
assert_policy 0 "T1 production readers never promote incomplete evidence" '
  value.empty === "unknown" && value.currentOnly === "unknown" &&
  value.staged === "staged" && value.wrongExecutable === "unknown" &&
  value.candidateOnly === "unknown" && value.invalidDelegate !== "matches" &&
  value.conflictingChoice === "conflicting"'

# run <expected-rc> <expected-token> <label> -- <ps args...>
run(){
    local want_rc="$1" want_tok="$2" label="$3"; shift 3; [[ "$1" == "--" ]] && shift
    local out rc
    local inventory="${RUN_MOCK_INVENTORY:-$MOCK_PACKAGE}"
    local package_state="${RUN_MOCK_PACKAGE:-$PKG_CLEAR}"
    local registration="${RUN_MOCK_REGISTRATION:-$REG_MATCHES}"
    local autoload="${RUN_AUTOLOAD:-codex-uri}"
    out="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1WIN" "$@" \
        -IpcRoot "$POLICY_ROOT" -Autoload "$autoload" \
        -MockInventoryJson "$inventory" -MockPackageJson "$package_state" \
        -MockRegistrationJson "$registration" 2>&1)"; rc=$?
    # PowerShell may wrap formatted diagnostics according to host width and invocation-path
    # length. Collapse whitespace so the assertion checks message content, not display layout.
    if [[ $rc -eq $want_rc ]] && printf '%s' "$out" | tr -s '[:space:]' ' ' | grep -qF -- "$want_tok"; then
        ok "$label (rc=$rc, token found)"
    else
        no "$label (rc=$rc want=$want_rc; out: $(printf '%s' "$out" | head -c 300))"
    fi
}

echo "== A. default policy (defer) x identity =="
run 2 "action=defer" "A1 legacy Codex name defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess Codex
run 2 "action=defer" "A2 merged host (ChatGPT under OpenAI.Codex_*) defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
RUN_MOCK_INVENTORY="$MOCK_OTHER" run 6 "other-desktop-host-running" "A3 undeclared other-ChatGPT refuses before activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT -MockForegroundPath "$CLASSIC_PATH"
run 2 "action=defer" "A4 ambiguous ChatGPT (no path) fails closed: defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT
run 2 "action=defer" "A5 unidentifiable foreground defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess unknown
run 0 "action=deeplink-snapback" "A6 known non-Codex (notepad) keeps deeplink+snapback" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad

echo "== B. switch policy x identity =="
run 5 "switch-refused" "B1 switch without ack refuses (legacy Codex)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess Codex
run 5 "switch-refused" "B2 switch without ack refuses (merged host)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 0 "action=switch-deeplink" "B3 switch+ack navigates (legacy Codex, backward compat)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch \
    -MockForegroundProcess Codex -MockForegroundPath "$CODEX_PATH"
run 0 "action=switch-deeplink" "B4 switch+ack navigates (merged host, positive identity)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 2 "foreground-unidentified" "B5 switch+ack on ambiguous ChatGPT still defers (never auto-switch on ambiguity)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT
RUN_MOCK_INVENTORY="$MOCK_OTHER" run 6 "other-desktop-host-running" "B6 switch+ack cannot bypass undeclared other-ChatGPT gate" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$CLASSIC_PATH"

echo "== C. restore-if-known stays fail-closed x identity =="
run 4 "restore-refused" "C1 restore-if-known refused (legacy Codex)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess Codex
run 4 "restore-refused" "C2 restore-if-known refused (merged host)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"

echo "== D. argument validation =="
run 1 "must be a UUID" "D1 non-UUID conversation id rejected" -- \
    -ConversationId "not-a-uuid" -DryRun -MockForegroundProcess Codex
RUN_AUTOLOAD=off run 6 "autoload-disabled" "D2 autoload off refuses helper activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad
RUN_MOCK_PACKAGE="$PKG_STAGED" run 6 "package-update-staged" "D3 staged update refuses helper activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad
RUN_MOCK_PACKAGE="$PKG_UNKNOWN" run 6 "package-update-unknown" "D4 unknown staged state refuses helper activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad
RUN_MOCK_REGISTRATION="$REG_CONFLICT" run 6 "protocol-registration-unproven" "D5 conflicting registration refuses helper activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad
RUN_MOCK_REGISTRATION="$REG_UNKNOWN" run 6 "protocol-registration-unproven" "D6 unknown registration refuses helper activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess notepad

HELPER_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1WIN" \
    -ConversationId "$UUID" -MockForegroundProcess notepad \
    -IpcRoot "$POLICY_ROOT" -Autoload codex-uri \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; HELPER_RC=$?
if [[ $HELPER_RC -eq 6 ]] \
    && printf '%s' "$HELPER_OUT" | grep -qF 'reason=host-policy-invalid' \
    && ! printf '%s' "$HELPER_OUT" | grep -qF "$MOCK_PACKAGE"; then
    ok "D7 helper rejects mocks without DryRun using a redacted reason token"
else
    no "D7 helper rejects mocks without DryRun (rc=$HELPER_RC; out: $(printf '%s' "$HELPER_OUT" | head -c 300))"
fi

echo "== E. process hygiene =="
# Suite-scoped leak check. Every helper invocation above is synchronous, and under
# -DryRun the helper exits before Start-Process (whose only target is a codex:// URI
# anyway, never powershell), so the only powershell process attributable to this
# suite would be a hung/detached helper invocation itself — and every one of those
# carries `-File <PS1WIN>` on its command line. Assert ZERO such processes remain.
# A host-global powershell count lived here before; that is racy on a shared host
# (unrelated concurrent powershell activity flaked gate run 4 while all helper
# invocations passed) and was replaced by this owned-scope check, mirroring the
# gate runner's ownership philosophy: if the enumeration itself fails, FAIL closed —
# never fabricate "no leaks" from a failed measurement.
HYG_SNIPPET='
$ErrorActionPreference = "Stop"
try {
  $needle = $env:AUTOLOAD_HYG_NEEDLE
  if ([string]::IsNullOrWhiteSpace($needle)) { Write-Output "ENUM_ERROR:helper-path needle missing from environment"; exit 3 }
  # Name scope ^powershell matches what the suite spawns (powershell.exe); if the
  # helper invocation ever migrates to pwsh, widen this or coverage silently ends.
  $ps = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -imatch "^powershell" })
  if (-not ($ps | Where-Object { $_.ProcessId -eq $PID })) {
    Write-Output "ENUM_ERROR:own pid $PID absent from powershell snapshot (enumeration untrustworthy)"; exit 3
  }
  $leaks = @($ps | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -and
    $_.CommandLine.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
  })
  foreach ($p in $leaks) { Write-Output ("LEAK: pid={0} cmd={1}" -f $p.ProcessId, $p.CommandLine) }
  Write-Output ("LEAKS={0}" -f $leaks.Count)
  exit 0
} catch { Write-Output ("ENUM_ERROR:{0}" -f $_.Exception.Message); exit 3 }
'
HYG_OUT="$(AUTOLOAD_HYG_NEEDLE="$PS1WIN" powershell.exe -NoProfile -NonInteractive -Command "$HYG_SNIPPET" 2>&1)"
HYG_RC=$?
HYG_OUT="${HYG_OUT//$'\r'/}"
# tail -n1: the genuine LEAKS= line is written last; a leaked command line that
# embedded a newline plus "LEAKS=0" could otherwise forge a pass via the first match.
LEAK_COUNT="$(printf '%s\n' "$HYG_OUT" | sed -n 's/^LEAKS=\([0-9][0-9]*\)$/\1/p' | tail -n1)"
if [[ $HYG_RC -ne 0 || -z "$LEAK_COUNT" ]]; then
    no "suite-scoped hygiene enumeration failed — failing closed (rc=$HYG_RC; out: $(printf '%s' "$HYG_OUT" | head -c 300))"
elif [[ "$LEAK_COUNT" -eq 0 ]]; then
    ok "no suite-attributable powershell processes remain (command line scoped to helper path)"
else
    no "suite-attributable powershell process(es) remain after matrix (count=$LEAK_COUNT): $(printf '%s' "$HYG_OUT" | grep '^LEAK:' | head -c 400)"
fi

echo
echo "autoload-matrix: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
