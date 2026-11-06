function Show-HostManager {
    [CmdletBinding()]
    param(
        [AllowNull()][Windows.Window]$Owner,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    Import-Module (Join-Path $PSScriptRoot 'SshConfig.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Mappings.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'HostManagement.psm1') -Force -DisableNameChecking
    $managerWindow = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'HostManager.xaml')))
    if ($null -ne $Owner) { $managerWindow.Owner = $Owner }
    $controls = @{}
    foreach ($name in @('ManagerConfigPathText', 'ManagerReloadButton', 'NewHostButton', 'ManagerHostList', 'ManagerEditorTitle', 'ManagerAliasInput', 'ManagerHostNameInput', 'ManagerUserInput', 'ManagerPortInput', 'ManagerWorkspaceInput', 'ManagerFormHint', 'DeleteHostButton', 'SaveHostButton', 'ManagerResultText', 'ManagerStatusText', 'CloseManagerButton')) {
        $controls[$name] = $managerWindow.FindName($name)
    }
    $controls.ManagerConfigPathText.Text = $ConfigPath
    $state = [pscustomobject]@{
        Document = $null
        Mappings = @{}
        SelectedHost = $null
        IsNew = $false
        Editable = $false
        Changed = $false
        Busy = $false
        SuppressSelection = $false
    }

    function Set-ManagerStatus([string]$Text, [bool]$IsError = $false) {
        $controls.ManagerStatusText.Text = $Text
        $controls.ManagerStatusText.Foreground = if ($IsError) { '#B93838' } else { '#526780' }
    }

    function Update-ManagerControls {
        $canEdit = $state.Editable -and (-not $state.Busy) -and ($null -ne $state.Document)
        foreach ($name in @('ManagerAliasInput', 'ManagerUserInput', 'ManagerPortInput', 'ManagerWorkspaceInput')) { $controls[$name].IsEnabled = $canEdit }
        $controls.SaveHostButton.IsEnabled = $canEdit
        $controls.DeleteHostButton.IsEnabled = $canEdit -and (-not $state.IsNew) -and ($null -ne $state.SelectedHost)
        $controls.NewHostButton.IsEnabled = (-not $state.Busy) -and ($null -ne $state.Document)
        $controls.ManagerReloadButton.IsEnabled = -not $state.Busy
        $controls.ManagerHostList.IsEnabled = -not $state.Busy
        $controls.CloseManagerButton.IsEnabled = -not $state.Busy
    }

    function Clear-ManagerEditor([bool]$ForNew = $false) {
        $state.SelectedHost = $null
        $state.IsNew = $ForNew
        $state.Editable = $ForNew
        $controls.ManagerEditorTitle.Text = if ($ForNew) { '新增本地主机' } else { '选择主机，或点击新增' }
        $controls.ManagerAliasInput.Text = ''
        $controls.ManagerUserInput.Text = if ($ForNew) { 'root' } else { '' }
        $controls.ManagerPortInput.Text = if ($ForNew) { '22' } else { '' }
        $controls.ManagerWorkspaceInput.Text = ''
        $controls.ManagerFormHint.Text = '别名与用户仅支持英文字母、数字、下划线、点和连字符。'
        Update-ManagerControls
    }

    function Select-ManagerHost {
        if ($state.SuppressSelection) { return }
        $item = $controls.ManagerHostList.SelectedItem
        if ($null -eq $item) { Clear-ManagerEditor; return }
        $state.SelectedHost = $item.HostInfo
        $state.IsNew = $false
        $state.Editable = $item.Editable
        $controls.ManagerEditorTitle.Text = if ($item.Editable) { '编辑本地主机' } else { '查看配置块' }
        $controls.ManagerAliasInput.Text = [string]$item.HostInfo.Alias
        $controls.ManagerUserInput.Text = [string]$item.HostInfo.User
        $controls.ManagerPortInput.Text = [string]$item.HostInfo.Port
        $controls.ManagerWorkspaceInput.Text = [string]$item.WorkspaceName
        $controls.ManagerFormHint.Text = if ($item.Editable) { '保存将更新此主机及其映射，并保留其他配置。' } else { '多别名、通配符或其他非简单别名配置块仅可查看。请在 SSH 配置文件中编辑。' }
        Update-ManagerControls
    }

    function Read-ManagerHosts([string]$SelectAlias = '') {
        $state.SuppressSelection = $true
        $state.Document = $null
        $controls.ManagerHostList.ItemsSource = $null
        Clear-ManagerEditor
        try {
            $document = Read-SshDocument -Path $ConfigPath
            $mappings = Get-CoderMappings
            $items = @()
            foreach ($hostInfo in @(Get-TargetHosts -Document $document)) {
                $workspaceName = if ($mappings.ContainsKey([string]$hostInfo.Alias)) { [string]$mappings[[string]$hostInfo.Alias] } else { '' }
                $editable = [string]$hostInfo.Alias -cmatch '^[A-Za-z0-9_.-]+$'
                $connection = if ([string]::IsNullOrWhiteSpace($hostInfo.User)) { $hostInfo.HostName } else { $hostInfo.User + '@' + $hostInfo.HostName }
                $items += [pscustomobject]@{
                    HostInfo = $hostInfo
                    Alias = [string]$hostInfo.Alias
                    Connection = $connection + ':' + $hostInfo.Port
                    WorkspaceName = $workspaceName
                    MappingLabel = if ($workspaceName) { 'Coder → ' + $workspaceName } else { '未绑定 Coder 工作区' }
                    Editable = $editable
                    EditHint = if ($editable) { '' } else { '只读配置块' }
                }
            }
            $state.Document = $document
            $state.Mappings = $mappings
            $controls.ManagerHostList.ItemsSource = $items
            $controls.ManagerHostList.SelectedIndex = -1
            if ($SelectAlias) {
                $matches = @($items | Where-Object { [string]::Equals($_.Alias, $SelectAlias, [StringComparison]::OrdinalIgnoreCase) })
                if ($matches.Count -eq 1) { $controls.ManagerHostList.SelectedItem = $matches[0] }
            }
            Set-ManagerStatus ('已读取 ' + $items.Count + ' 个本地主机；目标 IP 固定为 36.140.239.91。')
        } catch {
            Set-ManagerStatus ('读取失败：' + $_.Exception.Message) $true
            $controls.ManagerResultText.Text = $_.Exception.Message
        } finally {
            $state.SuppressSelection = $false
            Select-ManagerHost
            Update-ManagerControls
        }
    }

    function Get-ManagerFormValues {
        $alias = $controls.ManagerAliasInput.Text.Trim()
        $userName = $controls.ManagerUserInput.Text.Trim()
        $portText = $controls.ManagerPortInput.Text.Trim()
        $workspaceRaw = $controls.ManagerWorkspaceInput.Text
        $workspaceName = $workspaceRaw.Trim()
        if ($alias -cnotmatch '^[A-Za-z0-9_.-]+$') { throw 'SSH 别名仅可包含英文字母、数字、下划线、点和连字符，且不能为空。' }
        if ($userName -cnotmatch '^[A-Za-z0-9_.-]+$') { throw 'SSH 用户仅可包含英文字母、数字、下划线、点和连字符，且不能为空。' }
        $port = 0
        if ($portText -notmatch '^[0-9]{1,5}$' -or -not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw '端口必须为 1–65535 的整数。' }
        if ($workspaceName.Length -gt 128 -or $workspaceRaw -match '[\r\n]') { throw 'Coder 工作区名称最多 128 个字符，且不能包含换行。' }
        return @{ Alias = $alias; User = $userName; Port = [string]$port; WorkspaceName = $workspaceName }
    }

    function Show-ManagerChangeResult($Result, [string]$SelectAlias = '') {
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add($(if ($Result.ConfigChanged) { '✓ 本地 SSH 配置已保存。' } else { '本地 SSH 配置未改变。' }))
        $lines.Add($(if ($Result.MappingsSaved) { '✓ 本地工作区映射已保存。' } else { '本地工作区映射未保存。' }))
        if ($Result.ConfigBackupPath) { $lines.Add('SSH 配置备份：' + [string]$Result.ConfigBackupPath) }
        if ($Result.MappingBackupPath) { $lines.Add('工作区映射备份：' + [string]$Result.MappingBackupPath) }
        if ($Result.Error) { $lines.Add([string]$Result.Error) }
        if ($Result.ConfigChanged -or $Result.MappingsSaved) { $state.Changed = $true }
        $reloadFailed = $false
        if ($Result.Success -or $Result.ConfigChanged -or $Result.MappingsSaved) {
            Read-ManagerHosts -SelectAlias $SelectAlias
            $reloadFailed = $null -eq $state.Document
            if ($reloadFailed) { $lines.Add('重新加载失败：' + $controls.ManagerResultText.Text) }
        }
        $controls.ManagerResultText.Text = $lines -join "`r`n"
        if ($reloadFailed) { Set-ManagerStatus '已收到保存结果，但无法重新加载配置或映射。请查看执行结果后点击刷新。' $true }
        elseif ($Result.Success) { Set-ManagerStatus '已保存本地主机与映射。' }
        elseif ($Result.ConfigChanged -or $Result.MappingsSaved) { Set-ManagerStatus '操作部分完成；请查看已保存的内容、备份与错误，再重新编辑。' $true }
        else { Set-ManagerStatus '未完成保存，请查看执行结果。' $true }
    }

    function Save-ManagerHost {
        if ($state.Busy -or -not $state.Editable -or $null -eq $state.Document) { return }
        try {
            $values = Get-ManagerFormValues
            $options = @{
                ConfigPath = $ConfigPath
                ExpectedHash = $state.Document.Hash
                Action = if ($state.IsNew) { 'Add' } else { 'Edit' }
                Alias = $values.Alias
                User = $values.User
                Port = $values.Port
                WorkspaceName = $values.WorkspaceName
            }
            if (-not $state.IsNew) { $options.Id = [string]$state.SelectedHost.Id }
            $state.Busy = $true
            Update-ManagerControls
            $result = Invoke-HostManagementChange @options
            Show-ManagerChangeResult -Result $result -SelectAlias $values.Alias
        } catch {
            Set-ManagerStatus ('保存未完成：' + $_.Exception.Message) $true
            $controls.ManagerResultText.Text = $_.Exception.Message
        } finally {
            $state.Busy = $false
            Update-ManagerControls
        }
    }

    function Remove-ManagerHost {
        if ($state.Busy -or -not $state.Editable -or $state.IsNew -or $null -eq $state.SelectedHost) { return }
        $selectedHost = $state.SelectedHost
        $message = "将从本机 SSH 配置中删除以下完整 Host 配置块，并解除它的本地工作区映射：`r`n`r`nHost " + $selectedHost.Alias + "`r`n36.140.239.91:" + $selectedHost.Port + "`r`n`r`n文件：" + $ConfigPath + "`r`n`r`n远端 Coder 工作区不会被删除或停止。继续删除？"
        $answer = [Windows.MessageBox]::Show($managerWindow, $message, '删除本地主机', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        try {
            $state.Busy = $true
            Update-ManagerControls
            $result = Invoke-HostManagementChange -ConfigPath $ConfigPath -ExpectedHash $state.Document.Hash -Action Delete -Id ([string]$selectedHost.Id)
            Show-ManagerChangeResult -Result $result
        } catch {
            Set-ManagerStatus ('删除未完成：' + $_.Exception.Message) $true
            $controls.ManagerResultText.Text = $_.Exception.Message
        } finally {
            $state.Busy = $false
            Update-ManagerControls
        }
    }

    $controls.ManagerHostList.Add_SelectionChanged({ Select-ManagerHost })
    $controls.ManagerReloadButton.Add_Click({ if (-not $state.Busy) { Read-ManagerHosts } })
    $controls.NewHostButton.Add_Click({
        if ($state.Busy) { return }
        $controls.ManagerHostList.SelectedIndex = -1
        Clear-ManagerEditor -ForNew $true
        [void]$controls.ManagerAliasInput.Focus()
    })
    $controls.SaveHostButton.Add_Click({ Save-ManagerHost })
    $controls.DeleteHostButton.Add_Click({ Remove-ManagerHost })
    $controls.CloseManagerButton.Add_Click({ $managerWindow.Close() })
    $managerWindow.Add_Closing({ param($sender, $eventArgs) if ($state.Busy) { $eventArgs.Cancel = $true } })
    Read-ManagerHosts
    [void]$managerWindow.ShowDialog()
    return [bool]$state.Changed
}
