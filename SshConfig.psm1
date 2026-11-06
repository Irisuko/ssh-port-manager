Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ByteHash {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-SourceLines {
    param([AllowEmptyString()][string]$Text)
    $index = 0
    foreach ($match in [regex]::Matches($Text, '(?<body>[^\r\n]*)(?<ending>\r\n|\n|\r|$)')) {
        if ($match.Length -eq 0) { continue }
        [pscustomobject]@{
            Index = $index
            Start = $match.Index
            Text = $match.Groups['body'].Value
            Ending = $match.Groups['ending'].Value
        }
        $index++
    }
}

function Get-LineDirective {
    param([string]$Line)
    $match = [regex]::Match($Line, '^(?<indent>[ \t]*)(?<key>[a-zA-Z][a-zA-Z0-9]*)(?<separator>[ \t]+=?[ \t]*|[ \t]*=[ \t]*)(?<rest>.*)$')
    if (-not $match.Success) { return $null }
    $rest = $match.Groups['rest'].Value
    $token = [regex]::Match($rest, '^(?<padding>[ \t]*)(?<token>"[^"\r\n]*"|''[^''\r\n]*''|[^ \t#]+)')
    if (-not $token.Success) { return $null }
    $raw = $token.Groups['token'].Value
    $value = $raw
    if (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'"))) {
        $value = $raw.Substring(1, $raw.Length - 2)
    }
    # Comments are recognized only outside quotes. Host aliases use this whole value.
    $quote = [char]0
    $commentAt = $rest.Length
    for ($i = 0; $i -lt $rest.Length; $i++) {
        $char = $rest[$i]
        if ($quote -ne [char]0) {
            if ($char -eq $quote) { $quote = [char]0 }
        } elseif ($char -eq '"' -or $char -eq "'") {
            $quote = $char
        } elseif ($char -eq '#') {
            $commentAt = $i
            break
        }
    }
    return [pscustomobject]@{
        Key = $match.Groups['key'].Value.ToLowerInvariant()
        Indent = $match.Groups['indent'].Value
        Value = $value
        RawValue = $raw
        ValueOffset = $match.Groups['rest'].Index + $token.Groups['token'].Index
        ValueLength = $raw.Length
        FullValue = $rest.Substring(0, $commentAt).Trim()
    }
}

function Get-HostBlocks {
    param($Document)
    $current = $null
    foreach ($line in $Document.Lines) {
        $directive = Get-LineDirective -Line $line.Text
        if ($null -eq $directive) { continue }
        if ($directive.Key -eq 'host' -or $directive.Key -eq 'match') {
            if ($null -ne $current) { $current.End = $line.Start; Write-Output $current }
            $current = $null
            if ($directive.Key -eq 'host') {
                $current = [pscustomobject]@{
                    Id = $line.Index.ToString([Globalization.CultureInfo]::InvariantCulture)
                    Alias = $directive.FullValue
                    Header = $line
                    End = $Document.Text.Length
                    Entries = New-Object 'System.Collections.Generic.List[object]'
                }
            }
            continue
        }
        if ($null -ne $current) {
            $current.Entries.Add([pscustomobject]@{Line=$line;Directive=$directive})
        }
    }
    if ($null -ne $current) { Write-Output $current }
}

function ConvertTo-ValidPort {
    param($Value)
    $text = [string]$Value
    $number = 0
    if ($text -cnotmatch '\A[0-9]+\z' -or -not [int]::TryParse($text, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "Invalid SSH port '$text'. Enter a decimal integer from 1 to 65535."
    }
    return $number
}

function Read-SshDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { throw "SSH config file was not found: $fullPath" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    $offset = 0
    [byte[]]$preamble = @()
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    if ($bytes.Length -ge 4 -and (($bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff))) {
        throw 'UTF-32 SSH configuration is not supported. Save it as UTF-8 first.'
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        $offset = 3
        $preamble = [byte[]]@(0xef,0xbb,0xbf)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) {
        $offset = 2
        $preamble = [byte[]]@(0xff,0xfe)
        $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) {
        $offset = 2
        $preamble = [byte[]]@(0xfe,0xff)
        $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
    }
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch { throw 'SSH config encoding is unsupported or invalid. Save it as UTF-8 first; no file was changed.' }
    if ($text.Contains([string][char]0)) { throw 'SSH config contains NUL characters or an unsupported encoding; no file was changed.' }
    $lines = @(Get-SourceLines -Text $text)
    $newline = "`r`n"
    foreach ($line in $lines) { if ($line.Ending.Length -gt 0) { $newline = $line.Ending; break } }
    return [pscustomobject]@{
        Path = $fullPath
        Text = $text
        Hash = Get-ByteHash -Bytes $bytes
        Encoding = $encoding
        Preamble = $preamble
        Bytes = $bytes
        Lines = $lines
        Newline = $newline
    }
}

function Get-TargetHosts {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Document)
    foreach ($block in @(Get-HostBlocks -Document $Document)) {
        $name = $null
        $userValue = ''
        $port = 22
        $explicitPort = $false
        foreach ($entry in $block.Entries) {
            switch ($entry.Directive.Key) {
                'hostname' { if ($null -eq $name) { $name = $entry.Directive.Value } }
                'user' { if ($userValue.Length -eq 0) { $userValue = $entry.Directive.Value } }
                'port' {
                    if (-not $explicitPort) { $port = $entry.Directive.Value; $explicitPort = $true }
                }
            }
        }
        if ($name -cne '36.140.239.91') { continue }
        $portNumber = ConvertTo-ValidPort -Value $port
        [pscustomobject]@{
            Id = $block.Id
            Alias = $block.Alias
            HostName = $name
            User = $userValue
            Port = $portNumber
            HasExplicitPort = $explicitPort
        }
    }
}

function New-PortUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Document,
        [AllowEmptyCollection()][object[]]$Updates = @()
    )
    $targets = @{}
    foreach ($target in @(Get-TargetHosts -Document $Document)) { $targets[$target.Id] = $target }
    $requested = @{}
    foreach ($update in $Updates) {
        if ($null -eq $update -or $null -eq $update.PSObject.Properties['Id'] -or $null -eq $update.PSObject.Properties['Port']) { throw 'An update must contain Id and Port.' }
        $id = [string]$update.Id
        if (-not $targets.ContainsKey($id)) { throw "The selected host no longer exists: $id. Refresh the configuration." }
        if ($requested.ContainsKey($id)) { throw "The same host was selected more than once: $id." }
        $requested[$id] = ConvertTo-ValidPort -Value $update.Port
    }
    if ($requested.Count -eq 0) { return $Document.Text }
    $edits = New-Object 'System.Collections.Generic.List[object]'
    foreach ($block in @(Get-HostBlocks -Document $Document)) {
        if (-not $requested.ContainsKey($block.Id)) { continue }
        $newPort = $requested[$block.Id].ToString([Globalization.CultureInfo]::InvariantCulture)
        $ports = @($block.Entries | Where-Object { $_.Directive.Key -eq 'port' })
        if ($ports.Count -eq 0) {
            $indent = '    '
            foreach ($entry in $block.Entries) { if ($entry.Directive.Indent.Length -gt 0) { $indent = $entry.Directive.Indent; break } }
            $ending = $block.Header.Ending
            if ($ending.Length -eq 0) {
                $at = $block.Header.Start + $block.Header.Text.Length
                $replacement = $Document.Newline + $indent + 'Port ' + $newPort
            } else {
                $at = $block.Header.Start + $block.Header.Text.Length + $ending.Length
                $replacement = $indent + 'Port ' + $newPort + $ending
            }
            $edits.Add([pscustomobject]@{Start=$at;Length=0;Text=$replacement})
        } else {
            foreach ($entry in $ports) {
                $directive = $entry.Directive
                $replacement = $newPort
                if ($directive.RawValue.StartsWith('"')) { $replacement = '"' + $newPort + '"' }
                elseif ($directive.RawValue.StartsWith("'")) { $replacement = "'" + $newPort + "'" }
                $edits.Add([pscustomobject]@{Start=($entry.Line.Start + $directive.ValueOffset);Length=$directive.ValueLength;Text=$replacement})
            }
        }
    }
    $result = $Document.Text
    foreach ($edit in @($edits | Sort-Object -Property Start -Descending)) {
        $result = $result.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
    }
    return $result
}

