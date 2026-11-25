# codex_ipc_wake.ps1 -- ask the running Codex Desktop App to start a thread's queued item.
#
# The App's queue service starts a queued item only on a thread the App has loaded. After an App
# start, or after an idle unload, an item queued with `--deliver queue` waits until someone opens
# the chat. The App has a built-in route for this: codex://threads/wake/<uuid> resumes that thread
# in the background when its queue is non-empty, without navigating or showing a window.
#
# This helper delivers that URL to the RUNNING App only. It launches the App's own executable with
# the App's own user data, so Electron's single-instance lock forwards the argv to the running
# instance and the new process exits. It never uses OS protocol activation: Windows maps codex: to
# the Store package's executable, which uses different user data and would start a separate App.
# It never kills, stops or signals a process, including a launched process that does not exit.
#
# Guards, in order. The first failure refuses and nothing is launched:
#   Windows only; mocks only with -DryRun; -ThreadId is a UUID; the shared host configuration
#   (codex_ipc_host_policy.ps1: flag > CODEX_IPC_INTENDED_HOST > <IpcRoot>\host-policy.json >
#   package) names an alternate host whose executable exists; the caller runs at Medium mandatory
#   integrity outside an AppContainer; no process runs from the Store package directory; exactly
#   one root App process (no --type= switch) runs, from exactly that executable; its command line
#   carries one --user-data-dir= whose <dir>\lockfile exists; the root process is responding.
#
# Launch: <executable> --user-data-dir="<dir>" --single-argument codex://threads/wake/<uuid>, in
# that order with the URL last, hidden, with CODEX_ELECTRON_USER_DATA_PATH=<dir> and, when the
# intended runtime resolves from the same snapshot, CODEX_CLI_PATH=<runtime>. Then it waits up to
# 15 s for exit and checks: exit code 0, the same single root PID, no Store package process.
#
# Output: exactly one JSON document on stdout (schemaVersion 1, tool "codex_ipc_wake"), with
#   result  forwarded | dry-run | refused | unverified
#   code    a stable token: wake-forwarded, dry-run, the refusing guard, or the first failed
#           post-launch check (wake-launch-not-exited, host-changed, stock-app-running,
#           wake-launch-exit-nonzero, process-snapshot-failed)
# Exit codes:
#   0 = forwarded, or a dry-run that would launch
#   6 = refused; nothing was launched
#   7 = launched, and a post-launch check failed (the URL may still have been forwarded)
#
# Test hooks: -MockProcessesJson and -MockAfterProcessesJson substitute the process snapshots
# taken before and after the launch, -MockIntegrity the caller's integrity level, and
# -MockLaunchJson the launch outcome. Every mock requires -DryRun, and -DryRun never launches; a
# mock without -DryRun refuses (mock-requires-dry-run) before any other step.
param(
    [string]$ThreadId = '',
    [switch]$DryRun,
    [string]$IpcRoot = '',
    [string]$IntendedHost = '',
    [string]$MockProcessesJson = '',
    [string]$MockAfterProcessesJson = '',
    [string]$MockIntegrity = '',
    [string]$MockLaunchJson = ''
)

$WAKE_EXIT_TIMEOUT_MS = 15000
$STORE_PACKAGE_PATTERN = '(?i)^[a-z]:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]*\\'
$UUID_PATTERN = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

$MOCK_PROCESSES_BOUND = $PSBoundParameters.ContainsKey('MockProcessesJson')
$MOCK_AFTER_BOUND = $PSBoundParameters.ContainsKey('MockAfterProcessesJson')
$MOCK_INTEGRITY_BOUND = $PSBoundParameters.ContainsKey('MockIntegrity')
$MOCK_LAUNCH_BOUND = $PSBoundParameters.ContainsKey('MockLaunchJson')
$INTENDED_HOST_BOUND = $PSBoundParameters.ContainsKey('IntendedHost')
$IPC_ROOT_BOUND = $PSBoundParameters.ContainsKey('IpcRoot')

