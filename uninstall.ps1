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

if (-not (Test-Path $Target)) {
    Write-Output "Nothing to do: no install at `"$Target`"."
    exit 0
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