function Get-HostAliases {
    param([string]$Value)
    foreach ($token in [regex]::Matches($Value, '"[^"\r\n]*"|''[^''\r\n]*''|[^ \t]+')) {
        $aliasValue = $token.Value
        if (($aliasValue.StartsWith('"') -and $aliasValue.EndsWith('"')) -or ($aliasValue.StartsWith("'") -and $aliasValue.EndsWith("'"))) {
            $aliasValue = $aliasValue.Substring(1, $aliasValue.Length - 2)
        }
        Write-Output $aliasValue
    }
}

function Assert-LiteralHostAlias {
    param([AllowEmptyString()][string]$Value)
    if ($Value -cnotmatch '\A[A-Za-z0-9_.-]+\z') {
        throw 'Host alias must contain only ASCII letters, digits, underscore, dot or hyphen; spaces and wildcard patterns are not allowed.'
    }
}

function Assert-SshUser {
    param([AllowEmptyString()][string]$Value)
    if ($Value -cnotmatch '\A[A-Za-z0-9_.-]{1,64}\z') {
        throw 'SSH user must be 1-64 ASCII letters, digits, underscore, dot or hyphen.'
    }
}

function New-SshHostChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Document,
        [Parameter(Mandatory=$true)][ValidateSet('Add','Edit','Delete')][string]$Action,
        [string]$Id,
        [AllowEmptyString()][string]$Alias,
        [AllowEmptyString()][string]$User = 'root',
        [AllowNull()]$Port
    )
    $blocks = @(Get-HostBlocks -Document $Document)
    $selected = $null
    if ($Action -ne 'Add') {
        $targets = @(Get-TargetHosts -Document $Document | Where-Object { $_.Id -ceq $Id })
        if ($targets.Count -ne 1) { throw 'The selected target host no longer exists or is not managed by this application. Refresh the configuration.' }
        $selected = @($blocks | Where-Object { $_.Id -ceq $Id })[0]
        $existingAliases = @(Get-HostAliases -Value $selected.Alias)
        if ($existingAliases.Count -ne 1 -or $existingAliases[0] -cnotmatch '\A[A-Za-z0-9_.-]+\z') {
            throw 'Edit and delete support only a single literal Host alias. Multi-alias, wildcard and negated Host blocks must be edited manually.'
        }
        if ($Action -eq 'Delete') {
            # Comments and blank lines after its final directive remain part of this block.
            return $Document.Text.Remove($selected.Header.Start, $selected.End - $selected.Header.Start)
        }
    }

    $changeAlias = $Action -eq 'Add' -or $PSBoundParameters.ContainsKey('Alias')
    $changeUser = $Action -eq 'Add' -or $PSBoundParameters.ContainsKey('User')
    $changePort = $Action -eq 'Add' -or $PSBoundParameters.ContainsKey('Port')
    if ($changeAlias) {
        Assert-LiteralHostAlias -Value $Alias
        foreach ($block in $blocks) {
            if ($null -ne $selected -and $block.Id -ceq $selected.Id) { continue }
            foreach ($existingAlias in @(Get-HostAliases -Value $block.Alias)) {
                if ($existingAlias -ieq $Alias) { throw "Host alias '$Alias' already exists in the SSH configuration. Choose a different alias." }
            }
        }
    }
    if ($changeUser) { Assert-SshUser -Value $User }
    $portValue = $null
    if ($changePort) { $portValue = (ConvertTo-ValidPort -Value $Port).ToString([Globalization.CultureInfo]::InvariantCulture) }

    if ($Action -eq 'Add') {
        $newline = $Document.Newline
        $insertAt = $Document.Text.Length
        $globalOptions = @{}
        foreach ($line in $Document.Lines) {
            $directive = Get-LineDirective -Line $line.Text
            if ($null -ne $directive -and ($directive.Key -eq 'host' -or $directive.Key -eq 'match')) {
                $insertAt = $line.Start
                break
            }
            if ($null -ne $directive -and $directive.Key -in @('hostname','user','port') -and -not $globalOptions.ContainsKey($directive.Key)) {
                $globalOptions[$directive.Key] = $directive.Value
            }
        }
        $expectedGlobals = @{hostname='36.140.239.91';user=$User;port=$portValue}
        foreach ($key in $globalOptions.Keys) {
            $globalValue = $globalOptions[$key]
            if ($key -eq 'port') { $globalValue = (ConvertTo-ValidPort -Value $globalValue).ToString([Globalization.CultureInfo]::InvariantCulture) }
            if ($globalValue -cne $expectedGlobals[$key]) {
                throw "Cannot add host: global $key '$globalValue' before the first Host or Match conflicts with the requested value '$($expectedGlobals[$key])'. Update that global option manually first; no file was changed."
            }
        }
        $prefix = $Document.Text.Substring(0, $insertAt)
        $suffix = $Document.Text.Substring($insertAt)
        $separator = ''
        if ($suffix.Length -eq 0 -and $prefix.Length -gt 0) {
            $lastLine = $Document.Lines[$Document.Lines.Count - 1]
            if ($lastLine.Ending.Length -eq 0) { $separator = $newline + $newline }
            elseif ($lastLine.Text.Length -gt 0) { $separator = $newline }
        }
        $newBlock = 'Host ' + $Alias + $newline +
            '    HostName 36.140.239.91' + $newline +
            '    User ' + $User + $newline +
            '    Port ' + $portValue + $newline
        # Explicit hosts precede wildcard defaults: OpenSSH uses the first obtained value.
        if ($suffix.Length -gt 0) { $newBlock += $newline }
        return $prefix + $separator + $newBlock + $suffix
    }

    $edits = New-Object 'System.Collections.Generic.List[object]'
    if ($changeAlias) {
        $headerDirective = Get-LineDirective -Line $selected.Header.Text
        $aliasReplacement = $Alias
        if ($headerDirective.RawValue.StartsWith('"')) { $aliasReplacement = '"' + $Alias + '"' }
        elseif ($headerDirective.RawValue.StartsWith("'")) { $aliasReplacement = "'" + $Alias + "'" }
        $edits.Add([pscustomobject]@{Start=($selected.Header.Start + $headerDirective.ValueOffset);Length=$headerDirective.ValueLength;Text=$aliasReplacement})
    }
    $requested = [ordered]@{}
    if ($changeUser) { $requested['User'] = $User }
    if ($changePort) { $requested['Port'] = $portValue }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $indent = '    '
    foreach ($entry in $selected.Entries) { if ($entry.Directive.Indent.Length -gt 0) { $indent = $entry.Directive.Indent; break } }
    foreach ($key in $requested.Keys) {
        $entries = @($selected.Entries | Where-Object { $_.Directive.Key -ieq $key })
        if ($entries.Count -eq 0) {
            $missing.Add($indent + $key + ' ' + $requested[$key])
            continue
        }
        foreach ($entry in $entries) {
            $replacement = [string]$requested[$key]
            if ($entry.Directive.RawValue.StartsWith('"')) { $replacement = '"' + $replacement + '"' }
            elseif ($entry.Directive.RawValue.StartsWith("'")) { $replacement = "'" + $replacement + "'" }
            $edits.Add([pscustomobject]@{Start=($entry.Line.Start + $entry.Directive.ValueOffset);Length=$entry.Directive.ValueLength;Text=$replacement})
        }
    }
    if ($missing.Count -gt 0) {
        $ending = $selected.Header.Ending
        if ($ending.Length -eq 0) {
            $at = $selected.Header.Start + $selected.Header.Text.Length
            $replacement = $Document.Newline + ($missing -join $Document.Newline)
        } else {
            $at = $selected.Header.Start + $selected.Header.Text.Length + $ending.Length
            $replacement = ($missing -join $ending) + $ending
        }
        $edits.Add([pscustomobject]@{Start=$at;Length=0;Text=$replacement})
    }
    $result = $Document.Text
    foreach ($edit in @($edits | Sort-Object -Property Start -Descending)) {
        $result = $result.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
    }
    return $result
}

