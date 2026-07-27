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
$srcReal  = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath.TrimEnd('\')
$tgtReal  = (Resolve-Path -LiteralPath $Target).ProviderPath.TrimEnd('\')
$homeReal = (Resolve-Path -LiteralPath $env:USERPROFILE).ProviderPath.TrimEnd('\')
$tgtRoot  = [System.IO.Path]::GetPathRoot($tgtReal).TrimEnd('\')
# Resolve-Path does NOT resolve junctions/symlinks, so a reparse point aimed into the
# source tree would otherwise pass every comparison below. PS 5.1 Remove-Item -Recurse
# on a junction can delete the TARGET's contents, so refuse reparse points outright.
$isReparse = ((Get-Item -LiteralPath $tgtReal -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
# Refuse UNC outright, matching uninstall.sh's `//*/*` arm. A UNC respelling of a local
# path (\\localhost\c$\dev\... or \\127.0.0.1\c$\...) resolves to itself, so it matches
# neither the source-prefix test nor the root test, and is not a reparse point -- it
# walked the entire guard. Refusing all UNC is correct here: every supported install
# target is a local path under the user profile.
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
