# Standalone uninstaller: removes the ipc skill from the user's Claude skills directory.
# Safe by default: -DryRun prints the exact deletion list; real runs require -Yes
# (this script is non-interactive by design).
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [string]$Target = (Join-Path $env:USERPROFILE ".claude\skills\ipc")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Output "Nothing to do: no install at `"$Target`"."
    exit 0
}

# Resolved-path guard, mirroring install.ps1's -Force guard. The marker check below is
# NOT sufficient on its own: this repository's own skills\ipc carries `name: ipc`, so a
# marker-only uninstaller would recursively delete the canonical source tree (or a
# worktree copy) if it were named as -Target.
$ic       = [System.StringComparison]::OrdinalIgnoreCase
# Canonicalize with Get-Item, NOT Resolve-Path. Resolve-Path().ProviderPath is a weaker
# canonicalizer than the one Remove-Item acts through: it preserves trailing dots and spaces
# and preserves forward-slash UNC form. Every historical bypass of this guard was the same
# defect -- the guard compared a string the deleter would not have used. Get-Item hits the
# filesystem and collapses all of those spellings.
# NOT [System.IO.Path]::GetFullPath: that resolves a relative path against the process CWD
# rather than the PowerShell location, so a relative -Target would canonicalize against the
# wrong anchor.
$srcReal  = (Get-Item -LiteralPath $PSScriptRoot -Force).FullName.TrimEnd('\')
$tgtReal  = (Get-Item -LiteralPath $Target -Force).FullName.TrimEnd('\')
$homeReal = (Get-Item -LiteralPath $env:USERPROFILE -Force).FullName.TrimEnd('\')
$tgtRoot  = [System.IO.Path]::GetPathRoot($tgtReal).TrimEnd('\')
# Resolve-Path does NOT resolve junctions/symlinks, so a reparse point aimed into the
# source tree would otherwise pass every comparison below. PS 5.1 Remove-Item -Recurse
# on a junction can delete the TARGET's contents, so refuse reparse points outright.
$isReparse = ((Get-Item -LiteralPath $tgtReal -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
# Refuse UNC, matching uninstall.sh's `//*/*` arm. A UNC respelling of a local path
# (\\localhost\c$\dev\... or \\127.0.0.1\c$\...) is a different string for the same
# directory. Combined with the Get-Item canonicalization above this covers backslash AND
# forward-slash UNC; the earlier Resolve-Path form preserved forward slashes, so a
# `//localhost/c$/...` target walked the entire guard.
#
# KNOWN NOT CLOSED by this guard -- these defeat every string comparison here, and are
# recorded rather than implied away:
#   * subst / net use drive-letter aliasing (`subst Z: C:\dev\repo` then -Target Z:\...).
#   * A junction or symlink in an ANCESTOR directory: the reparse check below tests only
#     the target itself.
#   * Invoking THIS SCRIPT via a UNC or \\?\ path (e.g. `powershell -File
#     \\localhost\c$\...\uninstall.ps1`, or `\\?\C:\...\uninstall.ps1`). That
#     de-canonicalizes $srcReal, the guard's source ANCHOR, rather than its target, so a
#     canonical -Target stops matching the prefix test. Both measured live. A DOTTED
#     script path (`C:\dev\repo.\uninstall.ps1`) is NOT in this set -- Get-Item collapses
#     it and the guard refuses correctly. uninstall.sh is affected by the UNC form too.
# Closing these requires filesystem-identity comparison (volume serial + file id), not
# path canonicalization. Judged disproportionate for a single-user tool whose install
# targets are all local paths under the user profile.
if ($tgtReal.StartsWith('\\') -or
    $tgtReal.Equals($srcReal, $ic) -or
    $tgtReal.StartsWith($srcReal + '\', $ic) -or
    $tgtReal.Equals($homeReal, $ic) -or
    $tgtReal.Equals($tgtRoot, $ic) -or
    $isReparse -or
    [string]::IsNullOrWhiteSpace($tgtReal)) {
    Write-Error "Refusing dangerous -Target `"$Target`". It resolves inside this source tree, to the user profile, to a filesystem root, to a UNC path, or is a reparse point."
    exit 1
}

# Sanity guard: only ever delete a directory that actually looks like this skill.
$skillMd = Join-Path $Target "SKILL.md"
$looksRight = (Test-Path $skillMd) -and ((Get-Content -LiteralPath $skillMd -TotalCount 5) -contains "name: ipc")
if (-not $looksRight) {
    Write-Error "`"$Target`" does not look like an installed ipc skill (no matching SKILL.md). Refusing to delete it; remove it manually if you are sure."
    exit 1
}

Write-Output "Deletion plan (everything under the install target):"
Get-ChildItem -Path $Target -Recurse -File | Sort-Object FullName | ForEach-Object {
    Write-Output "    delete: `"$($_.FullName)`""
}
Write-Output "    delete: `"$Target`" (directory)"

if ($DryRun) {
    Write-Output ""
    Write-Output "Dry run: nothing was deleted."
    exit 0
}

if (-not $Yes) {
    Write-Error "Confirmation required: re-run with -Yes to delete, or -DryRun to preview."
    exit 1
}

Remove-Item -Recurse -Force -Confirm:$false -LiteralPath $Target
Write-Output "Removed `"$Target`"."
