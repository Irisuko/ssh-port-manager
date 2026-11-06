$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$appRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'Coder.psm1'))) {
    throw 'FAIL: Coder automation is not implemented.'
}
Import-Module (Join-Path $appRoot 'Coder.psm1') -Force
$script:passed = 0
$defaultMappings = @{ 'PyramidKV-plugin' = 'PyramidKV'; 'MuxWise-plugin' = 'Irisuko' }
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw ('FAIL: ' + $Message + ' expected <' + $Expected + '> actual <' + $Actual + '>') }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught) $Message
    Assert-True ($caught -match $Pattern) ($Message + ' (unexpected error: ' + $caught + ')')
    return $caught
}
function Pass([string]$Name) { $script:passed++; Write-Output ('PASS: ' + $Name) }
function New-Build([string]$Status = 'running', [int]$Port = 32067, [string]$Id = 'build-old') {
    return [PSCustomObject]@{
        id = $Id; status = $Status; transition = 'start'; template_version_id = 'template-original'
        job = [PSCustomObject]@{ status = 'succeeded'; error = '' }
        resources = @(
            [PSCustomObject]@{ name = 'ssh'; metadata = @(
                [PSCustomObject]@{ key = 'ssh'; value = ('ssh -p ' + $Port + ' root@36.140.239.91'); sensitive = $false }
            ) },
            [PSCustomObject]@{ name = 'unrelated'; metadata = @(
                [PSCustomObject]@{ key = 'ssh'; value = 'ssh -p 22 root@192.0.2.1'; sensitive = $false }
            ) }
        )
    }
}

Assert-Equal (Get-CoderWorkspaceName -Mappings $defaultMappings -Alias 'PyramidKV-plugin') 'PyramidKV' 'first exact alias'
Assert-Equal (Get-CoderWorkspaceName -Mappings $defaultMappings -Alias 'MUXWISE-PLUGIN') 'Irisuko' 'second exact alias ignores case'
foreach ($bad in @('PyramidKV', '*-plugin', 'MuxWise-plugin extra', 'other', '', ' PyramidKV-plugin')) {
    Assert-Throws { Get-CoderWorkspaceName -Mappings $defaultMappings -Alias $bad } '.' 'unknown or multi alias must be rejected' | Out-Null
}
Assert-Throws { Get-CoderWorkspaceName -Mappings $defaultMappings -Alias @('PyramidKV-plugin', 'MuxWise-plugin') } '.' 'array aliases must be rejected' | Out-Null
Pass 'default mappings resolve exact single aliases case-insensitively'

Assert-Equal (Get-CoderSshPort -Build (New-Build)) 32067 'observed ssh metadata extracts port'
foreach ($port in @(1, 65535)) {
    Assert-Equal (Get-CoderSshPort -Build (New-Build -Port $port)) $port 'valid boundary port'
}
Pass 'actual resource metadata and boundary ports parse as data'

foreach ($bad in @('ssh -p 0 root@36.140.239.91', 'ssh -p 65536 root@36.140.239.91', 'ssh -p 32067 root@192.0.2.1', 'ssh -p 22 -p 32067 root@36.140.239.91', 'ssh -p 32067 root@36.140.239.91; Set-Content bad', '$(Write-Output 32067)', '32067', "ssh -p 32067 root@36.140.239.91`nwhoami")) {
    $build = New-Build
    $build.resources[0].metadata[0].value = $bad
    Assert-Throws { Get-CoderSshPort -Build $build } '.' 'invalid, wrong-host, and command-shaped metadata must fail' | Out-Null
}
$build = New-Build
$build.resources[0].metadata[0].sensitive = $true
Assert-Throws { Get-CoderSshPort -Build $build } '.' 'sensitive metadata is not a public SSH endpoint' | Out-Null
$build = New-Build
$build.resources[0].metadata += $build.resources[0].metadata[0]
Assert-Throws { Get-CoderSshPort -Build $build } '.' 'duplicate ssh keys are ambiguous even with identical ports' | Out-Null
$build = New-Build
$build.resources += $build.resources[0]
Assert-Throws { Get-CoderSshPort -Build $build } '.' 'duplicate ssh resources are ambiguous' | Out-Null
Assert-Throws { Get-CoderSshPort -Build @{ resources = @() } } '.' 'missing ssh resource fails' | Out-Null
Pass 'invalid, missing, sensitive, duplicate, and executable metadata are rejected'

