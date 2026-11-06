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
        Success=$false; NotReady=$false; Deferred=$false; Status=''; HostId=''; Alias=''; WorkspaceName=''; Port=$null; Started=$false; Error=$null
    }
    try {
        $mode='Auto'
        if ($null -ne $Request.PSObject.Properties['Mode']) { $mode=[string]$Request.Mode }
        if (@('Auto','Check') -cnotcontains $mode) { throw '操作模式无效。' }
        $timeoutSeconds = if ($mode -eq 'Check') {30} else {180}
        if ($null -ne $Request.PSObject.Properties['TimeoutSeconds']) {
            $requestedTimeout=0
            if ([string]$Request.TimeoutSeconds -notmatch '\A[0-9]{1,3}\z' -or -not [int]::TryParse([string]$Request.TimeoutSeconds,[ref]$requestedTimeout) -or $requestedTimeout -lt 1 -or $requestedTimeout -gt 180) { throw '等待时间必须是 1–180 秒。' }
            $timeoutSeconds=[Math]::Min($timeoutSeconds,$requestedTimeout)
        }
        if ($null -ne $Request.PSObject.Properties['DeadlineUtc']) {
            $deadline=[DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$Request.DeadlineUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$deadline)) { throw '等待截止时间无效。' }
            $remaining=[int][Math]::Ceiling(($deadline-[DateTimeOffset]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) { throw '启动等待已达到 3 分钟，尚未取得可核验的新端口；本地配置未修改。' }
            $timeoutSeconds=[Math]::Min($timeoutSeconds,$remaining)
        }
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
        $operationArguments=@{Alias=$result.Alias;Credential=$Credential;OnProgress=$OnProgress;TimeoutSeconds=$timeoutSeconds}
        if ($mode -eq 'Check') { $operationArguments.RequireAlreadyRunning=$true }
        else { $operationArguments.AllowUnreadyPort=$true }
        if ($null -eq $StartWorkspace) {
            $remote = Invoke-CoderWorkspace -WorkspaceName $expectedWorkspace @operationArguments @mappingArguments
        } else {
            # Tests replace only this network boundary; requests cannot supply executable code.
            $remote = & $StartWorkspace @operationArguments
        }
        if ($mode -eq 'Check' -and [bool]$remote.Started) { throw '检查操作返回了无效的启动结果，已阻止本地更新。' }
        $result.Started = [bool]$remote.Started
        $result.WorkspaceName = [string]$remote.WorkspaceName
        if (-not [string]::Equals($result.WorkspaceName, $expectedWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
            throw '返回的服务器名称与所选主机不一致，未修改本地配置。'
        }
        $portText = [string]$remote.Port
        $port = 0
        $deferred=$false
        if ($null -ne $remote.PSObject.Properties['Deferred']) { $deferred=($remote.Deferred -is [bool] -and $remote.Deferred) }
        $validStatus=($remote.Status -ceq 'running') -or ($mode -eq 'Auto' -and $deferred -and @('pending','starting') -ccontains [string]$remote.Status)
        if ($portText -notmatch '\A[0-9]{1,5}\z' -or -not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or -not $validStatus) {
            throw '服务器尚未就绪或返回端口无效，未修改本地配置。'
        }
        $result.Port = $port
        $result.Status=[string]$remote.Status
        $result.Deferred=$deferred
        $result.Success = $true
        $stateText=if ($deferred) {'等待启动，已分配 SSH 端口：'} else {'已运行，SSH 端口：'}
        & $OnProgress ($result.WorkspaceName + ' ' + $stateText + $port)
    } catch {
        $result.Error = $_.Exception.Message
        if ($_.Exception.Data['CoderNotRunning'] -eq $true) { $result.NotReady=$true }
    }
    return $result
}

Export-ModuleMember -Function Invoke-CoderJob
