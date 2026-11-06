[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$project = Split-Path -Parent $PSScriptRoot
$fixtureFolder = Join-Path $PSScriptRoot ('.ui-check-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureFolder)
$script:fixturePath = Join-Path $fixtureFolder 'config'
$script:fixtureMappingsPath = Join-Path $fixtureFolder 'mappings.json'
$fixture = "Host pyramidkv-plugin`r`n    HostName 36.140.239.91`r`n    Port 31001`r`nHost MuxWise-plugin`r`n    HostName 36.140.239.91`r`n    Port 31002`r`nHost ManualOnly`r`n    HostName 36.140.239.91`r`n    Port 31003`r`n"
[IO.File]::WriteAllText($script:fixturePath, $fixture)

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'App.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $outerTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0]
    $body = $outerTry.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    $body = $body.Replace('$PSScriptRoot', "'" + $project.Replace("'", "''") + "'")
    $configAssignment = '$script:configPath = Join-Path ([Environment]::GetFolderPath(''UserProfile'')) ''.ssh\config'''
    if (-not $body.Contains($configAssignment)) { throw 'Update the test fixture injection for the changed App.ps1 config assignment.' }
    $body = $body.Replace($configAssignment, '$script:configPath = $script:fixturePath')
    $body = $body.Replace('$script:workspaceNames = Get-CoderMappings', '$script:workspaceNames = Get-CoderMappings -Path $script:fixtureMappingsPath')
    if (-not $body.Contains('[void]$script:window.ShowDialog()')) { throw 'Update the test window suppression for the changed App.ps1 entry point.' }
    $body = $body.Replace('[void]$script:window.ShowDialog()', '')
    # Exercise real XAML and event wiring without reading the user's saved credential.
    $body = [regex]::Replace($body, '(?m)^    Read-CredentialStatus\r?$', '    $script:hasCredential = $true')
    $tickAst = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick'
    }, $true))[0]
    $tickBody = $tickAst.Arguments[0].ScriptBlock.Extent.Text
    $script:tickCheck = [scriptblock]::Create($tickBody.Substring(1, $tickBody.Length - 2))

    $checks = {
        function Assert-Check([bool]$Condition, [string]$Message) {
            if (-not $Condition) { throw $Message }
        }

        Assert-Check ($script:AutoHostComboBox.Items.Count -eq 2) 'Expected two mapped current-config hosts, including the case-insensitive alias.'
        Assert-Check ($script:AutoHostComboBox.SelectedIndex -eq -1) 'Automatic default selection must be empty.'
        Assert-Check ($script:rows.Count -eq 3) 'Unmapped target host must remain available for manual editing.'
        Assert-Check (-not $script:StartSyncButton.IsEnabled) 'Automatic action must require an explicit selection.'
        $script:AutoHostComboBox.SelectedIndex = 0
        $selected = $script:AutoHostComboBox.SelectedItem
        $script:rows[1].Input.Text = '33333'
        $script:callCount = 0

        # No process or UAC is launched. The mock captures the real request built by the UI.
        function Start-Worker([string]$Stage, [string]$FileName, [Collections.IDictionary]$Request, [bool]$Elevated = $false) {
            $script:callCount++
            $script:capturedRequest = $Request
            $script:capturedElevated = $Elevated
            $script:worker = [pscustomobject]@{ HasExited = $false; Disposed = $false }
            $script:worker | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            $script:stage = $Stage
        }

        $script:autoContext = [pscustomobject]@{
            HostId = [string]$selected.HostInfo.Id
            Alias = [string]$selected.HostInfo.Alias
            WorkspaceName = [string]$selected.WorkspaceName
            Port = $null
            Started = $false
            RemoteCompleted = $false
        }
        $coderResult = [pscustomobject]@{
            Success = $true
            HostId = $script:autoContext.HostId
            Alias = $script:autoContext.Alias
            WorkspaceName = 'PyramidKV'
            Port = 41234
            Started = $false
            Error = $null
        }
        Set-Busy $true
        Assert-Check (-not $script:ManageHostsButton.IsEnabled) 'Host manager must be unavailable during a running job.'
        Complete-CoderStage $coderResult
        Assert-Check ($script:callCount -eq 1 -and $script:capturedElevated) 'Coder success must hand off to elevated Apply.'
        Assert-Check (@($script:capturedRequest.Updates).Count -eq 1) 'Automatic apply submitted another manual row.'
        Assert-Check ([string]$script:capturedRequest.Updates[0].Id -eq $script:autoContext.HostId) 'Automatic update has the wrong host.'
        Assert-Check ($script:rows[0].Input.Text -eq '41234' -and $script:rows[1].Input.Text -eq '33333') 'Retrieved port display or manual input preservation failed.'

        $script:worker = $null
        [IO.File]::AppendAllText($script:configPath, "# external edit`r`n")
        Complete-CoderStage $coderResult
        Assert-Check ($script:callCount -eq 1) 'Config hash conflict still launched Apply.'
        Assert-Check ($script:ResultText.Text.Contains('41234') -and $script:ResultText.Text.Contains('配置已被其他程序修改')) 'Hash conflict lost remote/port context.'
        [IO.File]::WriteAllText($script:configPath, $fixture)
        Read-Hosts -PreserveInputs

        $script:completed = [pscustomobject]@{ HasExited = $true; ExitCode = 0; Disposed = $false }
        $script:completed | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $script:worker = $script:completed
        $script:stage = 'Coder'
        $script:jobFolder = $fixtureFolder
        [IO.File]::WriteAllText((Join-Path $fixtureFolder 'result.json'), ($coderResult | ConvertTo-Json))
        Set-Busy $true
        & $script:tickCheck
        Assert-Check ($script:completed.Disposed) 'Completed Coder worker was not disposed.'
        Assert-Check ($null -ne $script:worker -and -not $script:worker.Disposed -and $script:stage -eq 'Apply' -and $script:busy) 'Timer disposed or unlocked the newly launched Apply worker.'

        $script:worker = $null
        function Start-Worker { throw [ComponentModel.Win32Exception]::new(1223) }
        Complete-CoderStage $coderResult
        Assert-Check ($script:ResultText.Text.Contains('已取消本地同步') -and $script:ResultText.Text.Contains('41234') -and $script:ResultText.Text.Contains('当前保持运行')) 'UAC cancellation lost remote or port state.'

        $renamedFixture = $fixture.Replace('MuxWise-plugin', 'DifferentHost')
        [IO.File]::WriteAllText($script:configPath, $renamedFixture)
        Read-Hosts -PreserveInputs
        Assert-Check ($script:rows[1].Input.Text -eq '') 'Preserved a port for a different alias at the same Id.'

        # A normal update inserts Port into the first block and shifts all later line IDs.
        $missingPortFixture = $fixture.Replace("    Port 31001`r`n", '')
        [IO.File]::WriteAllText($script:configPath, $missingPortFixture)
        Read-Hosts
        $script:rows[1].Input.Text = '33333'
        $script:AutoHostComboBox.SelectedIndex = 1
        $oldSecondId = [string]$script:rows[1].HostInfo.Id
        $withInsertedPort = New-PortUpdate -Document $script:document -Updates @([pscustomobject]@{ Id = [string]$script:rows[0].HostInfo.Id; Port = '41234' })
        [IO.File]::WriteAllText($script:configPath, $withInsertedPort)
        Read-Hosts -PreserveInputs
        Assert-Check ([string]$script:rows[1].HostInfo.Id -ne $oldSecondId) 'Missing-Port fixture did not shift the subsequent host ID.'
        Assert-Check ($script:rows[1].Input.Text -eq '33333') 'Port insertion discarded an unrelated pending manual input.'
        Assert-Check ($null -ne $script:AutoHostComboBox.SelectedItem -and $script:AutoHostComboBox.SelectedItem.HostInfo.Alias -eq 'MuxWise-plugin') 'Port insertion discarded the unique selected alias.'

        # Do not transfer input or selection when the identity is ambiguous in either snapshot.
        $duplicateFixture = $withInsertedPort + "Host MuxWise-plugin`r`n    HostName 36.140.239.91`r`n    Port 31004`r`n"
        [IO.File]::WriteAllText($script:configPath, $duplicateFixture)
        Read-Hosts -PreserveInputs
        $duplicates = @($script:rows | Where-Object { $_.HostInfo.Alias -eq 'MuxWise-plugin' })
        Assert-Check ($duplicates.Count -eq 2 -and $duplicates[0].Input.Text -eq '' -and $duplicates[1].Input.Text -eq '') 'New duplicate identities inherited a pending input.'
        Assert-Check ($script:AutoHostComboBox.SelectedIndex -eq -1) 'Ambiguous identity inherited an automatic selection.'
        $duplicates[0].Input.Text = '44444'
        $duplicates[1].Input.Text = '55555'
        [IO.File]::WriteAllText($script:configPath, $withInsertedPort)
        Read-Hosts -PreserveInputs
        Assert-Check ($script:rows[1].Input.Text -eq '') 'Previously duplicated identities transferred an ambiguous input.'

        $null = Save-CoderMappings -Mappings @{ ManualOnly = 'CustomWorkspace'; NotInConfig = 'HiddenWorkspace' } -Path $script:fixtureMappingsPath
        Set-Busy $false
        Read-Hosts
        Assert-Check ($script:AutoHostComboBox.Items.Count -eq 1 -and $script:AutoHostComboBox.Items[0].HostInfo.Alias -eq 'ManualOnly') 'Refreshed mappings did not replace defaults or included a host absent from config.'
        Assert-Check ($script:AutoHostComboBox.Items[0].DisplayName -eq 'ManualOnly → CustomWorkspace') 'Dynamic dropdown mapping is not explicit.'
        $script:AutoHostComboBox.SelectedIndex = 0
        function Start-Worker([string]$Stage, [string]$FileName, [Collections.IDictionary]$Request, [bool]$Elevated = $false) {
            $script:capturedCoderRequest = $Request
            $script:capturedCoderElevated = $Elevated
        }
        $script:StartSyncButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:capturedCoderRequest.WorkspaceName -eq 'CustomWorkspace' -and $script:capturedCoderRequest.Alias -eq 'ManualOnly' -and -not $script:capturedCoderElevated) 'Automatic request did not carry the selected mapping snapshot without elevation.'
        Set-Busy $false
        $null = Save-CoderMappings -Mappings @{} -Path $script:fixtureMappingsPath
        Read-Hosts
        Assert-Check ($script:AutoHostComboBox.Items.Count -eq 0 -and $script:rows.Count -eq 3) 'Explicitly empty mappings must leave manual hosts intact without restoring defaults.'
        [IO.File]::WriteAllText($script:fixtureMappingsPath, '{ malformed mapping file')
        Read-Hosts
        $script:rows[0].Input.Text = '34000'
        Assert-Check ($script:rows.Count -eq 3 -and $script:ApplyButton.IsEnabled) 'A malformed mapping file blocked valid manual port editing.'
        Assert-Check ($script:AutoHostComboBox.Items.Count -eq 0 -and -not $script:StartSyncButton.IsEnabled -and $script:mappingReadError.Length -gt 0) 'Malformed mappings silently restored defaults or left automatic startup enabled.'
        Assert-Check ($script:ResultText.Text.Contains('手动更新不受影响')) 'Mapping load error was not clearly separated from manual updates.'

        $script:timer.Stop()
        'PASS: WPF options, automatic handoff/hash/cancel guards, stable manual inputs, dynamic mapping snapshots, and manual fallback for corrupt mappings.'
    }.ToString()
    & ([scriptblock]::Create($body + "`r`n" + $checks))
} finally {
    # All files are test-owned inside the uniquely named fixture directory; no recursion.
    foreach ($checkFile in [IO.Directory]::GetFiles($fixtureFolder)) { [IO.File]::Delete($checkFile) }
    [IO.Directory]::Delete($fixtureFolder, $false)
}
