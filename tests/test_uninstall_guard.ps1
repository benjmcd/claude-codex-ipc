# UNINSTALLER DANGEROUS-TARGET SENTINEL, PowerShell leg (hermetic; nothing is ever deleted)
#
# SENTINELED:
# - uninstall.ps1 and install.ps1 -Force refuse a target that resolves into this source tree,
#   to the user profile, to a filesystem root, or to a UNC path -- in every spelling that has
#   historically defeated the guard: case variants, backslash UNC, FORWARD-SLASH UNC, and a
#   trailing dot on either the leaf or an ancestor segment.
# - The guard does NOT over-block: the three real install roots still produce a deletion plan,
#   and an absent target still short-circuits.
#
# WHY THIS FILE EXISTS:
#   The bash leg (test_uninstall_guard.sh) has existed and passed while the PowerShell guard
#   was bypassable three separate times. The defect was never that the guard was unfixable --
#   it was that nothing tested this side. Every prior fix was verified by hand, believed
#   complete, and then broken by a spelling nobody probed.
#
# GRADING RULE (deliberate):
#   Assertions grade on EXIT CODE plus the refusal banner, never on the absence of a plan line.
#   install.ps1 prints its "delete (then replace)" line BEFORE the guard runs, so grading on
#   stdout shape alone silently mis-scores. Do not "improve" this to a stdout check.
#
# NOT COVERED (known-open, deliberately not asserted):
# - subst / net use drive-letter aliasing, and junction/symlink ancestors: these defeat every
#   string comparison in all four scripts. Closing them requires file-identity comparison
#   (volume serial + file id), not path canonicalization.
# - Invoking the script itself via an aliased path (UNC or dotted), which de-canonicalizes the
#   guard's SOURCE anchor rather than its target. Both shells are affected equally.
# Both are named in the scripts' own comments; see CHANGELOG.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$uninstall = Join-Path $root 'uninstall.ps1'
$install   = Join-Path $root 'install.ps1'

if (-not (Test-Path -LiteralPath $uninstall)) {
    Write-Output "SKIP: uninstall.ps1 not present at $uninstall (installed-skill layout)"
    exit 0
}

$script:pass = 0
$script:fail = 0
function ok($m) { Write-Output "  PASS: $m"; $script:pass++ }
function no($m) { Write-Output "  FAIL: $m"; $script:fail++ }

