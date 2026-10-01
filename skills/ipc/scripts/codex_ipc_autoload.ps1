# codex_ipc_autoload.ps1 -- request a gated Codex Desktop thread activation through
# the package protocol, with focus handling after the shared host policy authorizes it.
# Activation is off by default and alternate intended hosts are never protocol-activated.
#
# Foreground policy (EXPERIMENTAL, wrapper-controlled):
#   defer            (default) never navigate while Codex itself is the foreground window;
#                    wait up to DeferSeconds for the operator to switch away, then give up.
#   switch           with -AckForegroundSwitch: navigate the visible Codex app to the target
#                    thread immediately (disclosed residue: Codex stays on the target thread).
#                    Without the acknowledgement: refuse (exit 5).
#   restore-if-known fail-closed this milestone (exit 4): no read-only selected-thread
#                    authority exists, so in-app thread restoration cannot be proven. A
#                    syntactically valid -RestoreConversationId is NOT proof.
#
# Host policy is shared with the wrapper. Configuration resolves per field as explicit
# parameter > environment > ${CODEX_IPC_ROOT}/host-policy.json > defaults. Every present
# layer is validated even when overridden. Before foreground handling and again immediately
# before Start-Process, activation requires a complete single-host inventory, the package
# intended host, explicit codex-uri opt-in, qualified package-update clearance, and a
# qualified effective protocol handler. Any unknown or conflicting evidence refuses.
#
# -DryRun prints a compact machine-readable action record and never calls Start-Process,
# SetForegroundWindow, or keybd_event. -MockForegroundProcess / -MockForegroundPath
# substitute the foreground process identity for hermetic tests.
#
# Exit codes:
#   0 = deep-link action permitted and completed (or dry-run equivalent)
#   1 = link fired, focus restore could not be verified
#   2 = foreground Codex (or unidentifiable foreground) deferred; nothing was fired
#   4 = restore-if-known requested but selected-thread restore authority is unproven
#   5 = switch requested without acknowledgement
#   6 = shared host/activation policy refused or was unavailable
param(
    [Parameter(Mandatory)][string]$ConversationId,
    [ValidateSet("defer", "restore-if-known", "switch")]
    [string]$ForegroundPolicy = "defer",
    [string]$RestoreConversationId = "",
    [switch]$AckForegroundSwitch,
    [switch]$DryRun,
    [string]$MockForegroundProcess = "",
    [string]$MockForegroundPath = "",
    [string]$IpcRoot = "",
    [string]$Autoload = "",
    [string]$IntendedHost = "",
    [string]$MockInventoryJson = "",
    [string]$MockPackageJson = "",
    [string]$MockRegistrationJson = "",
    [int]$DeferSeconds = 120
)

$UUID_RE = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if ($ConversationId -notmatch $UUID_RE) {
    Write-Error "ConversationId must be a UUID."
    exit 1
}
# UUID validity of a restore id is a format check only, never proof restoration is safe.
if ($RestoreConversationId -ne "" -and $RestoreConversationId -notmatch $UUID_RE) {
    Write-Error "RestoreConversationId must be a UUID when supplied."
    exit 1
}

$AUTOLOAD_BOUND = $PSBoundParameters.ContainsKey('Autoload')
$INTENDED_HOST_BOUND = $PSBoundParameters.ContainsKey('IntendedHost')
$IPC_ROOT_BOUND = $PSBoundParameters.ContainsKey('IpcRoot')
$MOCK_FOREGROUND_PROCESS_BOUND = $PSBoundParameters.ContainsKey('MockForegroundProcess')
$MOCK_FOREGROUND_PATH_BOUND = $PSBoundParameters.ContainsKey('MockForegroundPath')
$MOCK_INVENTORY_BOUND = $PSBoundParameters.ContainsKey('MockInventoryJson')
$MOCK_PACKAGE_BOUND = $PSBoundParameters.ContainsKey('MockPackageJson')
$MOCK_REGISTRATION_BOUND = $PSBoundParameters.ContainsKey('MockRegistrationJson')

if (($MOCK_FOREGROUND_PROCESS_BOUND -or $MOCK_FOREGROUND_PATH_BOUND) -and -not $DryRun) {
    Write-Error 'ACTION: host-policy-refused reason=host-policy-invalid detail=mock-inputs-require-dry-run'
    exit 6
}