function New-Workspace($Build, [bool]$Outdated = $false, [bool]$RequireActiveVersion = $false) {
    return [PSCustomObject]@{
        id = 'workspace-pyramid'; name = 'PyramidKV'; owner_name = 'test-user';
        latest_build = $Build; outdated = $Outdated; require_active_version = $RequireActiveVersion
    }
}
function New-Step([string]$Method, [string]$Path, $Body, [int]$StatusCode = 200) {
    return [PSCustomObject]@{ Method = $Method; Path = $Path; Body = $Body; StatusCode = $StatusCode }
}
function New-Transport($Steps) {
    $state = @{ Steps = @($Steps); Index = 0; Calls = (New-Object 'System.Collections.Generic.List[object]'); Failure = $null }
    $handler = {
        param($Request)
        $state.Calls.Add($Request)
        if ($state.Index -ge $state.Steps.Count) { $state.Failure = 'Unexpected extra request'; throw $state.Failure }
        $step = $state.Steps[$state.Index]
        $state.Index++
        $actualUri = [Uri]$Request.Uri
        if ($Request.Method -cne $step.Method -or $actualUri.PathAndQuery -cne $step.Path) {
            $state.Failure = 'Unexpected request: ' + $Request.Method + ' ' + $actualUri.PathAndQuery
            throw $state.Failure
        }
        if ($step.StatusCode -eq -1) { throw 'fake-secret-password fake-session-token raw-response-body' }
        if ($step.StatusCode -eq -2) { Start-Sleep -Milliseconds 1200 }
        return [PSCustomObject]@{ StatusCode = [Math]::Max(200, $step.StatusCode); Body = $step.Body }
    }.GetNewClosure()
    return [PSCustomObject]@{ Handler = $handler; State = $state }
}
function Get-Prefix($Workspace) {
    return @(
        (New-Step 'POST' '/api/v2/users/login' @{ session_token = 'fake-session-token' }),
        (New-Step 'GET' '/api/v2/workspaces?q=owner%3Ame' @{ workspaces = @($Workspace) }),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' $Workspace)
    )
}
function Assert-Transport($Transport) {
    Assert-Equal $Transport.State.Failure $null 'transport request contract'
    Assert-Equal $Transport.State.Index $Transport.State.Steps.Count 'all expected requests consumed'
    foreach ($call in $Transport.State.Calls) {
        Assert-True ($call.Uri.StartsWith('https://coder.sage.org.ai:9450/api/v2/', [StringComparison]::Ordinal)) 'every request stays on fixed Coder origin'
        Assert-True ($call.TimeoutMilliseconds -ge 1) 'request has a positive bounded timeout'
        if ($call.Uri -like '*/users/login') {
            $login = $call.Body | ConvertFrom-Json
            Assert-Equal $login.email 'test@example.invalid' 'credential username is login email'
            Assert-Equal $login.password 'fake-secret-password' 'password is sent only to login'
            Assert-Equal @($call.Headers.Keys).Count 0 'login does not send another session token'
        } else {
            Assert-Equal $call.Headers['Coder-Session-Token'] 'fake-session-token' 'authenticated API request header'
            Assert-True ([string]$call.Body -notmatch 'fake-secret-password') 'non-login request contains no password'
        }
    }
}
$credential = New-Object Management.Automation.PSCredential('test@example.invalid', (ConvertTo-SecureString 'fake-secret-password' -AsPlainText -Force))

$running = New-Build
$transport = New-Transport (@(Get-Prefix (New-Workspace $running)) + @(
    (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $running))
))
$messages = New-Object 'System.Collections.Generic.List[string]'
$progress = { param($message) $messages.Add($message) }.GetNewClosure()
$result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -OnProgress $progress
Assert-Equal $result.Port 32067 'already-running workspace returns observed port'
Assert-Equal $result.WorkspaceName 'PyramidKV' 'returned mapped workspace'
Assert-Equal $result.Status 'running' 'returned running status'
Assert-Equal $result.Started $false 'running workspace was not started'
Assert-True (@($messages).Count -gt 0) 'human progress is emitted'
Assert-True (($messages -join ' ') -notmatch 'fake-session-token|fake-secret-password') 'progress does not expose credentials'
Assert-Transport $transport
Pass 'already-running workspace reads exact current build without restart'