$script:Report = [ordered]@{
    schemaVersion = 1
    tool = 'codex_ipc_wake'
    result = $null
    code = $null
    reasons = @()
    detail = $null
    dryRun = [bool]$DryRun
    simulated = $false
    launched = $false
    threadId = $null
    url = $null
    intendedHost = $null
    callerIntegrity = $null
    rootPid = $null
    rootPidAfter = $null
    userDataDir = $null
    runtime = 'not-evaluated'
    command = $null
    environment = $null
    helperPid = $null
    helperExited = $null
    helperExitCode = $null
}

function Complete-Wake {
    param([string]$Result, [string]$Code, [string[]]$Reasons, [int]$Exit, [string]$Detail = $null)

    $script:Report.result = $Result
    $script:Report.code = $Code
    $script:Report.reasons = @($Reasons)
    if (-not [string]::IsNullOrEmpty($Detail)) { $script:Report.detail = $Detail }
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    Write-Output ([pscustomobject]$script:Report | ConvertTo-Json -Depth 6 -Compress)
    exit $Exit
}

function Deny-Wake {
    param([string]$Code, [string]$Detail = $null)
    Complete-Wake -Result 'refused' -Code $Code -Reasons @($Code) -Exit 6 -Detail $Detail
}

$onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
if (-not $onWindows) { Deny-Wake -Code 'unsupported-os' -Detail 'the wake helper is Windows-only' }

if (($MOCK_PROCESSES_BOUND -or $MOCK_AFTER_BOUND -or $MOCK_INTEGRITY_BOUND -or $MOCK_LAUNCH_BOUND) -and -not $DryRun) {
    Deny-Wake -Code 'mock-requires-dry-run'
}
if ($MOCK_LAUNCH_BOUND -and -not $MOCK_PROCESSES_BOUND) {
    Deny-Wake -Code 'mock-invalid' -Detail '-MockLaunchJson requires -MockProcessesJson'
}

if ($ThreadId -notmatch $UUID_PATTERN) { Deny-Wake -Code 'thread-id-invalid' }
$threadIdNormalized = $ThreadId.ToLowerInvariant()
$script:Report.threadId = $threadIdNormalized
$wakeUrl = "codex://threads/wake/$threadIdNormalized"
$script:Report.url = $wakeUrl

$HOST_POLICY_SCRIPT = Join-Path $PSScriptRoot 'codex_ipc_host_policy.ps1'
if (-not (Test-Path -LiteralPath $HOST_POLICY_SCRIPT -PathType Leaf)) {
    Deny-Wake -Code 'host-policy-unavailable' -Detail 'policy script missing'
}
try {
    . $HOST_POLICY_SCRIPT
} catch {
    Deny-Wake -Code 'host-policy-unavailable' -Detail 'policy script failed to load'
}

