# codex_ipc_host_policy.ps1 -- shared read-only Desktop host policy.
#
# The file is both a function library (dot-source it) and a JSON CLI. The CLI
# never contacts the IPC pipe, starts an application, changes registration, or
# writes configuration.

function Test-CodexIpcObjectProperty {
    param([object]$Object, [string]$Name)

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Assert-CodexIpcObjectKeys {
    param(
        [object]$Object,
        [string[]]$Allowed,
        [string]$Context
    )

    if ($Object -isnot [pscustomobject]) {
        throw "$Context must be a JSON object"
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ($Allowed -notcontains $property.Name) {
            throw "$Context has unknown key '$($property.Name)'"
        }
    }
}

function ConvertTo-CodexIpcAutoloadSetting {
    param([object]$Value, [string]$Context)

    if ($Value -isnot [string] -or ($Value -cne 'off' -and $Value -cne 'codex-uri')) {
        throw "$Context must be exactly 'off' or 'codex-uri'"
    }
    return [string]$Value
}

function ConvertTo-CodexIpcIntendedHostSetting {
    param([object]$Value, [string]$Source, [switch]$DescriptorObject)

    $kind = $null
    $executable = $null
    if ($DescriptorObject) {
        Assert-CodexIpcObjectKeys -Object $Value -Allowed @('kind', 'executable') -Context 'descriptor intendedHost'
        if (-not (Test-CodexIpcObjectProperty -Object $Value -Name 'kind') -or $Value.kind -isnot [string]) {
            throw "descriptor intendedHost kind must be 'package' or 'alternate'"
        }
        $kind = [string]$Value.kind
        $hasExecutable = Test-CodexIpcObjectProperty -Object $Value -Name 'executable'
        if ($kind -ceq 'package') {
            if ($hasExecutable) {
                throw 'descriptor intendedHost package must not include executable'
            }
        } elseif ($kind -ceq 'alternate') {
            if (-not $hasExecutable -or $Value.executable -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value.executable)) {
                throw 'descriptor intendedHost alternate requires a nonempty executable'
            }
            $executable = [string]$Value.executable
        } else {
            throw "descriptor intendedHost kind must be 'package' or 'alternate'"
        }
    } else {
        if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            throw "$Source intended host must be 'package' or an absolute executable path"
        }
        if ([string]$Value -ceq 'package') {
            $kind = 'package'
        } else {
            $kind = 'alternate'
            $executable = [string]$Value
        }
    }

    if ($kind -eq 'alternate') {
        $executable = ConvertTo-CodexIpcNormalizedPath -Value $executable
        $driveQualified = ($null -ne $executable -and $executable -match '^[A-Za-z]:\\')
        $uncQualified = ($null -ne $executable -and $executable -match '^\\\\[^\\]+\\[^\\]+(?:\\.*)?$')
        if (-not $driveQualified -and -not $uncQualified) {
            throw "$Source intended host must be 'package' or an absolute executable path"
        }
    }

    return [pscustomobject][ordered]@{
        kind = $kind
        executable = $executable
        source = $Source
    }
}

function Read-CodexIpcHostDescriptor {
    param([string]$IpcRoot)

    $descriptorPath = if ([string]::IsNullOrWhiteSpace($IpcRoot)) { $null } else { Join-Path $IpcRoot 'host-policy.json' }
    $result = [pscustomobject][ordered]@{
        path = $descriptorPath
        status = 'absent'
        hasAutoload = $false
        autoload = $null
        hasIntendedHost = $false
        intendedHost = $null
    }
    if ($null -eq $descriptorPath) {
        return $result
    }
    try {
        $descriptorExists = Test-Path -LiteralPath $descriptorPath -ErrorAction Stop
        $descriptorIsLeaf = if ($descriptorExists) {
            Test-Path -LiteralPath $descriptorPath -PathType Leaf -ErrorAction Stop
        } else {
            $false
        }
    } catch {
        throw "descriptor is unreadable: $($_.Exception.Message)"
    }
    if (-not $descriptorExists) {
        return $result
    }
    if (-not $descriptorIsLeaf) {
        throw "descriptor is unreadable: $descriptorPath"
    }

    try {
        $raw = Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        throw "descriptor is unreadable: $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'descriptor is empty'
    }
    try {
        $descriptor = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "descriptor JSON is malformed: $($_.Exception.Message)"
    }

    Assert-CodexIpcObjectKeys -Object $descriptor -Allowed @('schemaVersion', 'autoload', 'intendedHost') -Context 'descriptor'
    if (-not (Test-CodexIpcObjectProperty -Object $descriptor -Name 'schemaVersion')) {
        throw 'descriptor schemaVersion is required'
    }
    $schemaVersion = $descriptor.schemaVersion
    $schemaIsInteger = ($schemaVersion -is [int]) -or ($schemaVersion -is [long])
    if (-not $schemaIsInteger -or [long]$schemaVersion -ne 1) {
        throw 'descriptor schemaVersion must be the integer 1'
    }

    $result.status = 'loaded'
    if (Test-CodexIpcObjectProperty -Object $descriptor -Name 'autoload') {
        $result.hasAutoload = $true
        $result.autoload = ConvertTo-CodexIpcAutoloadSetting -Value $descriptor.autoload -Context 'descriptor autoload'
    }
    if (Test-CodexIpcObjectProperty -Object $descriptor -Name 'intendedHost') {
        $result.hasIntendedHost = $true
        $result.intendedHost = ConvertTo-CodexIpcIntendedHostSetting -Value $descriptor.intendedHost -Source 'descriptor' -DescriptorObject
    }
    return $result
}