$stopped = New-Build -Status 'stopped'
$pending = New-Build -Status 'pending' -Id 'build-new' -Port 32098
$starting = New-Build -Status 'starting' -Id 'build-new' -Port 32098
$newRunning = New-Build -Id 'build-new' -Port 32098
$transport = New-Transport (@(Get-Prefix (New-Workspace $stopped -Outdated $true)) + @(
    (New-Step 'POST' '/api/v2/workspaces/workspace-pyramid/builds' $pending),
    (New-Step 'GET' '/api/v2/workspacebuilds/build-new' $starting),
    (New-Step 'GET' '/api/v2/workspacebuilds/build-new' $newRunning),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $newRunning))
))
$result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -PollIntervalMilliseconds 1
Assert-Equal $result.Port 32098 'new build resources replace old stopped port'
Assert-Equal $result.Started $true 'stopped workspace was started'
$startCall = @($transport.State.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/builds' })
Assert-Equal $startCall.Count 1 'exactly one start call'
$body = $startCall[0].Body | ConvertFrom-Json
Assert-Equal $body.transition 'start' 'only start transition'
Assert-Equal $body.template_version_id 'template-original' 'start preserves prior template version even when outdated'
Assert-Equal @($body.PSObject.Properties).Count 2 'no rich parameters, state, or unrelated workspace settings are changed'
Assert-Transport $transport
Pass 'stopped workspace starts once, retains original template and all prior parameters'

foreach ($status in @('pending', 'starting')) {
    $existing = New-Build -Status $status
    $transport = New-Transport (@(Get-Prefix (New-Workspace $existing)) + @(
        (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $running))
    ))
    $result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -PollIntervalMilliseconds 1
    Assert-Equal $result.Started $false 'existing build joins without a new start'
    Assert-Equal $result.Port 32067 'existing build returns fresh running port'
    Assert-Transport $transport
}
Pass 'pending and starting builds are joined without duplicate starts'

foreach ($status in @('failed', 'canceled')) {
    $failed = New-Build -Status $status
    $failed.job.error = 'fake-secret-password fake-session-token raw-response-body'
    $transport = New-Transport (Get-Prefix (New-Workspace $failed))
    $errorText = Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } $status 'failed or canceled build returns actionable state error'
    Assert-True ($errorText -notmatch 'fake-secret-password|fake-session-token|raw-response-body') 'job failure does not leak raw server output'
    Assert-Transport $transport
}
Pass 'failed and canceled builds fail without blind retries or raw log leakage'

$transport = New-Transport (Get-Prefix (New-Workspace $stopped -Outdated $true -RequireActiveVersion $true))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'version|upgrade|版本|升级' 'active-version policy blocks automatic upgrade' | Out-Null
Assert-Transport $transport
Pass 'workspace policy requiring upgrade blocks start without mutating template'

foreach ($raceStatus in @('starting', 'running')) {
    $racing = New-Build -Status $raceStatus -Id 'build-race' -Port 32088
    $racingRunning = New-Build -Id 'build-race' -Port 32088
    $transport = New-Transport (@(Get-Prefix (New-Workspace $stopped)) + @(
        (New-Step 'POST' '/api/v2/workspaces/workspace-pyramid/builds' @{ message = 'fake-secret-password' } 409),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $racing)),
        (New-Step 'GET' '/api/v2/workspacebuilds/build-race' $racingRunning),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $racingRunning))
    ))
    $result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -PollIntervalMilliseconds 1
    Assert-Equal $result.Port 32088 '409 refresh joins actual latest build'
    Assert-Equal $result.Started $false '409 competing start is not reported as own successful start'
    Assert-Transport $transport
}
Pass '409 start race refreshes and joins current starting or running build'