# ---- host configuration (the same resolution as the queue route's host policy) ----------------
$resolvedIpcRoot = $IpcRoot
if (-not $IPC_ROOT_BOUND -or [string]::IsNullOrWhiteSpace($resolvedIpcRoot)) {
    $environmentRoot = [Environment]::GetEnvironmentVariable('CODEX_IPC_ROOT')
    if (-not [string]::IsNullOrEmpty($environmentRoot)) {
        $resolvedIpcRoot = $environmentRoot
    } else {
        $userHome = [Environment]::GetEnvironmentVariable('USERPROFILE')
        if ([string]::IsNullOrEmpty($userHome)) { $userHome = [Environment]::GetEnvironmentVariable('HOME') }
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            Deny-Wake -Code 'host-policy-invalid' -Detail 'IPC root cannot be resolved without HOME or USERPROFILE'
        }
        $resolvedIpcRoot = Join-Path (Join-Path $userHome '.claude') 'ipc'
    }
}
try {
    $configuration = Resolve-CodexIpcHostConfiguration `
        -IpcRoot $resolvedIpcRoot `
        -FlagAutoloadPresent $false `
        -FlagAutoload $null `
        -FlagIntendedHostPresent $INTENDED_HOST_BOUND `
        -FlagIntendedHost $IntendedHost
} catch {
    Deny-Wake -Code 'host-policy-invalid' -Detail $_.Exception.Message
}
$intended = $configuration.intendedHost
$script:Report.intendedHost = [pscustomobject][ordered]@{
    kind = $intended.kind
    executable = $intended.executable
    source = $intended.source
}
if ($intended.kind -ne 'alternate') {
    Deny-Wake -Code 'host-not-alternate' -Detail "intended host kind is $($intended.kind); the wake runs only for an alternate host"
}
$hostExecutable = [string]$intended.executable
if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
    Deny-Wake -Code 'host-executable-missing'
}
$hostLeaf = [System.IO.Path]::GetFileName($hostExecutable)

# ---- native helpers (compiled only when a real token query or a real launch needs them) -------
function Initialize-WakeNative {
    if ($null -ne ('CodexIpcWakeNative' -as [type])) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexIpcWakeNative {
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

  // The caller token's mandatory integrity RID, or -1 when it cannot be read. appContainer is
  // 1 inside an AppContainer, 0 outside, -1 when unknown.
  public static long IntegrityRid(out int appContainer) {
    appContainer = -1;
    IntPtr token;
    if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out token)) return -1;
    try {
      int length;
      IntPtr flag = Marshal.AllocHGlobal(4);
      try {
        if (GetTokenInformation(token, 29, flag, 4, out length)) appContainer = Marshal.ReadInt32(flag) != 0 ? 1 : 0;
      } finally { Marshal.FreeHGlobal(flag); }
      GetTokenInformation(token, 25, IntPtr.Zero, 0, out length);
      if (length <= 0) return -1;
      IntPtr label = Marshal.AllocHGlobal(length);
      try {
        if (!GetTokenInformation(token, 25, label, length, out length)) return -1;
        IntPtr sid = Marshal.ReadIntPtr(label);
        int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
        if (count < 1) return -1;
        return (long)(uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
      } finally { Marshal.FreeHGlobal(label); }
    } finally { CloseHandle(token); }
  }

  // The launched App process must not inherit this helper's standard handles, which are the
  // caller's pipes: a process that kept them would hold the caller's output open.
  public static void KeepStandardHandlesFromChildren() {
    for (int which = -10; which >= -12; which--) {
      IntPtr handle = GetStdHandle(which);
      if (handle != IntPtr.Zero && handle != new IntPtr(-1)) SetHandleInformation(handle, 1, 0);
    }
  }
}
"@
}

function Get-WakeCallerIntegrity {
    if ($MOCK_INTEGRITY_BOUND) {
        $allowed = @('untrusted', 'low', 'medium', 'medium-plus', 'high', 'system', 'appcontainer', 'unknown')
        if ($allowed -notcontains $MockIntegrity) { Deny-Wake -Code 'mock-invalid' -Detail '-MockIntegrity is not a known level' }
        return $MockIntegrity
    }
    try {
        Initialize-WakeNative
        $appContainer = 0
        $rid = [CodexIpcWakeNative]::IntegrityRid([ref]$appContainer)
    } catch {
        return 'unknown'
    }
    if ($appContainer -eq 1) { return 'appcontainer' }
    if ($appContainer -ne 0 -or $rid -lt 0) { return 'unknown' }
    if ($rid -lt 0x1000) { return 'untrusted' }
    if ($rid -lt 0x2000) { return 'low' }
    if ($rid -eq 0x2000) { return 'medium' }
    if ($rid -lt 0x3000) { return 'medium-plus' }
    if ($rid -lt 0x4000) { return 'high' }
    return 'system'
}

# ---- process snapshot -------------------------------------------------------------------------
function ConvertFrom-WakeMockProcesses {
    param([string]$Json, [string]$Context)

    try {
        $mock = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    } catch {
        throw "$Context JSON is malformed"
    }
    Assert-CodexIpcObjectKeys -Object $mock -Allowed @('processes') -Context $Context
    if (-not (Test-CodexIpcObjectProperty -Object $mock -Name 'processes') -or $mock.processes -isnot [System.Array]) {
        throw "$Context requires a processes array"
    }
    $processes = @()
    foreach ($process in $mock.processes) {
        Assert-CodexIpcObjectKeys -Object $process `
            -Allowed @('pid', 'parentPid', 'name', 'executable', 'commandLine', 'responding') `
            -Context "$Context process"
        foreach ($required in @('pid', 'parentPid', 'name', 'executable', 'commandLine')) {
            if (-not (Test-CodexIpcObjectProperty -Object $process -Name $required)) {
                throw "$Context process requires $required"
            }
        }
        $pidIsInteger = ($process.pid -is [int]) -or ($process.pid -is [long])
        $parentIsInteger = ($process.parentPid -is [int]) -or ($process.parentPid -is [long])
        if (-not $pidIsInteger -or [long]$process.pid -le 0 -or -not $parentIsInteger -or [long]$process.parentPid -lt 0) {
            throw "$Context process ids must be nonnegative integers and pid must be positive"
        }
        if ($process.name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$process.name)) {
            throw "$Context process name must be a nonempty string"
        }
        if ($null -ne $process.executable -and $process.executable -isnot [string]) {
            throw "$Context process executable must be a string or null"
        }
        if ($null -ne $process.commandLine -and $process.commandLine -isnot [string]) {
            throw "$Context process commandLine must be a string or null"
        }
        $responding = $null
        if (Test-CodexIpcObjectProperty -Object $process -Name 'responding') {
            if ($process.responding -isnot [bool]) { throw "$Context process responding must be a boolean" }
            $responding = [bool]$process.responding
        }
        $processes += [pscustomobject][ordered]@{
            pid = [long]$process.pid
            parentPid = [long]$process.parentPid
            name = [string]$process.name
            executable = ConvertTo-CodexIpcNormalizedPath -Value $process.executable
            commandLine = if ($null -eq $process.commandLine) { $null } else { [string]$process.commandLine }
            responding = $responding
        }
    }
    return @($processes)
}

function Get-WakeProcessSnapshot {
    param([string]$MockJson, [bool]$Mocked, [string]$Context)

    if ($Mocked) { return @(ConvertFrom-WakeMockProcesses -Json $MockJson -Context $Context) }
    $processes = @()
    foreach ($row in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $processes += [pscustomobject][ordered]@{
            pid = [long]$row.ProcessId
            parentPid = [long]$row.ParentProcessId
            name = [string]$row.Name
            executable = ConvertTo-CodexIpcNormalizedPath -Value $row.ExecutablePath
            commandLine = if ($null -eq $row.CommandLine) { $null } else { [string]$row.CommandLine }
            responding = $null
        }
    }
    return @($processes)
}

# The App candidates in a snapshot: a Store package process anywhere, or a process named like the
# App (ChatGPT.exe or the intended executable's file name). A root is a candidate with no --type=
# switch. Returns a code token on refusal, else the root list.
function Get-WakeAppState {
    param([object[]]$Processes, [long]$ExcludePid = 0)

    $state = [ordered]@{ refusal = $null; stock = $false; roots = @() }
    foreach ($process in $Processes) {
        if ($ExcludePid -gt 0 -and [long]$process.pid -eq $ExcludePid) { continue }
        if ($null -ne $process.executable -and $process.executable -match $STORE_PACKAGE_PATTERN) {
            $state.stock = $true
            continue
        }
        $name = [string]$process.name
        $named = ([string]::Equals($name, 'ChatGPT.exe', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($name, $hostLeaf, [System.StringComparison]::OrdinalIgnoreCase))
        if (-not $named) { continue }
        if ($null -eq $process.executable -or $null -eq $process.commandLine) {
            if ($null -eq $state.refusal) { $state.refusal = 'process-identity-unreadable' }
            continue
        }
        if ([string]$process.commandLine -match '(?i)(^|\s)"?--type=') { continue }
        $state.roots += $process
    }
    return [pscustomobject]$state
}

# Every token of a command line, with Windows quoting rules (the host policy's tokenizer), or
# $null when a quote is left open.
function Split-WakeCommandLine {
    param([string]$CommandLine)

    $tokens = @()
    $offset = 0
    while ($true) {
        $token = Read-CodexIpcCommandToken -CommandLine $CommandLine -Offset $offset
        if ($null -eq $token) { break }
        $tokens += [string]$token.value
        $offset = [int]$token.next
    }
    if ($offset -lt $CommandLine.Length -and -not [string]::IsNullOrWhiteSpace($CommandLine.Substring($offset))) {
        return $null
    }
    return @($tokens)
}

$launchedPid = 0
try {
    $callerIntegrity = Get-WakeCallerIntegrity
    $script:Report.callerIntegrity = $callerIntegrity
    if ($callerIntegrity -ne 'medium') {
        Deny-Wake -Code 'caller-integrity-refused' -Detail "caller integrity is $callerIntegrity; the wake needs Medium outside an AppContainer"
    }

    try {
        $before = @(Get-WakeProcessSnapshot -MockJson $MockProcessesJson -Mocked $MOCK_PROCESSES_BOUND -Context 'mock processes')
    } catch {
        if ($MOCK_PROCESSES_BOUND) { Deny-Wake -Code 'mock-invalid' -Detail $_.Exception.Message }
        Deny-Wake -Code 'process-snapshot-failed' -Detail $_.Exception.Message
    }
    $appState = Get-WakeAppState -Processes $before
    if ($appState.stock) { Deny-Wake -Code 'stock-app-running' }
    if ($null -ne $appState.refusal) { Deny-Wake -Code $appState.refusal }
    if ($appState.roots.Count -eq 0) { Deny-Wake -Code 'app-not-running' }
    if ($appState.roots.Count -gt 1) { Deny-Wake -Code 'app-root-ambiguous' }
    $root = $appState.roots[0]
    $script:Report.rootPid = [long]$root.pid
    if (-not [string]::Equals([string]$root.executable, $hostExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
        Deny-Wake -Code 'app-root-not-intended'
    }

    $tokens = Split-WakeCommandLine -CommandLine ([string]$root.commandLine)
    if ($null -eq $tokens) { Deny-Wake -Code 'command-line-unparseable' }
    $userDataTokens = @($tokens | Where-Object { $_.StartsWith('--user-data-dir=', [System.StringComparison]::OrdinalIgnoreCase) })
    if ($userDataTokens.Count -eq 0) { Deny-Wake -Code 'user-data-dir-missing' }
    if ($userDataTokens.Count -gt 1) { Deny-Wake -Code 'user-data-dir-ambiguous' }
    $userDataValue = ([string]$userDataTokens[0]).Substring('--user-data-dir='.Length)
    $userDataDir = ConvertTo-CodexIpcNormalizedPath -Value $userDataValue
    if ($null -eq $userDataDir -or $userDataDir -match '["\x00-\x1f]' -or
        -not ($userDataDir -match '^[A-Za-z]:\\.' -or $userDataDir -match '^\\\\[^\\]+\\[^\\]+')) {
        Deny-Wake -Code 'user-data-dir-invalid'
    }
    $script:Report.userDataDir = $userDataDir
    if (-not (Test-Path -LiteralPath (Join-Path $userDataDir 'lockfile') -PathType Leaf)) {
        Deny-Wake -Code 'lockfile-missing'
    }

    $responding = $root.responding
    if (-not $MOCK_PROCESSES_BOUND) {
        try {
            $responding = [bool](Get-Process -Id ([int]$root.pid) -ErrorAction Stop).Responding
        } catch {
            $responding = $false
        }
    }
    if ($responding -ne $true) { Deny-Wake -Code 'app-not-responding' }

    # The runtime the queue route ran: the intended GUI's proven app-server, from this snapshot.
    $runtimePath = $null
    try {
        $inventory = Resolve-CodexIpcInventory -IntendedHost $intended -RawInventory ([pscustomobject][ordered]@{
            complete = $true
            packageRootsComplete = $false
            packageRoots = @()
            errors = @()
            processes = @($before)
            coverage = 'wake-snapshot'
        })
        $runtime = Get-CodexIpcIntendedRuntime -Inventory $inventory
        $script:Report.runtime = [string]$runtime.status
        if ($runtime.status -eq 'resolved') { $runtimePath = [string]$runtime.executable }
    } catch {
        $script:Report.runtime = 'not-evaluated'
    }

    $arguments = @("--user-data-dir=`"$userDataDir`"", '--single-argument', $wakeUrl)
    $argumentLine = $arguments -join ' '
    $script:Report.command = [pscustomobject][ordered]@{
        executable = $hostExecutable
        arguments = @($arguments)
        commandLine = "`"$hostExecutable`" $argumentLine"
        windowStyle = 'Hidden'
    }
    $script:Report.environment = [pscustomobject][ordered]@{
        CODEX_ELECTRON_USER_DATA_PATH = $userDataDir
        CODEX_CLI_PATH = $runtimePath
    }

    if ($DryRun -and -not $MOCK_LAUNCH_BOUND) {
        Complete-Wake -Result 'dry-run' -Code 'dry-run' -Reasons @() -Exit 0
    }

    # ---- launch ---------------------------------------------------------------------------------
    $exited = $false
    $exitCode = $null
    if ($DryRun) {
        try {
            $launch = ConvertFrom-Json -InputObject $MockLaunchJson -ErrorAction Stop
            Assert-CodexIpcObjectKeys -Object $launch -Allowed @('pid', 'exited', 'exitCode', 'startError') -Context 'mock launch'
        } catch {
            Deny-Wake -Code 'mock-invalid' -Detail $_.Exception.Message
        }
        if ((Test-CodexIpcObjectProperty -Object $launch -Name 'startError') -and $launch.startError) {
            Deny-Wake -Code 'launch-failed' -Detail ([string]$launch.startError)
        }
        $script:Report.simulated = $true
        $launchedPid = [long]$launch.pid
        $exited = [bool]$launch.exited
        if ($exited -and $null -ne $launch.exitCode) { $exitCode = [int]$launch.exitCode }
    } else {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $hostExecutable
        $startInfo.Arguments = $argumentLine
        $startInfo.WorkingDirectory = Split-Path -Parent $hostExecutable
        # CreateProcess, not ShellExecute: the exact executable and argv, the environment below,
        # and no file-association or protocol handler involvement.
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $userDataDir
        if ($null -ne $runtimePath) { $startInfo.EnvironmentVariables['CODEX_CLI_PATH'] = $runtimePath }
        try { Initialize-WakeNative; [CodexIpcWakeNative]::KeepStandardHandlesFromChildren() } catch { }
        try {
            $process = [System.Diagnostics.Process]::Start($startInfo)
        } catch {
            Deny-Wake -Code 'launch-failed' -Detail $_.Exception.Message
        }
        if ($null -eq $process) { Deny-Wake -Code 'launch-failed' -Detail 'no process was started' }
        $launchedPid = [long]$process.Id
        $script:Report.launched = $true
        $exited = $process.WaitForExit($WAKE_EXIT_TIMEOUT_MS)
        if ($exited) { $exitCode = [int]$process.ExitCode }
    }
    $script:Report.launched = $true
    $script:Report.helperPid = $launchedPid
    $script:Report.helperExited = $exited
    $script:Report.helperExitCode = $exitCode

    # ---- post-launch checks -----------------------------------------------------------------------
    $reasons = @()
    if (-not $exited) { $reasons += 'wake-launch-not-exited' }
    $afterJson = if ($MOCK_AFTER_BOUND) { $MockAfterProcessesJson } else { $MockProcessesJson }
    try {
        $after = @(Get-WakeProcessSnapshot -MockJson $afterJson -Mocked $MOCK_PROCESSES_BOUND -Context 'mock after processes')
        $afterState = Get-WakeAppState -Processes $after -ExcludePid $launchedPid
        if ($afterState.roots.Count -eq 1) { $script:Report.rootPidAfter = [long]$afterState.roots[0].pid }
        if ($afterState.roots.Count -ne 1 -or $null -ne $afterState.refusal -or
            [long]$afterState.roots[0].pid -ne [long]$root.pid) {
            $reasons += 'host-changed'
        }
        if ($afterState.stock) { $reasons += 'stock-app-running' }
    } catch {
        $reasons += 'process-snapshot-failed'
    }
    if ($exited -and $exitCode -ne 0) { $reasons += 'wake-launch-exit-nonzero' }

    if ($reasons.Count -eq 0) {
        Complete-Wake -Result 'forwarded' -Code 'wake-forwarded' -Reasons @() -Exit 0
    }
    Complete-Wake -Result 'unverified' -Code ([string]$reasons[0]) -Reasons $reasons -Exit 7
} catch {
    if ($script:Report.launched) {
        Complete-Wake -Result 'unverified' -Code 'wake-helper-error' -Reasons @('wake-helper-error') -Exit 7 -Detail $_.Exception.Message
    }
    Deny-Wake -Code 'wake-helper-error' -Detail $_.Exception.Message
}
