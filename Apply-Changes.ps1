param([Parameter(Mandatory = $true)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$resultPath = $null
$result = $null
$exitCode = 1
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '请通过应用窗口确认操作，并允许管理员 PowerShell 请求。'
    }
    $requestFullPath = [IO.Path]::GetFullPath($RequestPath)
    if (-not [IO.Path]::IsPathRooted($RequestPath)) { throw '请求文件必须使用完整路径。' }
    $request = [IO.File]::ReadAllText($requestFullPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $candidateResultPath = [IO.Path]::GetFullPath([string]$request.ResultPath)
    $expectedResultPath = Join-Path ([IO.Path]::GetDirectoryName($requestFullPath)) 'result.json'
    if (-not [string]::Equals($candidateResultPath, $expectedResultPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw '结果文件位置无效。'
    }
    $resultPath = $candidateResultPath
    Import-Module (Join-Path $PSScriptRoot 'Operations.psm1') -Force
    $result = Invoke-PortChanges -Request $request
    if ($result.Success) { $exitCode = 0 }
}
catch {
    $result = [PSCustomObject]@{
        Success = $false; ConfigChanged = $false; BackupPath = $null
        KnownHostsBackupPath = $null; Results = @(); Error = $_.Exception.Message
    }
}
finally {
    if ($null -ne $resultPath -and $null -ne $result) {
        try {
            $temporaryPath = $resultPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            $json = $result | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::Move($temporaryPath, $resultPath)
        }
        catch {
            $exitCode = 1
            [Console]::Error.WriteLine('无法保存执行结果：' + $_.Exception.Message)
        }
    }
    elseif ($null -ne $result) {
        [Console]::Error.WriteLine([string]$result.Error)
    }
}
exit $exitCode
