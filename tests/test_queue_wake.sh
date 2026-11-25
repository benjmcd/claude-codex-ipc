#!/usr/bin/env bash
# Hermetic matrix for codex_ipc_wake.ps1, the queue wake the --queue-id waiter runs once.
#
# Runs the REAL helper under -DryRun with injected process snapshots (-MockProcessesJson,
# -MockAfterProcessesJson), caller integrity (-MockIntegrity) and launch outcomes
# (-MockLaunchJson). It never launches an App, never opens a codex:// URL, and never reads the
# operator's host policy: every case gets its own fixture IPC root, executable and user-data
# directory. One waiter CLI case runs the real helper without mocks against a fixture descriptor
# whose executable does not exist, so the helper refuses before any process snapshot.
#
# Windows runs the whole matrix with powershell.exe. Elsewhere the helper is inapplicable: the
# suite checks its non-Windows refusal with pwsh when pwsh is present and reports the rest as not
# applicable. The waiter's own wake scheduling is covered in tests/test_ipc_wait.sh.
# Dual-layout probe: repo layout (tests/ beside skills/ipc/) and installed-skill layout.
set -u

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAKE=""
WAIT=""
for _dir in "$TDIR/../skills/ipc/scripts" "$TDIR/../scripts"; do
    if [[ -f "$_dir/codex_ipc_wake.ps1" && -f "$_dir/codex_ipc_wait.mjs" ]]; then
        WAKE="$_dir/codex_ipc_wake.ps1"
        WAIT="$_dir/codex_ipc_wait.mjs"
        break
    fi
