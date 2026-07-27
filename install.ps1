# Standalone installer: copies skills\ipc\ to the user's Claude skills directory.
# Safe by default: -DryRun prints the exact plan; overwriting an existing install
# requires -Force; local/generated state is never copied.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$Target = (Join-Path $env:USERPROFILE ".claude\skills\ipc")
)

$ErrorActionPreference = "Stop"

$SrcRoot = Join-Path $PSScriptRoot "skills\ipc"
if (-not (Test-Path (Join-Path $SrcRoot "SKILL.md"))) {
    Write-Error "Skill source not found at `"$SrcRoot`" (run from the repo root)."
    exit 1
}

# Enumerate what would be copied: ALLOWLISTED skill source only (SKILL.md, scripts/,
# references/, examples/) — a sibling state dir (.omc/, .claude/) written into the tree
# by local tooling is never in scope. The dot-segment check is applied to the
# SrcRoot-RELATIVE path only, so a repo cloned under a dotted ancestor still installs.
$excludeNames = @("*.bak", "*.bak-*", "*.task.md", "*.reply.md", "*.log", "*.tmp")
$allowedRoots = @("SKILL.md", "scripts", "references", "examples") |
    ForEach-Object { Join-Path $SrcRoot $_ } | Where-Object { Test-Path $_ }
$files = Get-ChildItem -Path $allowedRoots -Recurse -File |
    Where-Object {
        $f = $_
        -not ($excludeNames | Where-Object { $f.Name -like $_ }) -and
        $f.FullName -notmatch '\\node_modules\\' -and
        $f.FullName -notmatch '\\\.git\\' -and
        $f.FullName.Substring($SrcRoot.Length) -notmatch '\\\.'
    } | Sort-Object FullName

if (-not $files -or $files.Count -eq 0) {
    Write-Error "Nothing to install (no files found under `"$SrcRoot`")."
    exit 1
}

Write-Output "Install plan:"
Write-Output "  source : `"$SrcRoot`""
Write-Output "  target : `"$Target`""
Write-Output "  files  : $($files.Count)"
foreach ($f in $files) {
    $rel = $f.FullName.Substring($SrcRoot.Length + 1)
    Write-Output "    copy: `"$rel`""
}

if (Test-Path -LiteralPath $Target) {
    if ($Force) {
        Write-Output "  delete (then replace): `"$Target`" and everything under it"
    } else {
        Write-Output ""
        Write-Error "Refusing to overwrite existing install at `"$Target`". Re-run with -Force to replace it (-DryRun -Force shows what is deleted)."
        exit 1
    }
}

if ($Force -and (Test-Path -LiteralPath $Target)) {
    # Canonicalize with Get-Item, NOT Resolve-Path: Resolve-Path().ProviderPath preserves
    # trailing dots/spaces and forward-slash UNC form, so the guard would compare a string
    # the deleter never uses. Not [System.IO.Path]::GetFullPath either -- it resolves a
    # relative path against the process CWD rather than the PowerShell location.
    $srcReal = (Get-Item -LiteralPath $SrcRoot -Force).FullName.TrimEnd('\', '/')
    $targetReal = (Get-Item -LiteralPath $Target -Force).FullName.TrimEnd('\', '/')
    $homeReal = (Get-Item -LiteralPath $HOME -Force).FullName.TrimEnd('\', '/')
    $targetRoot = [System.IO.Path]::GetPathRoot($targetReal).TrimEnd('\', '/')
    # Parity with uninstall.ps1: Get-Item/Resolve-Path do not resolve junctions, and this
    # block ends in Remove-Item -Recurse, which under PS 5.1 can delete a junction's TARGET
    # contents. uninstall.ps1 has refused reparse points since its guard was added; this arm
    # was missing here despite the identical destructive call.
    $isReparse = ((Get-Item -LiteralPath $targetReal -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

    # Refuse UNC outright, matching install.sh's `//*/*` arm: a UNC respelling of a local
    # path (\\localhost\c$\...) is a different string for the same directory.
    if (
        [string]::IsNullOrWhiteSpace($targetReal) -or
        $targetReal.StartsWith('\\') -or
        $isReparse -or
        $targetReal.Equals($srcReal, [System.StringComparison]::OrdinalIgnoreCase) -or
        $targetReal.StartsWith("$srcReal\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $targetReal.Equals($homeReal, [System.StringComparison]::OrdinalIgnoreCase) -or
        $targetReal.Equals($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        Write-Error "Refusing dangerous -Target `"$Target`"."
        exit 1
    }

    $sentinel = Join-Path $Target "SKILL.md"
    if (-not (Test-Path -LiteralPath $sentinel) -or -not (Select-String -LiteralPath $sentinel -Pattern '^name: ipc$' -Quiet)) {
        Write-Error "-Force refuses to delete `"$Target`": not an ipc skill install."
        exit 1
    }
}

if ($DryRun) {
    Write-Output ""
    Write-Output "Dry run: nothing was copied or deleted."
    exit 0
}

if (Test-Path -LiteralPath $Target) {
    Remove-Item -Recurse -Force -Confirm:$false -LiteralPath $Target
}
New-Item -ItemType Directory -Force -Path $Target | Out-Null
foreach ($f in $files) {
    $rel = $f.FullName.Substring($SrcRoot.Length + 1)
    $dest = Join-Path $Target $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dest
}

Write-Output ""
Write-Output "Installed $($files.Count) files to `"$Target`". Invoke as /ipc in Claude Code."
