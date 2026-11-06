Set-StrictMode -Version 2.0

function Get-VsCodeCandidatePaths {
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if ($localData) { Join-Path $localData 'Programs\Microsoft VS Code\Code.exe' }
    foreach ($programDirectory in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'), [Environment]::GetEnvironmentVariable('ProgramW6432'))) {
        if ($programDirectory) { Join-Path $programDirectory 'Microsoft VS Code\Code.exe' }
    }
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = $null; $key = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\App Paths\Code.exe', $false)
                if ($null -ne $key) {
                    $value = $key.GetValue('')
                    if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { $value }
                }
            } catch { } finally {
                if ($null -ne $key) { $key.Dispose() }
                if ($null -ne $base) { $base.Dispose() }
            }
        }
    }
    # Discover native applications only. Do not invoke aliases, functions or the cmd shim.
    foreach ($command in @(Get-Command -Name 'Code.exe','code.cmd' -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($command.Path) { $command.Path }
    }
}

function ConvertTo-VsCodeExecutable([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -match '[\x00-\x1f\x7f]') { return $null }
    $path = [Environment]::ExpandEnvironmentVariables($Candidate.Trim())
    if ($path.StartsWith('"') -and $path.EndsWith('"') -and $path.Length -gt 2) { $path = $path.Substring(1, $path.Length - 2) }
    if (-not [IO.Path]::IsPathRooted($path)) { return $null }
    try {
        $path = [IO.Path]::GetFullPath($path)
        if ([IO.Path]::GetFileName($path) -ieq 'code.cmd') {
            if (-not [IO.File]::Exists($path)) { return $null }
            $bin = [IO.Path]::GetDirectoryName($path)
            if ([IO.Path]::GetFileName($bin) -ine 'bin') { return $null }
            $path = Join-Path ([IO.Path]::GetDirectoryName($bin)) 'Code.exe'
        }
        if ([IO.Path]::GetFileName($path) -ine 'Code.exe' -or -not [IO.File]::Exists($path)) { return $null }
        return $path
    } catch { return $null }
}

function Resolve-VsCodeExecutable {
    param([string[]]$CandidatePaths)
    if (-not $PSBoundParameters.ContainsKey('CandidatePaths')) { $CandidatePaths = @(Get-VsCodeCandidatePaths) }
    foreach ($candidate in $CandidatePaths) {
        $executable = ConvertTo-VsCodeExecutable $candidate
        if ($executable) { return $executable }
    }
    return $null
}

function Start-VsCodeProcess([Diagnostics.ProcessStartInfo]$StartInfo) {
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo = $StartInfo
        return $process.Start()
    } finally { $process.Dispose() }
}

function Open-SshInVSCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Alias,
        [AllowEmptyString()][string]$RemotePath = '/root',
        [scriptblock]$Resolver,
        [scriptblock]$ProcessStarter
    )
    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject]@{Launched=$false;Path='';Error=$null}
    if ($Alias -cnotmatch '\A[A-Za-z0-9_.][A-Za-z0-9_.-]{0,127}\z') {
        $result.Error = '无法打开 VS Code：请选择单个有效 SSH 别名。'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($RemotePath) -or -not $RemotePath.StartsWith('/') -or
        $RemotePath.Length -gt 4096 -or $RemotePath -match '[\x00-\x1f\x7f]') {
        $result.Error = '无法打开 VS Code：远端目录必须是有效的绝对路径。'
        return $result
    }
    try {
        $candidate = if ($null -eq $Resolver) { Resolve-VsCodeExecutable } else { & $Resolver }
        if ($candidate -isnot [string]) { $candidate = $null }
        $executable = ConvertTo-VsCodeExecutable $candidate
        if (-not $executable) {
            $result.Error = '未找到 VS Code。请安装 VS Code 和 Remote - SSH 扩展，然后重试；SSH 配置与密钥处理结果已保留。'
            return $result
        }
        $result.Path = $executable
        $escapedSegments = @($RemotePath.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })
        $uri = 'vscode-remote://ssh-remote+' + [Uri]::EscapeDataString($Alias) + ($escapedSegments -join '/')
        # Official CLI: https://code.visualstudio.com/docs/remote/troubleshooting
        # URI escaping leaves no quotes, whitespace or shell expansions in this argument.
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.Arguments = '--new-window --folder-uri "' + $uri + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
        $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($executable)
        $startInfo.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
        # These injectable boundaries are code-only test hooks, never serialized job input.
        $launched = if ($null -eq $ProcessStarter) { Start-VsCodeProcess $startInfo } else { & $ProcessStarter $startInfo }
        if ($launched -isnot [bool] -or -not $launched) { throw 'Process launch failed.' }
        $result.Launched = $true
    } catch {
        $result.Error = '无法启动 VS Code。请确认 VS Code 可正常打开且已安装 Remote - SSH 扩展；SSH 配置与密钥处理结果已保留。'
    }
    # Launched confirms only local process creation; Remote - SSH reports connection status.
    return $result
}

Export-ModuleMember -Function Open-SshInVSCode