done
[[ -n "$WAKE" ]] || { echo "FATAL: codex_ipc_wake.ps1 not found in repo or installed layout" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node is required" >&2; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
finish(){
    echo
    echo "queue-wake: $PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]] || exit 1
    exit 0
}

THREAD="11111111-1111-4111-8111-111111111111"
URL="codex://threads/wake/$THREAD"

if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "== non-Windows: the helper refuses cleanly =="
    if command -v pwsh >/dev/null 2>&1; then
        OUT="$(pwsh -NoProfile -File "$WAKE" -ThreadId "$THREAD" 2>&1)"; RC=$?
        if [[ $RC -eq 6 ]] && printf '%s' "$OUT" | node -e '
let text = ""; process.stdin.on("data", (c) => { text += c; }).on("end", () => {
  const v = JSON.parse(text.trim().split(/\r?\n/).pop());
  process.exit(v.schemaVersion === 1 && v.tool === "codex_ipc_wake" && v.result === "refused" &&
    v.code === "unsupported-os" && v.launched === false ? 0 : 1);
});'; then
            ok "pwsh on a non-Windows host refuses with unsupported-os, exit 6, nothing launched"
        else
            no "non-Windows refusal (rc=$RC; out: $(printf '%s' "$OUT" | head -c 300))"
        fi
    else
        echo "  n/a: neither powershell.exe nor pwsh is present; the helper is Windows-only"
    fi
    echo "  n/a: the guard matrix needs powershell.exe (Windows); the waiter's skip is in test_ipc_wait.sh"
    finish
fi

TMP="$(mktemp -d)" && [[ -n "$TMP" && -d "$TMP" ]] \
    || { echo "FATAL: could not create wake fixture root" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
win(){ cygpath -w "$1"; }
WAKEWIN="$(win "$WAKE")"

mkdir -p "$TMP/host/app/resources" "$TMP/other/app" "$TMP/ud" "$TMP/ud-nolock" "$TMP/ipc-alt" "$TMP/ipc-pkg" "$TMP/ipc-bad" "$TMP/ipc-none" \
    || { echo "FATAL: could not create wake fixtures" >&2; exit 1; }
: > "$TMP/host/app/ChatGPT.exe"
: > "$TMP/other/app/ChatGPT.exe"
: > "$TMP/ud/lockfile"
EXE="$(win "$TMP/host/app/ChatGPT.exe")"
OTHER="$(win "$TMP/other/app/ChatGPT.exe")"
RUNTIME="$(win "$TMP/host/app/resources")\\codex.exe"
UD="$(win "$TMP/ud")"
UD_NOLOCK="$(win "$TMP/ud-nolock")"
STORE='C:\Program Files\WindowsApps\OpenAI.Codex_26.1117.31558.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
node -e 'const fs=require("fs");const [alt,pkg,bad,exe]=process.argv.slice(1);
fs.writeFileSync(alt,JSON.stringify({schemaVersion:1,intendedHost:{kind:"alternate",executable:exe}}));
fs.writeFileSync(pkg,JSON.stringify({schemaVersion:1,intendedHost:{kind:"package"}}));
fs.writeFileSync(bad,"{not json");' \
    "$TMP/ipc-alt/host-policy.json" "$TMP/ipc-pkg/host-policy.json" "$TMP/ipc-bad/host-policy.json" "$EXE" \
    || { echo "FATAL: could not write host-policy fixtures" >&2; exit 1; }
IPC_ALT="$(win "$TMP/ipc-alt")"; IPC_PKG="$(win "$TMP/ipc-pkg")"
IPC_BAD="$(win "$TMP/ipc-bad")"; IPC_NONE="$(win "$TMP/ipc-none")"

# procs <variant...>: a process snapshot as the helper's mock JSON. Variants adjust the baseline
# (one root from the fixture executable with --user-data-dir="<ud>", a renderer, an app-server).
procs(){
    EXE="$EXE" OTHER="$OTHER" RUNTIME="$RUNTIME" UD="$UD" UD_NOLOCK="$UD_NOLOCK" STORE="$STORE" node -e '
const { EXE, OTHER, RUNTIME, UD, UD_NOLOCK, STORE } = process.env;
const variants = new Set(process.argv.slice(1));
const rootLine = variants.has("ud-unquoted") ? `"${EXE}" --user-data-dir=${UD}`
  : variants.has("ud-token-quoted") ? `"${EXE}" "--user-data-dir=${UD}" --flag`
  : variants.has("ud-missing") ? `"${EXE}" --enable-features=x`
  : variants.has("ud-twice") ? `"${EXE}" --user-data-dir="${UD}" --user-data-dir="${UD}"`
  : variants.has("ud-relative") ? `"${EXE}" --user-data-dir=relative\\desktop`
  : variants.has("ud-nolock") ? `"${EXE}" --user-data-dir="${UD_NOLOCK}"`
  : variants.has("ud-open-quote") ? `"${EXE}" --user-data-dir="${UD}`
  : `"${EXE}" --user-data-dir="${UD}"`;
const root = { pid: variants.has("root-200") ? 200 : 100, parentPid: 1, name: "ChatGPT.exe",
  executable: variants.has("root-other") ? OTHER : EXE, commandLine: rootLine };
if (!variants.has("no-responding")) root.responding = !variants.has("hung");
if (variants.has("root-unreadable")) root.commandLine = null;
const list = [];
if (!variants.has("no-root")) list.push(root);
list.push({ pid: 101, parentPid: root.pid, name: "ChatGPT.exe", executable: EXE,
  commandLine: `"${EXE}" --type=renderer --user-data-dir="${UD}"` });
if (!variants.has("no-runtime")) {
  list.push({ pid: 102, parentPid: root.pid, name: "codex.exe", executable: RUNTIME,
    commandLine: `"${RUNTIME}" app-server --analytics-default-enabled` });
}
if (variants.has("second-root")) {
  list.push({ ...root, pid: 300, commandLine: `"${EXE}" --user-data-dir="${UD}"`, responding: true });
}
if (variants.has("stock")) {
  list.push({ pid: 400, parentPid: 1, name: "ChatGPT.exe", executable: STORE, commandLine: `"${STORE}"` });
}
if (variants.has("launched-still-running")) {
  list.push({ pid: 555, parentPid: 1, name: "ChatGPT.exe", executable: EXE,
    commandLine: `"${EXE}" --user-data-dir="${UD}" --single-argument codex://threads/wake/x` });
}
list.push({ pid: 900, parentPid: 1, name: "explorer.exe", executable: "C:\\Windows\\explorer.exe",
  commandLine: "C:\\Windows\\explorer.exe" });
process.stdout.write(JSON.stringify({ processes: list }));
' "$@"
}

# wake <args...>: run the real helper; OUT holds stdout, RC the exit code. The operator's own
# host-policy environment never reaches it.
wake(){
    OUT="$(env -u CODEX_IPC_INTENDED_HOST -u CODEX_IPC_AUTOLOAD -u CODEX_IPC_ROOT \
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WAKEWIN" "$@" 2>/dev/null)"
    RC=$?
    OUT="${OUT//$'\r'/}"
}
# expect <rc> <label> <predicate over `v`, the parsed document>
expect(){
    local want_rc="$1" label="$2" predicate="$3"
    if [[ $RC -eq $want_rc ]] && printf '%s' "$OUT" | PREDICATE="$predicate" EXE="$EXE" UD="$UD" \
        RUNTIME="$RUNTIME" URL="$URL" node -e '
let text = ""; process.stdin.on("data", (c) => { text += c; }).on("end", () => {
  const lines = text.trim().split(/\n/);
  if (lines.length !== 1) process.exit(1);
  let v; try { v = JSON.parse(lines[0]); } catch { process.exit(1); }
  const { EXE, UD, RUNTIME, URL } = process.env;
  if (v.schemaVersion !== 1 || v.tool !== "codex_ipc_wake") process.exit(1);
  process.exit(new Function("v", "EXE", "UD", "RUNTIME", "URL", `return (${process.env.PREDICATE});`)(v, EXE, UD, RUNTIME, URL) ? 0 : 1);
});'; then
        ok "$label"
    else
        no "$label (rc=$RC; out: $(printf '%s' "$OUT" | head -c 400))"
    fi
}
refused(){ # refused <code> <label> <helper args...>
    local code="$1" label="$2"; shift 2
    wake "$@"
    expect 6 "$label" "v.result === 'refused' && v.code === '$code' && v.launched === false && JSON.stringify(v.reasons) === JSON.stringify(['$code']) && v.helperPid === null"
}
BASE=(-ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity medium)

echo "== dry-run: the exact command, argument order and environment =="
wake "${BASE[@]}" -MockProcessesJson "$(procs)"
expect 0 "dry-run reports the command and launches nothing" \
    "v.result === 'dry-run' && v.code === 'dry-run' && v.launched === false && v.simulated === false && v.rootPid === 100 && v.callerIntegrity === 'medium' && v.intendedHost.kind === 'alternate' && v.intendedHost.source === 'descriptor'"
expect 0 "arguments are --user-data-dir=\"<dir>\", --single-argument, then the wake URL last" \
    "JSON.stringify(v.command.arguments) === JSON.stringify(['--user-data-dir=\"' + UD + '\"', '--single-argument', URL]) && v.command.executable === EXE && v.command.commandLine === '\"' + EXE + '\" --user-data-dir=\"' + UD + '\" --single-argument ' + URL && v.command.commandLine.endsWith(' ' + URL) && v.url === URL && v.command.windowStyle === 'Hidden'"
expect 0 "the child environment carries the user data dir and the intended runtime" \
    "v.environment.CODEX_ELECTRON_USER_DATA_PATH === UD && v.environment.CODEX_CLI_PATH === RUNTIME && v.runtime === 'resolved' && v.userDataDir === UD"
wake "${BASE[@]}" -MockProcessesJson "$(procs no-runtime)"
expect 0 "without a proven runtime, CODEX_CLI_PATH is left unset" \
    "v.result === 'dry-run' && v.runtime === 'missing' && v.environment.CODEX_CLI_PATH === null && v.environment.CODEX_ELECTRON_USER_DATA_PATH === UD"
wake -ThreadId "${THREAD^^}" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity medium -MockProcessesJson "$(procs)"
expect 0 "an upper-case thread id is normalized in the URL" "v.result === 'dry-run' && v.url === URL && v.command.arguments[2] === URL"
for variant in ud-unquoted ud-token-quoted; do
    wake "${BASE[@]}" -MockProcessesJson "$(procs "$variant")"
    expect 0 "the user data dir is read from a $variant command line" "v.result === 'dry-run' && v.userDataDir === UD"
done
wake -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_PKG" -IntendedHost "$EXE" -MockIntegrity medium -MockProcessesJson "$(procs)"
expect 0 "-IntendedHost outranks a package descriptor" "v.result === 'dry-run' && v.intendedHost.source === 'flag'"

echo "== guards: each refusal launches nothing =="
wake -ThreadId "$THREAD" -IpcRoot "$IPC_ALT" -MockIntegrity medium -MockProcessesJson "$(procs)"
expect 6 "a mock without -DryRun refuses first" "v.result === 'refused' && v.code === 'mock-requires-dry-run' && v.launched === false && v.callerIntegrity === null"
wake -ThreadId "$THREAD" -IpcRoot "$IPC_ALT" -MockLaunchJson '{"pid":1,"exited":true,"exitCode":0}'
expect 6 "a mocked launch without -DryRun refuses" "v.code === 'mock-requires-dry-run'"
refused thread-id-invalid "a thread id that is not a UUID" -ThreadId "not-a-uuid" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity medium -MockProcessesJson "$(procs)"
refused thread-id-invalid "a missing thread id" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity medium -MockProcessesJson "$(procs)"
refused host-not-alternate "a package descriptor" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_PKG" -MockIntegrity medium -MockProcessesJson "$(procs)"
refused host-not-alternate "no descriptor (package default)" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_NONE" -MockIntegrity medium -MockProcessesJson "$(procs)"
refused host-not-alternate "-IntendedHost package" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_ALT" -IntendedHost package -MockIntegrity medium -MockProcessesJson "$(procs)"
OUT="$(env CODEX_IPC_INTENDED_HOST=package powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WAKEWIN" "${BASE[@]}" -MockProcessesJson "$(procs)" 2>/dev/null)"; RC=$?; OUT="${OUT//$'\r'/}"
expect 6 "CODEX_IPC_INTENDED_HOST=package outranks an alternate descriptor" "v.code === 'host-not-alternate' && v.intendedHost.source === 'environment'"
refused host-policy-invalid "a malformed descriptor" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_BAD" -MockIntegrity medium -MockProcessesJson "$(procs)"
refused host-executable-missing "an alternate executable that does not exist" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_ALT" -IntendedHost 'C:\Nonexistent\Fixture\ChatGPT.exe' -MockIntegrity medium -MockProcessesJson "$(procs)"
for level in untrusted low medium-plus high system appcontainer unknown; do
    wake -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity "$level" -MockProcessesJson "$(procs)"
    expect 6 "caller integrity $level is refused" "v.code === 'caller-integrity-refused' && v.callerIntegrity === '$level' && v.launched === false && v.rootPid === null"
done
refused mock-invalid "an unknown mock integrity level" -ThreadId "$THREAD" -DryRun -IpcRoot "$IPC_ALT" -MockIntegrity elevated -MockProcessesJson "$(procs)"
refused mock-invalid "a malformed process snapshot" "${BASE[@]}" -MockProcessesJson '{"processes":[{"pid":"x"}]}'
refused stock-app-running "a Store package process is running" "${BASE[@]}" -MockProcessesJson "$(procs stock)"
refused app-not-running "no root App process" "${BASE[@]}" -MockProcessesJson "$(procs no-root)"
refused app-root-ambiguous "two root App processes" "${BASE[@]}" -MockProcessesJson "$(procs second-root)"
refused app-root-not-intended "the root runs another executable" "${BASE[@]}" -MockProcessesJson "$(procs root-other)"
refused process-identity-unreadable "an App process whose command line is unreadable" "${BASE[@]}" -MockProcessesJson "$(procs root-unreadable)"
refused user-data-dir-missing "no --user-data-dir on the root" "${BASE[@]}" -MockProcessesJson "$(procs ud-missing)"
refused user-data-dir-ambiguous "two --user-data-dir switches" "${BASE[@]}" -MockProcessesJson "$(procs ud-twice)"
refused user-data-dir-invalid "a relative --user-data-dir" "${BASE[@]}" -MockProcessesJson "$(procs ud-relative)"
refused command-line-unparseable "an unclosed quote in the root command line" "${BASE[@]}" -MockProcessesJson "$(procs ud-open-quote)"
refused lockfile-missing "a user data dir without a lockfile" "${BASE[@]}" -MockProcessesJson "$(procs ud-nolock)"
refused app-not-responding "a root that is not responding" "${BASE[@]}" -MockProcessesJson "$(procs hung)"
refused app-not-responding "a root whose responsiveness is unknown" "${BASE[@]}" -MockProcessesJson "$(procs no-responding)"

echo "== post-launch checks (simulated launch) =="
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":0}'
expect 0 "an exited launch with code 0 and the same root is forwarded" \
    "v.result === 'forwarded' && v.code === 'wake-forwarded' && v.launched === true && v.simulated === true && v.helperPid === 555 && v.helperExited === true && v.helperExitCode === 0 && v.rootPid === 100 && v.rootPidAfter === 100 && v.reasons.length === 0"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs launched-still-running)" -MockLaunchJson '{"pid":555,"exited":false}'
