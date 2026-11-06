$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'PreparationJob.psm1') -Force
Import-Module (Join-Path $project 'SshConfig.psm1') -Force -DisableNameChecking
$testRoot = Join-Path $PSScriptRoot ('.runs\preparation-job-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Pass([string]$Message) { $script:passed++; Write-Output ('PASS: ' + $Message) }
try {
    $config = Join-Path $testRoot 'config'
    $original = "Host PyramidKV-plugin`n HostName 36.140.239.91`n Port 31001`nHost MuxWise-plugin`n HostName 36.140.239.91`n Port 31002`nHost Other`n HostName 192.0.2.1`n Port 22`n"
    [IO.File]::WriteAllText($config, $original)
    $doc = Read-SshDocument -Path $config
    $hosts = @(Get-TargetHosts -Document $doc)
    $id1 = [string]$hosts[0].Id; $id2 = [string]$hosts[1].Id
    $credential = [pscredential]::new('fixture@example.test', (ConvertTo-SecureString 'fixture-password' -AsPlainText -Force))
    $request = [pscustomobject]@{ConfigPath=$config;ExpectedHash=$doc.Hash;Updates=@([pscustomobject]@{Id=$id1;Port='32091';WorkspaceName='PyramidKV'},[pscustomobject]@{Id=$id2;Port=' '})}
    $calls = [Collections.Generic.List[object]]::new()
    $progress = [Collections.Generic.List[string]]::new()
    $prepare = {
        param($Port,$Credential,$WorkspaceName,$OnProgress)
        $calls.Add([pscustomobject]@{Port=$Port;WorkspaceName=$WorkspaceName})
        & $OnProgress 'fixture progress'
        [pscustomobject]@{WorkspaceName=$(if ($WorkspaceName) {$WorkspaceName} else {'Discovered'});Port=$Port;Command='chmod g-w /root';RootMode='0755';ExitCode=0}
    }.GetNewClosure()
    $onProgress = {param($Message) $progress.Add($Message)}.GetNewClosure()
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $prepare -OnProgress $onProgress
    Assert $result.Success 'A valid preparation should succeed.'
    Assert ($calls.Count -eq 1 -and $calls[0].WorkspaceName -ceq 'PyramidKV') 'Blank hosts must be skipped and automatic workspace frozen.'
    Assert ($result.Updates.Count -eq 1 -and $result.Updates[0].Id -ceq $id1 -and $result.Updates[0].Port -eq 32091) 'Returned updates must preserve selected Id and normalized port.'
    Assert ($result.Results.Count -eq 1 -and $result.Results[0].Success -and $result.Results[0].Command -ceq 'chmod g-w /root') 'Return explicit command success for selected host.'
    Assert ($progress.Count -ge 2 -and [IO.File]::ReadAllText($config) -ceq $original) 'Progress is forwarded and configuration must remain unchanged.'
    Assert ($credential.Password.Length -gt 0) 'Caller-owned credentials must not be disposed.'
    Pass 'automatic snapshot, blank skip, verified command result and no local changes'

    $request.Updates = @([pscustomobject]@{Id=$id1;Port='32092'})
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $prepare
    Assert ($result.Success -and [string]::IsNullOrEmpty($calls[1].WorkspaceName) -and $result.Results[0].WorkspaceName -ceq 'Discovered') 'Manual mode must discover by port without requesting a workspace start.'
    Pass 'manual preparation discovers workspace by exact port'

    foreach ($empty in @(@(), @([pscustomobject]@{Id='unknown';Port=' '}))) {
        $request.Updates = $empty
        $result = Invoke-PreparationJob -Request $request -PrepareWorkspace { throw 'NETWORK MUST NOT RUN' }
        Assert ($result.Success -and $result.Updates.Count -eq 0 -and $result.Results.Count -eq 0) 'Empty or all-blank selections must succeed without credentials or network.'
    }
    Pass 'empty selections do not read credentials or run remote commands'

    $badUpdates = @(
        @([pscustomobject]@{Id=$id1;Port='32091'},[pscustomobject]@{Id=$id2;Port='65536'}),
        @([pscustomobject]@{Id=$id1;Port='32091'},[pscustomobject]@{Id=$id1;Port='32092'}),
        @([pscustomobject]@{Id='6';Port='32091'}),
        @([pscustomobject]@{Id='unknown';Port='32091'}),
        @([pscustomobject]@{Id=$id1;Port='32091; whoami'}),
        @([pscustomobject]@{Id=$id1;Port='32091';WorkspaceName="bad`nname"})
    )
    foreach ($updates in $badUpdates) {
        $request.Updates = $updates
        $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace { throw 'NETWORK MUST NOT RUN' }
        Assert (-not $result.Success -and $result.Results.Count -eq 0 -and $result.Error -notmatch 'NETWORK MUST NOT RUN') 'Validate the complete request before the first remote command.'
    }
    Pass 'invalid later rows, duplicates, unrelated hosts and unsafe inputs fail before all remote effects'

    $request.Updates = @([pscustomobject]@{Id=$id1;Port=32091})
    $request.ExpectedHash = '0' * 64
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace { throw 'NETWORK MUST NOT RUN' }
    Assert (-not $result.Success -and $result.Results.Count -eq 0 -and $result.Error -notmatch 'NETWORK MUST NOT RUN') 'Stale snapshot must reject before network.'
    $request.ExpectedHash = $doc.Hash
    Pass 'stale config rejected before remote effects'

    foreach ($case in @('Port','Workspace','Command','Mode','Exit','Missing')) {
        $request.Updates = @([pscustomobject]@{Id=$id1;Port=32091;WorkspaceName='PyramidKV'})
        $badResult = {
            param($Port,$Credential,$WorkspaceName,$OnProgress)
            $remote = [pscustomobject]@{WorkspaceName='PyramidKV';Port=32091;Command='chmod g-w /root';RootMode='755';ExitCode=0}
            switch ($case) {
                'Port' {$remote.Port=32092}
                'Workspace' {$remote.WorkspaceName='Other'}
                'Command' {$remote.Command='chmod 777 /root'}
                'Mode' {$remote.RootMode='775'}
                'Exit' {$remote.ExitCode=1}
                'Missing' {$remote.PSObject.Properties.Remove('ExitCode')}
            }
            return $remote
        }.GetNewClosure()
        $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $badResult
        Assert (-not $result.Success -and $result.Results.Count -eq 1 -and -not $result.Results[0].Success) ('Reject unverified terminal result: ' + $case)
    }
    Pass 'wrong target, command, writable mode and missing or nonzero exit cannot report success'

    $request.Updates = @([pscustomobject]@{Id=$id1;Port=32091},[pscustomobject]@{Id=$id2;Port=32092})
    $callState = @{Count=0}
    $partial = {
        param($Port,$Credential,$WorkspaceName,$OnProgress)
        $callState.Count++
        if ($callState.Count -eq 2) { throw 'Fixture terminal unavailable.' }
        [pscustomobject]@{WorkspaceName='First';Port=$Port;Command='chmod g-w /root';RootMode='700';ExitCode=0}
    }.GetNewClosure()
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $partial
    Assert (-not $result.Success -and $result.Results.Count -eq 2 -and $result.Results[0].Success -and -not $result.Results[1].Success) 'Preserve completed remote result when next server fails.'
    Assert ([IO.File]::ReadAllText($config) -ceq $original) 'Partial remote failure must leave SSH files unchanged.'
    Pass 'partial completion preserves success and failure details without local mutation'

    $callState.Count=0
    $firstFailure = {
        param($Port,$Credential,$WorkspaceName,$OnProgress)
        $callState.Count++
        throw 'Fixture first terminal unavailable.'
    }.GetNewClosure()
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $firstFailure
    Assert (-not $result.Success -and $callState.Count -eq 1 -and $result.Results.Count -eq 1) 'First failure must stop remote commands for all later hosts.'
    Pass 'first remote failure stops later hosts without pretending they ran'

    $callState.Count=0
    $externalEdit = {
        param($Port,$Credential,$WorkspaceName,$OnProgress)
        $callState.Count++
        [IO.File]::AppendAllText($config, '# external fixture edit')
        [pscustomobject]@{WorkspaceName='First';Port=$Port;Command='chmod g-w /root';RootMode='755';ExitCode=0}
    }.GetNewClosure()
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $externalEdit
    Assert (-not $result.Success -and $callState.Count -eq 1 -and $result.Results[0].Success) 'Config change after first remote command must prevent later commands and local handoff.'
    [IO.File]::WriteAllText($config,$original)
    $request.Updates = @([pscustomobject]@{Id=$id1;Port=32091})
    $result = Invoke-PreparationJob -Request $request -Credential $credential -PrepareWorkspace $externalEdit
    Assert (-not $result.Success -and $result.Results.Count -eq 1 -and $result.Results[0].Success) 'Final snapshot must be rechecked even after single-host preparation.'
    Pass 'external edits stop subsequent remote work and invalidate final handoff'
    Write-Output ('Preparation job tests passed: ' + $script:passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runs')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
