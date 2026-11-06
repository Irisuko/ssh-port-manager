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
        Assert-Check ($script:CheckHostComboBox.Items.Count -eq 3 -and $script:CheckHostComboBox.SelectedIndex -eq -1 -and -not $script:CheckConnectButton.IsEnabled) 'Check action must offer every literal host and require explicit selection.'
        $script:AutoHostComboBox.SelectedIndex = 0
        $selected = $script:AutoHostComboBox.SelectedItem
        $script:rows[1].Input.Text = '33333'
        $script:callCount = 0
        $script:vsCodeCalls = @()
        function Open-SshInVSCode([string]$Alias) {
            $script:vsCodeCalls += $Alias
            [pscustomobject]@{Launched=$true;Path='fixture-code.exe';Error=$null}
        }
        $wire = [byte[]](@(0,0,0,11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + @(0,0,0,32) + (1..32))
        $script:fixtureHostKey = [pscustomobject]@{Algorithm='ssh-ed25519';Key=[Convert]::ToBase64String($wire)}

        # No process or UAC is launched. The mock captures the real request built by the UI.
        function Start-Worker([string]$Stage, [string]$FileName, [Collections.IDictionary]$Request, [bool]$Elevated = $false) {
            $script:callCount++
            $script:capturedStage = $Stage
            $script:capturedFileName = $FileName
            $script:capturedRequest = $Request
            $script:capturedElevated = $Elevated
            $script:worker = [pscustomobject]@{ HasExited = $false; Disposed = $false }
            $script:worker | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            $script:stage = $Stage
        }

        function New-PreparationResult {
            $results = @()
            $updates = @()
            foreach ($entry in $script:preparationContext.Entries) {
                $workspace = if ($entry.WorkspaceName) { $entry.WorkspaceName } else { 'PortDiscoveredWorkspace' }
                $results += [pscustomobject]@{Id=$entry.Id;Alias=$entry.Alias;Port=$entry.Port;WorkspaceName=$workspace;Command='chmod g-w /root';Success=$true;Outcome='Prepared';Ready=$true;CommandExecuted=$true;RootMode='755';HostKeys=@($script:fixtureHostKey);Error=$null}
                $updates += [pscustomobject]@{Id=$entry.Id;Port=$entry.Port}
            }
            [pscustomobject]@{Success=$true;CanApply=$true;Deferred=$false;Error=$null;Updates=$updates;Results=$results}
        }

        function New-ApplyResult {
            $results = @($script:preparationContext.Entries | ForEach-Object { [pscustomobject]@{Endpoint=('[36.140.239.91]:' + $_.Port);Success=$true;Command='ssh-keygen -R';Output='fixture removed';KeyAdded=$true;AddedKeys=1;KeyPending=$false} })
            [pscustomobject]@{Success=$true;ConfigChanged=$false;BackupPath=$null;KnownHostsBackupPath=$null;Results=$results;Error=$null}
        }

        function Invoke-CapturedCoderJob([int]$Port = 41234) {
            # Exercise the real UI -> JSON -> CoderJob schema, replacing only network I/O.
            Import-Module (Join-Path $project 'CoderJob.psm1') -Force
            $request = $script:capturedRequest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $password = ConvertTo-SecureString 'isolated-fixture-password' -AsPlainText -Force
            $credential = [Management.Automation.PSCredential]::new('fixture@example.invalid', $password)
            $network = {
                param($Alias,$Credential,$OnProgress,$TimeoutSeconds,$RequireAlreadyRunning,$AllowUnreadyPort)
                if ($request.Mode -eq 'Check' -and -not $RequireAlreadyRunning) { throw 'Check mode lost its no-start guard.' }
                if ($request.Mode -eq 'Auto' -and -not $AllowUnreadyPort) { throw 'Auto mode lost pending-port support.' }
                [pscustomobject]@{WorkspaceName='PyramidKV';Port=$Port;Started=$false;Status='running';Deferred=$false}
            }.GetNewClosure()
            try {
                $result = Invoke-CoderJob -Request $request -Credential $credential -Mappings @{'pyramidkv-plugin'='PyramidKV'} -StartWorkspace $network
                Assert-Check $result.Success ('Actual CoderJob rejected the UI request: ' + $result.Error)
                return $result
            } finally { $password.Dispose() }
        }

        function Invoke-CapturedPreparationJob {
            Import-Module (Join-Path $project 'PreparationJob.psm1') -Force
            $request = $script:capturedRequest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $password = ConvertTo-SecureString 'isolated-fixture-password' -AsPlainText -Force
            $credential = [Management.Automation.PSCredential]::new('fixture@example.invalid', $password)
            $hostKey = $script:fixtureHostKey
            $network = {
                param($Port,$Credential,$OnProgress,$Mode,$WaitSeconds,$DeadlineUtc,$TimeoutSeconds,$WorkspaceName)
                if ($Mode -cne $request.Mode) { throw 'Preparation lost the selected operation mode.' }
                if ($Mode -eq 'Check' -and $WaitSeconds -ne 0) { throw 'Check must not wait for startup.' }
                if (-not $WorkspaceName) { $WorkspaceName='PortDiscoveredWorkspace' }
                [pscustomobject]@{WorkspaceName=$WorkspaceName;Port=$Port;Command='chmod g-w /root';Outcome='Prepared';Ready=$true;CommandExecuted=$true;RootMode='755';ExitCode=0;HostKeys=@($hostKey)}
            }.GetNewClosure()
            try {
                $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $network
                Assert-Check $result.Success ('Actual PreparationJob rejected the UI request: ' + $result.Error)
                return $result
            } finally { $password.Dispose() }
        }

        function Assert-Throws([scriptblock]$Action, [string]$Message) {
            $caught = $false
            try { & $Action } catch { $caught = $true }
            Assert-Check $caught $Message
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
        Assert-Check ($script:callCount -eq 1 -and -not $script:capturedElevated -and $script:capturedStage -eq 'Prepare' -and $script:capturedFileName -eq 'Start-Prepare.ps1') 'Coder success must first launch a normal-user Terminal preparation worker.'
        Assert-Check (@($script:capturedRequest.Updates).Count -eq 1) 'Automatic apply submitted another manual row.'
        Assert-Check ([string]$script:capturedRequest.Updates[0].Id -eq $script:autoContext.HostId) 'Automatic update has the wrong host.'
        Assert-Check ($script:capturedRequest.Updates[0].WorkspaceName -ceq 'PyramidKV') 'Auto Terminal preparation lost the frozen workspace identity.'
        Assert-Check ($script:rows[0].Input.Text -eq '41234' -and $script:rows[1].Input.Text -eq '33333') 'Retrieved port display or manual input preservation failed.'

        $forged = New-PreparationResult
        $forged.Results[0].Port = '41235'
        Assert-Throws { Complete-PrepareStage $forged } 'Wrong Terminal result port must be rejected.'
        $forged = New-PreparationResult
        $forged.Results[0].WorkspaceName = 'AnotherWorkspace'
        Assert-Throws { Complete-PrepareStage $forged } 'Wrong automatic workspace must be rejected.'
        $forged = New-PreparationResult
        $forged.Results[0].RootMode = '775'
        Assert-Throws { Complete-PrepareStage $forged } 'Group-writable root must not allow local Apply.'
        $forged = New-PreparationResult
        $forged.Updates[0].Id = 'unselected'
        Assert-Throws { Complete-PrepareStage $forged } 'Forged update selection must be rejected.'
        $forged = New-PreparationResult
        $forged.Results[0].Command = 'true'
        Assert-Throws { Complete-PrepareStage $forged } 'A different remote command must never authorize local Apply.'
        $forged = New-PreparationResult
        $forged.Results[0].HostKeys = @([pscustomobject]@{Algorithm='ssh-ed25519';Key='AAAA'})
        Assert-Throws { Complete-PrepareStage $forged } 'Malformed or forged public key wire data must never authorize local Apply.'
        $forged = New-PreparationResult
        $forged.Results = @()
        Assert-Throws { Complete-PrepareStage $forged } 'Claimed success without per-host Terminal evidence must fail.'
        Assert-Check ($script:callCount -eq 1) 'Invalid Terminal results launched another worker.'

        $prepared = New-PreparationResult
        Complete-PrepareStage $prepared
        Assert-Check ($script:callCount -eq 2 -and $script:capturedElevated -and $script:capturedStage -eq 'Apply') 'Only verified Terminal success may launch elevated Apply.'
        Assert-Check (@($script:capturedRequest.Updates).Count -eq 1 -and $script:capturedRequest.Updates[0].Id -ceq $script:autoContext.HostId) 'Terminal handoff changed the selected local update.'
        Assert-Check ($script:capturedRequest.Updates[0].AddHostKeys -eq $true -and @($script:capturedRequest.Updates[0].HostKeys).Count -eq 1) 'Prepared handoff must explicitly request installation of validated host public keys.'
        Assert-Check ($script:ResultText.Text.Contains('chmod g-w /root') -and $script:ResultText.Text.Contains('755')) 'Awaiting-UAC output must retain successful Terminal evidence.'

        $script:worker = $null
        [IO.File]::AppendAllText($script:configPath, "# external edit`r`n")
        Complete-CoderStage $coderResult
        Assert-Check ($script:callCount -eq 2) 'Config hash conflict still launched preparation.'
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
        Assert-Check ($null -ne $script:worker -and -not $script:worker.Disposed -and $script:stage -eq 'Prepare' -and $script:busy) 'Timer disposed or unlocked the newly launched preparation worker.'
        $prepared = New-PreparationResult
        $script:completed = [pscustomobject]@{ HasExited = $true; ExitCode = 0; Disposed = $false }
        $script:completed | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $script:worker = $script:completed
        $script:stage = 'Prepare'
        $script:jobFolder = $fixtureFolder
        [IO.File]::WriteAllText((Join-Path $fixtureFolder 'result.json'), ($prepared | ConvertTo-Json -Depth 5))
        & $script:tickCheck
        Assert-Check ($script:completed.Disposed -and $script:stage -eq 'Apply' -and -not $script:worker.Disposed -and $script:busy) 'Timer did not preserve the Prepare-to-Apply handoff.'

        $script:worker = $null
        function Start-Worker { throw [ComponentModel.Win32Exception]::new(1223) }
        Complete-PrepareStage $prepared
        Assert-Check ($script:ResultText.Text.Contains('已取消本地同步') -and $script:ResultText.Text.Contains('41234') -and $script:ResultText.Text.Contains('当前保持运行') -and $script:ResultText.Text.Contains('chmod g-w /root')) 'UAC cancellation lost remote command or port state.'

        # Manual mode discovers each running workspace by the supplied port, without starting it.
        function Start-Worker([string]$Stage, [string]$FileName, [Collections.IDictionary]$Request, [bool]$Elevated = $false) {
            $script:callCount++
            $script:capturedStage = $Stage
            $script:capturedFileName = $FileName
            $script:capturedRequest = $Request
            $script:capturedElevated = $Elevated
        }
        $script:worker = $null
        Set-Busy $false
        Read-Hosts
        $blankCallCount = $script:callCount
        $script:ApplyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:callCount -eq $blankCallCount) 'Blank manual ports must not launch any work.'
        $script:rows[0].Input.Text = '41000'
        $script:rows[1].Input.Text = '42000'
        $script:hasCredential = $false
        Update-Preview
        Assert-Check (-not $script:ApplyButton.IsEnabled -and $script:SelectionText.Text.Contains('Coder')) 'Manual mode must explain its login prerequisite.'
        $script:ApplyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:callCount -eq $blankCallCount) 'Manual mode launched Terminal work without credentials.'
        $script:hasCredential = $true
        Update-Preview
        Assert-Check ($script:ApplyButton.IsEnabled) 'Saving credentials should enable a valid manual selection.'
        $script:ApplyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:capturedStage -eq 'Prepare' -and -not $script:capturedElevated -and $script:capturedFileName -eq 'Start-Prepare.ps1') 'Manual click must only launch normal-user Terminal preparation.'
        Assert-Check (@($script:capturedRequest.Updates).Count -eq 2 -and $null -eq $script:capturedRequest.Updates[0].PSObject.Properties['WorkspaceName']) 'Manual selection must omit blank rows and discover by port rather than a binding.'
        $partial = New-PreparationResult
        $partial.Success = $false
        $partial.CanApply = $false
        $partial.Error = 'fixture Terminal failure'
        $partial.Results[1].Success = $false
        $partial.Results[1].Outcome = 'Failed'
        $partial.Results[1].Ready = $false
        $partial.Results[1].CommandExecuted = $false
        $partial.Results[1].HostKeys = @()
        $partial.Results[1].RootMode = ''
        $partial.Results[1].Error = 'fixture rejected'
        $beforePartial = $script:callCount
        Complete-PrepareStage $partial
        Assert-Check ($script:callCount -eq $beforePartial -and -not $script:preparationCompleted) 'Partial Terminal failure must block every local change.'
        Assert-Check ($script:ResultText.Text.Contains('fixture rejected') -and $script:ResultText.Text.Contains('755') -and $script:ResultText.Text.Contains('本地配置和密钥记录未修改')) 'Partial Terminal report must retain successes and failures.'
        Assert-Check ($script:rows[0].Input.Text -eq '41000' -and $script:rows[1].Input.Text -eq '42000') 'Terminal failure discarded manual inputs.'
        $prepared = New-PreparationResult
        [IO.File]::AppendAllText($script:configPath, "# changed during Terminal work`r`n")
        Complete-PrepareStage $prepared
        Assert-Check ($script:callCount -eq $beforePartial -and $script:ResultText.Text.Contains('配置已被其他程序修改')) 'Post-Terminal config hash guard failed.'
        [IO.File]::WriteAllText($script:configPath, $fixture)
        Read-Hosts -PreserveInputs
        Complete-PrepareStage $prepared
        Assert-Check ($script:capturedStage -eq 'Apply' -and $script:capturedElevated -and @($script:capturedRequest.Updates).Count -eq 2) 'Manual Terminal success must hand all frozen selected rows to local Apply.'
        $successApply = New-ApplyResult
        Show-ApplyResult $successApply
        Assert-Check ($script:StatusText.Text.Contains('chmod g-w /root') -and $script:ResultText.Text.Contains('41000') -and $script:ResultText.Text.Contains('42000')) 'Final success must identify the remote command and each manual endpoint.'
        Assert-Check ($script:vsCodeCalls.Count -eq 0) 'Manual or automatic synchronization must not open VS Code.'
        Set-Busy $false

        # Both network phases share the initial deadline, rather than each waiting three minutes.
        Read-Hosts
        Reset-Operation -Mode 'Sync'
        $script:readinessDeadline = [DateTime]::UtcNow.AddSeconds(40)
        Start-CoderSelection -Selected $script:AutoHostComboBox.Items[0]
        $initialDeadline = $script:capturedRequest.DeadlineUtc
        Assert-Check ($script:capturedRequest.Mode -eq 'Auto' -and $script:capturedRequest.TimeoutSeconds -le 40 -and $script:capturedRequest.TimeoutSeconds -gt 0) 'Automatic Coder phase must receive its Auto mode and the remaining global readiness budget.'
        Complete-CoderStage (Invoke-CapturedCoderJob)
        Assert-Check ($script:capturedRequest.WaitSeconds -le 40 -and $script:capturedRequest.WaitSeconds -gt 0 -and $script:capturedRequest.DeadlineUtc -ceq $initialDeadline) 'Preparation reset or lost the global deadline.'
        $script:autoContext.Deferred=$true; $script:autoContext.Status='starting'
        Assert-Check ((Get-RemoteSummary).Contains('仍在等待') -and -not (Get-RemoteSummary).Contains('已运行')) 'Pending Coder builds must not be reported as running servers.'
        Complete-PrepareStage (Invoke-CapturedPreparationJob)
        Assert-Check ((Get-RemoteSummary).Contains('已就绪') -and -not (Get-RemoteSummary).Contains('仍在等待')) 'A later verified preparation must replace the stale waiting status.'
        Show-ApplyResult (New-ApplyResult)
        Assert-Check ($script:vsCodeCalls.Count -eq 0) 'Automatic successful preparation must not open VS Code.'
        Set-Busy $false

        # A positively verified unavailable server may defer chmod, but never claim it ran.
        Read-Hosts
        Reset-Operation -Mode 'Sync'
        Start-PrepareUpdates -Updates @([pscustomobject]@{Id=[string]$script:rows[0].HostInfo.Id;Port='41234'})
        $deferred = New-PreparationResult
        $deferred.Deferred = $true
        $deferred.Results[0].Outcome = 'Deferred'
        $deferred.Results[0].Ready = $false
        $deferred.Results[0].CommandExecuted = $false
        $deferred.Results[0].RootMode = ''
        $deferred.Results[0].HostKeys = @()
        $deferred.Results[0].Error = 'fixture waiting for GPU'
        Assert-Throws { Complete-PrepareStage $deferred } 'A worker may not claim a deadline deferral before the global wait expires.'
        $script:preparationContext.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        $beforeDeferred = $script:callCount
        Complete-PrepareStage $deferred
        Assert-Check ($script:callCount -eq $beforeDeferred + 1 -and $script:capturedStage -eq 'Apply' -and $script:capturedElevated) 'Verified not-ready deadline must still hand port synchronization and cleanup to Apply.'
        Assert-Check ($script:capturedRequest.Updates[0].AddHostKeys -eq $false -and @($script:capturedRequest.Updates[0].HostKeys).Count -eq 0) 'Deferred cleanup must not install empty or unverified host keys.'
        $deferredApply = New-ApplyResult
        $deferredApply.Results[0].KeyAdded = $false
        $deferredApply.Results[0].AddedKeys = 0
        $deferredApply.Results[0].KeyPending = $true
        Show-ApplyResult $deferredApply
        Assert-Check ($script:StatusText.Text.Contains('待服务器就绪') -and -not $script:StatusText.Text.Contains('已执行') -and $script:ResultText.Text.Contains('待处理')) 'Deferred local success falsely reported successful chmod or fully completed keys.'
        Assert-Check ($script:vsCodeCalls.Count -eq 0) 'Deferred synchronization must not open VS Code.'
        Set-Busy $false

        # The new button never starts a stopped mapped workspace or submits other manual inputs.
        Read-Hosts
        $script:CheckHostComboBox.SelectedIndex = 0
        $script:rows[1].Input.Text = '33333'
        $script:CheckConnectButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:capturedStage -eq 'Coder' -and $script:capturedRequest.Mode -eq 'Check' -and -not $script:capturedElevated) 'Mapped check must call Coder in explicit no-start check mode.'
        $beforeNotRunning = $script:callCount
        Complete-CoderStage ([pscustomobject]@{Success=$false;NotReady=$true;Error='fixture stopped'})
        Assert-Check ($script:callCount -eq $beforeNotRunning -and $script:vsCodeCalls.Count -eq 0 -and $script:StatusText.Text.Contains('未启动服务器')) 'Stopped check must not prepare, elevate, start a workspace, or open VS Code.'
        Set-Busy $false
        $script:CheckConnectButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $freshCoder = Invoke-CapturedCoderJob -Port 45123
        Complete-CoderStage $freshCoder
        Assert-Check ($script:capturedStage -eq 'Prepare' -and $script:capturedRequest.Mode -eq 'Check' -and $script:capturedRequest.WaitSeconds -eq 0 -and @($script:capturedRequest.Updates).Count -eq 1 -and $script:capturedRequest.Updates[0].Port -eq '45123') 'Mapped check must refresh exactly the selected host port and check readiness immediately.'
        Assert-Check ($script:rows[1].Input.Text -eq '33333') 'Check changed another manual input.'
        $notReady = New-PreparationResult
        $notReady.Success=$false; $notReady.CanApply=$false
        $notReady.Results[0].Success=$false; $notReady.Results[0].Outcome='NotReady'; $notReady.Results[0].Ready=$false
        $notReady.Results[0].CommandExecuted=$false; $notReady.Results[0].RootMode=''; $notReady.Results[0].HostKeys=@()
        $beforeNotReady = $script:callCount
        Complete-PrepareStage $notReady
        Assert-Check ($script:callCount -eq $beforeNotReady -and $script:vsCodeCalls.Count -eq 0 -and -not $script:preparationCompleted) 'Agent-not-ready check must not modify local files or open VS Code.'
        $illegalDeferred = New-PreparationResult
        $illegalDeferred.Deferred=$true; $illegalDeferred.Results[0].Outcome='Deferred'
        $illegalDeferred.Results[0].Ready=$false; $illegalDeferred.Results[0].CommandExecuted=$false
        $illegalDeferred.Results[0].RootMode=''; $illegalDeferred.Results[0].HostKeys=@()
        Assert-Throws { Complete-PrepareStage $illegalDeferred } 'Check mode must not accept a deferred local update.'
        Complete-PrepareStage (New-PreparationResult)
        Assert-Check ($script:vsCodeCalls.Count -eq 0) 'VS Code must not open before elevated key installation completes.'
        $missingKeys = New-ApplyResult
        $missingKeys.Results[0].KeyAdded=$false; $missingKeys.Results[0].AddedKeys=0
        Show-ApplyResult $missingKeys
        Assert-Check ($script:vsCodeCalls.Count -eq 0 -and $script:StatusText.Text.Contains('无法确认新主机密钥')) 'An unconfirmed host key installation must block VS Code.'
        $wrongEndpoint = New-ApplyResult
        $wrongEndpoint.Results[0].Endpoint='[36.140.239.91]:49999'
        Show-ApplyResult $wrongEndpoint
        Assert-Check ($script:vsCodeCalls.Count -eq 0) 'Unrelated endpoint key evidence must not authorize VS Code.'
        Show-ApplyResult (New-ApplyResult)
        Assert-Check ($script:vsCodeCalls.Count -eq 1 -and $script:vsCodeCalls[0] -ceq 'pyramidkv-plugin') 'Completed mapped check must open VS Code for its frozen SSH alias.'
        Set-Busy $false

        # An unmapped host is checked by its current config port, without any Coder start stage.
        Read-Hosts
        $script:CheckHostComboBox.SelectedIndex = 2
        $script:rows[0].Input.Text = '49998'
        $script:CheckConnectButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Check ($script:capturedStage -eq 'Prepare' -and $script:capturedRequest.Mode -eq 'Check' -and $script:capturedRequest.WaitSeconds -eq 0 -and @($script:capturedRequest.Updates).Count -eq 1 -and $script:capturedRequest.Updates[0].Port -eq '31003' -and -not $script:capturedElevated) 'Unmapped check must immediately prepare only the current configured endpoint.'
        Complete-PrepareStage (Invoke-CapturedPreparationJob)
        $failedApply = New-ApplyResult
        $failedApply.Success=$false; $failedApply.Results[0].Success=$false
        Show-ApplyResult $failedApply
        Assert-Check ($script:vsCodeCalls.Count -eq 1) 'Failed local apply must not open VS Code.'
        Show-ApplyResult (New-ApplyResult)
        Assert-Check ($script:vsCodeCalls.Count -eq 2 -and $script:vsCodeCalls[1] -ceq 'ManualOnly') 'Unmapped ready check must launch the selected literal alias only after key apply succeeds.'
        Assert-Check ($script:rows[0].Input.Text -eq '49998') 'Unmapped check discarded unrelated manual inputs.'
        Set-Busy $false

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
        'PASS: WPF auto/manual/check flows, shared readiness deadlines, deferred cleanup, strict key proofs, no-start checks, VS Code gating, credential/hash/UAC guards, worker handoffs, stable inputs, and dynamic mappings.'
    }.ToString()
    & ([scriptblock]::Create($body + "`r`n" + $checks))
} finally {
    # All files are test-owned inside the uniquely named fixture directory; no recursion.
    foreach ($checkFile in [IO.Directory]::GetFiles($fixtureFolder)) { [IO.File]::Delete($checkFile) }
    [IO.Directory]::Delete($fixtureFolder, $false)
}