expect 7 "a launch that has not exited is reported with its PID and left running" \
    "v.result === 'unverified' && v.code === 'wake-launch-not-exited' && JSON.stringify(v.reasons) === JSON.stringify(['wake-launch-not-exited']) && v.helperPid === 555 && v.helperExited === false && v.helperExitCode === null && v.rootPidAfter === 100"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":1}'
expect 7 "a nonzero exit code is unverified" "v.result === 'unverified' && v.code === 'wake-launch-exit-nonzero' && v.helperExitCode === 1"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs root-200)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":0}'
expect 7 "a different root PID afterwards is host-changed" "v.result === 'unverified' && v.code === 'host-changed' && v.rootPid === 100 && v.rootPidAfter === 200"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs second-root)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":0}'
expect 7 "a second root afterwards is host-changed" "v.code === 'host-changed' && v.rootPidAfter === null"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs no-root)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":0}'
expect 7 "no root afterwards is host-changed" "v.code === 'host-changed'"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs stock)" -MockLaunchJson '{"pid":555,"exited":true,"exitCode":0}'
expect 7 "a Store package process afterwards is reported" "v.result === 'unverified' && v.code === 'stock-app-running'"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockAfterProcessesJson "$(procs root-200)" -MockLaunchJson '{"pid":555,"exited":false}'
expect 7 "every failed check is listed, not-exited first" "JSON.stringify(v.reasons) === JSON.stringify(['wake-launch-not-exited', 'host-changed'])"
wake "${BASE[@]}" -MockProcessesJson "$(procs)" -MockLaunchJson '{"startError":"synthetic"}'
expect 6 "a launch that could not start is refused, nothing launched" "v.result === 'refused' && v.code === 'launch-failed' && v.launched === false"