function Save-SshDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Document,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][string]$ExpectedHash
    )
    if ($ExpectedHash -cne $Document.Hash) { throw 'The requested snapshot does not match the loaded SSH config. Refresh and retry.' }
    $currentHash = Get-ByteHash -Bytes ([IO.File]::ReadAllBytes($Document.Path))
    if ($currentHash -cne $ExpectedHash) { throw 'SSH config changed since it was loaded. Refresh before applying updates; no file was changed.' }
    if ($Text -ceq $Document.Text) { return [pscustomobject]@{Changed=$false;BackupPath=$null} }
    [byte[]]$outputBytes = $Document.Preamble + $Document.Encoding.GetBytes($Text)
    $token = [Guid]::NewGuid().ToString('N')
    $temporaryPath = $Document.Path + '.port-manager-' + $token + '.tmp'
    $backupPath = $Document.Path + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $token.Substring(0,8)
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $outputBytes)
        $currentHash = Get-ByteHash -Bytes ([IO.File]::ReadAllBytes($Document.Path))
        if ($currentHash -cne $ExpectedHash) { throw 'SSH config changed while preparing updates. Refresh and retry; no file was changed.' }
        # Replace preserves the destination's metadata/ACL and backs up the original in one operation.
        [IO.File]::Replace($temporaryPath, $Document.Path, $backupPath, $false)
        return [pscustomobject]@{Changed=$true;BackupPath=$backupPath}
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

Export-ModuleMember -Function Read-SshDocument,Get-TargetHosts,New-PortUpdate,New-SshHostChange,Save-SshDocument
