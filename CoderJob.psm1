Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'CredentialStore.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Coder.psm1') -ErrorAction Stop

function Invoke-CoderJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Request,
        [pscredential]$Credential,
        [Collections.IDictionary]$Mappings,
        [scriptblock]$StartWorkspace,
        [scriptblock]$OnProgress = {}
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{
        Success=$false; HostId=''; Alias=''; WorkspaceName=''; Port=$null; Started=$false; Error=$null
    }
    try {
        $result.HostId = [string]$Request.HostId
        $result.Alias = [string]$Request.Alias
        $mappingArguments = @{}
        if ($PSBoundParameters.ContainsKey('Mappings')) { $mappingArguments.Mappings = $Mappings }
        $expectedWorkspace = Get-CoderWorkspaceName -Alias $result.Alias @mappingArguments
        if ($null -ne $Request.PSObject.Properties['WorkspaceName'] -and
            -not [string]::Equals([string]$Request.WorkspaceName, $expectedWorkspace, [StringComparison]::Ordinal)) {
            throw '主机与 Coder 工作区的对应关系已改变，请刷新后重新选择。'
        }
        if ([string]$Request.ExpectedHash -notmatch '\A[0-9a-fA-F]{64}\z') { throw '配置校验信息无效，请刷新。' }
        $document = Read-SshDocument -Path ([string]$Request.ConfigPath)
        if (-not [string]::Equals($document.Hash, [string]$Request.ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw '配置已被其他程序修改，请刷新后再启动。'
        }
        $selected = @(Get-TargetHosts -Document $document | Where-Object { [string]$_.Id -ceq $result.HostId })
        if ($selected.Count -ne 1 -or -not [string]::Equals($selected[0].Alias, $result.Alias, [StringComparison]::OrdinalIgnoreCase)) {
            throw '选中主机与配置不一致，请刷新后重试。'
        }
        if ($null -eq $Credential) { $Credential = Read-CoderCredential }
        if ($null -eq $Credential) { throw '请先在登录设置中保存 Coder 账号和密码。' }
        & $OnProgress ('正在登录 Coder，准备 ' + $expectedWorkspace + '…')
        if ($null -eq $StartWorkspace) {
            $remote = Invoke-CoderWorkspace -Alias $result.Alias -WorkspaceName $expectedWorkspace -Credential $Credential -OnProgress $OnProgress @mappingArguments
        } else {
            # Tests replace only this network boundary; requests cannot supply executable code.
            $remote = & $StartWorkspace -Alias $result.Alias -Credential $Credential -OnProgress $OnProgress
        }
        $result.Started = [bool]$remote.Started
        $result.WorkspaceName = [string]$remote.WorkspaceName
        if (-not [string]::Equals($result.WorkspaceName, $expectedWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
            throw '返回的服务器名称与所选主机不一致，未修改本地配置。'
        }
        $portText = [string]$remote.Port
        $port = 0
        if ($portText -notmatch '\A[0-9]{1,5}\z' -or -not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or $remote.Status -ne 'running') {
            throw '服务器尚未就绪或返回端口无效，未修改本地配置。'
        }
        $result.Port = $port
        $result.Success = $true
        & $OnProgress ($result.WorkspaceName + ' 已运行，SSH 端口：' + $port)
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

Export-ModuleMember -Function Invoke-CoderJob
