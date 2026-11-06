Set-StrictMode -Version 2.0
$script:CoderRootModule = Import-Module (Join-Path $PSScriptRoot 'Coder.psm1') -PassThru -ErrorAction Stop

function Stop-CoderRoot([string]$Message) {
    $errorObject = [InvalidOperationException]::new($Message)
    $errorObject.Data['CoderRootSafe'] = $true
    throw $errorObject
}

function Get-RootField($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-RootId($Object) {
    $id = Get-RootField $Object 'id'
    $parsed = [Guid]::Empty
    if ($id -isnot [string] -or -not [Guid]::TryParseExact($id, 'D', [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        Stop-CoderRoot 'Coder returned an invalid workspace, build, or agent identifier.'
    }
    return $id
}

function Invoke-RootApi([Collections.IDictionary]$Arguments, [string]$Method, [string]$Path, $Body = $null) {
    $requestArguments = @{}
    foreach ($key in $Arguments.Keys) { $requestArguments[$key] = $Arguments[$key] }
    $requestArguments.Method = $Method
    $requestArguments.Path = $Path
    if ($null -ne $Body) { $requestArguments.Body = $Body }
    try {
        # The existing Coder API allowlist, TLS validation and sanitized errors apply.
        return & $script:CoderRootModule { param($ApiArguments) Invoke-CoderApi @ApiArguments } $requestArguments
    } finally { $requestArguments.Clear() }
}

function Get-RootRemaining([Diagnostics.Stopwatch]$Clock, [int]$TimeoutSeconds) {
    $remaining = ([double]$TimeoutSeconds * 1000) - $Clock.Elapsed.TotalMilliseconds
    if ($remaining -le 0) {
        $errorObject = [TimeoutException]::new('Coder root preparation timed out.')
        $errorObject.Data['CoderRootTimeout'] = $true
        throw $errorObject
    }
    return [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($remaining))
}

function Get-RootSshPort($Build) {
    return Get-CoderSshPort -Build $Build
}

function Get-RootAgent($Build) {
    $agents = @()
    foreach ($resource in @(Get-RootField $Build 'resources' @())) {
        foreach ($agent in @(Get-RootField $resource 'agents' @())) {
            if ($null -ne $agent) { $agents += $agent }
        }
    }
    if ($agents.Count -ne 1) { Stop-CoderRoot 'The selected workspace must have exactly one terminal agent; no command was submitted.' }
    $null = Get-RootId $agents[0]
    if ([string](Get-RootField $agents[0] 'operating_system') -cne 'linux') {
        Stop-CoderRoot 'The selected workspace terminal must run Linux; no command was submitted.'
    }
    return $agents[0]
}

function Assert-RootWorkspaceSnapshot($ApiArguments, [string]$WorkspaceId, [string]$BuildId, [string]$WorkspaceName, [int]$Port) {
    $workspace = Invoke-RootApi $ApiArguments GET ('/api/v2/workspaces/' + $WorkspaceId)
    $latest = Get-RootField $workspace 'latest_build'
    if ((Get-RootId $workspace) -cne $WorkspaceId -or
        -not [string]::Equals([string](Get-RootField $workspace 'name'), $WorkspaceName, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-RootId $latest) -cne $BuildId -or [string](Get-RootField $latest 'status') -cne 'running') {
        Stop-CoderRoot 'The workspace changed during terminal preparation; the selected server could not be confirmed.'
    }
    $build = Invoke-RootApi $ApiArguments GET ('/api/v2/workspacebuilds/' + $BuildId)
    if ((Get-RootId $build) -cne $BuildId -or [string](Get-RootField $build 'status') -cne 'running' -or
        (Get-RootSshPort $build) -ne $Port) {
        Stop-CoderRoot 'The running build or SSH port changed during terminal preparation.'
    }
    return $build
}

function New-RootTerminalRequest([string]$AgentId, [string]$SessionToken, [int]$TimeoutMilliseconds) {
    $nonce = [Guid]::NewGuid().ToString('N')
    # The complete proof prefix never appears literally in the submitted command,
    # so a PTY command echo cannot masquerade as command completion.
    $body = 'chmod g-w /root; rc=$?; mode=$(stat -c %a /root 2>/dev/null); sr=$?; printf "\n%s%s|%s|%s|%s\n" "__SPM_" "' + $nonce + '__" "$rc" "$sr" "$mode"; exit "$rc"'
    $command = "sh -c '" + $body + "'"
    $uri = 'wss://coder.sage.org.ai:9450/api/v2/workspaceagents/' + $AgentId + '/pty?reconnect=' + [Guid]::NewGuid().ToString('D') + '&height=24&width=120&backend_type=buffered&command=' + [Uri]::EscapeDataString($command)
    return [pscustomobject]@{
        Uri = $uri; SessionToken = $SessionToken; Nonce = $nonce
        Command = $command; TimeoutMilliseconds = $TimeoutMilliseconds; MaximumBytes = 65536
    }
}

function Read-RootTerminalProof([string]$Output, [string]$Nonce) {
    if ($Nonce -cnotmatch '\A[0-9a-f]{32}\z') { Stop-CoderRoot 'Invalid terminal verification identifier.' }
    if ($null -eq $Output -or [Text.Encoding]::UTF8.GetByteCount($Output) -gt 65536) {
        Stop-CoderRoot 'Terminal output exceeded its limit; command completion could not be confirmed.'
    }
    $pattern = '(?m)^__SPM_' + $Nonce + '__\|([0-9]{1,3})\|([0-9]{1,3})\|([0-7]{3,4})\r?$'
    $proofs = [regex]::Matches($Output, $pattern)
    if ($proofs.Count -ne 1) { Stop-CoderRoot 'The terminal did not return one valid completion record; chmod may already have run.' }
    $exitCode = [int]$proofs[0].Groups[1].Value
    $statExitCode = [int]$proofs[0].Groups[2].Value
    $mode = $proofs[0].Groups[3].Value
    if ($exitCode -ne 0) { Stop-CoderRoot ('chmod g-w /root failed (exit code ' + $exitCode + '). Check the terminal account permissions.') }
    if ($statExitCode -ne 0) { Stop-CoderRoot 'chmod returned successfully, but /root permissions could not be verified.' }
    $numericMode = [Convert]::ToInt32($mode, 8)
    if (($numericMode -band 16) -ne 0) { Stop-CoderRoot 'The terminal still reports group-write permission on /root.' }
    return [pscustomobject]@{ RootMode=$mode; ExitCode=0 }
}

function Initialize-RootTerminalTransport {
    if ('SshPortManager.CoderPtyTransport' -as [type]) { return }
    # .NET Framework ClientWebSocket creates an HttpWebRequest internally.
    # Its options do not expose AllowAutoRedirect. Register a process-local
    # creator for this one fixed HTTPS authority and disable redirects there.
    # CreateDefault delegates to the framework's normal WebSocket request factory.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
namespace SshPortManager {
    public static class CoderPtyTransport {
        private static readonly object Gate = new object();
        private static bool configured;
        public static string CompletedOutput(byte[] bytes, string nonce) {
            if (bytes == null || bytes.Length > 65536 || !Regex.IsMatch(nonce, @"\A[0-9a-f]{32}\z"))
                throw new InvalidOperationException("Invalid terminal output.");
            string text = Encoding.UTF8.GetString(bytes);
            string proof = "\n__SPM_" + nonce + "__|";
            int start = text.IndexOf(proof, StringComparison.Ordinal);
            return start >= 0 && text.IndexOf('\n', start + proof.Length) >= 0 ? text : null;
        }
        private sealed class FixedOriginCreator : IWebRequestCreate {
            public WebRequest Create(Uri uri) {
                if (uri.Scheme != "wss" || uri.Host != "coder.sage.org.ai" || uri.Port != 9450 || !String.IsNullOrEmpty(uri.UserInfo))
                    throw new InvalidOperationException("Invalid terminal origin.");
                HttpWebRequest request = WebRequest.CreateDefault(uri) as HttpWebRequest;
                if (request == null) throw new InvalidOperationException("Unsupported terminal transport.");
                request.AllowAutoRedirect = false;
                request.UseDefaultCredentials = false;
                request.CookieContainer = null;
                return request;
            }
        }
        public static string Read(string address, string session, string nonce, int timeoutMilliseconds, int maximumBytes) {
            Uri uri = new Uri(address);
            if (uri.Scheme != "wss" || uri.Host != "coder.sage.org.ai" || uri.Port != 9450 || !String.IsNullOrEmpty(uri.UserInfo) ||
                !Regex.IsMatch(uri.AbsolutePath, @"\A/api/v2/workspaceagents/[0-9a-fA-F-]{36}/pty\z") ||
                !Regex.IsMatch(nonce, @"\A[0-9a-f]{32}\z") || maximumBytes != 65536 || timeoutMilliseconds <= 0)
                throw new InvalidOperationException("Invalid terminal request.");
            using (ClientWebSocket socket = new ClientWebSocket()) {
                lock (Gate) {
                    if (!configured) {
                        if (!WebRequest.RegisterPrefix("wss://coder.sage.org.ai:9450/", new FixedOriginCreator()))
                            throw new InvalidOperationException("Cannot configure isolated terminal transport.");
                        configured = true;
                    }
                }
                socket.Options.UseDefaultCredentials = false;
                socket.Options.Cookies = null;
                socket.Options.SetRequestHeader("Coder-Session-Token", session);
                socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
                using (CancellationTokenSource cancellation = new CancellationTokenSource(timeoutMilliseconds))
                using (MemoryStream output = new MemoryStream()) {
                    try {
                        socket.ConnectAsync(uri, cancellation.Token).GetAwaiter().GetResult();
                        byte[] buffer = new byte[4096];
                        for (;;) {
                            WebSocketReceiveResult received = socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancellation.Token).GetAwaiter().GetResult();
                            if (received.MessageType == WebSocketMessageType.Close)
                                throw new IOException("Terminal closed without proof.");
                            if (received.MessageType != WebSocketMessageType.Binary && received.MessageType != WebSocketMessageType.Text)
                                throw new IOException("Unexpected terminal frame.");
                            if (output.Length + received.Count > maximumBytes)
                                throw new IOException("Terminal output limit exceeded.");
                            output.Write(buffer, 0, received.Count);
                            string text = CompletedOutput(output.ToArray(), nonce);
                            if (text != null) return text;
                        }
                    } finally { socket.Abort(); }
                }
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Invoke-RootTerminalTransport($Request) {
    Initialize-RootTerminalTransport
    return [SshPortManager.CoderPtyTransport]::Read($Request.Uri, $Request.SessionToken, $Request.Nonce, $Request.TimeoutMilliseconds, $Request.MaximumBytes)
}

function Invoke-CoderRootPreparation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateRange(1,65535)][int]$Port,
        [Parameter(Mandatory=$true)][pscredential]$Credential,
        [string]$WorkspaceName,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 600,
        [scriptblock]$OnProgress = {},
        [scriptblock]$RequestHandler,
        [scriptblock]$TerminalHandler
    )
    $ErrorActionPreference = 'Stop'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $api = @{Clock=$clock;TimeoutSeconds=$TimeoutSeconds;RequestHandler=$RequestHandler}
    $loginBody = $null
    $terminalRequest = $null
    $submitted = $false
    try {
        if ($PSBoundParameters.ContainsKey('WorkspaceName') -and ([string]::IsNullOrWhiteSpace($WorkspaceName) -or $WorkspaceName.Length -gt 128 -or $WorkspaceName -match '[\r\n\x00]')) {
            Stop-CoderRoot 'Invalid expected Coder workspace name.'
        }
        & $OnProgress 'Checking the running Coder workspace before chmod g-w /root...' | Out-Null
        $loginBody = @{email=$Credential.UserName;password=$Credential.GetNetworkCredential().Password}
        $login = Invoke-RootApi $api POST '/api/v2/users/login' $loginBody
        $loginBody.Clear(); $loginBody = $null
        $session = Get-RootField $login 'session_token'
        if ($session -isnot [string] -or [string]::IsNullOrWhiteSpace($session) -or $session.Length -gt 4096 -or $session -match '[\r\n\x00]') {
            Stop-CoderRoot 'Coder login returned an invalid session token.'
        }
        $api.SessionToken = $session
        $login = $null
        $listing = Invoke-RootApi $api GET '/api/v2/workspaces?q=owner%3Ame'
        $all = @(Get-RootField $listing 'workspaces' @())
        if ($WorkspaceName) {
            $all = @($all | Where-Object { [string]::Equals([string](Get-RootField $_ 'name'), $WorkspaceName, [StringComparison]::OrdinalIgnoreCase) })
            if ($all.Count -ne 1) { Stop-CoderRoot 'The expected Coder workspace was missing or ambiguous; no command was submitted.' }
        }
        $candidates = @()
        foreach ($workspace in $all) {
            $latest = Get-RootField $workspace 'latest_build'
            if ([string](Get-RootField $latest 'status') -cne 'running') { continue }
            $workspaceId = Get-RootId $workspace
            $buildId = Get-RootId $latest
            $build = Invoke-RootApi $api GET ('/api/v2/workspacebuilds/' + $buildId)
            if ((Get-RootId $build) -cne $buildId -or [string](Get-RootField $build 'status') -cne 'running') { continue }
            $candidatePort = $null
            try { $candidatePort = Get-RootSshPort $build } catch {
                if ($WorkspaceName) { Stop-CoderRoot 'The expected workspace has invalid or ambiguous SSH metadata; no command was submitted.' }
                continue
            }
            if ($candidatePort -eq $Port) {
                $name = [string](Get-RootField $workspace 'name')
                if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or $name -match '[\r\n\x00]') { Stop-CoderRoot 'Coder returned an invalid workspace name.' }
                $candidates += [pscustomobject]@{WorkspaceId=$workspaceId;BuildId=$buildId;Name=$name;Build=$build}
            }
        }
        if ($candidates.Count -ne 1) { Stop-CoderRoot 'The SSH port must identify exactly one running Coder workspace; no command was submitted.' }
        $selected = $candidates[0]
        $agentId = $null
        while ($true) {
            $null = Get-RootRemaining $clock $TimeoutSeconds
            $freshBuild = Assert-RootWorkspaceSnapshot $api $selected.WorkspaceId $selected.BuildId $selected.Name $Port
            $agent = Get-RootAgent $freshBuild
            $currentAgentId = Get-RootId $agent
            if ($agentId -and $agentId -cne $currentAgentId) { Stop-CoderRoot 'The terminal agent changed; no command was submitted.' }
            $agentId = $currentAgentId
            $status = [string](Get-RootField $agent 'status')
            $lifecycle = [string](Get-RootField $agent 'lifecycle_state')
            if ($status -ceq 'connected' -and $lifecycle -ceq 'ready') { break }
            if (@('start_error','start_timeout','shutdown_timeout','shutdown_error','off') -ccontains $lifecycle) {
                Stop-CoderRoot 'The terminal agent is not ready; no command was submitted.'
            }
            & $OnProgress 'Waiting for the Coder terminal agent to become ready...' | Out-Null
            Start-Sleep -Milliseconds ([Math]::Min(1000, (Get-RootRemaining $clock $TimeoutSeconds)))
        }
        & $OnProgress 'Running chmod g-w /root in the Coder terminal...' | Out-Null
        $terminalRequest = New-RootTerminalRequest $agentId $session (Get-RootRemaining $clock $TimeoutSeconds)
        $submitted = $true
        if ($null -eq $TerminalHandler) { $output = Invoke-RootTerminalTransport $terminalRequest }
        else { $output = & $TerminalHandler $terminalRequest }
        $null = Get-RootRemaining $clock $TimeoutSeconds
        if ($output -isnot [string]) { Stop-CoderRoot 'The terminal did not return a valid completion record.' }
        $proof = Read-RootTerminalProof $output $terminalRequest.Nonce
        $after = Assert-RootWorkspaceSnapshot $api $selected.WorkspaceId $selected.BuildId $selected.Name $Port
        if ((Get-RootId (Get-RootAgent $after)) -cne $agentId) { Stop-CoderRoot 'The terminal agent changed after chmod; the selected endpoint could not be confirmed.' }
        & $OnProgress ('chmod g-w /root completed; /root mode is ' + $proof.RootMode + '.') | Out-Null
        $resultName = if ($WorkspaceName) { $WorkspaceName } else { $selected.Name }
        return [pscustomobject]@{WorkspaceName=$resultName;Port=$Port;Command='chmod g-w /root';RootMode=$proof.RootMode;ExitCode=0}
    } catch {
        if ($_.Exception -is [TimeoutException] -or $_.Exception.Data['CoderRootTimeout'] -eq $true -or $clock.Elapsed.TotalMilliseconds -ge ([double]$TimeoutSeconds * 1000)) {
            if ($submitted) { Stop-CoderRoot 'Coder root preparation timed out after command submission; chmod may already have run. Check the workspace before retrying.' }
            Stop-CoderRoot 'Coder root preparation timed out before command submission; chmod was not run. Check workspace readiness and network access.'
        }
        if ($_.Exception.Data['CoderRootSafe'] -eq $true) { throw }
        if ($submitted) { Stop-CoderRoot 'Coder terminal completion could not be confirmed; chmod may already have run. Check the workspace before retrying.' }
        Stop-CoderRoot 'Coder terminal preparation failed before command submission. Check login, workspace status, and network access.'
    } finally {
        if ($null -ne $loginBody) { $loginBody.Clear() }
        if ($null -ne $terminalRequest) { $terminalRequest.SessionToken = $null }
        $session = $null; $output = $null; $login = $null
        $api.Clear(); $clock.Stop()
    }
}

Export-ModuleMember -Function Invoke-CoderRootPreparation