foreach ($httpStatus in @(401, 403, 500, 302)) {
    $transport = New-Transport @(New-Step 'POST' '/api/v2/users/login' @{ message = 'fake-secret-password fake-session-token raw-response-body' } $httpStatus)
    $errorText = Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } ([string]$httpStatus) 'HTTP failures and redirects must fail visibly'
    Assert-True ($errorText -notmatch 'fake-secret-password|fake-session-token|raw-response-body') 'HTTP failure text is sanitized'
    Assert-Transport $transport
}
Pass 'HTTP errors and redirects report status without exposing response bodies'

$transport = New-Transport (@(Get-Prefix (New-Workspace $stopped)) + @(New-Step 'POST' '/api/v2/workspaces/workspace-pyramid/builds' $null -1))
$errorText = Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'network|uncertain|网络|确认' 'ambiguous start network failure must require state recheck'
Assert-True ($errorText -notmatch 'fake-secret-password|fake-session-token|raw-response-body') 'transport exceptions cannot leak data'
Assert-Transport $transport
Pass 'uncertain start network failure is never resubmitted'

$transport = New-Transport @(New-Step 'POST' '/api/v2/users/login' @{ session_token = 'fake-session-token' } -2)
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -TimeoutSeconds 1 } 'timed out|timeout|超时' 'global deadline includes network requests' | Out-Null
Assert-Transport $transport
$transport = New-Transport (Get-Prefix (New-Workspace (New-Build -Status 'pending')))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -TimeoutSeconds 1 -PollIntervalMilliseconds 1100 } 'timed out|timeout|超时' 'polling obeys timeout before another request' | Out-Null
Assert-Transport $transport
Pass 'network time and pending-build polling both obey the operation deadline'

$transport = New-Transport (Get-Prefix (New-Workspace $stopped))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -RequireAlreadyRunning } 'already running|read.only|正在运行|只读' 'read-only verification must reject a stopped workspace' | Out-Null
Assert-Transport $transport
$transport = New-Transport (@(Get-Prefix (New-Workspace $running)) + @(
    (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $running))
))
$result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -RequireAlreadyRunning
Assert-Equal $result.Port 32067 'read-only verification still reads running resources'
Assert-Equal $result.Started $false 'read-only verification does not start'
Assert-Transport $transport
Pass 'read-only verification requires an already-running workspace and never submits a build'

foreach ($changed in @((New-Build -Id 'replacement' -Port 32099), (New-Build -Status 'stopping'))) {
    $transport = New-Transport (@(Get-Prefix (New-Workspace $running)) + @(
        (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $changed))
    ))
    Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'changed|retry|变化|重新' 'replacement or stopping build must not return stale port' | Out-Null
    Assert-Transport $transport
}
Pass 'completed build is revalidated against latest workspace before returning a port'

$workspace = New-Workspace $stopped -Outdated $true
$workspace | Add-Member -NotePropertyName template_require_active_version -NotePropertyValue $true
$transport = New-Transport (Get-Prefix $workspace)
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'version|upgrade|版本|升级' 'alternate active-version policy field also blocks upgrades' | Out-Null
Assert-Transport $transport
Pass 'both Coder active-template policy field forms prevent automatic upgrades'

$stopping = New-Build -Status 'stopping'
$transport = New-Transport (@(Get-Prefix (New-Workspace $stopping)) + @(
    (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $stopped),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $stopped)),
    (New-Step 'POST' '/api/v2/workspaces/workspace-pyramid/builds' $pending),
    (New-Step 'GET' '/api/v2/workspacebuilds/build-new' $newRunning),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $newRunning))
))
$result = Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -PollIntervalMilliseconds 1
Assert-Equal $result.Port 32098 'stopping workspace waits for stop before obtaining a new port'
Assert-Equal $result.Started $true 'stopping workspace starts only after stop completes'
Assert-Transport $transport
$canceling = New-Build -Status 'canceling'
$canceled = New-Build -Status 'canceled'
$transport = New-Transport (@(Get-Prefix (New-Workspace $canceling)) + @(New-Step 'GET' '/api/v2/workspacebuilds/build-old' $canceled))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -PollIntervalMilliseconds 1 } 'canceled' 'canceling workspace waits then reports canceled without another start' | Out-Null
Assert-Transport $transport
Pass 'stopping waits before starting once, while canceled builds stay explicit failures'