$HOST_POLICY_SCRIPT = Join-Path $PSScriptRoot 'codex_ipc_host_policy.ps1'
if (-not (Test-Path -LiteralPath $HOST_POLICY_SCRIPT -PathType Leaf)) {
    Write-Error 'ACTION: host-policy-refused reason=host-policy-unavailable detail=policy-script-missing'
    exit 6
}
try {
    . $HOST_POLICY_SCRIPT
} catch {
    Write-Error 'ACTION: host-policy-refused reason=host-policy-unavailable detail=policy-load-failed'
    exit 6
}

function Get-CodexIpcActivationPolicyArguments {
    $policyArguments = @('-Purpose', 'activation')
    if ($IPC_ROOT_BOUND) { $policyArguments += @('-IpcRoot', $IpcRoot) }
    if ($AUTOLOAD_BOUND) { $policyArguments += @('-Autoload', $Autoload) }
    if ($INTENDED_HOST_BOUND) { $policyArguments += @('-IntendedHost', $IntendedHost) }
    if ($DryRun) { $policyArguments += '-DryRun' }
    if ($MOCK_INVENTORY_BOUND) { $policyArguments += @('-MockInventoryJson', $MockInventoryJson) }
    if ($MOCK_PACKAGE_BOUND) { $policyArguments += @('-MockPackageJson', $MockPackageJson) }
    if ($MOCK_REGISTRATION_BOUND) { $policyArguments += @('-MockRegistrationJson', $MockRegistrationJson) }
    return $policyArguments
}

function Invoke-CodexIpcActivationGate {
    param([string]$Phase)

    try {
        $report = Invoke-CodexIpcHostPolicyCli -Arguments (Get-CodexIpcActivationPolicyArguments)
    } catch {
        Write-Error "ACTION: host-policy-refused phase=$Phase reason=host-policy-invalid detail=configuration-or-inventory-rejected"
        return $null
    }
    if ($null -eq $report -or -not $report.ok) {
        Write-Error "ACTION: host-policy-refused phase=$Phase reason=host-policy-unavailable"
        return $null
    }
    if (-not $report.activationEligible) {
        $reasonTokens = @($report.activationReasons) + @($report.sendReasons)
        $reason = if ($reasonTokens.Count -gt 0) { [string]$reasonTokens[0] } else { 'host-policy-unavailable' }
        Write-Error "ACTION: host-policy-refused phase=$Phase reason=$reason reasons=$($reasonTokens -join ',')"
        return $null
    }
    return $report
}

$INITIAL_HOST_POLICY = Invoke-CodexIpcActivationGate -Phase 'pre-foreground'
if ($null -eq $INITIAL_HOST_POLICY) { exit 6 }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@

function Get-FgIdentity {
    if ($MockForegroundProcess -ne "") {
        return [pscustomobject]@{ Name = $MockForegroundProcess; Path = $MockForegroundPath }
    }
    $h = [W]::GetForegroundWindow(); $fgpid = 0
    [W]::GetWindowThreadProcessId($h, [ref]$fgpid) | Out-Null
    try {
        $p = Get-Process -Id $fgpid -ErrorAction Stop
        # .Path may be $null for elevated/protected processes; classification treats
        # a pathless 'chatgpt' as ambiguous (gated), never as provably non-Codex.
        [pscustomobject]@{ Name = $p.Name; Path = [string]$p.Path }
    } catch { [pscustomobject]@{ Name = "unknown"; Path = "" } }
}

