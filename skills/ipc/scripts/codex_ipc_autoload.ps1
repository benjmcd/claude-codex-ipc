# codex_ipc_autoload.ps1 -- load a Codex Desktop thread via the app's own deep link,
# with automatic focus snapback so the operator is never left displaced.
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
# Conservative foreground detection (positive identity, fail closed). Since the
# 2026-07-09 host merge the Codex Desktop GUI runs as ChatGPT.exe under the unchanged
# OpenAI.Codex package family, so name-only matching is insufficient in both directions:
#   provably-Codex  : process name 'codex' (pre-merge GUI, kept for backward compat), or
#                     process name 'chatgpt' whose executable path lies under
#                     WindowsApps\OpenAI.Codex_* (the merged host).
#   gated-as-Codex  : unknown/empty foreground names, or a 'chatgpt' process whose path is
#                     unreadable (elevated/protected) — ambiguous identity defers and never
#                     auto-switches (displacing an unidentified app is worse than deferring).
#   known non-Codex : everything else, including a 'chatgpt' process with a readable path
#                     outside OpenAI.Codex_* (e.g. a distinct ChatGPT-family app) — keeps
#                     the original deep-link + focus-snapback behavior unchanged.
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
param(
    [Parameter(Mandatory)][string]$ConversationId,
    [ValidateSet("defer", "restore-if-known", "switch")]
    [string]$ForegroundPolicy = "defer",
    [string]$RestoreConversationId = "",
    [switch]$AckForegroundSwitch,
    [switch]$DryRun,
    [string]$MockForegroundProcess = "",
    [string]$MockForegroundPath = "",
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

# Package-path identity for the merged host. WindowsApps package directories are
# ACL-protected (a same-user process cannot fabricate one), so a path prefix under
# WindowsApps\OpenAI.Codex_* is positive identity, not a spoofable name.
$CODEX_PKG_PATH_RE = '(?i)[\\/]WindowsApps[\\/]OpenAI\.Codex_[^\\/]+[\\/]'

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
    if ($fg.Name -match '^(?i)codex$') { return $true }
    return ($fg.Name -match '^(?i)chatgpt$') -and
           (-not [string]::IsNullOrWhiteSpace($fg.Path)) -and
           ($fg.Path -match $CODEX_PKG_PATH_RE)
}

function Test-CodexLike($fg) {
    # Provably Codex, or unidentifiable, or ambiguous ChatGPT (conservative: gate as if Codex).
    if (Test-CodexCertain $fg) { return $true }
    if ([string]::IsNullOrWhiteSpace($fg.Name) -or ($fg.Name -eq 'unknown')) { return $true }
    return ($fg.Name -match '^(?i)chatgpt$') -and [string]::IsNullOrWhiteSpace($fg.Path)
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
                Write-Output "DRYRUN: action=switch-deeplink policy=switch foreground=$fgName target=$ConversationId"
                exit 0
            }
            # Navigate the visible Codex app to the target thread. No snapback: Codex is
            # already the foreground app; the disclosed residue is that it now shows the
            # target thread.
            Start-Process "codex://threads/$ConversationId"
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

# Known non-Codex foreground: original behavior — save focus, fire deep link, snap back.
if ($DryRun) {
    Write-Output "DRYRUN: action=deeplink-snapback policy=$ForegroundPolicy foreground=$fgName target=$ConversationId"
    exit 0
}

$fg = [W]::GetForegroundWindow()
Start-Process "codex://threads/$ConversationId"

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