function Resolve-CodexIpcHostConfiguration {
    param(
        [string]$IpcRoot,
        [bool]$FlagAutoloadPresent,
        [object]$FlagAutoload,
        [bool]$FlagIntendedHostPresent,
        [object]$FlagIntendedHost
    )

    $descriptor = Read-CodexIpcHostDescriptor -IpcRoot $IpcRoot
    $autoloadValue = 'off'
    $autoloadSource = 'default'
    $intendedHost = ConvertTo-CodexIpcIntendedHostSetting -Value 'package' -Source 'default'

    if ($descriptor.hasAutoload) {
        $autoloadValue = $descriptor.autoload
        $autoloadSource = 'descriptor'
    }
    if ($descriptor.hasIntendedHost) {
        $intendedHost = $descriptor.intendedHost
    }

    $environmentAutoload = [Environment]::GetEnvironmentVariable('CODEX_IPC_AUTOLOAD')
    if ($null -ne $environmentAutoload) {
        $environmentAutoload = ConvertTo-CodexIpcAutoloadSetting -Value $environmentAutoload -Context 'CODEX_IPC_AUTOLOAD'
        $autoloadValue = $environmentAutoload
        $autoloadSource = 'environment'
    }
    $environmentIntendedHost = [Environment]::GetEnvironmentVariable('CODEX_IPC_INTENDED_HOST')
    if ($null -ne $environmentIntendedHost) {
        $environmentIntendedHost = ConvertTo-CodexIpcIntendedHostSetting -Value $environmentIntendedHost -Source 'environment'
        $intendedHost = $environmentIntendedHost
    }

    if ($FlagAutoloadPresent) {
        $flagAutoloadValue = ConvertTo-CodexIpcAutoloadSetting -Value $FlagAutoload -Context 'flag autoload'
        $autoloadValue = $flagAutoloadValue
        $autoloadSource = 'flag'
    }
    if ($FlagIntendedHostPresent) {
        $intendedHost = ConvertTo-CodexIpcIntendedHostSetting -Value $FlagIntendedHost -Source 'flag'
    }

    return [pscustomobject][ordered]@{
        valid = $true
        autoload = [pscustomobject][ordered]@{
            value = $autoloadValue
            source = $autoloadSource
        }
        intendedHost = $intendedHost
        descriptor = [pscustomobject][ordered]@{
            path = $descriptor.path
            status = $descriptor.status
        }
    }
}

function ConvertTo-CodexIpcNormalizedPath {
    param([object]$Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return ([string]$Value).Trim().Replace('/', '\').TrimEnd('\')
}

function ConvertFrom-CodexIpcMockInventory {
    param([string]$Json)

    try {
        $mock = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "mock inventory JSON is malformed: $($_.Exception.Message)"
    }
    Assert-CodexIpcObjectKeys -Object $mock `
        -Allowed @('complete', 'packageRootsComplete', 'packageRoots', 'errors', 'processes') `
        -Context 'mock inventory'
    foreach ($required in @('complete', 'packageRootsComplete', 'packageRoots', 'errors', 'processes')) {
        if (-not (Test-CodexIpcObjectProperty -Object $mock -Name $required)) {
            throw "mock inventory requires $required"
        }
    }
    if ($mock.complete -isnot [bool] -or $mock.packageRootsComplete -isnot [bool]) {
        throw 'mock inventory completeness fields must be booleans'
    }
    if ($mock.packageRoots -isnot [System.Array] -or $mock.errors -isnot [System.Array] -or $mock.processes -isnot [System.Array]) {
        throw 'mock inventory packageRoots, errors, and processes must be arrays'
    }

    $packageRoots = @()
    foreach ($root in $mock.packageRoots) {
        $normalizedRoot = ConvertTo-CodexIpcNormalizedPath -Value $root
        if ($null -eq $normalizedRoot -or -not [System.IO.Path]::IsPathRooted($normalizedRoot)) {
            throw 'mock inventory package roots must be absolute paths'
        }
        $packageRoots += $normalizedRoot
    }
    $errors = @()
    foreach ($item in $mock.errors) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) {
            throw 'mock inventory errors must contain nonempty strings'
        }
        $errors += [string]$item
    }
    $processes = @()
    foreach ($process in $mock.processes) {
        Assert-CodexIpcObjectKeys -Object $process `
            -Allowed @('pid', 'parentPid', 'name', 'executable', 'commandLine') `
            -Context 'mock inventory process'
        foreach ($required in @('pid', 'parentPid', 'name', 'executable')) {
            if (-not (Test-CodexIpcObjectProperty -Object $process -Name $required)) {
                throw "mock inventory process requires $required"
            }
        }
        $pidIsInteger = ($process.pid -is [int]) -or ($process.pid -is [long])
        $parentIsInteger = ($process.parentPid -is [int]) -or ($process.parentPid -is [long])
        if (-not $pidIsInteger -or [long]$process.pid -le 0 -or -not $parentIsInteger -or [long]$process.parentPid -lt 0) {
            throw 'mock inventory process ids must be nonnegative integers and pid must be positive'
        }
        if ($process.name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$process.name)) {
            throw 'mock inventory process name must be a nonempty string'
        }
        if ($null -ne $process.executable -and $process.executable -isnot [string]) {
            throw 'mock inventory process executable must be a string or null'
        }
        if ((Test-CodexIpcObjectProperty -Object $process -Name 'commandLine') -and
            $null -ne $process.commandLine -and $process.commandLine -isnot [string]) {
            throw 'mock inventory process commandLine must be a string or null'
        }
        $processes += [pscustomobject][ordered]@{
            pid = [long]$process.pid
            parentPid = [long]$process.parentPid
            name = [string]$process.name
            executable = ConvertTo-CodexIpcNormalizedPath -Value $process.executable
            commandLine = if (Test-CodexIpcObjectProperty -Object $process -Name 'commandLine') {
                if ($null -eq $process.commandLine) { $null } else { [string]$process.commandLine }
            } else {
                $null
            }
        }
    }

    return [pscustomobject][ordered]@{
        complete = [bool]$mock.complete
        packageRootsComplete = [bool]$mock.packageRootsComplete
        packageRoots = @($packageRoots)
        errors = @($errors)
        processes = @($processes)
        coverage = 'mock'
    }
}

