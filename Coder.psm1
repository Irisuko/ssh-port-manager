Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Mappings.psm1') -ErrorAction Stop

function Get-CoderField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-CoderWorkspaceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()]$Alias,
        [Collections.IDictionary]$Mappings
    )
    if ($Alias -isnot [string] -or $Alias -cnotmatch '\A[A-Za-z0-9_.-]+\z') {
        throw 'Coder requires exactly one literal SSH alias containing only ASCII letters, digits, underscores, dots, or hyphens.'
    }
    if ($null -eq $Mappings) { $Mappings = Get-CoderMappings }
    $matchingAliases = @($Mappings.Keys | Where-Object {
        $_ -is [string] -and [string]::Equals($_, $Alias, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matchingAliases.Count -eq 0) { throw 'This SSH alias has no Coder workspace mapping. Add a local mapping first.' }
    if ($matchingAliases.Count -ne 1) { throw 'This SSH alias has ambiguous mappings; keep exactly one workspace mapping per alias.' }
    $workspace = $Mappings[$matchingAliases[0]]
    if ($workspace -isnot [string] -or $workspace -match '[\r\n\x00]') {
        throw 'The mapped workspace name must be text without newlines or NUL characters.'
    }
    $workspace = $workspace.Trim()
    if ($workspace.Length -eq 0 -or $workspace.Length -gt 128) {
        throw 'The mapped workspace name must contain between 1 and 128 characters after trimming.'
    }
    return $workspace
}

function Get-CoderSshPort {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Build)
    $resources = @(Get-CoderField $Build 'resources')
    $sshResources = @($resources | Where-Object { (Get-CoderField $_ 'name') -ceq 'ssh' })
    if ($sshResources.Count -ne 1) { throw 'Coder build must contain exactly one ssh resource.' }
    $metadata = @(Get-CoderField $sshResources[0] 'metadata')
    $sshMetadata = @($metadata | Where-Object { (Get-CoderField $_ 'key') -ceq 'ssh' })
    if ($sshMetadata.Count -ne 1) { throw 'Coder ssh resource must contain exactly one ssh metadata entry.' }
    if ((Get-CoderField $sshMetadata[0] 'sensitive') -isnot [bool] -or
        (Get-CoderField $sshMetadata[0] 'sensitive') -ne $false) {
        throw 'Coder ssh metadata must be explicitly non-sensitive.'
    }
    $value = Get-CoderField $sshMetadata[0] 'value'
    # This is a deliberately narrow data grammar, never a command to execute.
    if ($value -isnot [string] -or $value -cnotmatch '\A[ \t]*ssh[ \t]+-p[ \t]+([0-9]{1,5})[ \t]+root@36\.140\.239\.91[ \t]*\z') {
        throw 'Coder ssh metadata must be a single SSH endpoint for root@36.140.239.91.'
    }
    $port = [int]$Matches[1]
    if ($port -lt 1 -or $port -gt 65535) { throw 'Coder SSH port must be between 1 and 65535.' }
    return $port
}

function Get-CoderRemainingMilliseconds {
    param([Diagnostics.Stopwatch]$Clock, [int]$TimeoutSeconds)
    $remaining = ([double]$TimeoutSeconds * 1000) - $Clock.Elapsed.TotalMilliseconds
    if ($remaining -le 0) {
        throw [TimeoutException]::new('Coder operation timed out. A submitted build may still be running; check the workspace before trying again.')
    }
    return [int][Math]::Min(30000, [Math]::Max(1, [Math]::Ceiling($remaining)))
}