# Every invocation carries -DryRun. A regression that defeats the guard cannot delete here;
# it produces a plan at exit 0, which is exactly what these assertions catch.
function Invoke-Guard($script, $argList) {
    # $ErrorActionPreference='Stop' turns a native command's stderr into a TERMINATING
    # NativeCommandError, which kills this harness on the FIRST successful refusal -- the
    # guards write their refusal to stderr. Scope it to Continue for the invocation only.
    # Do not remove: without this the suite dies at assertion 1 and reports nothing.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell -NoProfile -File $script @argList 2>&1
        return @{ rc = $LASTEXITCODE; text = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Refuses($script, $argList, $label) {
    $r = Invoke-Guard $script $argList
    if ($r.rc -ne 0 -and $r.text -match 'Refusing dangerous') { ok $label }
    else { no ("$label (rc=$($r.rc))"); ($r.text -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Output "      $_" } }
}

function Allows($script, $argList, $label) {
    $r = Invoke-Guard $script $argList
    if ($r.rc -eq 0 -and $r.text -match 'Deletion plan') { ok $label }
    else { no ("$label (rc=$($r.rc))"); ($r.text -split "`n" | Select-Object -First 3) | ForEach-Object { Write-Output "      $_" } }
}

$src      = $root
$srcSkill = Join-Path $root 'skills\ipc'

Write-Output "== 1. uninstall.ps1 refuses dangerous targets =="
Refuses $uninstall @('-DryRun','-Target',$srcSkill)                                   'canonical source tree'
Refuses $uninstall @('-DryRun','-Target',$srcSkill.ToUpper())                         'upper-cased source path'
Refuses $uninstall @('-DryRun','-Target',$env:USERPROFILE)                            'user profile'
Refuses $uninstall @('-DryRun','-Target','C:\')                                       'drive root'

Write-Output "== 2. UNC spellings (bypass #3 was backslash-only) =="
# Derive the UNC forms from $srcSkill, never hardcode a path: this suite must run on a CI
# runner and on any clone, not only on the author's machine. An admin-share UNC path is not
# always reachable (it needs a local drive letter and the share enabled), so probe first and
# skip loudly rather than emit a false failure.
$uncBack = $null
if ($srcSkill -match '^([A-Za-z]):\\(.*)$') {
    $uncBack = "\\localhost\$($Matches[1])`$\$($Matches[2])"
}
if ($uncBack -and (Test-Path -LiteralPath $uncBack)) {
    $uncFwd  = $uncBack.Replace('\', '/')
    $uncIp   = $uncBack.Replace('\\localhost\', '\\127.0.0.1\')
    Refuses $uninstall @('-DryRun','-Target',$uncBack) 'backslash UNC'
    Refuses $uninstall @('-DryRun','-Target',$uncFwd)  'FORWARD-SLASH UNC'
    Refuses $uninstall @('-DryRun','-Target',$uncIp)   'UNC via 127.0.0.1'
} else {
    Write-Output "  (SKIP: admin-share UNC not reachable for $srcSkill; UNC arms not asserted here)"
}

Write-Output "== 3. trailing dot / space (Windows strips them; string compare does not) =="
Refuses $uninstall @('-DryRun','-Target',"$srcSkill.")                                'trailing dot on leaf'
Refuses $uninstall @('-DryRun','-Target',"$src.\skills\ipc")                          'trailing dot on ancestor'

Write-Output "== 4. install.ps1 -Force refuses the same set =="
Refuses $install @('-DryRun','-Force','-Target',$srcSkill)                            'install: canonical source'
Refuses $install @('-DryRun','-Force','-Target',"$srcSkill.")                         'install: trailing dot on leaf'
Refuses $install @('-DryRun','-Force','-Target',"$src.\skills\ipc")                   'install: trailing dot on ancestor'
if ($uncBack -and (Test-Path -LiteralPath $uncBack)) {
    Refuses $install @('-DryRun','-Force','-Target',$uncBack.Replace('\','/')) 'install: forward-slash UNC'
}

# install.ps1 must not over-block either. Nothing asserted this before, so a change that
# blocked a legitimate root there would have kept the suite green.
foreach ($r in @("$env:USERPROFILE\.claude\skills\ipc")) {
    if (Test-Path -LiteralPath $r) {
        $res = Invoke-Guard $install @('-DryRun','-Force','-Target',$r)
        if ($res.rc -eq 0) { ok "install: legitimate root $r not over-blocked" }
        else { no "install: legitimate root $r not over-blocked (rc=$($res.rc))" }
    }
}

Write-Output "== 5. the guard does not over-block =="
$anyRoot = $false
foreach ($r in @("$env:USERPROFILE\.claude\skills\ipc", "$env:USERPROFILE\.agents\skills\ipc", "$env:USERPROFILE\.codex\skills\ipc")) {
    if (Test-Path -LiteralPath $r) { $anyRoot = $true; Allows $uninstall @('-DryRun','-Target',$r) "installed root $r" }
}
if (-not $anyRoot) { Write-Output "  (no installed roots present; nothing to assert)" }

$absent = Join-Path $env:USERPROFILE ".claude\skills\ipc-absent-$PID"
$r = Invoke-Guard $uninstall @('-DryRun','-Target',$absent)
if ($r.rc -eq 0 -and $r.text -match 'Nothing to do') { ok 'absent target short-circuits cleanly' }
else { no "absent target short-circuits cleanly (rc=$($r.rc))" }

Write-Output ""
Write-Output "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -eq 0) { Write-Output 'ALL GREEN'; exit 0 } else { exit 1 }