function Test-CodexCertain($fg) {
    if ($fg.Name -notmatch '^(?i)(codex|chatgpt)$' -or [string]::IsNullOrWhiteSpace($fg.Path)) {
        return $false
    }
    $foregroundPath = ConvertTo-CodexIpcNormalizedPath -Value $fg.Path
    foreach ($hostEntry in @($INITIAL_HOST_POLICY.inventory.guiHosts | Where-Object { $_.matchesIntended })) {
        if ([string]::Equals(
            $foregroundPath,
            [string]$hostEntry.executable,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
}

function Test-CodexLike($fg) {
    # Provably intended host, or unidentifiable, or a GUI-like name whose path does
    # not match the shared inventory (conservative: gate as if Codex).
    if (Test-CodexCertain $fg) { return $true }
    if ([string]::IsNullOrWhiteSpace($fg.Name) -or ($fg.Name -eq 'unknown')) { return $true }
    return ($fg.Name -match '^(?i)(codex|chatgpt)$')
}

function Invoke-CodexIpcProtocolActivation {
    $freshPolicy = Invoke-CodexIpcActivationGate -Phase 'pre-activation'
    if ($null -eq $freshPolicy) { return $false }
    if ($DryRun) { return $true }

    # This is the sole executable protocol-activation site. Every caller passes
    # through a fresh shared-policy gate immediately before this statement.
    Start-Process -FilePath "codex://threads/$ConversationId"
    return $true
}

$fg = Get-FgIdentity
$fgName = $fg.Name

if (Test-CodexLike $fg) {
    switch ($ForegroundPolicy) {
        "switch" {
            if (-not $AckForegroundSwitch) {
                Write-Error "ACTION: switch-refused policy=switch foreground=$fgName reason=ack-missing"
                exit 5
            }
            if (-not (Test-CodexCertain $fg)) {
                # Unknown foreground must never be auto-switched.
                Write-Error "ACTION: defer policy=switch foreground=$fgName reason=foreground-unidentified"
                exit 2
            }
            if ($DryRun) {
                if (-not (Invoke-CodexIpcProtocolActivation)) { exit 6 }
                Write-Output "DRYRUN: action=switch-deeplink policy=switch foreground=$fgName target=$ConversationId"
                exit 0
            }
            # Navigate the visible Codex app to the target thread. No snapback: Codex is
            # already the foreground app; the disclosed residue is that it now shows the
            # target thread.
            if (-not (Invoke-CodexIpcProtocolActivation)) { exit 6 }
            exit 0
        }
        "restore-if-known" {
            # Fail-closed until a documented read-only selected-thread authority plus
            # post-restore verification exist. Applies to dry-run too: the honest answer
            # is that this path cannot be proven yet.
            Write-Error "ACTION: restore-refused policy=restore-if-known foreground=$fgName reason=selected-thread-authority-unproven"
            exit 4
        }
        default {
            # defer
            if ($DryRun) {
                Write-Output "DRYRUN: action=defer policy=defer foreground=$fgName target=$ConversationId"
                exit 2
            }
            $deferDeadline = (Get-Date).AddSeconds($DeferSeconds)
            while (Test-CodexLike (Get-FgIdentity)) {
                if ((Get-Date) -ge $deferDeadline) {
                    Write-Error "defer window expired: operator active in Codex (or foreground unidentifiable); nothing was fired"
                    exit 2
                }
                Start-Sleep -Seconds 3
            }
            # Operator switched away; fall through to the non-Codex deep-link path below.
            $fg = Get-FgIdentity
            $fgName = $fg.Name
        }
    }
}

# Non-Codex foreground: save focus, request the freshly gated deep link, then snap back.
if ($DryRun) {
    if (-not (Invoke-CodexIpcProtocolActivation)) { exit 6 }
    Write-Output "DRYRUN: action=deeplink-snapback policy=$ForegroundPolicy foreground=$fgName target=$ConversationId"
    exit 0
}

$fg = [W]::GetForegroundWindow()
if (-not (Invoke-CodexIpcProtocolActivation)) { exit 6 }

# Wait for activation to steal focus (it may not, if the app absorbs it silently).
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 4000 -and [W]::GetForegroundWindow() -eq $fg) {
    Start-Sleep -Milliseconds 50
}

# Snap focus back (alt-key unlock defeats the foreground lock), verify in a retry loop.
for ($i = 0; $i -lt 20; $i++) {
    [W]::keybd_event(0xA4, 0, 0, [UIntPtr]::Zero)
    [W]::keybd_event(0xA4, 0, 2, [UIntPtr]::Zero)
    [W]::SetForegroundWindow($fg) | Out-Null
    Start-Sleep -Milliseconds 100
    if ([W]::GetForegroundWindow() -eq $fg) { break }
}

if ([W]::GetForegroundWindow() -eq $fg) { exit 0 }
Write-Error "focus restore unverified"
exit 1
