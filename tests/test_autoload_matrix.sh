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
for _cand in "$TDIR/../skills/ipc/scripts/codex_ipc_autoload.ps1" "$TDIR/../scripts/codex_ipc_autoload.ps1"; do
    [[ -f "$_cand" ]] && PS1SCRIPT="$_cand" && break
done
[[ -n "$PS1SCRIPT" ]] || { echo "FATAL: codex_ipc_autoload.ps1 not found in repo or installed layout" >&2; exit 1; }

if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "SKIP: powershell.exe not available (helper is Windows-only); matrix not applicable on this host"
    exit 0
fi

# Windows path for -File (powershell.exe does not grok /c/... MSYS paths).
if command -v cygpath >/dev/null 2>&1; then
    PS1WIN="$(cygpath -w "$PS1SCRIPT")"
else
    PS1WIN="$PS1SCRIPT"
fi

UUID="00000000-0000-4000-8000-000000000000"
CODEX_PATH='C:\Program Files\WindowsApps\OpenAI.Codex_26.707.3563.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
CLASSIC_PATH='C:\Program Files\WindowsApps\OpenAI.ChatGPT-Desktop_1.2026.100.0_x64__9x9x9x9x9x9x9\app\ChatGPT.exe'

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# run <expected-rc> <expected-token> <label> -- <ps args...>
run(){
    local want_rc="$1" want_tok="$2" label="$3"; shift 3; [[ "$1" == "--" ]] && shift
    local out rc
    out="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1WIN" "$@" 2>&1)"; rc=$?
    if [[ $rc -eq $want_rc ]] && printf '%s' "$out" | grep -qF -- "$want_tok"; then
        ok "$label (rc=$rc, token found)"
    else
        no "$label (rc=$rc want=$want_rc; out: $(printf '%s' "$out" | head -c 300))"
    fi
}

# Baseline powershell process count (hygiene check at the end; every invocation
# above is synchronous, so the count must not grow).
ps_count(){ tasklist 2>/dev/null | grep -ci "powershell" || true; }
PS_BEFORE="$(ps_count)"

echo "== A. default policy (defer) x identity =="
run 2 "action=defer" "A1 legacy Codex name defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess Codex
run 2 "action=defer" "A2 merged host (ChatGPT under OpenAI.Codex_*) defers" -- \
    -ConversationId "$UUID" -DryRun -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 0 "action=deeplink-snapback" "A3 other-ChatGPT (readable non-Codex path) keeps deeplink+snapback" -- \
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
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess Codex
run 0 "action=switch-deeplink" "B4 switch+ack navigates (merged host, positive identity)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"
run 2 "foreground-unidentified" "B5 switch+ack on ambiguous ChatGPT still defers (never auto-switch on ambiguity)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT
run 0 "action=deeplink-snapback" "B6 switch+ack on other-ChatGPT is not gated (non-Codex path)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy switch -AckForegroundSwitch -MockForegroundProcess ChatGPT -MockForegroundPath "$CLASSIC_PATH"

echo "== C. restore-if-known stays fail-closed x identity =="
run 4 "restore-refused" "C1 restore-if-known refused (legacy Codex)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess Codex
run 4 "restore-refused" "C2 restore-if-known refused (merged host)" -- \
    -ConversationId "$UUID" -DryRun -ForegroundPolicy restore-if-known -MockForegroundProcess ChatGPT -MockForegroundPath "$CODEX_PATH"

echo "== D. argument validation =="
run 1 "must be a UUID" "D1 non-UUID conversation id rejected" -- \
    -ConversationId "not-a-uuid" -DryRun -MockForegroundProcess Codex

echo "== E. process hygiene =="
# Every invocation above is synchronous and -DryRun never reaches Start-Process, so a
# lingering child can only mean a leak. The global count is jitter-prone (unrelated
# powershell activity on the host), so allow one settle-and-recount before failing.
PS_AFTER="$(ps_count)"
if [[ "$PS_AFTER" -gt "$PS_BEFORE" ]]; then
    sleep 2
    PS_AFTER="$(ps_count)"
fi
if [[ "$PS_AFTER" -le "$PS_BEFORE" ]]; then
    ok "no lingering powershell processes (before=$PS_BEFORE after=$PS_AFTER)"
else
    no "powershell process count grew and did not settle (before=$PS_BEFORE after=$PS_AFTER)"
fi

echo
echo "autoload-matrix: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
