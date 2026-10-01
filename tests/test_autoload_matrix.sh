#!/usr/bin/env bash
# Hermetic behavioral matrix for codex_ipc_autoload.ps1 host-identity gating.
# Runs the REAL PowerShell script under -DryRun with mocked foreground identity
# (-MockForegroundProcess / -MockForegroundPath); never fires codex://, never
# touches focus. Windows-only by nature: skips cleanly when powershell.exe is
# absent (e.g. the ubuntu CI leg).
#
# Identity matrix under test (2026-07-09 ChatGPT/Codex host merge):
#   intended GUI: process 'Codex'/'ChatGPT' + exact intended executable -> Codex-certain
#   other Desktop: process 'Codex'/'ChatGPT' + another readable path    -> refuse immediately
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
ALT_PATH='C:\Alt\Host\ChatGPT.exe'
CLAUDE_PATH='C:\Alt\Tools\claude.exe'
EXPLORER_PATH='C:\Windows\explorer.exe'

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

echo "== P2. standalone default-root resolution =="
DEFAULT_HOME="$POLICY_ROOT/default-home"
DEFAULT_ROOT="$DEFAULT_HOME/.claude/ipc"
HOME_ONLY="$POLICY_ROOT/home-only"
HOME_ONLY_ROOT="$HOME_ONLY/.claude/ipc"
ENV_ROOT="$POLICY_ROOT/env-root"
mkdir -p "$DEFAULT_ROOT" "$HOME_ONLY_ROOT" "$ENV_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    DEFAULT_HOME_WIN="$(cygpath -w "$DEFAULT_HOME")"
    HOME_ONLY_WIN="$(cygpath -w "$HOME_ONLY")"
    ENV_ROOT_WIN="$(cygpath -w "$ENV_ROOT")"
else
    DEFAULT_HOME_WIN="$DEFAULT_HOME"
    HOME_ONLY_WIN="$HOME_ONLY"
    ENV_ROOT_WIN="$ENV_ROOT"
fi
cat > "$DEFAULT_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"codex-uri"}
JSON
cat > "$HOME_ONLY_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"off"}
JSON
cat > "$ENV_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"off","intendedHost":{"kind":"package"}}
JSON

POLICY_OUT="$(env -u CODEX_IPC_ROOT -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST \
  USERPROFILE="$DEFAULT_HOME_WIN" HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration 2>&1)"; POLICY_RC=$?
assert_policy 0 "P2 USERPROFILE default descriptor is loaded before HOME" '
  value.configuration.autoload.value === "codex-uri" &&
  value.configuration.autoload.source === "descriptor" &&
  value.configuration.descriptor.status === "loaded"'

POLICY_OUT="$(env -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST CODEX_IPC_ROOT= \
  USERPROFILE="$DEFAULT_HOME_WIN" HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration 2>&1)"; POLICY_RC=$?
assert_policy 0 "P3 empty CODEX_IPC_ROOT falls back to USERPROFILE" '
  value.configuration.autoload.value === "codex-uri" &&
  value.configuration.autoload.source === "descriptor"'

POLICY_OUT="$(env -u CODEX_IPC_ROOT -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST \
  -u USERPROFILE HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration 2>&1)"; POLICY_RC=$?
assert_policy 0 "P4 HOME supplies the default when USERPROFILE is absent" '
  value.configuration.autoload.value === "off" &&
  value.configuration.autoload.source === "descriptor" &&
  value.configuration.descriptor.status === "loaded"'

POLICY_OUT="$(env -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST CODEX_IPC_ROOT="$ENV_ROOT_WIN" \
  USERPROFILE="$DEFAULT_HOME_WIN" HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration 2>&1)"; POLICY_RC=$?
assert_policy 0 "P5 CODEX_IPC_ROOT overrides the home-derived root" '
  value.configuration.autoload.value === "off" &&
  value.configuration.autoload.source === "descriptor" &&
  value.configuration.descriptor.status === "loaded"'

printf '%s\n' '{"schemaVersion":1,' > "$DEFAULT_ROOT/host-policy.json"
POLICY_OUT="$(env -u CODEX_IPC_ROOT -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST \
  USERPROFILE="$DEFAULT_HOME_WIN" HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -Autoload off 2>&1)"; POLICY_RC=$?
assert_policy 1 "P6 malformed default descriptor refuses despite a flag" '
  value.ok === false && value.error.reason === "host-policy-invalid" &&
  value.error.message.includes("descriptor")'
cat > "$DEFAULT_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"codex-uri"}
JSON

POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration -IpcRoot ' ' 2>&1)"; POLICY_RC=$?
assert_policy 1 "P7 explicit blank IpcRoot refuses" '
  value.ok === false && value.error.reason === "host-policy-invalid" &&
  value.error.message.includes("IPC root must be nonempty")'

POLICY_OUT="$(env -u CODEX_IPC_ROOT -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST \
  -u USERPROFILE -u HOME \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose configuration 2>&1)"; POLICY_RC=$?
assert_policy 1 "P8 unresolved standalone root refuses" '
  value.ok === false && value.error.reason === "host-policy-invalid" &&
  value.error.message.includes("HOME or USERPROFILE")'

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

MOCK_EXTERNAL_APP_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":771,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":772,"parentPid":771,"name":"codex.exe","executable":"C:\\Alt Runtime\\codex.exe","commandLine":"\"C:\\Alt Runtime\\codex.exe\" app-server --analytics-default-enabled"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_EXTERNAL_APP_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R18 external app-server child is not counted as a second GUI" '
  value.sendEligible === true && value.inventory.complete === true &&
  value.inventory.guiHosts.length === 1 && value.inventory.guiHosts[0].pid === 771 &&
  value.inventory.appServers.length === 1 && value.inventory.appServers[0].pid === 772'

MOCK_PACKAGE_EXTERNAL_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":["C:\\Program Files\\WindowsApps\\OpenAI.Codex_fixture"],"errors":[],"processes":[{"pid":775,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Program Files\\WindowsApps\\OpenAI.Codex_fixture\\app\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":776,"parentPid":775,"name":"codex.exe","executable":"C:\\Local\\Runtime\\codex.exe","commandLine":"codex.exe app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -DryRun \
    -MockInventoryJson "$MOCK_PACKAGE_EXTERNAL_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R18b package GUI accepts its basename-bound external app-server child" '
  value.sendEligible === true && value.inventory.complete === true &&
  value.inventory.guiHosts.length === 1 && value.inventory.guiHosts[0].pid === 775 &&
  value.inventory.appServers.length === 1 && value.inventory.appServers[0].pid === 776'

MOCK_UNPROVEN_CODEX_CHILD='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":781,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":782,"parentPid":781,"name":"codex.exe","executable":"C:\\Alt\\Other\\codex.exe","commandLine":"codex.exe serve"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_UNPROVEN_CODEX_CHILD" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R19 unproven codex child remains a second GUI candidate" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_ORPHAN_EXTERNAL_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":791,"parentPid":1,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":"codex.exe app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_ORPHAN_EXTERNAL_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R20 orphan external app-server claim cannot stand in for a GUI host" '
  value.sendEligible === false && value.inventory.guiHosts.length === 1 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("intended-host-not-running")'

MOCK_MISMATCHED_APP_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":801,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":802,"parentPid":801,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":"\"C:\\Other\\codex.exe\" app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_MISMATCHED_APP_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R21 app-server command must name its own executable" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_DELAYED_APP_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":811,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":812,"parentPid":811,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":"codex.exe exec app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_DELAYED_APP_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R22 app-server must be the immediate subcommand" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_ORPHAN_WITH_GUI='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":821,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":822,"parentPid":1,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":"codex.exe app-server"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_ORPHAN_WITH_GUI" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R23 orphan app-server claim remains a competing GUI candidate" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_NULL_APP_SERVER_ROLE='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":831,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":832,"parentPid":831,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":null}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_NULL_APP_SERVER_ROLE" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R24 unreadable external child role remains a competing GUI candidate" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

MOCK_WRAPPER_APP_SERVER='{"complete":true,"packageRootsComplete":true,"packageRoots":[],"errors":[],"processes":[{"pid":841,"parentPid":1,"name":"ChatGPT.exe","executable":"C:\\Alt\\Host\\ChatGPT.exe","commandLine":"ChatGPT.exe"},{"pid":842,"parentPid":841,"name":"codex.exe","executable":"C:\\Alt\\Runtime\\codex.exe","commandLine":"codex.exe app-server-wrapper"}]}'
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$POLICYWIN" \
    -Purpose send -IpcRoot "$POLICY_ROOT" -IntendedHost 'C:\Alt\Host\ChatGPT.exe' \
    -DryRun -MockInventoryJson "$MOCK_WRAPPER_APP_SERVER" 2>&1)"; POLICY_RC=$?
