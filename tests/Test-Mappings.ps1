$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$appRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $appRoot 'Mappings.psm1'
if (-not [IO.File]::Exists($modulePath)) { throw 'FAIL: local Coder mapping storage is not implemented.' }
Import-Module $modulePath -Force
$script:passed = 0
$runsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runs'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $runsRoot ('mappings-' + [Guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($true)
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('FAIL: ' + $Message) } }
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw ('FAIL: ' + $Message + ' expected <' + $Expected + '> actual <' + $Actual + '>') }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true }
    Assert-True $caught $Message
}
function Pass([string]$Name) { $script:passed++; Write-Output ('PASS: ' + $Name) }

try {
    $missingPath = Join-Path $testRoot 'not-created\mappings.json'
    $items = @(Get-CoderMappings -Path $missingPath)
    Assert-Equal $items.Count 1 'loader emits exactly one map'
    $map = $items[0]
    Assert-True ($map -is [hashtable]) 'loader returns a hashtable'
    Assert-Equal $map.Count 2 'missing settings have two original defaults'
    Assert-Equal $map['PYRAMIDKV-PLUGIN'] 'PyramidKV' 'lookup is case-insensitive'
    Assert-Equal $map['muxwise-plugin'] 'Irisuko' 'second default preserved'
    Assert-True (-not [IO.Directory]::Exists((Split-Path $missingPath -Parent))) 'Get never creates directories or files'
    $map['PyramidKV-plugin'] = 'changed'
    Assert-Equal (Get-CoderMappings -Path $missingPath)['PyramidKV-plugin'] 'PyramidKV' 'caller mutation cannot change future defaults'
    Pass 'absent settings return independent case-insensitive defaults without writes'

    $path = Join-Path $testRoot 'new-settings\mappings.json'
    $saved = Save-CoderMappings -Path $path -Mappings @{ 'project-new' = '  My Workspace  '; 'other.alias_2' = '研究空间' }
    Assert-Equal $saved.Path ([IO.Path]::GetFullPath($path)) 'save returns full path'
    Assert-Equal $saved.BackupPath $null 'first save needs no backup'
    $loaded = Get-CoderMappings -Path $path
    Assert-Equal $loaded.Count 2 'saved map replaces defaults'
    Assert-Equal $loaded['PROJECT-NEW'] 'My Workspace' 'workspace name is trimmed and alias is case-insensitive'
    Assert-Equal $loaded['other.alias_2'] '研究空间' 'Unicode workspace names survive JSON'
    Assert-True (-not $loaded.ContainsKey('PyramidKV-plugin')) 'saved maps do not merge hidden defaults'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $path -Parent)).Count 1 'atomic create leaves only destination'
    Pass 'new aliases and arbitrary workspace names round-trip as local mappings'

    $before = [IO.File]::ReadAllBytes($path)
    $saved = Save-CoderMappings -Path $path -Mappings @{ 'new-alias' = 'another-workspace' }
    Assert-True ([IO.File]::Exists($saved.BackupPath)) 'replacement creates a backup'
    Assert-True ([IO.Path]::GetFileName($saved.BackupPath) -match '^mappings\.json\.backup-\d{8}-\d{6}-\d{3}-[a-f0-9]+$') 'backup has timestamp and collision-safe suffix'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($saved.BackupPath))) ([Convert]::ToBase64String($before)) 'backup is byte-identical to previous content'
    Assert-Equal (Get-CoderMappings -Path $path)['new-alias'] 'another-workspace' 'replacement has new map'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count 0 'replacement leaves no staging files'
    Pass 'atomic replacement backs up previous bytes with a timestamp'

    $null = Save-CoderMappings -Path $path -Mappings @{}
    $empty = Get-CoderMappings -Path $path
    Assert-True ($empty -is [hashtable]) 'empty mapping returns a single hashtable'
    Assert-Equal $empty.Count 0 'empty mapping stays empty across reload'
    Assert-True (-not $empty.ContainsKey('PyramidKV-plugin')) 'empty settings do not re-seed defaults'
    Pass 'deleting every mapping persists an empty collection'

    $beforeText = [IO.File]::ReadAllText($path)
    $beforeCount = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent)).Count
    foreach ($alias in @('', 'two aliases', 'wild*', 'wild?', 'bad[alias]', '!excluded', ' padded', '路径', "bad`nname")) {
        $badMap = @{}; $badMap[$alias] = 'workspace'
        Assert-Throws { Save-CoderMappings -Path $path -Mappings $badMap } 'invalid alias must be rejected before writes'
    }
    foreach ($workspace in @('', '   ', "one`ntwo", "one`rtwo", ('x' * 129))) {
        Assert-Throws { Save-CoderMappings -Path $path -Mappings @{ alias = $workspace } } 'invalid workspace must be rejected before writes'
    }
    $duplicate = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $duplicate.Add('same', 'one'); $duplicate.Add('SAME', 'two')
    Assert-Throws { Save-CoderMappings -Path $path -Mappings $duplicate } 'case-colliding aliases are ambiguous'
    Assert-Equal ([IO.File]::ReadAllText($path)) $beforeText 'invalid save leaves previous settings unchanged'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $path -Parent)).Count $beforeCount 'invalid save creates no backup or temporary files'
    Pass 'invalid names and duplicate aliases fail before any mutation'

    $badPath = Join-Path $testRoot 'bad.json'
    foreach ($content in @(
        '{',
        '{"version":2,"mappings":[]}',
        '{"version":1,"mappings":null}',
        '{"version":1,"mappings":[{"alias":"a","workspace":"one"},{"alias":"A","workspace":"two"}]}',
        '{"version":1,"mappings":[{"alias":"two aliases","workspace":"one"}]}',
        '{"version":1,"mappings":[{"alias":"a"}]}'
    )) {
        [IO.File]::WriteAllText($badPath, $content, $utf8)
        Assert-Throws { Get-CoderMappings -Path $badPath } 'corrupt, unsupported, or ambiguous settings must not silently fall back'
        Assert-Equal ([IO.File]::ReadAllText($badPath)) $content 'loader never repairs malformed settings by overwriting them'
    }
    Pass 'malformed stored settings fail explicitly without fallback or writes'

    $previousLocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    try {
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path $testRoot 'fake-localappdata'), 'Process')
        $defaults = Get-CoderMappings
        Assert-Equal $defaults.Count 2 'default path can load absent defaults'
        $saved = Save-CoderMappings -Mappings @{ 'local-new' = 'own-workspace' }
        Assert-Equal $saved.Path (Join-Path $testRoot 'fake-localappdata\SshPortManager\mappings.json') 'default path is LocalAppData SshPortManager'
        Assert-Equal (Get-CoderMappings)['LOCAL-NEW'] 'own-workspace' 'default-path reads saved local mapping'
    }
    finally { [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $previousLocalAppData, 'Process') }
    Pass 'default path uses only the configured local application data directory'

    Write-Output ($script:passed.ToString() + ' mapping tests passed.')
}
finally {
    if ($testRoot.StartsWith($runsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
