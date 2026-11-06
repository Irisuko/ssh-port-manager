Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HostKeys.psm1') -ErrorAction Stop

function Get-OperationField($Object,[string]$Name,$Default=$null) {
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-OperationHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

function Add-VerifiedHostKeys([string]$Path,[string]$Endpoint,[object[]]$Keys) {
    $keysToAdd=@(ConvertTo-ValidatedHostKeys -Keys $Keys)
    $existed=[IO.File]::Exists($Path)
    [byte[]]$before=@()
    if ($existed) { $before=[IO.File]::ReadAllBytes($Path) }
    $beforeHash=Get-OperationHash $before
    $prefix=''
    if ($before.Length -gt 0 -and $before[$before.Length-1] -ne 10) { $prefix="`n" }
    $lines=@($keysToAdd | ForEach-Object { $Endpoint+' '+$_.Algorithm+' '+$_.Key })
    $suffix=[Text.Encoding]::UTF8.GetBytes($prefix+($lines -join "`n")+"`n")
    $temporary=$Path+'.port-manager-'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,[byte[]]($before+$suffix))
        if ($existed) {
            if (-not [IO.File]::Exists($Path) -or (Get-OperationHash ([IO.File]::ReadAllBytes($Path))) -cne $beforeHash) { throw 'known_hosts 已被其他程序修改，新密钥未写入，请重新检查。' }
            [IO.File]::Replace($temporary,$Path,[NullString]::Value)
        } else { [IO.File]::Move($temporary,$Path) }
        return $keysToAdd.Count
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Invoke-PortChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request)

    $ErrorActionPreference = 'Stop'
    $result = [PSCustomObject]@{
        Success = $false
        ConfigChanged = $false
        BackupPath = $null
        KnownHostsBackupPath = $null
        Results = @()
        Error = $null
    }
    try {
        $configPath = [IO.Path]::GetFullPath([string]$Request.ConfigPath)
        $knownHostsPath = [IO.Path]::GetFullPath([string]$Request.KnownHostsPath)
        if (-not [IO.Path]::IsPathRooted([string]$Request.ConfigPath) -or
            -not [IO.Path]::IsPathRooted([string]$Request.KnownHostsPath)) {
            throw '必须使用完整的 SSH 文件路径。'
        }
        if ([IO.Path]::GetFileName($configPath) -ine 'config') {
            throw '配置文件必须名为 config。'
        }
        $expectedKnownHostsPath = Join-Path ([IO.Path]::GetDirectoryName($configPath)) 'known_hosts'
        if (-not [string]::Equals($knownHostsPath, $expectedKnownHostsPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'known_hosts 必须位于所选 config 文件的同一目录。'
        }
        if ([string]$Request.ExpectedHash -notmatch '\A[0-9a-fA-F]{64}\z') {
            throw '配置校验信息无效，请刷新后重试。'
        }
        $document = Read-SshDocument -Path $configPath
        if (-not [string]::Equals([string]$document.Hash, [string]$Request.ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw '配置文件已被其他程序修改，请刷新后重试。'
        }
        $updates = @($Request.Updates)
        if ($updates.Count -eq 0) {
            $result.Success = $true
            return $result
        }

        $targets = @{}
        foreach ($item in @(Get-TargetHosts -Document $document)) {
            $targets[[string]$item.Id] = $item
        }
        $selectedIds = @{}
        $normalized = @()
        $ports = New-Object 'System.Collections.Generic.List[int]'
        $keyPlans = @{}
        foreach ($update in $updates) {
            if ($null -eq $update) { throw '主机选择无效，请刷新后重试。' }
            $id = [string]$update.Id
            if (-not $targets.ContainsKey($id)) { throw '所选主机不属于目标 IP，请刷新后重试。' }
            if ($selectedIds.ContainsKey($id)) { throw '同一主机不能重复提交。' }
            $selectedIds[$id] = $true
            $portText = ([string]$update.Port).Trim()
            $port = 0
            if ($portText -notmatch '\A[0-9]+\z' -or
                -not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw '端口必须是 1–65535 之间的整数。'
            }
            $normalized += [PSCustomObject]@{ Id = $id; Port = $port }
            $addKeys=Get-OperationField $update 'AddHostKeys' $false
            if ($addKeys -isnot [bool]) { throw '添加主机公钥的选项无效。' }
            $suppliedKeys=@(Get-OperationField $update 'HostKeys' @())
            if ($suppliedKeys.Count -eq 1 -and $null -eq $suppliedKeys[0]) { $suppliedKeys=@() }
            $validatedKeys=@()
            if ($addKeys) { $validatedKeys=@(ConvertTo-ValidatedHostKeys -Keys $suppliedKeys) }
            elseif ($suppliedKeys.Count -gt 0) { throw '尚未确认添加新密钥，但请求包含公钥，已阻止修改。' }
            $signature=$addKeys.ToString()+':'+((@($validatedKeys | ForEach-Object { $_.Algorithm+' '+$_.Key } | Sort-Object)) -join '|')
            if ($keyPlans.ContainsKey($port) -and $keyPlans[$port].Signature -cne $signature) { throw '同一 SSH 端点的新密钥结果不一致，请重新检查。' }
            $keyPlans[$port]=[pscustomobject]@{Add=$addKeys;Keys=$validatedKeys;Signature=$signature}
            if (-not $ports.Contains($port)) { $ports.Add($port) }
        }
        $newText = New-PortUpdate -Document $document -Updates $normalized
        $windowsDirectory = [Environment]::GetFolderPath('Windows')
        $systemDirectory = 'System32'
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory = 'Sysnative' }
        $keygenPath = Join-Path $windowsDirectory ($systemDirectory + '\OpenSSH\ssh-keygen.exe')
        if (-not [IO.File]::Exists($keygenPath)) {
            throw '未找到 Windows OpenSSH 的 ssh-keygen.exe，请先安装 Windows 可选功能“OpenSSH 客户端”。'
        }
        if ([IO.Directory]::Exists($knownHostsPath)) { throw 'known_hosts 路径是目录，无法执行清理。' }

        if ([IO.File]::Exists($knownHostsPath)) {
            $backupSuffix = '.backup-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $result.KnownHostsBackupPath = $knownHostsPath + $backupSuffix
            [IO.File]::Copy($knownHostsPath, $result.KnownHostsBackupPath, $false)
        }
        $saved = Save-SshDocument -Document $document -Text $newText -ExpectedHash ([string]$Request.ExpectedHash)
        $result.ConfigChanged = [bool]$saved.Changed
        $result.BackupPath = $saved.BackupPath

        foreach ($port in $ports) {
            $endpoint = '[36.140.239.91]:' + $port
            $cleanupEndpoints = @($endpoint)
            $knownHostName = $endpoint
            if ($port -eq 22) {
                # OpenSSH looks up its default port by bare host name. Remove both
                # canonical and legacy bracketed records, keeping the UI endpoint stable.
                $knownHostName = '36.140.239.91'
                $cleanupEndpoints += $knownHostName
            }
            $command = (@($cleanupEndpoints | ForEach-Object { 'ssh-keygen -R "' + $_ + '" -f "' + $knownHostsPath + '"' })) -join "`r`n"
            $entry = [PSCustomObject]@{ Endpoint = $endpoint; Success = $false; Output = ''; Command = $command; KeyAdded=$false; AddedKeys=0; KeyPending=(-not $keyPlans[$port].Add) }
            if (-not [IO.File]::Exists($knownHostsPath)) {
                $entry.Success = $true
                $entry.Output = 'known_hosts 文件不存在，没有需要清除的旧主机密钥。'
            } else {
                $entry.Success = $true
                $cleanupOutputs = New-Object 'System.Collections.Generic.List[string]'
                foreach ($cleanupEndpoint in $cleanupEndpoints) {
                    $process = $null
                    $cleanupSuccess = $false
                    $cleanupOutput = ''
                    try {
                        # Native execution only: validated endpoints and a Windows path
                        # never pass through a shell or PowerShell evaluation.
                        $startInfo = New-Object Diagnostics.ProcessStartInfo
                        $startInfo.FileName = $keygenPath
                        $startInfo.Arguments = '-R "' + $cleanupEndpoint + '" -f "' + $knownHostsPath + '"'
                        $startInfo.UseShellExecute = $false
                        $startInfo.CreateNoWindow = $true
                        $startInfo.RedirectStandardOutput = $true
                        $startInfo.RedirectStandardError = $true
                        $process = New-Object Diagnostics.Process
                        $process.StartInfo = $startInfo
                        if (-not $process.Start()) { throw 'ssh-keygen 进程未能启动。' }
                        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                        $stderrTask = $process.StandardError.ReadToEndAsync()
                        $process.WaitForExit()
                        $cleanupOutput = (($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result).Trim())
                        $cleanupSuccess = ($process.ExitCode -eq 0)
                        if (-not $cleanupSuccess -and [string]::IsNullOrWhiteSpace($cleanupOutput)) {
                            $cleanupOutput = 'ssh-keygen 退出代码：' + $process.ExitCode
                        }
                    }
                    catch { $cleanupOutput = $_.Exception.Message }
                    finally { if ($null -ne $process) { $process.Dispose() } }
                    if (-not $cleanupSuccess) { $entry.Success = $false }
                    if ($cleanupEndpoints.Count -gt 1) { $cleanupOutput = $cleanupEndpoint + "`r`n" + $cleanupOutput }
                    $cleanupOutputs.Add($cleanupOutput)
                }
                $entry.Output = $cleanupOutputs -join "`r`n"
                if (-not $entry.Success) { $entry.KeyPending = $true }
            }
            if ($entry.Success -and $keyPlans[$port].Add) {
                try {
                    $entry.AddedKeys=Add-VerifiedHostKeys -Path $knownHostsPath -Endpoint $knownHostName -Keys $keyPlans[$port].Keys
                    $entry.KeyAdded=$true
                    $entry.KeyPending=$false
                    $entry.Output += "`r`n已添加 "+$entry.AddedKeys+' 个经 Coder Terminal 验证的服务器主机公钥。'
                } catch {
                    $entry.Success=$false
                    $entry.KeyPending=$true
                    $entry.Output += "`r`n旧密钥已清理，但新密钥添加失败："+$_.Exception.Message
                }
            } elseif ($entry.KeyPending) {
                $entry.Output += "`r`n"+'新主机密钥待服务器就绪后通过“检查并连接”添加。'
            }
            $result.Results += $entry
        }
        $failed = @($result.Results | Where-Object { -not $_.Success })
        $result.Success = ($failed.Count -eq 0)
        if (-not $result.Success) {
            $result.Error = '配置处理已完成，但部分主机密钥更新失败。请查看下方结果；备份可用于恢复。'
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.Success = $false
    }
    return $result
}

Export-ModuleMember -Function Invoke-PortChanges
