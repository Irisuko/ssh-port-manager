$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot ('coder-worker-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $config = Join-Path $testRoot 'config'
    $source = "Host PyramidKV-plugin`n HostName 36.140.239.91`n Port 32041`n"
    [IO.File]::WriteAllText($config,$source)
    $resultPath = Join-Path $testRoot 'result.json'
    $requestPath = Join-Path $testRoot 'request.json'
    $request = @{ConfigPath=$config;ExpectedHash=('0'*64);HostId='0';Alias='PyramidKV-plugin';ResultPath=$resultPath}
    [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'Start-Coder.ps1') -RequestPath $requestPath
    if ($LASTEXITCODE -ne 1) { throw 'Worker must return exit 1 for stale config.' }
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    if ($result.Success -or [string]::IsNullOrWhiteSpace($result.Error) -or $result.HostId -ne '0') { throw 'Worker must serialize tied failure result.' }
    if ([IO.File]::ReadAllText($config) -cne $source) { throw 'Worker modified fixture config.' }
    Write-Output 'PASS: child worker returns serialized failure without network access or local mutation'

    # Exercise the unmodified child script with only the network/job boundary replaced.
    # This catches callback scope errors and serialization errors across a real process.
    $successRoot = Join-Path $testRoot 'success'
    [void][IO.Directory]::CreateDirectory($successRoot)
    Copy-Item -LiteralPath (Join-Path $project 'Start-Coder.ps1') -Destination (Join-Path $successRoot 'Start-Coder.ps1')
    $stub = @'
Import-Module (Join-Path $PSScriptRoot 'NestedProgress.psm1') -Force
function Invoke-CoderJob {
    param($Request,[scriptblock]$OnProgress)
    & $OnProgress 'fixture first progress from module'
    Send-FixtureProgress -OnProgress $OnProgress
    [pscustomobject]@{Success=$true;HostId='0';Alias='PyramidKV-plugin';WorkspaceName='PyramidKV';Port=32091;Started=$false;Error=$null}
}
Export-ModuleMember -Function Invoke-CoderJob
'@
    [IO.File]::WriteAllText((Join-Path $successRoot 'CoderJob.psm1'),$stub)
    $nestedStub = @'
function Send-FixtureProgress {
    param([scriptblock]$OnProgress)
    & $OnProgress 'fixture progress from module'
}
Export-ModuleMember -Function Send-FixtureProgress
'@
    [IO.File]::WriteAllText((Join-Path $successRoot 'NestedProgress.psm1'),$nestedStub)
    $request.ResultPath = Join-Path $successRoot 'result.json'
    $successRequest = Join-Path $successRoot 'request.json'
    [IO.File]::WriteAllText($successRequest,($request|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $successRoot 'Start-Coder.ps1') -RequestPath $successRequest
    $directExitCode = $LASTEXITCODE
    $result = [IO.File]::ReadAllText($request.ResultPath) | ConvertFrom-Json
    if ($directExitCode -ne 0) { throw ('Direct child worker failed: ' + $result.Error) }
    $progress = [IO.File]::ReadAllText((Join-Path $successRoot 'progress.json')) | ConvertFrom-Json
    if (-not $result.Success -or $result.Port -ne 32091 -or $progress.Message -ne 'fixture progress from module') {
        throw 'Child worker lost its module callback progress or successful result.'
    }
    Write-Output 'PASS: child worker serializes progress and success across module callback scope'

    # The GUI invokes the worker with an encoded call operator, which gives the
    # worker its own script scope instead of the top-level scope used by -File.
    [IO.File]::Delete($request.ResultPath)
    [IO.File]::Delete((Join-Path $successRoot 'progress.json'))
    $workerPath = Join-Path $successRoot 'Start-Coder.ps1'
    $command = "& '" + $workerPath.Replace("'", "''") + "' -RequestPath '" + $successRequest.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded
    $workerExitCode = $LASTEXITCODE
    $result = [IO.File]::ReadAllText($request.ResultPath) | ConvertFrom-Json
    if ($workerExitCode -ne 0 -or -not $result.Success) {
        throw ('GUI-style encoded worker invocation failed: ' + $result.Error)
    }
    $progress = [IO.File]::ReadAllText((Join-Path $successRoot 'progress.json')) | ConvertFrom-Json
    if ($result.Port -ne 32091 -or $progress.Message -ne 'fixture progress from module') {
        throw 'GUI-style encoded worker invocation lost progress or its successful result.'
    }
    if ([IO.File]::Exists((Join-Path $successRoot 'progress.json.tmp')) -or [IO.File]::Exists(($request.ResultPath + '.tmp'))) {
        throw 'Worker left incomplete JSON files after progress replacement.'
    }
    if ([IO.File]::ReadAllText($config) -cne $source) { throw 'Worker modified fixture config.' }
    Write-Output 'PASS: GUI-style encoded child invocation serializes module callback progress and success'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
