Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -ErrorAction Stop

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
            $command = 'ssh-keygen -R "' + $endpoint + '" -f "' + $knownHostsPath + '"'
            $entry = [PSCustomObject]@{ Endpoint = $endpoint; Success = $false; Output = ''; Command = $command }
            if (-not [IO.File]::Exists($knownHostsPath)) {
                $entry.Success = $true
                $entry.Output = 'known_hosts 文件不存在，没有需要清除的旧主机密钥。'
                $result.Results += $entry
                continue
            }
            $process = $null
            try {
                # Arguments are validated integer endpoints and a Windows file path;
                # no shell or PowerShell evaluates any user-supplied input.
                $startInfo = New-Object Diagnostics.ProcessStartInfo
                $startInfo.FileName = $keygenPath
                $startInfo.Arguments = '-R "' + $endpoint + '" -f "' + $knownHostsPath + '"'
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
                $entry.Output = (($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result).Trim())
                $entry.Success = ($process.ExitCode -eq 0)
                if (-not $entry.Success -and [string]::IsNullOrWhiteSpace($entry.Output)) {
                    $entry.Output = 'ssh-keygen 退出代码：' + $process.ExitCode
                }
            }
            catch { $entry.Output = $_.Exception.Message }
            finally { if ($null -ne $process) { $process.Dispose() } }
            $result.Results += $entry
        }
        $failed = @($result.Results | Where-Object { -not $_.Success })
        $result.Success = ($failed.Count -eq 0)
        if (-not $result.Success) {
            $result.Error = '配置处理已完成，但部分旧主机密钥清理失败。请查看下方结果；备份可用于恢复。'
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.Success = $false
    }
    return $result
}

Export-ModuleMember -Function Invoke-PortChanges
