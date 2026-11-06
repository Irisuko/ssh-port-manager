Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Mappings.psm1') -ErrorAction Stop

function Invoke-HostManagementChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$ExpectedHash,
        [Parameter(Mandatory=$true)][ValidateSet('Add','Edit','Delete')][string]$Action,
        [string]$Id,
        [string]$Alias,
        [string]$User,
        $Port,
        [AllowEmptyString()][string]$WorkspaceName = '',
        [string]$MappingsPath
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{
        Success=$false; ConfigChanged=$false; ConfigBackupPath=$null
        MappingBackupPath=$null; MappingsSaved=$false; Error=$null
    }
    try {
        $document = Read-SshDocument -Path $ConfigPath
        if (-not [string]::Equals($document.Hash,$ExpectedHash,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'SSH 配置已被其他程序修改。请重新加载列表后再保存。'
        }
        if ($WorkspaceName -match '[\r\n\x00]' -or $WorkspaceName.Trim().Length -gt 128) {
            throw 'Coder 工作区名称不能包含换行或超过 128 个字符。'
        }
        $workspace = $WorkspaceName.Trim()
        $mappingArgs = @{}
        if (-not [string]::IsNullOrWhiteSpace($MappingsPath)) { $mappingArgs.Path = $MappingsPath }
        # Read the latest mapping file, so unrelated entries from other windows survive.
        $mappings = Get-CoderMappings @mappingArgs
        $oldAlias = $null
        $oldAliasCount = 0
        if ($Action -ne 'Add') {
            $hosts = @(Get-TargetHosts -Document $document)
            $selected = @($hosts | Where-Object { [string]$_.Id -ceq $Id })
            if ($selected.Count -ne 1) { throw '主机已不存在或不属于目标 IP，请重新加载列表。' }
            $oldAlias = [string]$selected[0].Alias
            $oldAliasCount = @($hosts | Where-Object { [string]::Equals($_.Alias,$oldAlias,[StringComparison]::OrdinalIgnoreCase) }).Count
        }
        $change = @{Document=$document;Action=$Action}
        foreach ($name in @('Id','Alias','User','Port')) {
            if ($PSBoundParameters.ContainsKey($name)) { $change[$name] = $PSBoundParameters[$name] }
        }
        $text = New-SshHostChange @change
        $newAlias = if ($PSBoundParameters.ContainsKey('Alias')) { $Alias } else { $oldAlias }
        if ($oldAlias -and ($oldAliasCount -eq 1 -or ($Action -eq 'Edit' -and $oldAlias -eq $newAlias))) {
            $mappings.Remove($oldAlias)
        }
        if ($Action -ne 'Delete') {
            if ($workspace.Length -gt 0) { $mappings[$newAlias] = $workspace }
            elseif ($mappings.Contains($newAlias)) { $mappings.Remove($newAlias) }
        }
        $saved = Save-SshDocument -Document $document -Text $text -ExpectedHash $ExpectedHash
        $result.ConfigChanged = [bool]$saved.Changed
        $result.ConfigBackupPath = $saved.BackupPath
        $mappingSaved = Save-CoderMappings -Mappings $mappings @mappingArgs
        $result.MappingBackupPath = $mappingSaved.BackupPath
        $result.MappingsSaved = $true
        $result.Success = $true
    } catch {
        $result.Error = if ($result.ConfigChanged) {
            'SSH 配置已保存，但对应关系保存失败。请重新加载检查；配置备份可用于恢复。' + "`r`n" + $_.Exception.Message
        } else { $_.Exception.Message }
    }
    return $result
}

Export-ModuleMember -Function Invoke-HostManagementChange