function Get-CodexIpcRawInventory {
    $errors = @()
    $processes = @()
    $processesComplete = $true
    try {
        $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        foreach ($row in $rows) {
            $processes += [pscustomobject][ordered]@{
                pid = [long]$row.ProcessId
                parentPid = [long]$row.ParentProcessId
                name = [string]$row.Name
                executable = ConvertTo-CodexIpcNormalizedPath -Value $row.ExecutablePath
                commandLine = if ($null -eq $row.CommandLine) { $null } else { [string]$row.CommandLine }
            }
        }
    } catch {
        $processesComplete = $false
        $errors += "process-enumeration:$($_.Exception.Message)"
    }

    $packageRoots = @()
    $packageRootsComplete = $true
    try {
        if ($null -eq (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
            throw 'Get-AppxPackage is unavailable'
        }
        foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
            $root = ConvertTo-CodexIpcNormalizedPath -Value $package.InstallLocation
            if ($null -ne $root) { $packageRoots += $root }
        }
    } catch {
        $packageRootsComplete = $false
        $errors += "package-enumeration:$($_.Exception.Message)"
    }

    return [pscustomobject][ordered]@{
        complete = $processesComplete
        packageRootsComplete = $packageRootsComplete
        packageRoots = @($packageRoots)
        errors = @($errors)
        processes = @($processes)
        coverage = 'win32-process-current-user-appx'
    }
}

