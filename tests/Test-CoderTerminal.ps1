$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'CoderTerminal.psm1') -Force
$module = Get-Module CoderTerminal
$credential = [pscredential]::new('fixture@example.test', (ConvertTo-SecureString 'fixture-only-password' -AsPlainText -Force))
$hostKey=[Convert]::ToBase64String([byte[]](0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+[byte[]](0,0,0,32)+(New-Object byte[] 32))
$script:passed = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Pass([string]$Message) { $script:passed++; Write-Output ('PASS: ' + $Message) }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failed = $false
    try { $null = & $Action } catch {
        $failed = $true
        Assert ($_.Exception.Message -match $Pattern) ('Unexpected sanitized failure: ' + $_.Exception.Message)
        Assert ($_.Exception.Message -notmatch 'fixture-secret-leak') 'Failures must not expose untrusted output or tokens.'
    }
    Assert $failed 'Expected failure did not occur.'
}
function New-Fixture {
    $agent = @{id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';status='connected';lifecycle_state='ready';operating_system='linux'}
    $build = @{id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';status='running';resources=@(
        @{name='ssh';metadata=@(@{key='ssh';sensitive=$false;value='ssh -p 32091 root@36.140.239.91'})},
        @{name='container';agents=@($agent)}
    )}
    $workspace = @{id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';name='PyramidKV';latest_build=@{id=$build.id;status='running'}}
    return @{Workspace=$workspace;Build=$build;Agent=$agent;Calls=[Collections.Generic.List[string]]::new();Terminals=0;SnapshotReads=0;Mode='success';ExpectedWorkspace=$null;HostKey=$hostKey}
}
function Get-HttpHandler($Fixture) {
    return {
        param($Request)
        $path = ([Uri]$Request.Uri).PathAndQuery
        $Fixture.Calls.Add($Request.Method + ' ' + $path)
        $body = $null
        if ($path -eq '/api/v2/users/login') { $body = @{session_token='fixture-session-token'} }
        elseif ($path -eq '/api/v2/workspaces?q=owner%3Ame') {
            $items = @($Fixture.Workspace)
            if ($Fixture.Mode -eq 'ambiguous') { $copy = @{};foreach($k in $Fixture.Workspace.Keys){$copy[$k]=$Fixture.Workspace[$k]};$copy.id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';$copy.name='Other';$items += $copy }
            $body = @{workspaces=$items}
        }
        elseif ($path -like '/api/v2/workspacebuilds/*') {
            $body = $Fixture.Build
        }
        elseif ($path -like '/api/v2/workspaces/*') {
            $Fixture.SnapshotReads++
            if ($Fixture.Mode -eq 'stale-before' -or ($Fixture.Mode -eq 'stale-after' -and $Fixture.Terminals -gt 0)) {
                $Fixture.Workspace.latest_build.id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
            }
            if ($Fixture.Mode -eq 'warming' -and $Fixture.SnapshotReads -ge 2) { $Fixture.Agent.status='connected';$Fixture.Agent.lifecycle_state='ready';$Fixture.Workspace.latest_build.status='running';$Fixture.Build.status='running' }
            $body = $Fixture.Workspace
        }
        else { throw 'Unexpected API endpoint.' }
        [pscustomobject]@{StatusCode=200;Body=$body}
    }.GetNewClosure()
}
function Get-TerminalHandler($Fixture) {
    return {
        param($Request)
        $Fixture.Terminals++
        $Fixture.LastTerminal = $Request
        if ($Request.Uri -notmatch '^wss://coder\.sage\.org\.ai:9450/api/v2/workspaceagents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/pty\?') { throw 'Wrong terminal target.' }
        if ($Request.Uri -match 'fixture-session-token') { throw 'Token leaked in URL.' }
        if ($Request.Command.Contains('__SPM_' + $Request.Nonce + '__')) { throw 'Command echo could spoof the marker.' }
        if ($Request.Command.Contains('__SPK_' + $Request.Nonce + '__')) { throw 'Command echo could spoof host keys.' }
        if ($Request.Command -notmatch 'chmod g-w /root') { throw 'Required command missing.' }
        if ($Request.Command -notmatch '/etc/ssh/ssh_host_\*_key\.pub') { throw 'Only public host key paths must be read.' }
        if ($Fixture.Mode -eq 'transport-fail') { throw 'fixture-secret-leak' }
        if ($Fixture.Mode -eq 'elapsed-after') { Start-Sleep -Milliseconds 1100 }
        $prefix = '__SPM_' + $Request.Nonce + '__'
        $keyPrefix='__SPK_' + $Request.Nonce + '__'
        $keyLine="$keyPrefix|ssh-ed25519|$($Fixture.HostKey)"
        switch ($Fixture.Mode) {
            'nonzero' { return "`r`n$prefix|1|0|755`r`n" }
            'stat-fail' { return "`r`n$prefix|0|1|755`r`n" }
            'still-writable' { return "`r`n$prefix|0|0|775`r`n" }
            'no-proof' { return 'fixture-secret-leak' }
            'echo' { return $Request.Command }
            'duplicate-proof' { return "`r`n$prefix|0|0|755`r`n$prefix|0|0|755`r`n" }
            'no-keys' { return "`r`n$prefix|0|0|755`r`n" }
            'invalid-key' { return "`r`n$keyPrefix|ssh-ed25519|invalid`r`n$prefix|0|0|755`r`n" }
            'malformed-key' { return "`r`n$keyLine`r`n$keyPrefix|broken|extra|fields`r`n$prefix|0|0|755`r`n" }
            'keys-after-proof' { return "`r`n$prefix|0|0|755`r`n$keyLine`r`n" }
            default { return "`r`n$keyLine`r`n$prefix|0|0|755`r`n" }
        }
    }.GetNewClosure()
}
function Run-Fixture($Fixture, [string]$WorkspaceName = '', [int]$Port=32091, [int]$Timeout=5, [int]$Wait=180, [string]$Mode='Sync', [string]$DeadlineUtc='') {
    $args = @{Port=$Port;Credential=$credential;RequestHandler=(Get-HttpHandler $Fixture);TerminalHandler=(Get-TerminalHandler $Fixture);TimeoutSeconds=$Timeout;WaitSeconds=$Wait;Mode=$Mode}
    if ($WorkspaceName) { $args.WorkspaceName=$WorkspaceName }
    if ($DeadlineUtc) { $args.DeadlineUtc=$DeadlineUtc }
    Invoke-CoderRootPreparation @args
}

$f = New-Fixture
$result = Run-Fixture $f 'PyramidKV'
Assert ($result.WorkspaceName -ceq 'PyramidKV' -and $result.Port -eq 32091 -and $result.Command -ceq 'chmod g-w /root' -and $result.ExitCode -eq 0 -and $result.RootMode -eq '755') 'Expected verified command result.'
Assert ($result.Outcome -ceq 'Prepared' -and $result.Ready -and $result.CommandExecuted -and $result.HostKeys.Count -eq 1 -and $result.HostKeys[0].Key -ceq $hostKey) 'Ready result must carry verified SSH host public keys.'
Assert ($f.Terminals -eq 1 -and $f.SnapshotReads -eq 2) 'Command must run once with before/after build revalidation.'
Assert (@($f.Calls | Where-Object { $_ -match '/builds$' }).Count -eq 0) 'Preparation must never start a workspace.'
Assert ($null -eq $f.LastTerminal.SessionToken) 'Retained request objects must be scrubbed of session credentials.'
Pass 'automatic expected workspace and exact port; one command and revalidated completion'

$f = New-Fixture
$result = Run-Fixture $f
Assert ($result.WorkspaceName -eq 'PyramidKV' -and $f.Terminals -eq 1) 'Manual discovery must find unique running workspace by port.'
$f = New-Fixture; $f.Mode='ambiguous'
Expect-Failure { Run-Fixture $f } 'exactly one running'
Assert ($f.Terminals -eq 0) 'Ambiguous port must not execute.'
Pass 'manual exact-port discovery and ambiguity rejection without mutations'

foreach ($case in @('wrong-port','wrong-name','stopped','bad-metadata','sensitive-metadata','injected-metadata')) {
    $f = New-Fixture
    $port=32091;$name='PyramidKV'
    switch ($case) {
        'wrong-port' {$port=32092}
        'wrong-name' {$name='Irisuko'}
        'stopped' {$f.Workspace.latest_build.status='stopped'}
        'bad-metadata' {$f.Build.resources[0].metadata=@()}
        'sensitive-metadata' {$f.Build.resources[0].metadata[0].sensitive=$true}
        'injected-metadata' {$f.Build.resources[0].metadata[0].value='ssh -p 32091 root@36.140.239.91; echo fixture-secret-leak'}
    }
    Expect-Failure { Run-Fixture $f $name $port } 'workspace|metadata'
    Assert ($f.Terminals -eq 0) 'Invalid endpoint selection must never execute.'
}
Pass 'wrong/stopped workspace, mismatched port and sensitive/malicious metadata reject before command'

foreach ($case in @('two-agents','no-agents','windows','bad-agent-id','start-error','unknown-status','unknown-lifecycle')) {
    $f=New-Fixture
    switch ($case) {
        'two-agents' {$f.Build.resources[1].agents=@($f.Agent,$f.Agent)}
        'no-agents' {$f.Build.resources[1].Remove('agents')}
        'windows' {$f.Agent.operating_system='windows'}
        'bad-agent-id' {$f.Agent.id='unsafe/agent'}
        'start-error' {$f.Agent.lifecycle_state='start_error'}
        'unknown-status' {$f.Agent.status='unknown'}
        'unknown-lifecycle' {$f.Agent.lifecycle_state=$null}
    }
    Expect-Failure { Run-Fixture $f } 'agent|identifier|Linux'
    Assert ($f.Terminals -eq 0) 'Unverified agent must never execute.'
}
Pass 'strict unique Linux agent validation, missing fields and lifecycle errors'

$f=New-Fixture;$f.Mode='warming';$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
$result=Run-Fixture $f
Assert ($f.Terminals -eq 1 -and $f.SnapshotReads -eq 3) 'Connecting agent must be polled until ready.'
$f=New-Fixture;$f.Agent.status='connecting';$f.Agent.lifecycle_state='created'
$watch=[Diagnostics.Stopwatch]::StartNew()
$result=Run-Fixture $f '' 32091 5 1
$watch.Stop()
Assert ($result.Outcome -ceq 'Deferred' -and -not $result.Ready -and -not $result.CommandExecuted -and $null -eq $result.ExitCode -and $result.HostKeys.Count -eq 0 -and $f.Terminals -eq 0) 'Known unready agent must defer without command or forged keys.'
Assert ($watch.Elapsed.TotalSeconds -ge 1 -and $watch.Elapsed.TotalSeconds -lt 3) 'Readiness must honor its own bound instead of the longer network budget.'
$f=New-Fixture;$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
$watch.Restart()
$result=Run-Fixture $f '' 32091 5 180 'Check'
$watch.Stop()
Assert ($result.Outcome -ceq 'NotReady' -and $f.Terminals -eq 0 -and $f.SnapshotReads -eq 1 -and $watch.Elapsed.TotalSeconds -lt 2) 'Check must report immediately without starting or polling.'
$f=New-Fixture;$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
$result=Run-Fixture $f '' 32091 5 180 'Sync' ([DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o'))
Assert ($result.Outcome -ceq 'Deferred' -and $f.SnapshotReads -eq 1) 'Shared expired readiness deadline must not reset the wait.'
$f=New-Fixture
$result=Run-Fixture $f '' 32091 5 180 'Sync' ([DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o'))
Assert ($result.Outcome -ceq 'Deferred' -and $f.Terminals -eq 0) 'A late ready snapshot during network grace must not extend the command readiness deadline.'
$f=New-Fixture
$result=Run-Fixture $f '' 32091 5 0 'Check'
Assert ($result.Outcome -ceq 'Prepared' -and $f.Terminals -eq 1) 'Immediate Check may execute when its current readiness snapshot is ready.'
Pass 'bounded readiness deferral, immediate check and shared deadline avoid extra commands'
$f=New-Fixture;$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
Expect-Failure { Run-Fixture $f '' 32091 1 } 'timed out before command submission.*chmod was not run'
Assert ($f.Terminals -eq 0) 'Timed-out readiness wait must not run a command.'
$f=New-Fixture;$f.Mode='elapsed-after'
Expect-Failure { Run-Fixture $f '' 32091 1 } 'timed out after command submission.*may already have run'
Assert ($f.Terminals -eq 1) 'Post-command timeout must not resubmit the command.'
$f=New-Fixture
$null=Invoke-CoderRootPreparation -Port 32091 -Credential $credential -RequestHandler (Get-HttpHandler $f) -TerminalHandler (Get-TerminalHandler $f)
Assert ($f.LastTerminal.TimeoutMilliseconds -gt 209000 -and $f.LastTerminal.TimeoutMilliseconds -le 210000) 'Default operation budget allows three minutes readiness plus a bounded command/network allowance.'
Pass 'bounded readiness wait and accurate before/after-submission timeout reporting'

foreach ($buildState in @('pending','starting')) {
    $f=New-Fixture;$f.Workspace.latest_build.status=$buildState;$f.Build.status=$buildState;$f.Build.resources[1].Remove('agents')
    $result=Run-Fixture $f 'PyramidKV' 32091 5 0
    Assert ($result.Outcome -ceq 'Deferred' -and $f.Terminals -eq 0 -and $result.Port -eq 32091) 'Current pending build with verified port can be handed off without an agent.'
}
$f=New-Fixture;$f.Mode='warming';$f.Workspace.latest_build.status='pending';$f.Build.status='pending'
$result=Run-Fixture $f 'PyramidKV'
Assert ($result.Outcome -ceq 'Prepared' -and $f.Terminals -eq 1 -and $f.SnapshotReads -eq 3) 'Pending build must become running before command submission even when its agent appears ready.'
Pass 'allocated current-build ports defer while pending and become executable only when running'

$f=New-Fixture;$f.Mode='stale-before'
Expect-Failure { Run-Fixture $f } 'workspace changed'
Assert ($f.Terminals -eq 0) 'Stale build must fail before execution.'
$f=New-Fixture;$f.Mode='stale-after'
Expect-Failure { Run-Fixture $f } 'workspace changed'
Assert ($f.Terminals -eq 1) 'Post-command build change must not cause a blind retry.'
Pass 'stale builds rejected before and after execution without resubmission'

foreach ($mode in @('nonzero','stat-fail','still-writable','no-proof','echo','duplicate-proof','transport-fail')) {
    $f=New-Fixture;$f.Mode=$mode
    Expect-Failure { Run-Fixture $f } 'chmod|permissions|completion|group-write'
    Assert ($f.Terminals -eq 1) 'Uncertain or failed terminal command must not be retried.'
}
Pass 'failure/status/mode checks, echo spoofing, missing/duplicate proof and transport failures'

foreach ($mode in @('no-keys','invalid-key','malformed-key','keys-after-proof')) {
    $f=New-Fixture;$f.Mode=$mode
    Expect-Failure { Run-Fixture $f } 'public.key|public keys'
    Assert ($f.Terminals -eq 1) 'Missing or malformed host keys must fail without retrying chmod.'
}
Pass 'missing, malformed and out-of-order host public keys reject trusted-key handoff'

& $module { Initialize-RootTerminalTransport }
$nonce='0123456789abcdef0123456789abcdef'
$complete="noise`r`n__SPM_$nonce`__|0|0|755`r`n"
$bytes=[Text.Encoding]::UTF8.GetBytes($complete)
for($size=1;$size -lt $bytes.Length;$size++) {
    $partial=New-Object byte[] $size;[Array]::Copy($bytes,$partial,$size)
    Assert ($null -eq [SshPortManager.CoderPtyTransport]::CompletedOutput($partial,$nonce)) 'Fragmented proof must not complete before final newline.'
}
Assert ([SshPortManager.CoderPtyTransport]::CompletedOutput($bytes,$nonce) -ceq $complete) 'Full proof must survive arbitrary frame boundaries.'
Expect-Failure { [SshPortManager.CoderPtyTransport]::CompletedOutput((New-Object byte[] 65537),$nonce) } 'Invalid terminal output'
$request = & $module { New-RootTerminalRequest 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' 'fixture-session-token' 1000 }
Expect-Failure { & $module {param($text,$n) Read-RootTerminalProof $text $n} $request.Command $request.Nonce } 'completion record'
$client=[Net.WebSockets.ClientWebSocket]::new()
try {
    $creatorType=[SshPortManager.CoderPtyTransport].GetNestedType('FixedOriginCreator',[Reflection.BindingFlags]::NonPublic)
    $creator=[Activator]::CreateInstance($creatorType,$true)
    Assert ([Net.WebRequest]::RegisterPrefix('wss://coder.sage.org.ai:9450/', $creator)) 'Fixed origin request factory must register in the real Framework prefix table.'
    $httpRequest=[Net.WebRequest]::Create([Uri]'wss://coder.sage.org.ai:9450/api/v2/workspaceagents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/pty')
    Assert (-not $httpRequest.AllowAutoRedirect -and -not $httpRequest.UseDefaultCredentials -and $null -eq $httpRequest.CookieContainer) 'Terminal handshakes must disable redirects/default credentials/cookies.'
    Expect-Failure { $creator.Create([Uri]'wss://example.test/api') } 'Invalid terminal origin'
} finally {$client.Dispose()}
Pass 'compiled transport, every proof fragment boundary, output cap and same-origin nonredirecting handshake'

Write-Output ('Coder terminal tests passed: ' + $script:passed + ' groups (no live network, credentials, SSH mutation or terminal command).')
