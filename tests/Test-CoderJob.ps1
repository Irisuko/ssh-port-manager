$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'CredentialStore.psm1') -Force
Import-Module (Join-Path $project 'CoderJob.psm1') -Force
Import-Module (Join-Path $project 'SshConfig.psm1') -Force -DisableNameChecking
$testRoot = Join-Path $PSScriptRoot ('coder-job-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:passed = 0
$PSDefaultParameterValues['Invoke-CoderJob:Mappings'] = @{ 'PyramidKV-plugin'='PyramidKV'; 'MuxWise-plugin'='Irisuko' }
function Assert($value, [string]$message) { if (-not $value) { throw $message } }
function Pass([string]$message) { $script:passed++; Write-Output ('PASS: ' + $message) }
try {
    $password = 'fixture-only-secret-!&<>123'
    $credential = [pscredential]::new('fixture@example.test', (ConvertTo-SecureString $password -AsPlainText -Force))
    $credentialPath = Join-Path $testRoot 'login.xml'
    Assert ($null -eq (Read-CoderCredential -Path $credentialPath)) 'Missing credential must return null.'
    Save-CoderCredential -Credential $credential -Path $credentialPath
    $restored = Read-CoderCredential -Path $credentialPath
    Assert ($restored.UserName -eq 'fixture@example.test') 'Username should round trip.'
    Assert ($restored.GetNetworkCredential().Password -ceq $password) 'Protected password should round trip.'
    Assert (-not [IO.File]::ReadAllText($credentialPath).Contains($password)) 'Credential file must not contain plaintext password.'
    Pass 'DPAPI credential round trip without plaintext storage'

    $replacementPassword = 'replacement-fixture-only-123'
    $replacement = [pscredential]::new('replacement@example.test', (ConvertTo-SecureString $replacementPassword -AsPlainText -Force))
    Save-CoderCredential -Credential $replacement -Path $credentialPath
    $restored = Read-CoderCredential -Path $credentialPath
    Assert ($restored.UserName -eq $replacement.UserName -and $restored.GetNetworkCredential().Password -ceq $replacementPassword) 'Saving updated credentials must replace the existing protected file.'
    Assert (-not [IO.File]::ReadAllText($credentialPath).Contains($replacementPassword)) 'Updated credential must remain encrypted.'
    Assert (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp').Count -eq 0) 'Credential replacement must leave no temporary files.'
    Pass 'saved credentials can be replaced atomically without plaintext or temporary files'

    [IO.File]::WriteAllText($credentialPath, '<invalid>')
    $caught = $false
    try { $null = Read-CoderCredential -Path $credentialPath } catch { $caught = $true }
    Assert $caught 'Corrupt credential must fail explicitly.'
    Save-CoderCredential -Credential $credential -Path $credentialPath
    Assert ((Read-CoderCredential -Path $credentialPath).UserName -eq $credential.UserName) 'Saving credentials must repair an unreadable previous file.'
    Pass 'unreadable saved credential requires replacement'

    $configPath = Join-Path $testRoot 'config'
    $source = "Host PyramidKV-plugin`n    HostName 36.140.239.91`n    Port 32041`nHost MuxWise-plugin`n    HostName 36.140.239.91`n    Port 32081`n"
    [IO.File]::WriteAllText($configPath, $source, [Text.UTF8Encoding]::new($false))
    $doc = Read-SshDocument -Path $configPath
    $request = [pscustomobject]@{ ConfigPath=$configPath; ExpectedHash=$doc.Hash; HostId='0'; Alias='PyramidKV-plugin' }
    $fakeStart = { param($Alias,$Credential,$OnProgress) & $OnProgress 'fixture started'; [pscustomobject]@{ WorkspaceName='PyramidKV'; Port=32091; Started=$true; Status='running' } }
    $messages = [Collections.Generic.List[string]]::new()
    $progress = {param($message) $messages.Add($message)}.GetNewClosure()
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $fakeStart -OnProgress $progress
    Assert $result.Success 'Valid selection should succeed.'
    Assert ($result.Port -eq 32091 -and $result.HostId -eq '0') 'Result must tie port to selected ID.'
    Assert ($result.Alias -eq 'PyramidKV-plugin' -and $result.Started) 'Result must retain alias and start outcome.'
    Assert ([IO.File]::ReadAllText($configPath) -ceq $source) 'Network worker must never write config.'
    Assert ($messages.Count -gt 0) 'Progress must be forwarded.'
    Pass 'network result remains tied to selected host without local writes'

    $noCall = { throw 'MUST NOT START REMOTE WORKSPACE' }
    $request.ExpectedHash = '0' * 64
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noCall
    Assert (-not $result.Success -and $result.Error -notmatch 'MUST NOT') 'Stale config must be rejected before network.'
    $request.ExpectedHash = $doc.Hash
    $request.Alias = 'MuxWise-plugin'
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noCall
    Assert (-not $result.Success -and $result.Error -notmatch 'MUST NOT') 'Alias/ID mismatch must be rejected before network.'
    $request.Alias = 'PyramidKV-plugin'
    $request.HostId = '99'
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noCall
    Assert (-not $result.Success -and $result.Error -notmatch 'MUST NOT') 'Unknown ID must be rejected before network.'
    Pass 'stale snapshot and wrong host are rejected before network side effects'

    $request.HostId = '0'
    $request | Add-Member -NotePropertyName WorkspaceName -NotePropertyValue 'UnexpectedServer'
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noCall
    Assert (-not $result.Success -and $result.Error -notmatch 'MUST NOT') 'Changed workspace mapping must be rejected before network.'
    $request.WorkspaceName = 'PyramidKV'
    Pass 'mapping changes are rejected before starting another workspace'

    $request.HostId = '0'
    $badPort = { [pscustomobject]@{WorkspaceName='PyramidKV';Port=0;Started=$false;Status='running'} }
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $badPort
    Assert (-not $result.Success) 'Invalid remote port must fail.'
    $wrongWorkspace = { [pscustomobject]@{WorkspaceName='Irisuko';Port=32091;Started=$false;Status='running'} }
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $wrongWorkspace
    Assert (-not $result.Success) 'Wrong remote workspace must fail.'
    Pass 'invalid network result cannot reach local apply'

    $failedStart = { throw 'Workspace start failed in fixture.' }
    $result = Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $failedStart
    Assert (-not $result.Success -and $result.Error -match 'failed in fixture') 'Failure must be surfaced.'
    Assert ([IO.File]::ReadAllText($configPath) -ceq $source) 'Failures must leave config intact.'
    Pass 'network failures report error and leave configuration intact'

    $argumentsSeen=@{}
    $observed={
        param($Alias,$Credential,$OnProgress,$TimeoutSeconds,$RequireAlreadyRunning,$AllowUnreadyPort)
        $argumentsSeen.Timeout=$TimeoutSeconds;$argumentsSeen.Check=$RequireAlreadyRunning;$argumentsSeen.Pending=$AllowUnreadyPort
        [pscustomobject]@{WorkspaceName='PyramidKV';Port=32091;Started=$false;Status='running'}
    }.GetNewClosure()
    $request | Add-Member -NotePropertyName Mode -NotePropertyValue 'Check'
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $observed
    Assert ($result.Success -and $argumentsSeen.Check -eq $true -and -not $argumentsSeen.Pending -and $argumentsSeen.Timeout -eq 30) 'Check must be read-only and use a short network budget.'
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $fakeStart
    Assert (-not $result.Success) 'A Check result claiming it started a server must never be accepted.'
    $unready={ $errorObject=[InvalidOperationException]::new('fixture not running');$errorObject.Data['CoderNotRunning']=$true;throw $errorObject }
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $unready
    Assert (-not $result.Success -and $result.NotReady -and $null -eq $result.Port) 'Known non-running check must expose NotReady without a stale port.'
    Pass 'check never starts, uses bounded inspection and distinguishes a verified non-running workspace'

    $request.Mode='Auto'
    $request | Add-Member -NotePropertyName DeadlineUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.AddSeconds(45).ToString('o'))
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $observed
    Assert ($result.Success -and $argumentsSeen.Pending -eq $true -and -not $argumentsSeen.Check -and $argumentsSeen.Timeout -gt 0 -and $argumentsSeen.Timeout -le 45) 'Auto requests observed pending allocation with the remaining shared deadline.'
    $request.DeadlineUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noCall
    Assert (-not $result.Success -and $result.Error -notmatch 'MUST NOT') 'Expired startup deadline must reject before network with no old-port fallback.'
    $request.PSObject.Properties.Remove('DeadlineUtc')
    $allocated={ [pscustomobject]@{WorkspaceName='PyramidKV';Port=32123;Started=$true;Status='pending';Deferred=$true} }
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $allocated
    Assert ($result.Success -and $result.Deferred -and $result.Status -ceq 'pending' -and $result.Port -eq 32123) 'Auto may hand off explicitly unready current allocation for bounded preparation.'
    $noEvidence={ [pscustomobject]@{WorkspaceName='PyramidKV';Port=32123;Started=$false;Status='pending'} }
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noEvidence
    Assert (-not $result.Success) 'Unready port without explicit deferred evidence must be rejected.'
    $request.Mode='Check'
    $result=Invoke-CoderJob -Request $request -Credential $credential -StartWorkspace $noEvidence
    Assert (-not $result.Success -and $null -eq $result.Port) 'Check must never accept a pending allocation.'
    Assert ([IO.File]::ReadAllText($configPath) -ceq $source) 'Readiness handling must never mutate local configuration.'
    Pass 'shared startup budget and explicit current pending allocation preserve truthful state and local isolation'
    Write-Output ('Coder job tests passed: ' + $script:passed)
} finally {
    $PSDefaultParameterValues.Remove('Invoke-CoderJob:Mappings')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