$transport = New-Transport (@(Get-Prefix (New-Workspace $stopped)) + @(
    (New-Step 'POST' '/api/v2/workspaces/workspace-pyramid/builds' @{ message = 'fake-secret-password' } 409),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' (New-Workspace $stopped))
))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } '409' 'unresolved conflict cannot trigger another start' | Out-Null
Assert-Transport $transport
Pass 'unresolved 409 remains an explicit error without resubmission'

foreach ($owned in @(@{ workspaces = @() }, @{ workspaces = @((New-Workspace $running), (New-Workspace $running)) })) {
    $transport = New-Transport @(
        (New-Step 'POST' '/api/v2/users/login' @{ session_token = 'fake-session-token' }),
        (New-Step 'GET' '/api/v2/workspaces?q=owner%3Ame' $owned)
    )
    Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'exactly one|唯一' 'missing or ambiguous owned workspace cannot select another workspace' | Out-Null
    Assert-Transport $transport
}
$transport = New-Transport @()
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'unrelated-plugin' -Credential $credential -RequestHandler $transport.Handler } 'alias' 'unknown aliases fail before login' | Out-Null
Assert-Transport $transport
Pass 'missing, ambiguous, and unrelated workspace choices never cause a start'

$transport = New-Transport @(New-Step 'POST' '/api/v2/users/login' '{ fake-secret-password fake-session-token raw-response-body')
$errorText = Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'JSON' 'malformed success JSON gives sanitized parse error'
Assert-True ($errorText -notmatch 'fake-secret-password|fake-session-token|raw-response-body') 'JSON parse failures cannot disclose response data'
Assert-Transport $transport
$transport = New-Transport @(New-Step 'POST' '/api/v2/users/login' @{ session_token = "fake-session-token`r`ninvalid-header" })
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler } 'token' 'malformed session token fails before authenticated requests' | Out-Null
Assert-Transport $transport
Pass 'malformed JSON and header-shaped session values fail without leaking response data'

$transport = New-Transport (@(Get-Prefix (New-Workspace $running)) + @(New-Step 'GET' '/api/v2/workspacebuilds/build-old' $stopped))
Assert-Throws { Invoke-CoderWorkspace -Mappings $defaultMappings -Alias 'PyramidKV-plugin' -Credential $credential -RequestHandler $transport.Handler -RequireAlreadyRunning } 'already running|read.only' 'read-only guard is enforced after subsequent build reads too' | Out-Null
Assert-Transport $transport
Pass 'read-only verification cannot start when the workspace stops during lookup'

$customMappings = @{ 'team-box' = 'TeamSpace'; 'another.alias' = 'Other Workspace' }
Assert-Equal (Get-CoderWorkspaceName -Alias 'TEAM-BOX' -Mappings $customMappings) 'TeamSpace' 'arbitrary single alias resolves case-insensitively'
Assert-Equal (Get-CoderWorkspaceName -Alias 'another.alias' -Mappings $customMappings) 'Other Workspace' 'arbitrary own workspace name is preserved'
Assert-Throws { Get-CoderWorkspaceName -Alias 'PyramidKV-plugin' -Mappings @{} } 'mapping|映射' 'explicit empty mapping does not restore the original aliases' | Out-Null
$duplicates = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$duplicates.Add('alias', 'first'); $duplicates.Add('ALIAS', 'second')
Assert-Throws { Get-CoderWorkspaceName -Alias 'alias' -Mappings $duplicates } 'ambiguous|exactly one|多个|唯一|重复' 'case-colliding injected mappings cannot select an arbitrary workspace' | Out-Null
foreach ($badWorkspace in @('', '  ', "one`ntwo", ('x' * 129))) {
    Assert-Throws { Get-CoderWorkspaceName -Alias 'alias' -Mappings @{ alias = $badWorkspace } } 'workspace|工作空间' 'invalid mapped workspace names are rejected' | Out-Null
}
Pass 'dynamic mapping resolution supports new aliases and rejects missing or ambiguous choices'

