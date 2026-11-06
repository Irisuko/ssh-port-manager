Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'CredentialStore.psm1') -ErrorAction Stop

function Get-PreparationField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-PreparationSnapshot([string]$Path, [string]$ExpectedHash) {
    $current = Read-SshDocument -Path $Path
    if (-not [string]::Equals($current.Hash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SSH 配置已被其他程序修改，请刷新后重试。已完成的远端命令不会撤销；本地配置尚未更新。'
    }
    return $current
}

function Invoke-PreparationJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Request,
        [pscredential]$Credential,
        [scriptblock]$PrepareWorkspace,
        [scriptblock]$OnProgress = {}
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{Success=$false;Error=$null;Updates=@();Results=@()}
    $ownsCredential = $false
    try {
        $expectedHash = [string](Get-PreparationField $Request 'ExpectedHash')
        if ($expectedHash -notmatch '\A[0-9a-fA-F]{64}\z') { throw '配置校验信息无效，请刷新后重试。' }
        $configPath = [string](Get-PreparationField $Request 'ConfigPath')
        if (-not [IO.Path]::IsPathRooted($configPath) -or [IO.Path]::GetFileName($configPath) -ine 'config') {
            throw 'SSH 配置必须使用名为 config 的完整文件路径。'
        }
        $configPath = [IO.Path]::GetFullPath($configPath)
        $document = Assert-PreparationSnapshot -Path $configPath -ExpectedHash $expectedHash
        $targets = @{}
        foreach ($hostInfo in @(Get-TargetHosts -Document $document)) { $targets[[string]$hostInfo.Id] = $hostInfo }
        $selected = @{}
        $normalized = @()
        foreach ($update in @(Get-PreparationField $Request 'Updates')) {
            if ($null -eq $update) { throw '主机选择无效，请刷新后重试。' }
            $rawPort = Get-PreparationField $update 'Port'
            if ($null -eq $rawPort) { throw '更新项目缺少端口。' }
            $portText = ([string]$rawPort).Trim()
            if ($portText.Length -eq 0) { continue }
            $port = 0
            if ($portText -notmatch '\A[0-9]{1,5}\z' -or -not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw '端口必须是 1–65535 之间的整数。'
            }
            $id = [string](Get-PreparationField $update 'Id')
            if (-not $targets.ContainsKey($id)) { throw '所选主机不属于目标 IP，或已从配置中移除，请刷新后重试。' }
            if ($selected.ContainsKey($id)) { throw '同一主机不能重复提交。' }
            $selected[$id] = $true
            $workspaceName = Get-PreparationField $update 'WorkspaceName'
            if ($null -ne $workspaceName) {
                if ($workspaceName -isnot [string] -or $workspaceName -match '[\r\n\x00]' -or $workspaceName.Length -gt 128 -or [string]::IsNullOrWhiteSpace($workspaceName)) {
                    throw 'Coder 工作区名称无效，请刷新后重新选择。'
                }
                $workspaceName = $workspaceName.Trim()
            }
            $normalized += [pscustomobject]@{Id=$id;Alias=[string]$targets[$id].Alias;Port=$port;WorkspaceName=$workspaceName}
        }
        # Validate every row before loading credentials or making the first remote call.
        $result.Updates = @($normalized | ForEach-Object { [pscustomobject]@{Id=$_.Id;Port=$_.Port} })
        if ($normalized.Count -eq 0) { $result.Success=$true; return $result }
        if ($null -eq $Credential) { $Credential=Read-CoderCredential; $ownsCredential=$true }
        if ($null -eq $Credential) { throw '请先在登录设置中保存 Coder 账号和密码；手动与自动模式都需要执行远端命令。' }
        if ($null -eq $PrepareWorkspace) { Import-Module (Join-Path $PSScriptRoot 'CoderTerminal.psm1') -ErrorAction Stop }

        foreach ($item in $normalized) {
            $null = Assert-PreparationSnapshot -Path $configPath -ExpectedHash $expectedHash
            $entry = [pscustomobject]@{Id=$item.Id;Alias=$item.Alias;Port=$item.Port;WorkspaceName=[string]$item.WorkspaceName;Command='chmod g-w /root';Success=$false;RootMode='';Error=$null}
            $result.Results += $entry
            try {
                & $OnProgress ($item.Alias + '：正在通过 Coder Terminal 执行 chmod g-w /root…') | Out-Null
                $arguments = @{Port=[int]$item.Port;Credential=$Credential;OnProgress=$OnProgress}
                if ($null -ne $item.WorkspaceName) { $arguments.WorkspaceName=[string]$item.WorkspaceName }
                if ($null -eq $PrepareWorkspace) { $remote=Invoke-CoderRootPreparation @arguments }
                else { $remote = & $PrepareWorkspace @arguments }

                $remotePort = 0
                $exitCode = -1
                $remoteWorkspace = Get-PreparationField $remote 'WorkspaceName'
                $mode = [string](Get-PreparationField $remote 'RootMode')
                if (-not [int]::TryParse([string](Get-PreparationField $remote 'Port'),[ref]$remotePort) -or $remotePort -ne $item.Port -or
                    $remoteWorkspace -isnot [string] -or [string]::IsNullOrWhiteSpace($remoteWorkspace) -or $remoteWorkspace -match '[\r\n\x00]' -or $remoteWorkspace.Length -gt 128 -or
                    ($null -ne $item.WorkspaceName -and -not [string]::Equals($remoteWorkspace,$item.WorkspaceName,[StringComparison]::Ordinal)) -or
                    [string](Get-PreparationField $remote 'Command') -cne 'chmod g-w /root' -or
                    -not [int]::TryParse([string](Get-PreparationField $remote 'ExitCode'),[ref]$exitCode) -or $exitCode -ne 0 -or
                    $mode -notmatch '\A[0-7]{3,4}\z') {
                    throw '远端命令结果无法确认，已阻止本地更新。'
                }
                if (([Convert]::ToInt32($mode,8) -band 16) -ne 0) { throw '远端 /root 仍有组写入权限，已阻止本地更新。' }
                $entry.WorkspaceName=$remoteWorkspace
                $entry.RootMode=$mode
                $entry.Success=$true
                & $OnProgress ($item.Alias + '：chmod g-w /root 已成功，/root 权限为 ' + $mode + '。') | Out-Null
            } catch {
                $entry.Error=$_.Exception.Message
                throw
            }
        }
        $null = Assert-PreparationSnapshot -Path $configPath -ExpectedHash $expectedHash
        $result.Success=$true
    } catch {
        $result.Error=$_.Exception.Message
    } finally {
        if ($ownsCredential -and $null -ne $Credential) { $Credential.Password.Dispose() }
    }
    return $result
}

Export-ModuleMember -Function Invoke-PreparationJob