assert_policy 0 "R25 app-server prefix is not an exact role" '
  value.sendEligible === false && value.inventory.guiHosts.length === 2 &&
  value.inventory.appServers.length === 0 &&
  value.sendReasons.includes("other-desktop-host-running")'

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
    local reached_activation=0
    if [[ $want_rc -ne 0 ]] && printf '%s' "$out" | grep -Eq 'action=(switch-deeplink|deeplink-snapback)'; then
        reached_activation=1
    fi
    if [[ $rc -eq $want_rc && $reached_activation -eq 0 ]] \
      && printf '%s' "$out" | tr -s '[:space:]' ' ' | grep -qF -- "$want_tok"; then
        ok "$label (rc=$rc, token found, refusal/defer did not reach an activation action)"
    else
        no "$label (rc=$rc want=$want_rc activation=$reached_activation; out: $(printf '%s' "$out" | head -c 300))"
    fi
}

echo "== A. required 28-run DryRun foreground-policy matrix =="
# Row (a): a readable ChatGPT executable outside the intended package inventory.
run 6 "foreground-alternate-host" "M01 alternate/defer refuses immediately" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT -MockForegroundPath "$ALT_PATH"
run 6 "foreground-alternate-host" "M02 alternate/switch-no-ack refuses immediately" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess ChatGPT -MockForegroundPath "$ALT_PATH"
run 6 "foreground-alternate-host" "M03 alternate/switch-ack refuses immediately" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$ALT_PATH"
run 6 "foreground-alternate-host" "M04 alternate/restore refuses immediately" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ChatGPT -MockForegroundPath "$ALT_PATH"

# Row (b): the exact intended package GUI.
run 2 "action=defer" "M05 package/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 5 "switch-refused" "M06 package/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 0 "action=switch-deeplink" "M07 package/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 4 "restore-refused" "M08 package/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"

# Row (c1): a known non-Desktop foreground.
run 0 "action=deeplink-snapback" "M09 claude/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess claude -MockForegroundPath "$CLAUDE_PATH"
run 0 "action=deeplink-snapback" "M10 claude/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess claude -MockForegroundPath "$CLAUDE_PATH"
run 0 "action=deeplink-snapback" "M11 claude/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess claude -MockForegroundPath "$CLAUDE_PATH"
run 0 "action=deeplink-snapback" "M12 claude/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess claude -MockForegroundPath "$CLAUDE_PATH"

# Row (c2): Explorer, another known non-Desktop foreground.
run 0 "action=deeplink-snapback" "M13 explorer/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"
run 0 "action=deeplink-snapback" "M14 explorer/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"
run 0 "action=deeplink-snapback" "M15 explorer/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"
run 0 "action=deeplink-snapback" "M16 explorer/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"

# Row (d1): an unidentifiable foreground.
run 2 "action=defer" "M17 unknown/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess unknown
run 5 "switch-refused" "M18 unknown/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess unknown
run 2 "foreground-unidentified" "M19 unknown/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess unknown
run 4 "restore-refused" "M20 unknown/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess unknown

# Row (d2): a whitespace-only name.
run 2 "action=defer" "M21 blank/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ' '
run 5 "switch-refused" "M22 blank/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess ' '
run 2 "foreground-unidentified" "M23 blank/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ' '
run 4 "restore-refused" "M24 blank/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ' '

# Row (d3): GUI-like name with no readable path.
run 2 "action=defer" "M25 pathless-ChatGPT/defer" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT
run 5 "switch-refused" "M26 pathless-ChatGPT/switch-no-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -MockForegroundProcess ChatGPT
run 2 "foreground-unidentified" "M27 pathless-ChatGPT/switch-ack" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT
run 4 "restore-refused" "M28 pathless-ChatGPT/restore" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ChatGPT

echo "== B. added host/inventory matrix cases =="
run 0 "action=switch-deeplink" "B1 legacy Codex name at intended executable remains compatible" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch \
    -MockForegroundProcess Codex -MockForegroundPath "$CODEX_PATH"
RUN_MOCK_INVENTORY="$MOCK_OTHER" run 6 "send-ineligible" "B2 other-host inventory refuses before activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"
RUN_MOCK_INVENTORY="$MOCK_EMPTY" run 6 "send-ineligible" "B3 empty inventory refuses before activation" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess explorer -MockForegroundPath "$EXPLORER_PATH"
RUN_MOCK_INVENTORY="$MOCK_ALTERNATE" RUN_MOCK_PACKAGE="$PKG_UNKNOWN" RUN_MOCK_REGISTRATION="$REG_UNKNOWN" \
  run 6 "protocol-host-not-package" "B4 declared alternate is never protocol activated" -- \
    -ConversationId "$UUID" -DryRun -IntendedHost "$ALT_PATH" \
    -MockForegroundProcess ChatGPT -MockForegroundPath "$ALT_PATH"

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

