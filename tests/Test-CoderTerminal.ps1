$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'CoderTerminal.psm1') -Force
$module = Get-Module CoderTerminal
$credential = [pscredential]::new('fixture@example.test', (ConvertTo-SecureString 'fixture-only-password' -AsPlainText -Force))
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
    return @{Workspace=$workspace;Build=$build;Agent=$agent;Calls=[Collections.Generic.List[string]]::new();Terminals=0;SnapshotReads=0;Mode='success';ExpectedWorkspace=$null}
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
            if ($Fixture.Mode -eq 'warming' -and $Fixture.SnapshotReads -ge 2) { $Fixture.Agent.status='connected';$Fixture.Agent.lifecycle_state='ready' }
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
        if ($Request.Command -notmatch 'chmod g-w /root') { throw 'Required command missing.' }
        if ($Fixture.Mode -eq 'transport-fail') { throw 'fixture-secret-leak' }
        if ($Fixture.Mode -eq 'elapsed-after') { Start-Sleep -Milliseconds 1100 }
        $prefix = '__SPM_' + $Request.Nonce + '__'
        switch ($Fixture.Mode) {
            'nonzero' { return "`r`n$prefix|1|0|755`r`n" }
            'stat-fail' { return "`r`n$prefix|0|1|755`r`n" }
            'still-writable' { return "`r`n$prefix|0|0|775`r`n" }
            'no-proof' { return 'fixture-secret-leak' }
            'echo' { return $Request.Command }
            'duplicate-proof' { return "`r`n$prefix|0|0|755`r`n$prefix|0|0|755`r`n" }
            default { return "`r`n$prefix|0|0|755`r`n" }
        }
    }.GetNewClosure()
}
function Run-Fixture($Fixture, [string]$WorkspaceName = '', [int]$Port=32091, [int]$Timeout=5) {
    $args = @{Port=$Port;Credential=$credential;RequestHandler=(Get-HttpHandler $Fixture);TerminalHandler=(Get-TerminalHandler $Fixture);TimeoutSeconds=$Timeout}
    if ($WorkspaceName) { $args.WorkspaceName=$WorkspaceName }
    Invoke-CoderRootPreparation @args
}

$f = New-Fixture
$result = Run-Fixture $f 'PyramidKV'
Assert ($result.WorkspaceName -ceq 'PyramidKV' -and $result.Port -eq 32091 -and $result.Command -ceq 'chmod g-w /root' -and $result.ExitCode -eq 0 -and $result.RootMode -eq '755') 'Expected verified command result.'
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

foreach ($case in @('two-agents','no-agents','windows','bad-agent-id','start-error')) {
    $f=New-Fixture
    switch ($case) {
        'two-agents' {$f.Build.resources[1].agents=@($f.Agent,$f.Agent)}
        'no-agents' {$f.Build.resources[1].Remove('agents')}
        'windows' {$f.Agent.operating_system='windows'}
        'bad-agent-id' {$f.Agent.id='unsafe/agent'}
        'start-error' {$f.Agent.lifecycle_state='start_error'}
    }
    Expect-Failure { Run-Fixture $f } 'agent|identifier|Linux'
    Assert ($f.Terminals -eq 0) 'Unverified agent must never execute.'
}
Pass 'strict unique Linux agent validation, missing fields and lifecycle errors'

$f=New-Fixture;$f.Mode='warming';$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
$result=Run-Fixture $f
Assert ($f.Terminals -eq 1 -and $f.SnapshotReads -eq 3) 'Connecting agent must be polled until ready.'
$f=New-Fixture;$f.Agent.status='connecting';$f.Agent.lifecycle_state='starting'
Expect-Failure { Run-Fixture $f '' 32091 1 } 'timed out before command submission.*chmod was not run'
Assert ($f.Terminals -eq 0) 'Timed-out readiness wait must not run a command.'
$f=New-Fixture;$f.Mode='elapsed-after'
Expect-Failure { Run-Fixture $f '' 32091 1 } 'timed out after command submission.*may already have run'
Assert ($f.Terminals -eq 1) 'Post-command timeout must not resubmit the command.'
$f=New-Fixture
$null=Invoke-CoderRootPreparation -Port 32091 -Credential $credential -RequestHandler (Get-HttpHandler $f) -TerminalHandler (Get-TerminalHandler $f)
Assert ($f.LastTerminal.TimeoutMilliseconds -gt 590000 -and $f.LastTerminal.TimeoutMilliseconds -le 600000) 'Default preparation deadline must allow about ten minutes for cold-start agents.'
Pass 'bounded readiness wait and accurate before/after-submission timeout reporting'

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
