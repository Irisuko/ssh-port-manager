$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot ('.runs\preparation-worker-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $config = Join-Path $testRoot 'config'
    $source = "Host PyramidKV-plugin`n HostName 36.140.239.91`n Port 32041`n"
    [IO.File]::WriteAllText($config,$source)
    $requestPath = Join-Path $testRoot 'request.json'
    $resultPath = Join-Path $testRoot 'result.json'
    $request = @{ConfigPath=$config;ExpectedHash=('0'*64);Updates=@(@{Id='0';Port=32091});ResultPath=$resultPath}
    [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'Start-Prepare.ps1') -RequestPath $requestPath
    if ($LASTEXITCODE -ne 1) { throw 'Stale preparation worker must fail before remote access.' }
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    if ($result.Success -or @($result.Results).Count -ne 0 -or [string]::IsNullOrWhiteSpace($result.Error)) { throw 'Worker must serialize stale-snapshot failure.' }
    if ([IO.File]::ReadAllText($config) -cne $source) { throw 'Worker changed fixture config.' }
    Write-Output 'PASS: real child rejects stale snapshot before credential or network access'

    $request.ExpectedHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $request.Updates=@(@{Id='0';Port=' '})
    [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'Start-Prepare.ps1') -RequestPath $requestPath
    if ($LASTEXITCODE -ne 0) { throw 'Blank preparation must complete without credentials or network.' }
    $result=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
    if (-not $result.Success -or @($result.Updates).Count -ne 0) { throw 'Worker must keep blank requests empty.' }
    Write-Output 'PASS: all-blank real child is a no-op with atomic result replacement'

    $successRoot=Join-Path $testRoot "child with spaces and quote's 工作"
    [void][IO.Directory]::CreateDirectory($successRoot)
    Copy-Item -LiteralPath (Join-Path $project 'Start-Prepare.ps1') -Destination (Join-Path $successRoot 'Start-Prepare.ps1')
    $stub=@'
Import-Module (Join-Path $PSScriptRoot 'NestedProgress.psm1') -Force
function Invoke-PreparationJob {
    param($Request,[scriptblock]$OnProgress)
    & $OnProgress 'fixture first progress'
    Send-FixtureProgress -OnProgress $OnProgress
    [pscustomobject]@{Success=$true;Error=$null;Updates=@([pscustomobject]@{Id='0';Port=32091});Results=@([pscustomobject]@{Id='0';Alias='PyramidKV-plugin';Port=32091;WorkspaceName='PyramidKV';Command='chmod g-w /root';RootMode='755';Success=$true;Error=$null})}
}
Export-ModuleMember -Function Invoke-PreparationJob
'@
    $nested=@'
function Send-FixtureProgress {
    param([scriptblock]$OnProgress)
    & $OnProgress 'fixture nested progress'
}
Export-ModuleMember -Function Send-FixtureProgress
'@
    [IO.File]::WriteAllText((Join-Path $successRoot 'PreparationJob.psm1'),$stub,[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $successRoot 'NestedProgress.psm1'),$nested,[Text.UTF8Encoding]::new($true))
    $request.ResultPath=Join-Path $successRoot 'result.json'
    $request.Updates=@(@{Id='0';Port=32091})
    $successRequest=Join-Path $successRoot 'request.json'
    [IO.File]::WriteAllText($successRequest,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $worker=Join-Path $successRoot 'Start-Prepare.ps1'
    $command="& '" + $worker.Replace("'","''") + "' -RequestPath '" + $successRequest.Replace("'","''") + "'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'Exact GUI encoded invocation must succeed.' }
    $result=[IO.File]::ReadAllText($request.ResultPath)|ConvertFrom-Json
    $progress=[IO.File]::ReadAllText((Join-Path $successRoot 'progress.json'))|ConvertFrom-Json
    if (-not $result.Success -or $result.Results[0].Command -cne 'chmod g-w /root' -or $result.Results[0].RootMode -ne '755' -or $progress.Message -ne 'fixture nested progress') {
        throw 'Worker lost verified results or nested callback progress.'
    }
    if (@(Get-ChildItem -LiteralPath $successRoot -Filter '*.tmp').Count -gt 0) { throw 'Repeated progress updates left temporary files.' }
    Write-Output 'PASS: GUI encoded child handles spaces, apostrophes, Unicode and repeated nested progress'

    [IO.File]::Delete($request.ResultPath)
    $request.ResultPath=Join-Path $testRoot 'forbidden-result.json'
    [IO.File]::WriteAllText($successRequest,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    try {
        $ErrorActionPreference='Continue'
        & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>$null
    } finally { $ErrorActionPreference='Stop' }
    if ($LASTEXITCODE -ne 1 -or [IO.File]::Exists($request.ResultPath) -or [IO.File]::Exists((Join-Path $successRoot 'result.json'))) { throw 'Worker must reject result paths outside its own job directory.' }
    if ([IO.File]::ReadAllText($config) -cne $source) { throw 'Worker changed fixture config.' }
    Write-Output 'PASS: worker rejects redirected results and never changes fixture SSH config'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $allowed=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runs')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