function Invoke-CoderHttp {
    param($Request)
    # The platform TLS validator is unchanged. No certificate callback, redirect,
    # cookie store, credential cache, external executable, or persisted token is used.
    Add-Type -AssemblyName System.Net.Http
    $handler = $null
    $client = $null
    $message = $null
    $response = $null
    try {
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.UseDefaultCredentials = $false
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMilliseconds($Request.TimeoutMilliseconds)
        $message = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::new($Request.Method), [Uri]$Request.Uri)
        $message.Headers.Accept.ParseAdd('application/json')
        foreach ($name in $Request.Headers.Keys) { $message.Headers.Add($name, [string]$Request.Headers[$name]) }
        if ($null -ne $Request.Body) {
            $message.Content = New-Object Net.Http.StringContent($Request.Body, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($message).GetAwaiter().GetResult()
        $body = $null
        if ($response.IsSuccessStatusCode) { $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        return [PSCustomObject]@{ StatusCode = [int]$response.StatusCode; Body = $body }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $message) { $message.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        elseif ($null -ne $handler) { $handler.Dispose() }
    }
}

function Invoke-CoderApi {
    param(
        [string]$Method, [string]$Path, [string]$SessionToken, $Body,
        [scriptblock]$RequestHandler, [Diagnostics.Stopwatch]$Clock, [int]$TimeoutSeconds
    )
    $remaining = Get-CoderRemainingMilliseconds $Clock $TimeoutSeconds
    if ($Path -cnotmatch '\A/api/v2/(users/login|workspaces(?:\?q=owner%3Ame|/[A-Za-z0-9%._~-]+(?:/builds)?)?|workspacebuilds/[A-Za-z0-9%._~-]+)\z') {
        throw 'Invalid Coder API endpoint.'
    }
    $headers = @{}
    if (-not [string]::IsNullOrEmpty($SessionToken)) { $headers['Coder-Session-Token'] = $SessionToken }
    $json = $null
    if ($null -ne $Body) { $json = ConvertTo-Json -InputObject $Body -Depth 8 -Compress }
    $request = [PSCustomObject]@{
        Method = $Method; Uri = ('https://coder.sage.org.ai:9450' + $Path)
        Headers = $headers; Body = $json; TimeoutMilliseconds = $remaining
    }
    try {
        try {
            if ($null -ne $RequestHandler) { $response = & $RequestHandler $request }
            else { $response = Invoke-CoderHttp $request }
        }
        catch {
            # Never surface transport exception strings, server bodies, or inner
            # exceptions: they can carry passwords, tokens, or request content.
            $null = Get-CoderRemainingMilliseconds $Clock $TimeoutSeconds
            throw [InvalidOperationException]::new('Coder network request failed. A submitted start has an uncertain outcome; check workspace status before trying again.')
        }
        $null = Get-CoderRemainingMilliseconds $Clock $TimeoutSeconds
        $statusValue = Get-CoderField $response 'StatusCode'
        $status = 0
        if (-not [int]::TryParse([string]$statusValue, [ref]$status) -or $status -lt 100 -or $status -gt 599) {
            throw 'Coder returned an invalid HTTP response.'
        }
        if ($status -lt 200 -or $status -ge 300) {
            $detail = 'Check the workspace in Coder before retrying.'
            if ($status -eq 401) { $detail = 'Check the login email and password, then sign in again.' }
            elseif ($status -eq 403) { $detail = 'This account does not have permission for the requested workspace action.' }
            elseif ($status -ge 300 -and $status -lt 400) { $detail = 'Redirects are not followed; use the configured Coder site.' }
            $errorObject = [InvalidOperationException]::new(('Coder API request failed (HTTP ' + $status + '). ' + $detail))
            $errorObject.Data['CoderHttpStatus'] = $status
            throw $errorObject
        }
        $data = Get-CoderField $response 'Body'
        if ($data -is [string]) {
            try { $data = ConvertFrom-Json -InputObject $data -ErrorAction Stop }
            catch { throw [InvalidOperationException]::new('Coder returned invalid JSON data.') }
        }
        if ($null -eq $data -or $data -is [string] -or $data -is [ValueType]) { throw 'Coder returned an invalid API object.' }
        return $data
    }
    finally { $json = $null; $request = $null; $headers = $null; $SessionToken = $null; $Body = $null }
}

function Get-CoderObjectId {
    param($Object)
    $id = Get-CoderField $Object 'id'
    if ($id -isnot [string] -or $id -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z') {
        throw 'Coder returned an invalid workspace or build ID.'
    }
    return $id
}

function Send-CoderProgress {
    param([scriptblock]$OnProgress, [string]$Message)
    if ($null -ne $OnProgress) { & $OnProgress $Message | Out-Null }
}

function Invoke-CoderWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Alias,
        [Parameter(Mandatory = $true)][Management.Automation.PSCredential]$Credential,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 180,
        [ValidateRange(1, 60000)][int]$PollIntervalMilliseconds = 2000,
        [scriptblock]$OnProgress,
        [scriptblock]$RequestHandler,
        [switch]$RequireAlreadyRunning,
        [switch]$AllowUnreadyPort,
        [Collections.IDictionary]$Mappings,
        [string]$WorkspaceName
    )
    $ErrorActionPreference = 'Stop'
    $selectedWorkspaceName = Get-CoderWorkspaceName -Alias $Alias -Mappings $Mappings
    if ($PSBoundParameters.ContainsKey('WorkspaceName') -and
        -not [string]::Equals($WorkspaceName, $selectedWorkspaceName, [StringComparison]::Ordinal)) {
        throw 'The local SSH-to-Coder mapping changed. Refresh the selection before starting the workspace.'
    }
    # Resolve once before any callback or network request; later local mapping
    # edits cannot redirect this operation to another remote workspace.
    $workspaceName = $selectedWorkspaceName
    if ([string]::IsNullOrWhiteSpace($Credential.UserName)) { throw 'Enter the Coder login email and password.' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sessionToken = $null
    $loginBody = $null
    $loginResponse = $null
    try {
        Send-CoderProgress $OnProgress ('正在登录 Coder，准备检查 ' + $workspaceName + '…')
        $apiArgs = @{ RequestHandler = $RequestHandler; Clock = $clock; TimeoutSeconds = $TimeoutSeconds }
        try {
            $loginBody = @{ email = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
            $loginResponse = Invoke-CoderApi @apiArgs -Method POST -Path '/api/v2/users/login' -Body $loginBody
        }
        finally { if ($null -ne $loginBody) { $loginBody.Clear() }; $loginBody = $null }
        $sessionToken = Get-CoderField $loginResponse 'session_token'
        if ($sessionToken -isnot [string] -or [string]::IsNullOrWhiteSpace($sessionToken) -or
            $sessionToken.Length -gt 4096 -or $sessionToken -match '[\r\n\x00]') {
            throw 'Coder login did not return a valid session token.'
        }
        $loginResponse = $null
        $apiArgs['SessionToken'] = $sessionToken
        $listing = Invoke-CoderApi @apiArgs -Method GET -Path '/api/v2/workspaces?q=owner%3Ame'
        $matches = @((Get-CoderField $listing 'workspaces') | Where-Object {
            [string]::Equals([string](Get-CoderField $_ 'name'), $workspaceName, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1) { throw ('Coder account must own exactly one workspace named ' + $workspaceName + '.') }
        $workspaceId = Get-CoderObjectId $matches[0]
        $workspacePath = '/api/v2/workspaces/' + $workspaceId
        $workspace = Invoke-CoderApi @apiArgs -Method GET -Path $workspacePath
        if ((Get-CoderObjectId $workspace) -cne $workspaceId -or
            -not [string]::Equals([string](Get-CoderField $workspace 'name'), $workspaceName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Coder returned a different workspace; no action was taken.'
        }
        $build = Get-CoderField $workspace 'latest_build'
        $started = $false
        $attemptedStart = $false
        $fullBuild = $false
        $refreshAfterStop = $false
        while ($true) {
            $null = Get-CoderRemainingMilliseconds $clock $TimeoutSeconds
            $buildId = Get-CoderObjectId $build
            $status = [string](Get-CoderField $build 'status')
            if ($RequireAlreadyRunning -and $status -cne 'running') {
                $notRunningError = [InvalidOperationException]::new('Read-only verification requires an already running workspace; no start was submitted.')
                $notRunningError.Data['CoderNotRunning'] = $true
                throw $notRunningError
            }
            switch -CaseSensitive -Exact ($status) {
                'running' {
                    if ($fullBuild) {
                        $currentWorkspace = Invoke-CoderApi @apiArgs -Method GET -Path $workspacePath
                        $currentBuild = Get-CoderField $currentWorkspace 'latest_build'
                        if ((Get-CoderObjectId $currentWorkspace) -cne $workspaceId -or
                            (Get-CoderObjectId $currentBuild) -cne $buildId -or
                            (Get-CoderField $currentBuild 'status') -cne 'running') {
                            throw 'Coder workspace changed while reading its SSH port. Refresh the workspace and retry; the old build port was not used.'
                        }
                        $port = Get-CoderSshPort -Build $build
                        Send-CoderProgress $OnProgress ($workspaceName + ' 已运行，SSH 端口：' + $port + '。')
                        return [PSCustomObject]@{ WorkspaceName = $workspaceName; Port = $port; Started = $started; Status = 'running' }
                    }
                    Send-CoderProgress $OnProgress ($workspaceName + ' 已在运行，正在读取 SSH 端口…')
                    $build = Invoke-CoderApi @apiArgs -Method GET -Path ('/api/v2/workspacebuilds/' + $buildId)
                    if ((Get-CoderObjectId $build) -cne $buildId) { throw 'Coder returned a different build; retry after checking workspace status.' }
                    $fullBuild = $true
                }
                'stopped' {
                    if ($attemptedStart) { throw 'Coder build stopped before becoming ready. Check the workspace; no second start was submitted.' }
                    if ($refreshAfterStop) {
                        $workspace = Invoke-CoderApi @apiArgs -Method GET -Path $workspacePath
                        if ((Get-CoderObjectId $workspace) -cne $workspaceId) { throw 'Coder returned a different workspace.' }
                        $build = Get-CoderField $workspace 'latest_build'
                        $fullBuild = $false
                        $refreshAfterStop = $false
                        continue
                    }
                    if (((Get-CoderField $workspace 'require_active_version' $false) -eq $true -or
                         (Get-CoderField $workspace 'template_require_active_version' $false) -eq $true) -and
                        (Get-CoderField $workspace 'outdated' $false) -eq $true) {
                        throw 'Coder requires an active template version, but this workspace is outdated. Automatic upgrade is disabled; review the template upgrade in Coder first.'
                    }
                    $templateId = Get-CoderField $build 'template_version_id'
                    if ($templateId -isnot [string] -or [string]::IsNullOrWhiteSpace($templateId)) {
                        throw 'Coder previous template version is missing; start was not submitted.'
                    }
                    $attemptedStart = $true
                    Send-CoderProgress $OnProgress ('正在启动 ' + $workspaceName + '，保留原模板版本和参数…')
                    try {
                        # Omitting rich_parameter_values/state preserves Coder's prior
                        # values. Never substitute the active/newest template version.
                        $build = Invoke-CoderApi @apiArgs -Method POST -Path ($workspacePath + '/builds') -Body @{
                            transition = 'start'; template_version_id = $templateId
                        }
                        $started = $true
                        $fullBuild = $false
                    }
                    catch {
                        if ($_.Exception.Data['CoderHttpStatus'] -ne 409) { throw }
                        $workspace = Invoke-CoderApi @apiArgs -Method GET -Path $workspacePath
                        if ((Get-CoderObjectId $workspace) -cne $workspaceId) { throw 'Coder returned a different workspace.' }
                        $build = Get-CoderField $workspace 'latest_build'
                        if (@('running', 'pending', 'starting') -cnotcontains [string](Get-CoderField $build 'status')) {
                            throw 'Coder start conflicted (HTTP 409). Check the workspace before trying again; no additional start was submitted.'
                        }
                        $fullBuild = $false
                        Send-CoderProgress $OnProgress ($workspaceName + ' 已有启动任务，正在等待该任务完成…')
                    }
                }
                { $_ -ceq 'pending' -or $_ -ceq 'starting' -or $_ -ceq 'stopping' -or $_ -ceq 'canceling' } {
                    if ($AllowUnreadyPort -and $fullBuild -and @('pending','starting') -ccontains $status) {
                        $allocatedPort=$null
                        try { $allocatedPort=Get-CoderSshPort -Build $build } catch { }
                        if ($null -ne $allocatedPort) {
                            $currentWorkspace=Invoke-CoderApi @apiArgs -Method GET -Path $workspacePath
                            $currentBuild=Get-CoderField $currentWorkspace 'latest_build'
                            if ((Get-CoderObjectId $currentWorkspace) -cne $workspaceId -or (Get-CoderObjectId $currentBuild) -cne $buildId) {
                                throw 'Coder workspace changed while reading its allocated SSH port; the old build port was not used.'
                            }
                            if ([string](Get-CoderField $currentBuild 'status') -cne $status) { $build=$currentBuild; $fullBuild=$false; continue }
                            Send-CoderProgress $OnProgress ($workspaceName + ' 仍在等待启动，已分配 SSH 端口：' + $allocatedPort + '。')
                            return [pscustomobject]@{WorkspaceName=$workspaceName;Port=$allocatedPort;Started=$started;Status=$status;Deferred=$true}
                        }
                    }
                    if ($status -ceq 'stopping' -or $status -ceq 'canceling') { $refreshAfterStop = $true }
                    Send-CoderProgress $OnProgress ($workspaceName + ' 当前状态：' + $status + '，正在等待…')
                    $remaining = Get-CoderRemainingMilliseconds $clock $TimeoutSeconds
                    Start-Sleep -Milliseconds ([Math]::Min($PollIntervalMilliseconds, $remaining))
                    $null = Get-CoderRemainingMilliseconds $clock $TimeoutSeconds
                    $build = Invoke-CoderApi @apiArgs -Method GET -Path ('/api/v2/workspacebuilds/' + $buildId)
                    if ((Get-CoderObjectId $build) -cne $buildId) { throw 'Coder returned a different build; retry after checking workspace status.' }
                    $fullBuild = $true
                }
                'failed' { throw 'Coder workspace build failed. Inspect its build log in Coder and resolve the error before trying again.' }
                'canceled' { throw 'Coder workspace build was canceled. Check the workspace in Coder before starting a new build.' }
                default { throw 'Coder workspace is not in a supported startable state. Check its status in Coder.' }
            }
        }
    }
    finally {
        # Do not call logout: Coder logout may revoke sessions used by other apps.
        if ($null -ne $loginBody) { $loginBody.Clear() }
        $loginBody = $null
        $loginResponse = $null
        $sessionToken = $null
        if (Test-Path variable:apiArgs) { $apiArgs.Clear() }
        $clock.Stop()
    }
}

Export-ModuleMember -Function Get-CoderWorkspaceName, Get-CoderSshPort, Invoke-CoderWorkspace