echo "== static: the helper's only launch is CreateProcess of the intended executable =="
if ! grep -nE 'Start-Process|Invoke-Item|UseShellExecute *= *\$true|Stop-Process|\.Kill\(|taskkill' "$WAKE" >/dev/null \
    && [[ "$(grep -c '\[System\.Diagnostics\.Process\]::Start(' "$WAKE")" -eq 1 ]] \
    && grep -q 'UseShellExecute = \$false' "$WAKE"; then
    ok "no Start-Process, shell or protocol activation, and no process-stopping call"
else
    no "the helper has a forbidden launch or kill path"
fi

echo "== waiter CLI runs the real helper, which refuses before any snapshot =="
STORE_DIR="$TMP/queue-store"; mkdir -p "$STORE_DIR" "$TMP/sessions" "$TMP/transport" || { echo "FATAL: fixture" >&2; exit 1; }
QUEUE_ID="0f0f0001-0000-4000-8000-000000000001"
DISPATCH="9100000000-1-abcdef0123456789"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$THREAD\"}}" > "$TMP/sessions/rollout-$THREAD.jsonl"
node -e 'const fs=require("fs");const [p,exe]=process.argv.slice(1);
fs.writeFileSync(p,JSON.stringify({schemaVersion:1,intendedHost:{kind:"alternate",executable:exe}}));' \
    "$TMP/transport/host-policy.json" 'C:\Nonexistent\Fixture\app\ChatGPT.exe'
