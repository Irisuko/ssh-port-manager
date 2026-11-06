param([Parameter(Mandatory=$true)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$resultPath = $null
$result = $null
$exitCode = 1

function Write-JobJson([string]$Path, $Value) {
    $temporaryPath = $Path + '.tmp'
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporaryPath, $Path) }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

try {
    if (-not [IO.Path]::IsPathRooted($RequestPath)) { throw '请求文件必须使用完整路径。' }
    $requestFullPath = [IO.Path]::GetFullPath($RequestPath)
    $jobDirectory = [IO.Path]::GetDirectoryName($requestFullPath)
    $expectedResultPath = Join-Path $jobDirectory 'result.json'
    $request = [IO.File]::ReadAllText($requestFullPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$request.ResultPath), $expectedResultPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw '结果文件位置无效。'
    }
    $resultPath = $expectedResultPath
    $progressPath = Join-Path $jobDirectory 'progress.json'
    Import-Module (Join-Path $PSScriptRoot 'CoderJob.psm1') -Force -ErrorAction Stop
    # GetNewClosure captures variables, not script-local functions. The GUI's
    # encoded call-operator bootstrap runs this worker in its own script scope.
    $writeProgressJson = ${function:Write-JobJson}
    $progress = { param($message) & $writeProgressJson -Path $progressPath -Value ([pscustomobject]@{ Message=[string]$message }) }.GetNewClosure()
    $result = Invoke-CoderJob -Request $request -OnProgress $progress
    if ($result.Success) { $exitCode = 0 }
} catch {
    $result = [pscustomobject]@{ Success=$false;HostId='';Alias='';WorkspaceName='';Port=$null;Started=$false;Error=$_.Exception.Message }
} finally {
    if ($null -ne $resultPath -and $null -ne $result) {
        try { Write-JobJson -Path $resultPath -Value $result }
        catch { $exitCode=1; [Console]::Error.WriteLine('无法保存 Coder 操作结果。') }
    } else {
        [Console]::Error.WriteLine('无法读取 Coder 操作请求。')
    }
}
exit $exitCode
