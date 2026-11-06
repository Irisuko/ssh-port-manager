Set-StrictMode -Version Latest

function Get-CoderMappingsPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        if ([string]::IsNullOrWhiteSpace($localAppData) -or -not [IO.Path]::IsPathRooted($localAppData)) {
            throw 'LOCALAPPDATA is unavailable; choose a full mapping settings path.'
        }
        $Path = Join-Path $localAppData 'SshPortManager\mappings.json'
    }
    return [IO.Path]::GetFullPath($Path)
}

function ConvertTo-CoderMappingTable {
    param([Collections.IDictionary]$Mappings)
    if ($null -eq $Mappings) { throw 'Coder mappings must be a dictionary.' }
    $normalized = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in $Mappings.Keys) {
        if ($alias -isnot [string] -or $alias -cnotmatch '\A[A-Za-z0-9_.-]+\z') {
            throw 'Each SSH alias must be one literal name containing only ASCII letters, digits, underscores, dots, or hyphens.'
        }
        if ($normalized.ContainsKey($alias)) { throw 'Duplicate SSH aliases differ only by case; keep exactly one mapping per alias.' }
        $workspace = $Mappings[$alias]
        if ($workspace -isnot [string] -or $workspace -match '[\r\n\x00]') {
            throw 'Each workspace name must be text without newlines or NUL characters.'
        }
        $workspace = $workspace.Trim()
        if ($workspace.Length -eq 0 -or $workspace.Length -gt 128) {
            throw 'Each workspace name must contain between 1 and 128 characters after trimming.'
        }
        $normalized.Add($alias, $workspace)
    }
    return ,$normalized
}

function Get-CoderMappings {
    [CmdletBinding()]
    param([string]$Path)
    $resolvedPath = Get-CoderMappingsPath $Path
    try {
        $text = [IO.File]::ReadAllText($resolvedPath, [Text.UTF8Encoding]::new($false, $true))
    }
    catch [IO.FileNotFoundException] {
        return ,(ConvertTo-CoderMappingTable @{ 'PyramidKV-plugin' = 'PyramidKV'; 'MuxWise-plugin' = 'Irisuko' })
    }
    catch [IO.DirectoryNotFoundException] {
        return ,(ConvertTo-CoderMappingTable @{ 'PyramidKV-plugin' = 'PyramidKV'; 'MuxWise-plugin' = 'Irisuko' })
    }
    catch { throw 'Unable to read local Coder mapping settings. Check the file path, permissions, and encoding.' }
    try { $document = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw 'Local Coder mapping settings contain invalid JSON; restore a backup or correct the file.' }
    if ($null -eq $document -or $null -eq $document.PSObject.Properties['version'] -or
        $document.version -isnot [int] -or $document.version -ne 1 -or
        $null -eq $document.PSObject.Properties['mappings'] -or $document.mappings -isnot [Array]) {
        throw 'Local Coder mapping settings must use version 1 and a mappings array.'
    }
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($entry in $document.mappings) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['alias'] -or
            $null -eq $entry.PSObject.Properties['workspace'] -or $entry.alias -isnot [string]) {
            throw 'Each stored mapping must contain an SSH alias and a workspace name.'
        }
        if ($entries.ContainsKey($entry.alias)) { throw 'The mapping settings contain duplicate SSH aliases.' }
        $entries.Add($entry.alias, $entry.workspace)
    }
    return ,(ConvertTo-CoderMappingTable $entries)
}

function Save-CoderMappings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.IDictionary]$Mappings,
        [string]$Path
    )
    $normalized = ConvertTo-CoderMappingTable $Mappings
    $resolvedPath = Get-CoderMappingsPath $Path
    $directory = [IO.Path]::GetDirectoryName($resolvedPath)
    if ([IO.Directory]::Exists($resolvedPath)) { throw 'The mapping settings path is a directory, not a file.' }
    $entries = @(
        foreach ($alias in @($normalized.Keys | Sort-Object)) {
            [ordered]@{ alias = $alias; workspace = $normalized[$alias] }
        }
    )
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; mappings = $entries }) -Depth 5
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $token = [Guid]::NewGuid().ToString('N')
    $temporaryPath = $resolvedPath + '.mapping-' + $token + '.tmp'
    $backupPath = $null
    try {
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($resolvedPath)) {
            $backupPath = $resolvedPath + '.backup-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '-' + $token.Substring(0, 8)
            # Same-directory replacement atomically publishes the new map while
            # preserving the previous file bytes and destination security metadata.
            [IO.File]::Replace($temporaryPath, $resolvedPath, $backupPath, $false)
        }
        else { [IO.File]::Move($temporaryPath, $resolvedPath) }
        return [PSCustomObject]@{ Path = $resolvedPath; BackupPath = $backupPath }
    }
    finally { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } }
}

Export-ModuleMember -Function Get-CoderMappings, Save-CoderMappings