node --input-type=module -e '
import { DatabaseSync } from "node:sqlite";
const [file, id, thread] = process.argv.slice(1);
const db = new DatabaseSync(file);
db.exec("create table queued_items (id text primary key not null, thread_id text not null, payload_json text not null, queue_order integer not null, created_at_ms integer not null, updated_at_ms integer not null)");
db.prepare("insert into queued_items values (?,?,?,?,?,?)").run(id, thread, "{}", 0, Date.now() - 600000, Date.now() - 600000);
db.close();' "$(win "$STORE_DIR")\\queue_1.sqlite" "$QUEUE_ID" "$THREAD" 2>/dev/null
WAIT_ERR="$TMP/wait.err"
WAIT_OUT="$(env -u CODEX_IPC_INTENDED_HOST -u CODEX_IPC_AUTOLOAD HOME="$TMP" USERPROFILE="$(win "$TMP")" \
    node "$WAIT" --thread "$THREAD" --dispatch "$DISPATCH" --rollout-path "$(win "$TMP/sessions/rollout-$THREAD.jsonl")" \
    --sessions-root "$(win "$TMP/sessions")" --transport-root "$(win "$TMP/transport")" \
    --queue-id "$QUEUE_ID" --queue-db "$(win "$STORE_DIR")\\queue_1.sqlite" \
    --budget-ms 1500 --interval-ms 500 --status-exit-codes 2>"$WAIT_ERR")"; WAIT_RC=$?
if [[ "$WAIT_OUT" == "pending" && $WAIT_RC -eq 2 ]] && node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split(/\r?\n/)
  .filter((line) => line.startsWith("WAIT_DIAGNOSTIC ")).map((line) => JSON.parse(line.slice(16)))
  .filter((item) => /^wake-/.test(item.code));
const ok = lines.length === 2 && lines[0].code === "wake-attempted" && lines[1].code === "wake-result" &&
  lines[1].result === "refused" && lines[1].wakeCode === "host-executable-missing" &&
  lines[1].launched === false && lines[1].exitStatus === 6 &&
  !JSON.stringify(lines).includes("Nonexistent");
process.exit(ok ? 0 : 1);' "$WAIT_ERR"; then
    ok "the waiter ran powershell.exe -File codex_ipc_wake.ps1 once and reported its refusal; token and exit unchanged"
else
    no "waiter CLI wake (rc=$WAIT_RC; out=$WAIT_OUT; err: $(head -c 600 "$WAIT_ERR"))"
fi

finish
