param([Parameter(Mandatory=$true)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$resultPath = $null
$result = $null
$exitCode = 1

function Write-PreparationJson([string]$Path, $Value) {
    $temporaryPath = $Path + '.tmp'
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporaryPath,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporaryPath,$Path) }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

try {
    if (-not [IO.Path]::IsPathRooted($RequestPath)) { throw 'Invalid request path.' }
    $requestFullPath = [IO.Path]::GetFullPath($RequestPath)
    $jobDirectory = [IO.Path]::GetDirectoryName($requestFullPath)
    $expectedResultPath = Join-Path $jobDirectory 'result.json'
    $request = [IO.File]::ReadAllText($requestFullPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$request.ResultPath),$expectedResultPath,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Invalid result path.'
    }
    $resultPath=$expectedResultPath
    $progressPath = Join-Path $jobDirectory 'progress.json'
    Import-Module (Join-Path $PSScriptRoot 'PreparationJob.psm1') -Force -ErrorAction Stop
    $writeProgressJson = ${function:Write-PreparationJson}
    $progress = {param($Message) & $writeProgressJson -Path $progressPath -Value ([pscustomobject]@{Message=[string]$Message})}.GetNewClosure()
    $result = Invoke-PreparationJob -Request $request -OnProgress $progress
    if ($result.Success) { $exitCode=0 }
} catch {
    # Request/parser/import failures may contain raw input; do not copy them into job files.
    $result=[pscustomobject]@{Success=$false;Error='无法读取或执行远端权限准备请求，请刷新后重试。本地 SSH 配置尚未修改。';Updates=@();Results=@()}
} finally {
    if ($null -ne $resultPath -and $null -ne $result) {
        try { Write-PreparationJson -Path $resultPath -Value $result }
        catch { $exitCode=1; [Console]::Error.WriteLine('无法保存远端权限准备结果。') }
    } else { [Console]::Error.WriteLine('无法读取远端权限准备请求。') }
}
exit $exitCode