printf '%s\n' '{"schemaVersion":1,' > "$DEFAULT_ROOT/host-policy.json"
HELPER_OUT="$(env -u CODEX_IPC_ROOT -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_INTENDED_HOST \
  USERPROFILE="$DEFAULT_HOME_WIN" HOME="$HOME_ONLY_WIN" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1WIN" \
    -ConversationId "$UUID" -DryRun -Autoload codex-uri -MockForegroundProcess notepad \
    -MockInventoryJson "$MOCK_PACKAGE" -MockPackageJson "$PKG_CLEAR" \
    -MockRegistrationJson "$REG_MATCHES" 2>&1)"; HELPER_RC=$?
if [[ $HELPER_RC -eq 6 ]] && printf '%s' "$HELPER_OUT" | grep -qF 'reason=host-policy-invalid'; then
    ok "D7 helper reads and refuses a malformed default descriptor under DryRun"
else
    no "D7 helper default descriptor refusal (rc=$HELPER_RC; out: $(printf '%s' "$HELPER_OUT" | head -c 300))"
fi
cat > "$DEFAULT_ROOT/host-policy.json" <<'JSON'
{"schemaVersion":1,"autoload":"codex-uri"}
JSON

GUARD_CHECK_PS1="$POLICY_ROOT/mock-guard-ast.ps1"
cat > "$GUARD_CHECK_PS1" <<'POWERSHELL'
param([Parameter(Mandatory = $true)][string]$HelperPath)
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $HelperPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) { throw 'helper parser errors' }
$source = [System.IO.File]::ReadAllText($HelperPath)
$guards = @($ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
    $guardText = $node.Extent.Text
    return $guardText.Contains('MOCK_FOREGROUND_PROCESS_BOUND') -and
        $guardText.Contains('MOCK_FOREGROUND_PATH_BOUND') -and
        $guardText.Contains('mock-inputs-require-dry-run')
}, $true))
$guardText = if ($guards.Count -eq 1) { $guards[0].Extent.Text } else { '' }
$policyOffset = $source.IndexOf('$HOST_POLICY_SCRIPT =')
$nativeOffset = $source.IndexOf('Add-Type @"')
$activationOffset = $source.IndexOf('Start-Process -FilePath')
[pscustomobject][ordered]@{
    guardCount = $guards.Count
    processBinding = $source.Contains("`$MOCK_FOREGROUND_PROCESS_BOUND = `$PSBoundParameters.ContainsKey('MockForegroundProcess')")
    pathBinding = $source.Contains("`$MOCK_FOREGROUND_PATH_BOUND = `$PSBoundParameters.ContainsKey('MockForegroundPath')")
    checksDryRun = $guardText.Contains('-not $DryRun')
    fixedDiagnostic = $guardText.Contains('mock-inputs-require-dry-run')
    exitsSix = $guardText.Contains('exit 6')
    beforePolicyLoad = $guards.Count -eq 1 -and $guards[0].Extent.StartOffset -lt $policyOffset
    beforeNativeLoad = $guards.Count -eq 1 -and $guards[0].Extent.StartOffset -lt $nativeOffset
    beforeActivationSite = $guards.Count -eq 1 -and $guards[0].Extent.StartOffset -lt $activationOffset
    guardHasNoNativeEffect = $guardText -notmatch 'Start-Process|Invoke-CodexIpcProtocolActivation|SetForegroundWindow|keybd_event'
    soleActivationSite = ([regex]::Matches($source, 'Start-Process\s+-FilePath')).Count -eq 1
} | ConvertTo-Json -Compress
POWERSHELL
if command -v cygpath >/dev/null 2>&1; then
    GUARD_CHECK_WIN="$(cygpath -w "$GUARD_CHECK_PS1")"
else
    GUARD_CHECK_WIN="$GUARD_CHECK_PS1"
fi
POLICY_OUT="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$GUARD_CHECK_WIN" \
    -HelperPath "$PS1WIN" 2>&1)"; POLICY_RC=$?
assert_policy 0 "D8 foreground mock bindings use explicit PSBoundParameters presence" '
  value.guardCount === 1 && value.processBinding === true && value.pathBinding === true'
assert_policy 0 "D9 early mock guard pins DryRun, redacted diagnostic, and exit 6" '
  value.checksDryRun === true && value.fixedDiagnostic === true && value.exitsSix === true'
assert_policy 0 "D10 mock guard precedes policy/native/activation code and contains no native effect" '
  value.beforePolicyLoad === true && value.beforeNativeLoad === true &&
  value.beforeActivationSite === true && value.guardHasNoNativeEffect === true &&
  value.soleActivationSite === true'

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