$customWorkspace = New-Workspace $running
$customWorkspace.name = 'TeamSpace'
$transport = New-Transport (@(Get-Prefix $customWorkspace) + @(
    (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' $customWorkspace)
))
$result = Invoke-CoderWorkspace -Alias 'team-box' -Mappings $customMappings -WorkspaceName 'TeamSpace' -Credential $credential -RequestHandler $transport.Handler -RequireAlreadyRunning
Assert-Equal $result.WorkspaceName 'TeamSpace' 'custom workspace snapshot is used through normal API state machine'
Assert-Equal $result.Port 32067 'custom mapping retains strict target-host port parser'
Assert-Transport $transport
$transport = New-Transport @()
Assert-Throws { Invoke-CoderWorkspace -Alias 'team-box' -Mappings $customMappings -WorkspaceName 'OldWorkspace' -Credential $credential -RequestHandler $transport.Handler } 'changed|mapping|变化|映射' 'stale mapping snapshot fails before login or workspace action' | Out-Null
Assert-Transport $transport
Pass 'workspace snapshot must match current mapping before any remote operation'

$mutableMappings = @{ 'team-box' = 'TeamSpace' }
$changeMappingProgress = { param($message) $mutableMappings['team-box'] = 'UnrelatedWorkspace' }.GetNewClosure()
$transport = New-Transport (@(Get-Prefix $customWorkspace) + @(
    (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
    (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' $customWorkspace)
))
$result = Invoke-CoderWorkspace -Alias 'team-box' -Mappings $mutableMappings -WorkspaceName 'TeamSpace' -Credential $credential -RequestHandler $transport.Handler -OnProgress $changeMappingProgress -RequireAlreadyRunning
Assert-Equal $result.WorkspaceName 'TeamSpace' 'selection remains frozen even if caller mapping changes during progress'
Assert-Transport $transport
Pass 'the selected workspace remains frozen for the entire operation'

Import-Module (Join-Path $appRoot 'Mappings.psm1') -Force
$coderMappingRunsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runs'))
$coderMappingTestRoot = [IO.Path]::GetFullPath((Join-Path $coderMappingRunsRoot ('coder-mapping-' + [Guid]::NewGuid().ToString('N'))))
$previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
try {
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $coderMappingTestRoot, 'Process')
    Assert-Equal (Get-CoderWorkspaceName -Alias 'PyramidKV-plugin') 'PyramidKV' 'default resolver reads absent-store defaults'
    Assert-True (-not [IO.Directory]::Exists($coderMappingTestRoot)) 'default resolution writes no settings'
    $null = Save-CoderMappings -Mappings $customMappings
    Assert-Equal (Get-CoderWorkspaceName -Alias 'TEAM-BOX') 'TeamSpace' 'default resolver reads saved local mapping'
    $transport = New-Transport (@(Get-Prefix $customWorkspace) + @(
        (New-Step 'GET' '/api/v2/workspacebuilds/build-old' $running),
        (New-Step 'GET' '/api/v2/workspaces/workspace-pyramid' $customWorkspace)
    ))
    $result = Invoke-CoderWorkspace -Alias 'team-box' -WorkspaceName 'TeamSpace' -Credential $credential -RequestHandler $transport.Handler -RequireAlreadyRunning
    Assert-Equal $result.WorkspaceName 'TeamSpace' 'production-style invocation uses current settings without injected mappings'
    Assert-Transport $transport
    $null = Save-CoderMappings -Mappings @{ 'team-box' = 'ChangedWorkspace' }
    $transport = New-Transport @()
    Assert-Throws { Invoke-CoderWorkspace -Alias 'team-box' -WorkspaceName 'TeamSpace' -Credential $credential -RequestHandler $transport.Handler } 'changed|mapping|变化|映射' 'job snapshot is checked against changes persisted in local store' | Out-Null
    Assert-Transport $transport
    $null = Save-CoderMappings -Mappings @{}
    Assert-Throws { Get-CoderWorkspaceName -Alias 'PyramidKV-plugin' } 'mapping|映射' 'saved empty mapping cannot resurrect default workspace selection' | Out-Null
}
finally {
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $previousLocalAppData, 'Process')
    if ($coderMappingTestRoot.StartsWith($coderMappingRunsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($coderMappingTestRoot)) {
        Remove-Item -LiteralPath $coderMappingTestRoot -Recurse -Force
    }
}
Pass 'default storage integration honors saved mappings, stale snapshots, and persisted empty maps'

Write-Output ($script:passed.ToString() + ' Coder tests passed.')
