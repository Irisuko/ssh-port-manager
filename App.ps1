[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

try {
    Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'CredentialStore.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Mappings.psm1') -Force -DisableNameChecking
    . (Join-Path $PSScriptRoot 'HostManager.ps1')
    $script:configPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\config'
    $script:knownHostsPath = Join-Path (Split-Path -Parent $script:configPath) 'known_hosts'
    $script:window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'App.xaml')))
    foreach ($controlName in @('ConfigPathText', 'RefreshButton', 'ManageHostsButton', 'HostCountText', 'HostsPanel', 'SelectionText', 'PreviewText', 'ResultText', 'StatusText', 'ApplyButton', 'AutoHostComboBox', 'AutoSelectionPlaceholder', 'StartSyncButton', 'AutoHintText', 'CredentialStatusText', 'LoginSettingsExpander', 'CredentialUserName', 'CredentialPassword', 'SaveCredentialButton')) {
        Set-Variable -Name $controlName -Value $script:window.FindName($controlName) -Scope Script
    }
    $script:ConfigPathText.Text = $script:configPath
    $script:rows = @()
    $script:document = $null
    $script:busy = $false
    $script:worker = $null
    $script:jobFolder = $null
    $script:appFolder = $PSScriptRoot
    $script:stage = $null
    $script:autoContext = $null
    $script:hasCredential = $false
    $script:lastProgress = ''
    $script:workspaceNames = @{}
    $script:mappingReadError = ''

    function Set-Status([string]$Text, [bool]$IsError = $false) {
        $script:StatusText.Text = $Text
        $script:StatusText.Foreground = if ($IsError) { '#B93838' } else { '#526780' }
    }

    function Update-AutoControls {
        $selected = $script:AutoHostComboBox.SelectedItem
        $script:AutoSelectionPlaceholder.Visibility = if ($null -eq $selected) { 'Visible' } else { 'Collapsed' }
        $script:StartSyncButton.IsEnabled = (-not $script:busy) -and $script:hasCredential -and ($null -ne $selected) -and ($null -ne $script:document)
        $passwordSnapshot = $script:CredentialPassword.SecurePassword
        try { $hasPasswordInput = $passwordSnapshot.Length -gt 0 } finally { $passwordSnapshot.Dispose() }
        $script:SaveCredentialButton.IsEnabled = (-not $script:busy) -and (-not [string]::IsNullOrWhiteSpace($script:CredentialUserName.Text)) -and $hasPasswordInput
        if ($script:mappingReadError) {
            $script:AutoHintText.Text = '工作区映射无法读取；手动更新仍可使用。请修复本地映射文件后刷新。'
        } elseif ($script:AutoHostComboBox.Items.Count -eq 0) {
            $script:AutoHintText.Text = '当前配置中没有已绑定的主机。可在“管理主机与映射”中设置 SSH 主机与 Coder 工作区的对应关系。'
        } else {
            $script:AutoHintText.Text = '仅处理所选主机；获取端口后将请求管理员授权并自动同步。其他手动填写的端口不会提交。'
        }
    }

    function Read-CredentialStatus {
        $savedCredential = $null
        try {
            $savedCredential = Read-CoderCredential
            $script:hasCredential = $null -ne $savedCredential
            if ($script:hasCredential) {
                $script:CredentialStatusText.Text = '已保存登录凭据：' + $savedCredential.UserName + ' · 当前 Windows 用户加密'
                $script:CredentialUserName.Text = $savedCredential.UserName
            } else {
                $script:CredentialStatusText.Text = '尚未保存登录凭据，请展开“登录设置”后保存。'
            }
        } catch {
            $script:hasCredential = $false
            $script:CredentialStatusText.Text = '无法读取已保存的凭据，请在“登录设置”中重新保存。'
        } finally {
            if ($null -ne $savedCredential) { $savedCredential.Password.Dispose() }
        }
        Update-AutoControls
    }

    function Update-Preview {
        $count = 0
        $valid = $true
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($row in $script:rows) {
            $raw = $row.Input.Text.Trim()
            $row.Input.BorderBrush = '#CCD7E6'
            $row.Hint.Foreground = '#728198'
            if ($raw.Length -eq 0) {
                $row.Hint.Text = '留空跳过'
                continue
            }
            $port = 0
            if ($raw -notmatch '^[0-9]{1,5}$' -or -not [int]::TryParse($raw, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                $valid = $false
                $row.Input.BorderBrush = '#D45454'
                $row.Hint.Text = '请输入 1–65535 的整数'
                $row.Hint.Foreground = '#B93838'
                continue
            }
            $count++
            $row.Hint.Text = if ($port -eq $row.HostInfo.Port) { '端口不变，清除旧记录' } else { '将更新为 ' + $port }
            $lines.Add(('{0}：{1} → {2}' -f $row.HostInfo.Alias, $row.HostInfo.Port, $port))
            $lines.Add(('ssh-keygen -R "[36.140.239.91]:{0}"' -f $port))
        }
        if (-not $valid) {
            $script:SelectionText.Text = '请修正标红的端口'
        } elseif ($count -gt 0) {
            $script:SelectionText.Text = '将处理 ' + $count + ' 个主机'
        } else {
            $script:SelectionText.Text = '填写端口后，在这里预览操作'
        }
        $script:PreviewText.Text = if ($lines.Count -gt 0) {
            ($lines -join "`r`n") + "`r`n清理文件：" + $script:knownHostsPath
        } else {
            '确认后自动备份 config，再使用管理员 PowerShell 清除对应记录。'
        }
        $script:ApplyButton.IsEnabled = $valid -and ($count -gt 0) -and (-not $script:busy)
    }

    function Read-Hosts([switch]$PreserveInputs) {
        $previousInputs = @{}
        $previousSelectionKey = $null
        if ($PreserveInputs) {
            foreach ($row in $script:rows) {
                $identityKey = [string]$row.HostInfo.Alias + "`0" + [string]$row.HostInfo.HostName
                if ($previousInputs.ContainsKey($identityKey)) { $previousInputs[$identityKey].Count++ }
                else { $previousInputs[$identityKey] = [pscustomobject]@{ Count = 1; Text = $row.Input.Text } }
            }
            if ($null -ne $script:AutoHostComboBox.SelectedItem) {
                $selectedHost = $script:AutoHostComboBox.SelectedItem.HostInfo
                $previousSelectionKey = [string]$selectedHost.Alias + "`0" + [string]$selectedHost.HostName
            }
        }
        $script:HostsPanel.Children.Clear()
        $script:AutoHostComboBox.ItemsSource = $null
        $script:rows = @()
        $script:document = $null
        $script:workspaceNames = @{}
        $script:mappingReadError = ''
        try {
            $script:document = Read-SshDocument -Path $script:configPath
            $targetHosts = @(Get-TargetHosts -Document $script:document)
            try { $script:workspaceNames = Get-CoderMappings }
            catch { $script:mappingReadError = $_.Exception.Message }
            $currentIdentityCounts = @{}
            foreach ($targetHost in $targetHosts) {
                $identityKey = [string]$targetHost.Alias + "`0" + [string]$targetHost.HostName
                if ($currentIdentityCounts.ContainsKey($identityKey)) { $currentIdentityCounts[$identityKey]++ }
                else { $currentIdentityCounts[$identityKey] = 1 }
            }
            $autoChoices = @()
            $script:HostCountText.Text = '目标主机 · ' + $targetHosts.Count
            foreach ($targetHost in $targetHosts) {
                $rowXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="White" BorderBrush="#DFE7F1" BorderThickness="1" CornerRadius="10" Padding="20,16" Margin="0,0,0,10">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="115"/><ColumnDefinition Width="175"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,15,0">
      <TextBlock x:Name="AliasText" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock x:Name="ConnectionText" Foreground="#728198" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,15,0">
      <TextBlock Text="当前端口" Foreground="#728198" FontSize="11"/>
      <TextBlock x:Name="CurrentPortText" FontSize="20" FontFamily="Consolas" Margin="0,5,0,0"/>
    </StackPanel>
    <StackPanel Grid.Column="2">
      <TextBlock Text="新端口（可选）" Foreground="#526780" FontSize="11" Margin="0,0,0,5"/>
      <TextBox x:Name="PortInput" FontFamily="Consolas" FontSize="16" AutomationProperties.Name="新端口" ToolTip="例如 32091；留空跳过此主机"/>
      <TextBlock x:Name="PortHint" Text="留空跳过" Foreground="#728198" FontSize="11" Margin="0,5,0,0"/>
    </StackPanel>
  </Grid>
</Border>
'@
                $card = [Windows.Markup.XamlReader]::Parse($rowXaml)
                $card.FindName('AliasText').Text = $targetHost.Alias
                $card.FindName('CurrentPortText').Text = [string]$targetHost.Port
                $connection = if ([string]::IsNullOrWhiteSpace($targetHost.User)) { $targetHost.HostName } else { $targetHost.User + '@' + $targetHost.HostName }
                $card.FindName('ConnectionText').Text = $connection
                $inputControl = $card.FindName('PortInput')
                [Windows.Automation.AutomationProperties]::SetName($inputControl, $targetHost.Alias + ' 新端口')
                $script:rows += [pscustomobject]@{ HostInfo = $targetHost; Input = $inputControl; Hint = $card.FindName('PortHint') }
                $identityKey = [string]$targetHost.Alias + "`0" + [string]$targetHost.HostName
                if ($PreserveInputs -and $previousInputs.ContainsKey($identityKey)) {
                    $previousInput = $previousInputs[$identityKey]
                    # Inserting a missing Port changes line-based IDs. Preserve only an identity
                    # that is unique in both snapshots, so duplicates cannot inherit another row.
                    if ($previousInput.Count -eq 1 -and $currentIdentityCounts[$identityKey] -eq 1) { $inputControl.Text = $previousInput.Text }
                }
                $inputControl.Add_TextChanged({ Update-Preview })
                [void]$script:HostsPanel.Children.Add($card)
                if ($script:workspaceNames.ContainsKey([string]$targetHost.Alias)) {
                    $workspaceName = $script:workspaceNames[[string]$targetHost.Alias]
                    $autoChoices += [pscustomobject]@{ HostInfo = $targetHost; WorkspaceName = $workspaceName; DisplayName = ($targetHost.Alias + ' → ' + $workspaceName) }
                }
            }
            $script:AutoHostComboBox.ItemsSource = $autoChoices
            $script:AutoHostComboBox.SelectedIndex = -1
            if ($previousSelectionKey -and $previousInputs[$previousSelectionKey].Count -eq 1 -and $currentIdentityCounts[$previousSelectionKey] -eq 1) {
                foreach ($choice in $autoChoices) {
                    $identityKey = [string]$choice.HostInfo.Alias + "`0" + [string]$choice.HostInfo.HostName
                    if ([string]::Equals($identityKey, $previousSelectionKey, [StringComparison]::OrdinalIgnoreCase)) {
                        $script:AutoHostComboBox.SelectedItem = $choice
                        break
                    }
                }
            }
            if ($script:mappingReadError) {
                Set-Status 'SSH 配置已读取，但工作区映射无法读取；仍可手动更新端口。' $true
                $script:ResultText.Text = "自动启动暂不可用。请修复本地工作区映射文件后刷新；手动更新不受影响。`r`n" + $script:mappingReadError
            } elseif ($targetHosts.Count -eq 0) {
                Set-Status '未找到 HostName 为 36.140.239.91 的直接配置项。' $true
            } else {
                Set-Status ('已读取 ' + $targetHosts.Count + ' 个匹配主机，填写需要更新的端口。')
            }
        } catch {
            $script:HostCountText.Text = '目标主机 · 无法读取'
            Set-Status ('读取失败：' + $_.Exception.Message) $true
            $script:ResultText.Text = "无法读取 SSH 配置。请检查文件，然后点击刷新。`r`n" + $_.Exception.Message
        }
        Update-Preview
        Update-AutoControls
    }

    function Set-Busy([bool]$Value) {
        $script:busy = $Value
        $script:RefreshButton.IsEnabled = -not $Value
        $script:ManageHostsButton.IsEnabled = -not $Value
        $script:AutoHostComboBox.IsEnabled = -not $Value
        $script:LoginSettingsExpander.IsEnabled = -not $Value
        foreach ($row in $script:rows) { $row.Input.IsEnabled = -not $Value }
        $script:ApplyButton.Content = if ($Value -and $null -eq $script:autoContext) { '正在处理…' } else { '确认手动更新' }
        $script:StartSyncButton.Content = if ($Value -and $null -ne $script:autoContext) { '正在处理…' } else { '启动并同步端口' }
        Update-Preview
        Update-AutoControls
    }

    function Remove-JobFiles([string]$Folder) {
        if ($Folder -and [IO.Directory]::Exists($Folder)) {
            # Only remove worker-owned files from this application's unique GUID directory.
            $jobRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SshPortManager\Jobs'))
            $fullFolder = [IO.Path]::GetFullPath($Folder)
            if (-not [string]::Equals([IO.Path]::GetDirectoryName($fullFolder), $jobRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
            if ([IO.Path]::GetFileName($fullFolder) -notmatch '^[0-9a-f]{32}$') { return }
            foreach ($file in [IO.Directory]::GetFiles($fullFolder)) {
                if ([IO.Path]::GetFileName($file) -match '^(request\.json|result\.json|progress\.json)(\.[0-9a-f]+)?(\.tmp)?$') {
                    try { [IO.File]::Delete($file) } catch { }
                }
            }
            try { [IO.Directory]::Delete($fullFolder, $false) } catch { }
        }
    }

    function Get-RemoteSummary {
        if ($null -eq $script:autoContext -or -not $script:autoContext.RemoteCompleted) { return '' }
        $startText = if ($script:autoContext.Started) { '已启动' } else { '已运行' }
        return ('远端工作区 {0} {1}，当前保持运行。{2} → 端口 {3}。' -f $script:autoContext.WorkspaceName, $startText, $script:autoContext.Alias, $script:autoContext.Port)
    }

    function Show-LaunchFailure([Exception]$Exception) {
        $cancelled = $false
        $currentException = $Exception
        while ($null -ne $currentException) {
            if ($currentException -is [ComponentModel.Win32Exception] -and $currentException.NativeErrorCode -eq 1223) { $cancelled = $true }
            $currentException = $currentException.InnerException
        }
        $remoteSummary = Get-RemoteSummary
        if ($cancelled) {
            Set-Status '已取消管理员授权，本地配置和密钥记录均未修改。'
            $script:ResultText.Text = $remoteSummary + "`r`n已取消本地同步。已获取或填写的端口保留，可以稍后手动确认。"
        } else {
            Set-Status '无法开始本地同步，请查看执行结果。' $true
            $script:ResultText.Text = $remoteSummary + "`r`n本次操作未修改本地配置和密钥记录。`r`n" + $Exception.Message
        }
    }

    function Start-Worker([string]$Stage, [string]$FileName, [Collections.IDictionary]$Request, [bool]$Elevated = $false) {
        $jobRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SshPortManager\Jobs'
        $folder = Join-Path $jobRoot ([guid]::NewGuid().ToString('N'))
        try {
            [void][IO.Directory]::CreateDirectory($folder)
            $requestPath = Join-Path $folder 'request.json'
            $Request['ResultPath'] = Join-Path $folder 'result.json'
            [IO.File]::WriteAllText($requestPath, ($Request | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $workerPath = Join-Path $script:appFolder $FileName
            # Only literal file paths become code. Credentials never enter arguments or job files.
            $bootstrap = "& '" + $workerPath.Replace("'", "''") + "' -RequestPath '" + $requestPath.Replace("'", "''") + "'"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
            $processOptions = @{
                FilePath = (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe')
                WindowStyle = 'Hidden'
                ArgumentList = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
                PassThru = $true
                ErrorAction = 'Stop'
            }
            if ($Elevated) { $processOptions['Verb'] = 'RunAs' }
            $script:worker = Start-Process @processOptions
            $script:jobFolder = $folder
            $script:stage = $Stage
            $script:lastProgress = ''
            $script:timer.Start()
        } catch {
            Remove-JobFiles -Folder $folder
            throw
        }
    }

    function Start-ApplyUpdates([object[]]$Updates) {
        # Revalidate the original UI snapshot immediately before requesting elevation.
        $null = New-PortUpdate -Document $script:document -Updates $Updates
        $currentDocument = Read-SshDocument -Path $script:configPath
        if ($currentDocument.Hash -ne $script:document.Hash) { throw '配置已被其他程序修改。请点击刷新后重新选择或填写；本次不会覆盖外部修改。' }
        $request = [ordered]@{
            ConfigPath = $script:configPath
            KnownHostsPath = $script:knownHostsPath
            ExpectedHash = $script:document.Hash
            Updates = @($Updates)
        }
        Set-Status '正在请求管理员权限；取消授权不会修改本地配置。'
        $script:ResultText.Text = (Get-RemoteSummary) + "`r`n等待 Windows 授权。批准后将先备份并更新 config，再清除对应端口的旧主机密钥记录。"
        Start-Worker -Stage 'Apply' -FileName 'Apply-Changes.ps1' -Request $request -Elevated $true
        Set-Status '管理员 PowerShell 正在同步本地配置，请稍候…'
    }

    function Show-ApplyResult($Result) {
        $log = [Collections.Generic.List[string]]::new()
        $remoteSummary = Get-RemoteSummary
        if ($remoteSummary) { $log.Add($remoteSummary); $log.Add('') }
        if ($Result.ConfigChanged) { $log.Add('✓ config 中的端口已更新。') }
        elseif ($Result.Success) { $log.Add('config 端口无需改变。') }
        else { $log.Add('config 未修改。') }
        if ($Result.BackupPath) { $log.Add('配置备份：' + $Result.BackupPath) }
        if ($Result.KnownHostsBackupPath) { $log.Add('密钥记录备份：' + $Result.KnownHostsBackupPath) }
        foreach ($entry in @($Result.Results)) {
            if ($null -eq $entry) { continue }
            $log.Add('')
            $log.Add($(if ($entry.Success) { '✓ ' } else { '✗ ' }) + $entry.Command)
            if ($entry.Output) { $log.Add([string]$entry.Output) }
        }
        if ($Result.Error) { $log.Add("`r`n" + [string]$Result.Error) }
        # Keep other manually entered ports visible after automatic work; they were not submitted.
        if ($null -ne $script:autoContext) { Read-Hosts -PreserveInputs } else { Read-Hosts }
        $script:ResultText.Text = $log -join "`r`n"
        if ($Result.Success) { Set-Status '已完成：端口已同步，对应的旧主机密钥记录已清除。' }
        elseif ($Result.ConfigChanged) { Set-Status '端口已更新，但密钥清理未全部成功。请查看执行结果。' $true }
        else { Set-Status '本地同步未完成，请查看执行结果。' $true }
    }

    function Complete-CoderStage($Result) {
        if (-not $Result.Success) {
            $script:ResultText.Text = ("{0} → {1}`r`n" -f $script:autoContext.Alias, $script:autoContext.WorkspaceName) + '自动获取端口未完成。本地配置和密钥记录未修改；远端可能仍在运行，请检查 Coder 状态。' + "`r`n" + [string]$Result.Error
            Set-Status '自动启动或端口获取失败，本地配置未修改。' $true
            return
        }
        if ([string]$Result.HostId -ne $script:autoContext.HostId -or
            -not [string]::Equals([string]$Result.Alias, $script:autoContext.Alias, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$Result.WorkspaceName -cne $script:autoContext.WorkspaceName) { throw '后台返回的主机或工作区与本次选择不一致，已阻止本地更新。' }
        $port = 0
        if ([string]$Result.Port -notmatch '^[0-9]{1,5}$' -or -not [int]::TryParse([string]$Result.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw '后台未返回有效的 SSH 端口，已阻止本地更新。' }
        $script:autoContext.Port = $port
        $script:autoContext.Started = [bool]$Result.Started
        $script:autoContext.RemoteCompleted = $true
        foreach ($row in $script:rows) {
            if ([string]$row.HostInfo.Id -eq $script:autoContext.HostId) { $row.Input.Text = [string]$port; break }
        }
        try {
            # The automatic path deliberately submits only its selected host, never manual rows.
            $singleUpdate = [pscustomobject]@{ Id = $script:autoContext.HostId; Port = [string]$port }
            Start-ApplyUpdates -Updates @($singleUpdate)
        } catch { Show-LaunchFailure -Exception $_.Exception }
    }

    $script:timer = [Windows.Threading.DispatcherTimer]::new()
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:timer.Add_Tick({
        if ($null -eq $script:worker) { return }
        if ($script:stage -eq 'Coder') {
            $progressPath = Join-Path $script:jobFolder 'progress.json'
            if ([IO.File]::Exists($progressPath)) {
                try {
                    $progress = [IO.File]::ReadAllText($progressPath) | ConvertFrom-Json
                    if ($progress.Message -and [string]$progress.Message -ne $script:lastProgress) {
                        $script:lastProgress = [string]$progress.Message
                        Set-Status ($script:autoContext.Alias + '：' + $script:lastProgress)
                        $script:ResultText.Text = $script:autoContext.Alias + ' → ' + $script:autoContext.WorkspaceName + "`r`n" + $script:lastProgress + "`r`n本地 SSH 配置尚未修改。"
                    }
                } catch { } # An atomic progress replacement may overlap a tick; retry next tick.
            }
        }
        if (-not $script:worker.HasExited) { return }
        $script:timer.Stop()
        # Detach this completed worker before a handler may start the next stage.
        $completedWorker = $script:worker
        $completedFolder = $script:jobFolder
        $completedStage = $script:stage
        $script:worker = $null
        $script:jobFolder = $null
        $script:stage = $null
        try {
            $resultPath = Join-Path $completedFolder 'result.json'
            if (-not [IO.File]::Exists($resultPath)) { throw ('后台进程未返回执行结果（退出码 ' + $completedWorker.ExitCode + '）。') }
            $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
            if ($completedStage -eq 'Coder') { Complete-CoderStage -Result $result }
            else { Show-ApplyResult -Result $result }
        } catch {
            if ($completedStage -eq 'Coder') {
                $script:ResultText.Text = $script:autoContext.Alias + ' → ' + $script:autoContext.WorkspaceName + "`r`n本地配置和密钥记录未修改；远端状态尚未确认，工作区可能仍在运行。`r`n" + $_.Exception.Message
            } else {
                $script:ResultText.Text = (Get-RemoteSummary) + "`r`n无法确认本地修改是否完整完成。请刷新并检查配置及备份，不要直接重复提交。`r`n" + $_.Exception.Message
            }
            Set-Status '无法确认完整结果，请查看详情。' $true
        } finally {
            $completedWorker.Dispose()
            Remove-JobFiles -Folder $completedFolder
            # Never dispose or unlock a newly launched Apply worker here.
            if ($null -eq $script:worker) { Set-Busy $false }
        }
    })

    $script:RefreshButton.Add_Click({ if (-not $script:busy) { Read-Hosts } })
    $script:ManageHostsButton.Add_Click({
        if ($script:busy) { return }
        try {
            $changed = Show-HostManager -Owner $script:window -ConfigPath $script:configPath
            Read-Hosts -PreserveInputs
            if ($changed -and $null -ne $script:document -and -not $script:mappingReadError) { Set-Status '本地主机与映射已重新载入。选择主机即可自动启动并同步。' }
        } catch {
            Set-Status '无法打开主机与映射管理，请查看执行结果。' $true
            $script:ResultText.Text = $_.Exception.Message
        }
    })
    $script:AutoHostComboBox.Add_SelectionChanged({ Update-AutoControls })
    $script:CredentialUserName.Add_TextChanged({ Update-AutoControls })
    $script:CredentialPassword.Add_PasswordChanged({ Update-AutoControls })
    $script:SaveCredentialButton.Add_Click({
        if ($script:busy) { return }
        $securePassword = $script:CredentialPassword.SecurePassword
        try {
            $userName = $script:CredentialUserName.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($userName) -or $securePassword.Length -eq 0) { throw '请输入用户名和密码后保存。' }
            $credential = [Management.Automation.PSCredential]::new($userName, $securePassword)
            $null = Save-CoderCredential -Credential $credential
            $script:CredentialPassword.Clear()
            Read-CredentialStatus
            Set-Status '登录凭据已使用当前 Windows 用户加密保存。'
        } catch {
            Set-Status '无法保存登录凭据，请检查本机凭据目录权限后重试。' $true
        } finally { $securePassword.Dispose() }
    })
    $script:StartSyncButton.Add_Click({
        if ($script:busy) { return }
        try {
            $selected = $script:AutoHostComboBox.SelectedItem
            if ($null -eq $selected) { return }
            if (-not $script:hasCredential) { throw '请先在登录设置中保存凭据。' }
            $currentDocument = Read-SshDocument -Path $script:configPath
            if ($currentDocument.Hash -ne $script:document.Hash) { throw '配置已被其他程序修改，请先点击刷新并重新选择主机。' }
            $script:autoContext = [pscustomobject]@{
                HostId = [string]$selected.HostInfo.Id
                Alias = [string]$selected.HostInfo.Alias
                WorkspaceName = [string]$selected.WorkspaceName
                Port = $null
                Started = $false
                RemoteCompleted = $false
            }
            $request = [ordered]@{
                ConfigPath = $script:configPath
                ExpectedHash = $script:document.Hash
                HostId = $script:autoContext.HostId
                Alias = $script:autoContext.Alias
                WorkspaceName = $script:autoContext.WorkspaceName
            }
            Set-Busy $true
            Set-Status ('正在连接 Coder：' + $script:autoContext.Alias + ' → ' + $script:autoContext.WorkspaceName)
            $script:ResultText.Text = '正在读取加密凭据并获取工作区状态；本地 SSH 配置尚未修改。'
            Start-Worker -Stage 'Coder' -FileName 'Start-Coder.ps1' -Request $request
        } catch {
            Set-Status '无法开始自动启动，请查看执行结果。' $true
            $script:ResultText.Text = "本地 SSH 配置未修改。`r`n" + $_.Exception.Message
            Set-Busy $false
        }
    })
    $script:ApplyButton.Add_Click({
        if ($script:busy) { return }
        $script:autoContext = $null
        try {
            $updates = @()
            foreach ($row in $script:rows) {
                $raw = $row.Input.Text.Trim()
                if ($raw.Length -gt 0) { $updates += [pscustomobject]@{ Id = [string]$row.HostInfo.Id; Port = $raw } }
            }
            if ($updates.Count -eq 0) { return }
            Set-Busy $true
            Start-ApplyUpdates -Updates $updates
        } catch {
            Show-LaunchFailure -Exception $_.Exception
            Set-Busy $false
        }
    })
    $script:window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:busy) {
            $eventArgs.Cancel = $true
            Set-Status '操作正在进行，请等待执行结果后再关闭。'
        }
    })
    Read-CredentialStatus
    Read-Hosts
    [void]$script:window.ShowDialog()
} catch {
    [void][Windows.MessageBox]::Show(('应用启动失败：' + $_.Exception.Message), 'SSH 端口助手', 'OK', 'Error')
    exit 1
}
