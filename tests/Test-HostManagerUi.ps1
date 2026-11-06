[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$project = Split-Path -Parent $PSScriptRoot
$fixtureFolder = Join-Path $PSScriptRoot ('.manager-ui-check-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureFolder)
$script:managerFixtureConfig = Join-Path $fixtureFolder 'config'
$script:managerFixtureMappings = Join-Path $fixtureFolder 'mappings.json'
$fixture = "# preserve this comment`r`nHost FirstHost`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 31001`r`nHost one two`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 31002`r`nHost gpu-*`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 31003`r`nHost OtherIp`r`n    HostName 192.0.2.10`r`n    Port 31004`r`n"
[IO.File]::WriteAllText($script:managerFixtureConfig, $fixture)

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $project 'Mappings.psm1') -Force
    $null = Save-CoderMappings -Mappings @{ FirstHost = 'ExistingWorkspace'; Unrelated = 'KeepWorkspace' } -Path $script:managerFixtureMappings
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'HostManager.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-HostManager' }, $true))[0]
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    $body = $body.Replace('$PSScriptRoot', "'" + $project.Replace("'", "''") + "'")
    $body = $body.Replace('$mappings = Get-CoderMappings', '$mappings = Get-CoderMappings -Path $script:managerFixtureMappings')
    $body = $body.Replace('Invoke-HostManagementChange @options', 'Invoke-HostManagementChange @options -MappingsPath $script:managerFixtureMappings')
    $body = $body.Replace('Invoke-HostManagementChange -ConfigPath', 'Invoke-HostManagementChange -MappingsPath $script:managerFixtureMappings -ConfigPath')
    # Suppress every window and confirm only the test-owned deletion, never a real host.
    $body = [regex]::Replace($body, '(?m)^        \$answer = \[Windows.MessageBox\]::Show\([^\r\n]+\)\r?$', '        $answer = [Windows.MessageBoxResult]::Yes')
    $body = $body.Replace('return [bool]$state.Changed', '')
    $checks = {
        function Assert-Manager([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
        Assert-Manager ($controls.ManagerHostList.Items.Count -eq 3) 'Manager did not limit rows to direct fixed-IP hosts.'
        Assert-Manager ($controls.ManagerHostNameInput.IsReadOnly -and $controls.ManagerHostNameInput.Text -eq '36.140.239.91') 'Target IP must stay fixed and read-only.'
        Assert-Manager (-not $controls.SaveHostButton.IsEnabled -and -not $controls.DeleteHostButton.IsEnabled) 'An untouched manager must not edit a default selection.'

        foreach ($readOnlyAlias in @('one two', 'gpu-*')) {
            $controls.ManagerHostList.SelectedItem = @($controls.ManagerHostList.Items | Where-Object { $_.Alias -eq $readOnlyAlias })[0]
            Assert-Manager (-not $state.Editable -and -not $controls.ManagerAliasInput.IsEnabled -and -not $controls.SaveHostButton.IsEnabled -and -not $controls.DeleteHostButton.IsEnabled) 'Complex Host block was editable.'
            $before = [IO.File]::ReadAllText($ConfigPath)
            Save-ManagerHost
            Remove-ManagerHost
            Assert-Manager ([IO.File]::ReadAllText($ConfigPath) -ceq $before) 'Read-only host handler mutated the config.'
        }

        $controls.NewHostButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Manager ($state.IsNew -and $controls.ManagerUserInput.Text -eq 'root' -and $controls.ManagerPortInput.Text -eq '22') 'New-host defaults are incorrect.'
        $controls.ManagerAliasInput.Text = 'DynamicAlias'
        $controls.ManagerPortInput.Text = '32000'
        $controls.ManagerWorkspaceInput.Text = '  DynamicWorkspace  '
        $beforeHash = $state.Document.Hash
        $controls.SaveHostButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Manager ($state.Changed -and -not $state.IsNew -and $state.SelectedHost.Alias -eq 'DynamicAlias') ('Add did not reload/select the new host: ' + $controls.ManagerResultText.Text)
        Assert-Manager ($state.Document.Hash -ne $beforeHash -and $controls.ManagerWorkspaceInput.Text -eq 'DynamicWorkspace') 'Add did not refresh hash or trim the mapping.'
        $mappings = Get-CoderMappings -Path $script:managerFixtureMappings
        Assert-Manager ($mappings['DynamicAlias'] -eq 'DynamicWorkspace' -and $mappings['Unrelated'] -eq 'KeepWorkspace') 'Add changed unrelated mappings.'

        $controls.ManagerAliasInput.Text = 'RenamedAlias'
        $controls.ManagerUserInput.Text = 'ubuntu'
        $controls.ManagerPortInput.Text = '32100'
        $controls.ManagerWorkspaceInput.Text = ''
        Save-ManagerHost
        $mappings = Get-CoderMappings -Path $script:managerFixtureMappings
        Assert-Manager ($state.SelectedHost.Alias -eq 'RenamedAlias' -and $state.SelectedHost.User -eq 'ubuntu' -and $state.SelectedHost.Port -eq 32100) ('Edit did not refresh the row: ' + $controls.ManagerResultText.Text)
        Assert-Manager (-not $mappings.ContainsKey('DynamicAlias') -and -not $mappings.ContainsKey('RenamedAlias') -and $mappings['Unrelated'] -eq 'KeepWorkspace') 'Rename/unbind left the old mapping or changed unrelated mappings.'

        $before = [IO.File]::ReadAllText($ConfigPath)
        $controls.ManagerAliasInput.Text = 'bad alias'
        Save-ManagerHost
        Assert-Manager ([IO.File]::ReadAllText($ConfigPath) -ceq $before) 'Invalid alias changed config.'
        $controls.ManagerAliasInput.Text = 'RenamedAlias'
        $controls.ManagerPortInput.Text = '65536'
        Save-ManagerHost
        Assert-Manager ([IO.File]::ReadAllText($ConfigPath) -ceq $before) 'Invalid port changed config.'
        $controls.ManagerPortInput.Text = '32100'
        $controls.ManagerWorkspaceInput.Text = "bad`nworkspace"
        Save-ManagerHost
        Assert-Manager ([IO.File]::ReadAllText($ConfigPath) -ceq $before) 'Multiline workspace changed config.'
        $controls.ManagerWorkspaceInput.Text = ''
        Remove-ManagerHost
        Assert-Manager (-not [IO.File]::ReadAllText($ConfigPath).Contains('RenamedAlias')) ('Delete left the selected local host: ' + $controls.ManagerResultText.Text)
        Assert-Manager ([IO.File]::ReadAllText($ConfigPath).Contains("Host OtherIp`r`n    HostName 192.0.2.10`r`n    Port 31004")) 'Management changed the unrelated IP block.'

        # Simulate a mapping write failure after a successful fixture config save.
        function Invoke-HostManagementChange {
            param($ConfigPath, $ExpectedHash, $Action, $Id, $Alias, $User, $Port, $WorkspaceName, $MappingsPath)
            $doc = Read-SshDocument -Path $ConfigPath
            $text = New-SshHostChange -Document $doc -Action $Action -Id $Id -Alias $Alias -User $User -Port $Port
            $saved = Save-SshDocument -Document $doc -Text $text -ExpectedHash $ExpectedHash
            return [pscustomobject]@{ Success = $false; ConfigChanged = $saved.Changed; ConfigBackupPath = $saved.BackupPath; MappingBackupPath = $null; MappingsSaved = $false; Error = 'Fixture mapping write failure.' }
        }
        $controls.ManagerHostList.SelectedItem = @($controls.ManagerHostList.Items | Where-Object { $_.Alias -eq 'FirstHost' })[0]
        $controls.ManagerPortInput.Text = '33000'
        $controls.ManagerWorkspaceInput.Text = 'ReplacementWorkspace'
        Save-ManagerHost
        Assert-Manager ($state.SelectedHost.Port -eq 33000 -and $state.Document.Hash -eq (Read-SshDocument -Path $ConfigPath).Hash) 'Partial save did not reload the changed config snapshot.'
        Assert-Manager ($controls.ManagerWorkspaceInput.Text -eq 'ExistingWorkspace') 'Partial save incorrectly showed the failed mapping as saved.'
        Assert-Manager ($controls.ManagerResultText.Text.Contains('本地 SSH 配置已保存') -and $controls.ManagerResultText.Text.Contains('本地工作区映射未保存') -and $controls.ManagerResultText.Text.Contains('Fixture mapping write failure.') -and $controls.ManagerStatusText.Text.Contains('部分完成')) 'Partial save did not report config/mapping status accurately.'
        'PASS: host manager fixed-IP/read-only rows, local add/edit/unbind/delete, validation, backup reload, and partial-save reporting.'
    }.ToString()
    if (-not $body.Contains('[void]$managerWindow.ShowDialog()')) { throw 'Manager dialog suppression marker changed.' }
    $body = $body.Replace('[void]$managerWindow.ShowDialog()', $checks)
    & ([scriptblock]::Create($body)) -ConfigPath $script:managerFixtureConfig
} finally {
    # Every file is fixture-owned; backups remain inside this unique directory.
    foreach ($path in [IO.Directory]::GetFiles($fixtureFolder)) { [IO.File]::Delete($path) }
    [IO.Directory]::Delete($fixtureFolder, $false)
}