function Test-CodexIpcPathWithinRoot {
    param([string]$Path, [string]$Root)

    if ($null -eq $Path -or $null -eq $Root) { return $false }
    $prefix = $Root.TrimEnd('\') + '\'
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CodexIpcCandidateProcess {
    param(
        [object]$Process,
        [object]$IntendedHost,
        [string[]]$PackageRoots,
        [bool]$PackageRootsComplete
    )

    $name = ([string]$Process.name).ToLowerInvariant()
    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    if ($name -eq 'chatgpt.exe' -or $name -eq 'codex.exe' -or $name -eq 'chatgpt' -or $name -eq 'codex') {
        return $true
    }
    foreach ($root in $PackageRoots) {
        if (Test-CodexIpcPathWithinRoot -Path $path -Root $root) { return $true }
    }
    if (-not $PackageRootsComplete -and $null -ne $path -and
        $path -match '(?i)^[a-z]:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]+\\') {
        return $true
    }
    if ($IntendedHost.kind -eq 'alternate') {
        $intendedName = [System.IO.Path]::GetFileName([string]$IntendedHost.executable).ToLowerInvariant()
        if ($name -eq $intendedName) { return $true }
        if ($null -ne $path -and [string]::Equals(
            $path,
            [string]$IntendedHost.executable,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
}

function Get-CodexIpcHostClassification {
    param(
        [object]$Process,
        [object]$IntendedHost,
        [string[]]$PackageRoots,
        [bool]$PackageRootsComplete
    )

    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    if ($null -eq $path) { return 'unknown' }
    if ($IntendedHost.kind -eq 'alternate' -and [string]::Equals(
        $path,
        [string]$IntendedHost.executable,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return 'alternate'
    }
    foreach ($root in $PackageRoots) {
        if (Test-CodexIpcPathWithinRoot -Path $path -Root $root) { return 'package' }
    }
    if (-not $PackageRootsComplete -and $path -match '(?i)^[a-z]:\\Program Files\\WindowsApps\\OpenAI\.Codex_[^\\]+\\') {
        return 'unknown'
    }
    return 'other'
}

function Test-CodexIpcCandidateDescendant {
    param(
        [object]$Process,
        [hashtable]$ProcessById,
        [hashtable]$CandidateById
    )

    $seen = @{}
    $parentId = [long]$Process.parentPid
    while ($parentId -gt 0 -and -not $seen.ContainsKey([string]$parentId)) {
        $seen[[string]$parentId] = $true
        if ($CandidateById.ContainsKey([string]$parentId)) { return $true }
        if (-not $ProcessById.ContainsKey([string]$parentId)) { return $false }
        $parentId = [long]$ProcessById[[string]$parentId].parentPid
    }
    return $false
}

function Test-CodexIpcSameExecutableCandidateAncestor {
    param(
        [object]$Process,
        [hashtable]$ProcessById,
        [hashtable]$CandidateById
    )

    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    if ($null -eq $path) { return $false }

    $seen = @{}
    $parentId = [long]$Process.parentPid
    while ($parentId -gt 0 -and -not $seen.ContainsKey([string]$parentId)) {
        $seen[[string]$parentId] = $true
        if ($CandidateById.ContainsKey([string]$parentId)) {
            $ancestorPath = ConvertTo-CodexIpcNormalizedPath -Value $CandidateById[[string]$parentId].executable
            if ($null -ne $ancestorPath -and [string]::Equals(
                $path,
                $ancestorPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                return $true
            }
        }
        if (-not $ProcessById.ContainsKey([string]$parentId)) { return $false }
        $parentId = [long]$ProcessById[[string]$parentId].parentPid
    }
    return $false
}

function Read-CodexIpcCommandToken {
    param([string]$CommandLine, [int]$Offset = 0)

    # Read only the prefix needed for executable, global config pairs, and role.
    $cursor = $Offset
    while ($cursor -lt $CommandLine.Length -and $CommandLine[$cursor] -in @(' ', "`t")) { $cursor++ }
    if ($cursor -ge $CommandLine.Length) { return $null }
    $value = New-Object System.Text.StringBuilder
    $quoted = $false
    while ($cursor -lt $CommandLine.Length) {
        $character = $CommandLine[$cursor]
        if (-not $quoted -and $character -in @(' ', "`t")) { break }
        if ($character -eq '\') {
            $start = $cursor
            while ($cursor -lt $CommandLine.Length -and $CommandLine[$cursor] -eq '\') { $cursor++ }
            $count = $cursor - $start
            if ($cursor -lt $CommandLine.Length -and $CommandLine[$cursor] -eq '"') {
                [void]$value.Append(('\' * [int][math]::Floor($count / 2)))
                if ($count % 2 -eq 1) { [void]$value.Append('"') } else { $quoted = -not $quoted }
                $cursor++
            } else {
                [void]$value.Append(('\' * $count))
            }
        } elseif ($character -eq '"') {
            $quoted = -not $quoted
            $cursor++
        } else {
            [void]$value.Append($character)
            $cursor++
        }
    }
    if ($quoted) { return $null }
    return [pscustomobject]@{ value = $value.ToString(); next = $cursor }
}

function Test-CodexIpcCommandExecutable {
    param([string]$Token, [string]$Path)

    $normalized = ConvertTo-CodexIpcNormalizedPath -Value $Token
    return ($null -ne $normalized -and $null -ne $Path -and (
        [string]::Equals($normalized, $Path, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($normalized, [System.IO.Path]::GetFileName($Path), [System.StringComparison]::OrdinalIgnoreCase)
    ))
}

function Get-CodexIpcNativeRole {
    param([object]$Process)

    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    if ($Process.commandLine -isnot [string] -or $null -eq $path) { return $null }
    $token = Read-CodexIpcCommandToken -CommandLine $Process.commandLine
    if ($null -eq $token -or -not (Test-CodexIpcCommandExecutable -Token $token.value -Path $path)) { return $null }
    $token = Read-CodexIpcCommandToken -CommandLine $Process.commandLine -Offset $token.next
    while ($null -ne $token -and $token.value -cin @('-c', '--config')) {
        $value = Read-CodexIpcCommandToken -CommandLine $Process.commandLine -Offset $token.next
        if ($null -eq $value -or $value.value -notmatch '^[^=\s]+=.+$') { return $null }
        $token = Read-CodexIpcCommandToken -CommandLine $Process.commandLine -Offset $value.next
    }
    if ($null -ne $token -and $token.value -cin @('app-server', 'exec-server', 'sandbox')) { return $token.value }
    return $null
}

function Test-CodexIpcGuiAnchor {
    param([object]$Process, [object]$IntendedHost, [object]$RawInventory)

    $classification = Get-CodexIpcHostClassification -Process $Process -IntendedHost $IntendedHost -PackageRoots @($RawInventory.packageRoots) -PackageRootsComplete ([bool]$RawInventory.packageRootsComplete)
    if ($classification -ne $IntendedHost.kind) { return $false }
    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    $token = Read-CodexIpcCommandToken -CommandLine ([string]$Process.commandLine)
    if ($null -eq $token -or -not (Test-CodexIpcCommandExecutable -Token $token.value -Path $path)) { return $false }
    if ($path -match '(?i)\\resources\\codex(?:\.exe)?$' -or
        $null -ne (Get-CodexIpcNativeRole -Process $Process) -or
        [string]$Process.commandLine -match '(?i)(^|\s)--type(?:=|\s)') { return $false }
    if ($classification -eq 'alternate') {
        return ([System.IO.Path]::GetFileName($path) -notin @('codex', 'codex.exe'))
    }
    foreach ($root in @($RawInventory.packageRoots)) {
        if ([string]::Equals($path, "$root\app\ChatGPT.exe", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CodexIpcRuntimeAncestry {
    param([object]$Process, [hashtable]$ProcessById, [hashtable]$CandidateById,
        [hashtable]$NativeRoleById, [hashtable]$GuiById, [hashtable]$RuntimeByGuiId)

    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    $seen = @{ ([string]$Process.pid) = $true }
    $parentId = [long]$Process.parentPid
    while ($parentId -gt 0) {
        $key = [string]$parentId
        if ($seen.ContainsKey($key) -or -not $ProcessById.ContainsKey($key)) { return $false }
        $seen[$key] = $true
        if ($GuiById.ContainsKey($key)) {
            return ($RuntimeByGuiId.ContainsKey($key) -and [string]::Equals(
                $path, [string]$RuntimeByGuiId[$key], [System.StringComparison]::OrdinalIgnoreCase))
        }
        $ancestor = $ProcessById[$key]
        if ($null -eq $ancestor.executable -or [string]::IsNullOrWhiteSpace([string]$ancestor.commandLine)) { return $false }
        if ($CandidateById.ContainsKey($key) -and (
            -not $NativeRoleById.ContainsKey($key) -or -not [string]::Equals(
                $path, [string]$ancestor.executable, [System.StringComparison]::OrdinalIgnoreCase))) { return $false }
        $parentId = [long]$ancestor.parentPid
    }
    return $false
}

function Test-CodexIpcElectronAncestry {
    param([object]$Process, [hashtable]$ProcessById, [hashtable]$GuiById)

    $path = ConvertTo-CodexIpcNormalizedPath -Value $Process.executable
    if ($null -eq $path) { return $false }
    $seen = @{ ([string]$Process.pid) = $true }
    $parentId = [long]$Process.parentPid
    while ($parentId -gt 0) {
        $key = [string]$parentId
        if ($seen.ContainsKey($key) -or -not $ProcessById.ContainsKey($key)) { return $false }
        $seen[$key] = $true
        $ancestor = $ProcessById[$key]
        $ancestorPath = ConvertTo-CodexIpcNormalizedPath -Value $ancestor.executable
        if ($null -eq $ancestorPath -or [string]::IsNullOrWhiteSpace([string]$ancestor.commandLine) -or
            -not [string]::Equals($path, $ancestorPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($GuiById.ContainsKey($key)) { return $true }
        $token = Read-CodexIpcCommandToken -CommandLine ([string]$ancestor.commandLine)
        if ($null -eq $token -or -not (Test-CodexIpcCommandExecutable -Token $token.value -Path $ancestorPath) -or
            [string]$ancestor.commandLine -notmatch '(?i)(^|\s)--type(?:=|\s)') { return $false }
        $parentId = [long]$ancestor.parentPid
    }
    return $false
}

function Resolve-CodexIpcInventory {
    param([object]$RawInventory, [object]$IntendedHost)

    $processById = @{}
    $candidateById = @{}
    foreach ($process in @($RawInventory.processes)) {
        $processById[[string]$process.pid] = $process
        if (Test-CodexIpcCandidateProcess `
            -Process $process `
            -IntendedHost $IntendedHost `
            -PackageRoots @($RawInventory.packageRoots) `
            -PackageRootsComplete ([bool]$RawInventory.packageRootsComplete)) {
            $candidateById[[string]$process.pid] = $process
        }
    }

    $nativeRoleById = @{}
    $guiById = @{}
    $runtimeByGuiId = @{}
    foreach ($process in @($RawInventory.processes)) {
        if (-not $candidateById.ContainsKey([string]$process.pid)) { continue }
        if ([string]$process.name -in @('codex', 'codex.exe')) {
            $role = Get-CodexIpcNativeRole -Process $process
            if ($null -ne $role) { $nativeRoleById[[string]$process.pid] = $role }
        }
        if (Test-CodexIpcGuiAnchor -Process $process -IntendedHost $IntendedHost -RawInventory $RawInventory) {
            $guiById[[string]$process.pid] = $process
        }
    }
    foreach ($process in @($RawInventory.processes)) {
        $parentKey = [string]$process.parentPid
        if ($nativeRoleById[[string]$process.pid] -eq 'app-server' -and $guiById.ContainsKey($parentKey)) {
            $path = ConvertTo-CodexIpcNormalizedPath -Value $process.executable
            if ($runtimeByGuiId.ContainsKey($parentKey) -and -not [string]::Equals(
                [string]$runtimeByGuiId[$parentKey], $path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $runtimeByGuiId[$parentKey] = ''
            } else { $runtimeByGuiId[$parentKey] = $path }
        }
    }

    $guiHosts = @()
    $appServers = @()
    $complete = [bool]$RawInventory.complete
    $errors = @($RawInventory.errors)
    foreach ($process in @($RawInventory.processes)) {
        if (-not $candidateById.ContainsKey([string]$process.pid)) { continue }
        $classification = Get-CodexIpcHostClassification `
            -Process $process `
            -IntendedHost $IntendedHost `
            -PackageRoots @($RawInventory.packageRoots) `
            -PackageRootsComplete ([bool]$RawInventory.packageRootsComplete)
        $matchesIntended = ($IntendedHost.kind -eq $classification)
        $entry = [pscustomobject][ordered]@{
            pid = [long]$process.pid
            parentPid = [long]$process.parentPid
            name = [string]$process.name
            executable = $process.executable
            classification = $classification
            matchesIntended = $matchesIntended
        }
        $path = ConvertTo-CodexIpcNormalizedPath -Value $process.executable
        $isDescendant = Test-CodexIpcCandidateDescendant `
            -Process $process -ProcessById $processById -CandidateById $candidateById
        $hasProvenNativeRole = ($nativeRoleById.ContainsKey([string]$process.pid) -and
            (Test-CodexIpcRuntimeAncestry -Process $process -ProcessById $processById -CandidateById $candidateById -NativeRoleById $nativeRoleById -GuiById $guiById -RuntimeByGuiId $runtimeByGuiId))
        $commandToken = Read-CodexIpcCommandToken -CommandLine ([string]$process.commandLine)
        $hasProvenElectronRole = (
            $matchesIntended -and
            ($path -notmatch '(?i)\\resources\\codex(?:\.exe)?$') -and
            (Test-CodexIpcElectronAncestry -Process $process -ProcessById $processById -GuiById $guiById) -and
            $null -ne $commandToken -and (Test-CodexIpcCommandExecutable -Token $commandToken.value -Path $path) -and
            $process.commandLine -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$process.commandLine) -and
            [string]$process.commandLine -match '(?i)(^|\s)--type(?:=|\s)'
        )
        if ($hasProvenNativeRole -or $hasProvenElectronRole) {
            $appServers += $entry
        } else {
            if (($null -ne $path -and (
                    $path -match '(?i)\\resources\\codex(?:\.exe)?$' -or
                    [System.IO.Path]::GetFileName($path) -in @('codex', 'codex.exe'))) -or
                [string]$process.commandLine -match '(?i)(^|\s)--type(?:=|\s)' -or
                $null -ne (Get-CodexIpcNativeRole -Process $process)) {
                # Unproven backend and typed child evidence cannot establish an intended GUI.
                $entry.matchesIntended = $false
            }
            $guiHosts += $entry
        }
        if ($isDescendant -and -not $hasProvenNativeRole -and -not $hasProvenElectronRole -and
            $null -eq $process.commandLine -and
            (Test-CodexIpcSameExecutableCandidateAncestor `
                -Process $process -ProcessById $processById -CandidateById $candidateById)) {
            $complete = $false
            $errors += "candidate-role-unreadable:$($process.pid)"
        }
        if ($classification -eq 'unknown') {
            $complete = $false
            $errors += "candidate-identity-unreadable:$($process.pid)"
        }
    }

    return [pscustomobject][ordered]@{
        complete = $complete
        coverage = [string]$RawInventory.coverage
        errors = @($errors)
        packageRootsComplete = [bool]$RawInventory.packageRootsComplete
        packageRoots = @($RawInventory.packageRoots)
        guiHosts = @($guiHosts)
        appServers = @($appServers)
    }
}

function Get-CodexIpcSendDecision {
    param([object]$Inventory)

    $reasons = @()
    $intendedCount = @($Inventory.guiHosts | Where-Object { $_.matchesIntended }).Count
    $otherCount = @($Inventory.guiHosts | Where-Object { -not $_.matchesIntended }).Count
    if (-not $Inventory.complete) { $reasons += 'host-inventory-incomplete' }
    if ($intendedCount -eq 0) { $reasons += 'intended-host-not-running' }
    if ($otherCount -gt 0 -or $intendedCount -gt 1) { $reasons += 'other-desktop-host-running' }
    return [pscustomobject][ordered]@{
        eligible = ($Inventory.complete -and $intendedCount -eq 1 -and $otherCount -eq 0)
        reasons = @($reasons)
    }
}

function ConvertFrom-CodexIpcMockPackageState {
    param([string]$Json)

    try {
        $mock = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "mock package JSON is malformed: $($_.Exception.Message)"
    }
    Assert-CodexIpcObjectKeys -Object $mock `
        -Allowed @('state', 'runningPackageFullName', 'runningVersion', 'installLocation', 'higherVersions', 'evidence') `
        -Context 'mock package state'
    foreach ($required in @('state', 'runningPackageFullName', 'runningVersion', 'higherVersions', 'evidence')) {
        if (-not (Test-CodexIpcObjectProperty -Object $mock -Name $required)) {
            throw "mock package state requires $required"
        }
    }
    if ($mock.state -isnot [string] -or @('clear', 'staged', 'unknown') -notcontains [string]$mock.state) {
        throw "mock package state must be 'clear', 'staged', or 'unknown'"
    }
    if ($mock.higherVersions -isnot [System.Array]) {
        throw 'mock package higherVersions must be an array'
    }
    $higherVersions = @()
    foreach ($versionText in $mock.higherVersions) {
        $parsedVersion = $null
        if ($versionText -isnot [string] -or -not [version]::TryParse([string]$versionText, [ref]$parsedVersion)) {
            throw 'mock package higherVersions must contain version strings'
        }
        $higherVersions += [string]$parsedVersion
    }
    if ($mock.state -eq 'clear' -or $mock.state -eq 'staged') {
        $runningVersion = $null
        if ($mock.runningPackageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$mock.runningPackageFullName) -or
            $mock.runningVersion -isnot [string] -or -not [version]::TryParse([string]$mock.runningVersion, [ref]$runningVersion)) {
            throw 'mock package clear/staged state requires running package identity and version'
        }
        if ($mock.state -eq 'clear' -and $higherVersions.Count -ne 0) {
            throw 'mock package clear state cannot include higherVersions'
        }
        if ($mock.state -eq 'staged' -and $higherVersions.Count -eq 0) {
            throw 'mock package staged state requires higherVersions'
        }
    }
    if ($mock.evidence -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$mock.evidence)) {
        throw 'mock package evidence must be a nonempty string'
    }

    return [pscustomobject][ordered]@{
        state = [string]$mock.state
        runningPackageFullName = if ($null -eq $mock.runningPackageFullName) { $null } else { [string]$mock.runningPackageFullName }
        runningVersion = if ($null -eq $mock.runningVersion) { $null } else { [string]$mock.runningVersion }
        installLocation = if (Test-CodexIpcObjectProperty -Object $mock -Name 'installLocation') { ConvertTo-CodexIpcNormalizedPath -Value $mock.installLocation } else { $null }
        higherVersions = @($higherVersions)
        evidence = [string]$mock.evidence
    }
}

function ConvertFrom-CodexIpcMockRegistration {
    param([string]$Json)

    try {
        $mock = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "mock registration JSON is malformed: $($_.Exception.Message)"
    }
    Assert-CodexIpcObjectKeys -Object $mock `
        -Allowed @('state', 'handler', 'packageFullName', 'evidence') `
        -Context 'mock registration'
    foreach ($required in @('state', 'handler', 'packageFullName', 'evidence')) {
        if (-not (Test-CodexIpcObjectProperty -Object $mock -Name $required)) {
            throw "mock registration requires $required"
        }
    }
    if ($mock.state -isnot [string] -or @('matches', 'conflicting', 'unknown') -notcontains [string]$mock.state) {
        throw "mock registration state must be 'matches', 'conflicting', or 'unknown'"
    }
    if (($mock.state -eq 'matches' -or $mock.state -eq 'conflicting') -and
        ($mock.handler -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$mock.handler))) {
        throw 'mock registration matches/conflicting state requires handler'
    }
    if ($mock.state -eq 'matches' -and
        ($mock.packageFullName -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$mock.packageFullName))) {
        throw 'mock registration matches state requires packageFullName'
    }
    if ($mock.evidence -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$mock.evidence)) {
        throw 'mock registration evidence must be a nonempty string'
    }
    return [pscustomobject][ordered]@{
        state = [string]$mock.state
        handler = if ($null -eq $mock.handler) { $null } else { [string]$mock.handler }
        packageFullName = if ($null -eq $mock.packageFullName) { $null } else { [string]$mock.packageFullName }
        evidence = [string]$mock.evidence
    }
}

function New-CodexIpcUncheckedPackageState {
    return [pscustomobject][ordered]@{
        state = 'not-checked'
        runningPackageFullName = $null
        runningVersion = $null
        installLocation = $null
        higherVersions = @()
        evidence = 'not-checked'
    }
}

function New-CodexIpcUncheckedRegistration {
    return [pscustomobject][ordered]@{
        state = 'not-checked'
        handler = $null
        packageFullName = $null
        evidence = 'not-checked'
    }
}

function Get-CodexIpcPackageState {
    param([object]$Inventory)

    try {
        $guiHost = @($Inventory.guiHosts | Where-Object { $_.matchesIntended }) | Select-Object -First 1
        if ($null -eq $guiHost -or [string]::IsNullOrWhiteSpace([string]$guiHost.executable)) {
            throw 'running package host executable is unavailable'
        }
        $matchingPackages = @()
        foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
            $root = ConvertTo-CodexIpcNormalizedPath -Value $package.InstallLocation
            if ($null -ne $root -and (Test-CodexIpcPathWithinRoot -Path $guiHost.executable -Root $root)) {
                $matchingPackages += $package
            }
        }
        if ($matchingPackages.Count -ne 1) {
            throw "running package identity count was $($matchingPackages.Count), expected 1"
        }
        $runningPackage = $matchingPackages[0]
        $runningVersion = [version]$runningPackage.Version
        $installLocation = ConvertTo-CodexIpcNormalizedPath -Value $runningPackage.InstallLocation
        $expectedGui = ConvertTo-CodexIpcNormalizedPath -Value (Join-Path $installLocation 'app\ChatGPT.exe')
        if (-not [string]::Equals(
                [string]$guiHost.executable,
                [string]$expectedGui,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'running package host is not the registered protocol executable'
        }
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
                Id = 400
            } -MaxEvents 300 -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        }

        $packagePattern = 'Package ' + [Regex]::Escape([string]$runningPackage.Name) + '_(?<v>\d+(?:\.\d+){3})_'
        $operationPattern = 'Deployment (?<operation>Stage|DeStage|Register) operation'
        $latestOperation = @{}
        foreach ($entry in @($events | Sort-Object TimeCreated -Descending)) {
            if ($entry.Message -notmatch $packagePattern) { continue }
            $candidateVersion = [version]$Matches.v
            if ($candidateVersion -le $runningVersion -or $latestOperation.ContainsKey([string]$candidateVersion)) { continue }
            if ($entry.Message -match $operationPattern) {
                $latestOperation[[string]$candidateVersion] = $Matches.operation
            }
        }
        $higherVersions = @($latestOperation.Keys | Sort-Object { [version]$_ })
        $pending = @($higherVersions | Where-Object { $latestOperation[$_] -eq 'Stage' })
        # Event 400 can positively identify a still-latest Stage operation. Its
        # absence cannot establish that a circular, cleared, localized, capped,
        # or otherwise incomplete log contains every relevant transition.
        # Until a qualified current-state reader supplies positive clearance,
        # no event-history-only path may return 'clear'.
        $state = if ($pending.Count -gt 0) { 'staged' } else { 'unknown' }
        return [pscustomobject][ordered]@{
            state = $state
            runningPackageFullName = [string]$runningPackage.PackageFullName
            runningVersion = [string]$runningVersion
            installLocation = $installLocation
            higherVersions = @($pending)
            evidence = if ($state -eq 'staged') {
                'appx-event-log-400-stage'
            } else {
                'appx-event-log-400-insufficient-for-clearance'
            }
        }
    } catch {
        return [pscustomobject][ordered]@{
            state = 'unknown'
            runningPackageFullName = $null
            runningVersion = $null
            installLocation = $null
            higherVersions = @()
            evidence = "package-query-error:$($_.Exception.Message)"
        }
    }
}

function Get-CodexIpcProtocolRegistration {
    param([object]$PackageState)

    if ([string]::IsNullOrWhiteSpace([string]$PackageState.runningPackageFullName)) {
        return [pscustomobject][ordered]@{
            state = 'unknown'; handler = $null; packageFullName = $null; evidence = 'package-identity-unavailable'
        }
    }
    # Candidate registry metadata cannot qualify the effective handler.
    return [pscustomobject][ordered]@{
        state = 'unknown'; handler = $null
        packageFullName = [string]$PackageState.runningPackageFullName
        evidence = 'effective-handler-unqualified'
    }
}

function Get-CodexIpcActivationDecision {
    param(
        [bool]$SendEligible,
        [object]$Configuration,
        [object]$PackageState,
        [object]$Registration
    )

    $reasons = @()
    if (-not $SendEligible) {
        $reasons += 'send-ineligible'
    } elseif ($Configuration.autoload.value -ne 'codex-uri') {
        $reasons += 'autoload-disabled'
    } elseif ($Configuration.intendedHost.kind -ne 'package') {
        $reasons += 'protocol-host-not-package'
    } else {
        $registrationMatchesPackage = (
            $Registration.state -eq 'matches' -and
            -not [string]::IsNullOrWhiteSpace([string]$PackageState.runningPackageFullName) -and
            [string]::Equals(
                [string]$Registration.packageFullName,
                [string]$PackageState.runningPackageFullName,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
        if (-not $registrationMatchesPackage) { $reasons += 'protocol-registration-unproven' }
        if ($PackageState.state -eq 'staged') {
            $reasons += 'package-update-staged'
        } elseif ($PackageState.state -ne 'clear') {
            $reasons += 'package-update-unknown'
        }
    }
    return [pscustomobject][ordered]@{
        eligible = ($reasons.Count -eq 0)
        reasons = @($reasons)
    }
}

function Invoke-CodexIpcHostPolicyCli {
    param([object[]]$Arguments)

    $purpose = 'send'
    $ipcRoot = ''
    $purposePresent = $false
    $ipcRootPresent = $false
    $flagAutoloadPresent = $false
    $flagAutoload = $null
    $flagIntendedHostPresent = $false
    $flagIntendedHost = $null
    $dryRun = $false
    $dryRunPresent = $false
    $mockInventoryPresent = $false
    $mockInventoryJson = $null
    $mockPackagePresent = $false
    $mockPackageJson = $null
    $mockRegistrationPresent = $false
    $mockRegistrationJson = $null
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        switch ($argument) {
            '-Purpose' {
                if ($purposePresent) { throw '-Purpose may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-Purpose requires a value' }
                $purpose = [string]$Arguments[$index]
                $purposePresent = $true
            }
            '-IpcRoot' {
                if ($ipcRootPresent) { throw '-IpcRoot may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-IpcRoot requires a value' }
                $ipcRoot = [string]$Arguments[$index]
                $ipcRootPresent = $true
            }
            '-Autoload' {
                if ($flagAutoloadPresent) { throw '-Autoload may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-Autoload requires a value' }
                $flagAutoload = [string]$Arguments[$index]
                $flagAutoloadPresent = $true
            }
            '-IntendedHost' {
                if ($flagIntendedHostPresent) { throw '-IntendedHost may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-IntendedHost requires a value' }
                $flagIntendedHost = [string]$Arguments[$index]
                $flagIntendedHostPresent = $true
            }
            '-DryRun' {
                if ($dryRunPresent) { throw '-DryRun may be supplied only once' }
                $dryRun = $true
                $dryRunPresent = $true
            }
            '-MockInventoryJson' {
                if ($mockInventoryPresent) { throw '-MockInventoryJson may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-MockInventoryJson requires a value' }
                $mockInventoryJson = [string]$Arguments[$index]
                $mockInventoryPresent = $true
            }
            '-MockPackageJson' {
                if ($mockPackagePresent) { throw '-MockPackageJson may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-MockPackageJson requires a value' }
                $mockPackageJson = [string]$Arguments[$index]
                $mockPackagePresent = $true
            }
            '-MockRegistrationJson' {
                if ($mockRegistrationPresent) { throw '-MockRegistrationJson may be supplied only once' }
                $index += 1
                if ($index -ge $Arguments.Count) { throw '-MockRegistrationJson requires a value' }
                $mockRegistrationJson = [string]$Arguments[$index]
                $mockRegistrationPresent = $true
            }
            default { throw "unknown argument: $argument" }
        }
    }

    if ($purpose -ne 'configuration' -and $purpose -ne 'send' -and $purpose -ne 'activation') {
        throw "unsupported purpose: $purpose"
    }
    if (($mockInventoryPresent -or $mockPackagePresent -or $mockRegistrationPresent) -and -not $dryRun) {
        throw 'mock inputs require -DryRun'
    }
    if ($purpose -eq 'configuration' -and ($dryRunPresent -or $mockInventoryPresent -or $mockPackagePresent -or $mockRegistrationPresent)) {
        throw 'configuration purpose does not accept inventory inputs'
    }
    if ($purpose -ne 'activation' -and ($mockPackagePresent -or $mockRegistrationPresent)) {
        throw 'package and registration mocks require activation purpose'
    }
    if ($purpose -eq 'activation' -and $dryRun -and ($mockPackagePresent -xor $mockRegistrationPresent)) {
        throw 'DryRun activation mocks require both package and registration inputs'
    }

    if (-not $ipcRootPresent) {
        $environmentRoot = [Environment]::GetEnvironmentVariable('CODEX_IPC_ROOT')
        if (-not [string]::IsNullOrEmpty($environmentRoot)) {
            $ipcRoot = $environmentRoot
        } else {
            $userHome = [Environment]::GetEnvironmentVariable('USERPROFILE')
            if ([string]::IsNullOrEmpty($userHome)) {
                $userHome = [Environment]::GetEnvironmentVariable('HOME')
            }
            if ([string]::IsNullOrWhiteSpace($userHome)) {
                throw 'IPC root cannot be resolved without HOME or USERPROFILE'
            }
            $ipcRoot = Join-Path (Join-Path $userHome '.claude') 'ipc'
        }
    }
    if ([string]::IsNullOrWhiteSpace($ipcRoot)) {
        throw 'IPC root must be nonempty'
    }
    $configuration = Resolve-CodexIpcHostConfiguration `
        -IpcRoot $ipcRoot `
        -FlagAutoloadPresent $flagAutoloadPresent `
        -FlagAutoload $flagAutoload `
        -FlagIntendedHostPresent $flagIntendedHostPresent `
        -FlagIntendedHost $flagIntendedHost

    $inventory = $null
    $sendDecision = $null
    $sendEligible = $null
    $sendReasons = @()
    $activationEligible = $null
    $activationReasons = @()
    if ($purpose -eq 'send' -or $purpose -eq 'activation') {
        $rawInventory = if ($mockInventoryPresent) {
            ConvertFrom-CodexIpcMockInventory -Json $mockInventoryJson
        } else {
            Get-CodexIpcRawInventory
        }
        $inventory = Resolve-CodexIpcInventory `
            -RawInventory $rawInventory `
            -IntendedHost $configuration.intendedHost
        $sendDecision = Get-CodexIpcSendDecision -Inventory $inventory
        $sendEligible = [bool]$sendDecision.eligible
        $sendReasons = @($sendDecision.reasons)
        if ($purpose -eq 'send') {
            $activationEligible = $false
            $activationReasons = @('activation-not-evaluated')
        }
    }

    $packageState = $null
    $registration = $null
    if ($purpose -eq 'activation') {
        $packageState = New-CodexIpcUncheckedPackageState
        $registration = New-CodexIpcUncheckedRegistration
        if ($mockPackagePresent) {
            $packageState = ConvertFrom-CodexIpcMockPackageState -Json $mockPackageJson
            $registration = ConvertFrom-CodexIpcMockRegistration -Json $mockRegistrationJson
        } elseif ($sendEligible -and $configuration.autoload.value -eq 'codex-uri' -and $configuration.intendedHost.kind -eq 'package') {
            $packageState = Get-CodexIpcPackageState -Inventory $inventory
            $registration = Get-CodexIpcProtocolRegistration -PackageState $packageState
        }
        $activationDecision = Get-CodexIpcActivationDecision `
            -SendEligible $sendEligible `
            -Configuration $configuration `
            -PackageState $packageState `
            -Registration $registration
        $activationEligible = [bool]$activationDecision.eligible
        $activationReasons = @($activationDecision.reasons)
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $true
        purpose = $purpose
        configuration = $configuration
        inventory = $inventory
        packageState = $packageState
        registration = $registration
        sendEligible = $sendEligible
        activationEligible = $activationEligible
        sendReasons = @($sendReasons)
        activationReasons = @($activationReasons)
        limitations = @('inventory-does-not-prove-thread-ownership')
    }
}

# Dot-sourcing defines the functions only. It must not emit JSON or terminate the
# caller, because codex_ipc_autoload.ps1 consumes these functions in-process.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    # CLI consumers decode JSON as UTF-8, even without an attached console.
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $result = Invoke-CodexIpcHostPolicyCli -Arguments $args
    $result | ConvertTo-Json -Depth 12 -Compress
    exit 0
} catch {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $false
        purpose = $null
        error = [pscustomobject][ordered]@{
            reason = 'host-policy-invalid'
            message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 6 -Compress
    exit 1
}
