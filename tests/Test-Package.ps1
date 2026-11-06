[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Run packaging checks with Windows PowerShell 5.1.' }
$project = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot ('.package-check-' + [Guid]::NewGuid().ToString('N'))
$payload = @('App.ps1', 'App.xaml', 'Apply-Changes.ps1', 'Check-Coder.ps1', 'Coder.psm1', 'CoderJob.psm1', 'CredentialStore.psm1', 'HostManagement.psm1', 'HostManager.ps1', 'HostManager.xaml', 'Mappings.psm1', 'Operations.psm1', 'SshConfig.psm1', 'Start-Coder.ps1')
$checks = 0

function Assert-Package([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Get-ByteHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-Resource([Reflection.Assembly]$Assembly, [string]$Name) {
    $stream = $Assembly.GetManifestResourceStream($Name)
    $memory = New-Object IO.MemoryStream
    try { $stream.CopyTo($memory); return ,$memory.ToArray() }
    finally { $memory.Dispose(); $stream.Dispose() }
}

function Get-Package([string]$Path) {
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($Path))
    $method = $assembly.GetType('Launcher').GetMethod('PrepareRuntime', [Reflection.BindingFlags]'Static,NonPublic')
    Assert-Package ($null -ne $method) 'Portable launcher must provide its production non-UI resource extraction method.'
    return [pscustomobject]@{ Assembly = $assembly; Prepare = $method }
}

function Invoke-Prepare($Package, [string]$LocalData) {
    return $Package.Prepare.Invoke($null, [object[]]@($LocalData))
}

try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $source = Join-Path $fixture 'source with spaces'
    $standalone = Join-Path $fixture 'portable copy'
    $localData = Join-Path $fixture 'local-data'
    [void][IO.Directory]::CreateDirectory($source)
    [void][IO.Directory]::CreateDirectory($standalone)
    foreach ($name in ($payload + @('Launcher.cs', 'Build.ps1', 'AssemblyInfo.cs'))) {
        $path = Join-Path $project $name
        if ([IO.File]::Exists($path)) { [IO.File]::Copy($path, (Join-Path $source $name)) }
    }
    if ([IO.Directory]::Exists((Join-Path $project 'Assets'))) {
        Copy-Item -LiteralPath (Join-Path $project 'Assets') -Destination (Join-Path $source 'Assets') -Recurse
    }
    # These must never enter the executable even if a build directory contains private files.
    [IO.File]::WriteAllText((Join-Path $source 'credential.json'), 'PRIVATE-PACKAGE-FIXTURE')
    [IO.File]::WriteAllText((Join-Path $source 'arbitrary.ps1'), 'throw "Do not embed me"')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'Build.ps1')
    Assert-Package ($LASTEXITCODE -eq 0) 'Build must work when invoked directly with powershell.exe -File.'
    $built = Join-Path $source 'dist\SshPortManager.exe'
    Assert-Package ([IO.File]::Exists($built)) 'Build must default to dist/SshPortManager.exe.'
    $exe = Join-Path $standalone 'SshPortManager.exe'
    [IO.File]::Copy($built, $exe)
    Assert-Package (@(Get-ChildItem -LiteralPath $standalone).Count -eq 1) 'Portable fixture must contain only the executable.'
    $package = Get-Package $exe
    $names = @($package.Assembly.GetManifestResourceNames() | Sort-Object)
    $expected = @($payload | ForEach-Object { 'SshPortManager.Runtime.' + $_ } | Sort-Object)
    Assert-Package (($names -join '|') -ceq ($expected -join '|')) 'Only the explicit application payload may be embedded.'
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    Assert-Package ($version.FileVersion -eq '1.0.0.0' -and $version.ProductVersion -eq '1.0.0.0') 'Executable must expose file and product version 1.0.0.0.'
    foreach ($name in $payload) {
        Assert-Package ((Get-ByteHash (Read-Resource $package.Assembly ('SshPortManager.Runtime.' + $name))) -ceq (Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $source $name))))) ('Embedded bytes changed: ' + $name)
    }

    $stateFolder = Join-Path $localData 'SshPortManager'
    [void][IO.Directory]::CreateDirectory($stateFolder)
    $stateFile = Join-Path $stateFolder 'mappings.json'
    [IO.File]::WriteAllText($stateFile, 'SAVED-STATE-FIXTURE')
    $runtime = Invoke-Prepare $package $localData
    Assert-Package ([IO.Path]::GetDirectoryName($runtime) -eq (Join-Path $stateFolder 'Runtime')) 'Runtime must be under the application data Runtime folder.'
    Assert-Package ([IO.Path]::GetFileName($runtime) -cmatch '^[a-f0-9]{64}$') 'Runtime version must be a SHA-256 content hash.'
    Assert-Package (@(Get-ChildItem -LiteralPath $runtime -File).Count -eq $payload.Count) 'Extraction must contain only the allowlisted payload.'
    foreach ($name in $payload) {
        Assert-Package ((Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $runtime $name)))) -ceq (Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $source $name))))) ('Extracted bytes changed: ' + $name)
    }
    $appFile = Join-Path $runtime 'App.ps1'
    $timestamp = [IO.File]::GetLastWriteTimeUtc($appFile)
    Assert-Package ((Invoke-Prepare $package $localData) -eq $runtime) 'Repeated launches must reuse the content-addressed cache.'
    Assert-Package ([IO.File]::GetLastWriteTimeUtc($appFile) -eq $timestamp) 'Valid cached payload must not be rewritten.'
    [IO.File]::WriteAllText($appFile, 'tampered-cache')
    [IO.File]::Delete((Join-Path $runtime 'App.xaml'))
    [void](Invoke-Prepare $package $localData)
    foreach ($name in @('App.ps1', 'App.xaml')) {
        Assert-Package ((Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $runtime $name)))) -ceq (Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $source $name))))) ('Missing or corrupted cache must be restored: ' + $name)
    }
    Assert-Package ([IO.File]::ReadAllText($stateFile) -ceq 'SAVED-STATE-FIXTURE') 'Extraction must preserve saved application state.'

    # Several independent processes must be able to initialize one empty cache safely.
    $concurrentData = Join-Path $fixture 'concurrent'
    $jobs = @()
    try {
        for ($i = 0; $i -lt 4; $i++) {
            $jobs += Start-Job -ArgumentList $exe, $concurrentData -ScriptBlock {
                param($Executable, $DataRoot)
                $ErrorActionPreference = 'Stop'
                $loaded = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($Executable))
                $prepare = $loaded.GetType('Launcher').GetMethod('PrepareRuntime', [Reflection.BindingFlags]'Static,NonPublic')
                for ($attempt = 0; $attempt -lt 3; $attempt++) { $prepare.Invoke($null, [object[]]@($DataRoot)) }
            }
        }
        $finished = @($jobs | Wait-Job -Timeout 45)
        Assert-Package ($finished.Count -eq 4) 'Concurrent extraction must finish promptly.'
        $paths = @($jobs | Receive-Job -ErrorAction Stop)
        Assert-Package (@($jobs | Where-Object { $_.State -ne 'Completed' }).Count -eq 0) 'Concurrent extraction processes must all succeed.'
        Assert-Package ($paths.Count -eq 12 -and @($paths | Select-Object -Unique).Count -eq 1) 'Concurrent launches must share one complete runtime.'
        $concurrentRuntime = $paths[0]
        Assert-Package (@(Get-ChildItem -LiteralPath $concurrentRuntime -File).Count -eq $payload.Count) 'Concurrent extraction must leave no partial files.'
        foreach ($name in $payload) {
            Assert-Package ((Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $concurrentRuntime $name)))) -ceq (Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $source $name))))) ('Concurrent extraction corrupted: ' + $name)
        }
    }
    finally {
        foreach ($job in $jobs) {
            if ($job.State -eq 'Running') { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
    }

    # Rebuild identical bytes: changing PE metadata must not change the payload identity.
    & (Join-Path $source 'Build.ps1')
    $rebuilt = Get-Package $built
    Assert-Package ((Invoke-Prepare $rebuilt $localData) -eq $runtime) 'Identical resource bytes must have a stable runtime directory across builds.'
    # Mutate a resource outside the entry script to catch incomplete payload hashing.
    [IO.File]::AppendAllText((Join-Path $source 'Mappings.psm1'), "`r`n# Package hash fixture mutation.`r`n")
    & (Join-Path $source 'Build.ps1')
    $changed = Get-Package $built
    $changedRuntime = Invoke-Prepare $changed $localData
    Assert-Package ($changedRuntime -ne $runtime) 'Changing any embedded resource must select a different runtime directory.'
    Assert-Package ([IO.Directory]::Exists($runtime)) 'New payload versions must preserve old runtime directories.'
    Assert-Package ((Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $changedRuntime 'Mappings.psm1')))) -ceq (Get-ByteHash ([IO.File]::ReadAllBytes((Join-Path $source 'Mappings.psm1'))))) 'Changed resource must be extracted byte-for-byte.'
    Assert-Package ([IO.File]::ReadAllText($stateFile) -ceq 'SAVED-STATE-FIXTURE') 'Upgrading a payload must preserve saved application state.'
    Write-Output ('PASS: Package (' + $checks + ' checks; no UI, user SSH files, credentials, elevation, or network used).')
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $safePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.package-check-'
    if ($resolvedFixture.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
