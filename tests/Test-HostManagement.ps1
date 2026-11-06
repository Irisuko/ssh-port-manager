$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'HostManagement.psm1') -Force
Import-Module (Join-Path $project 'SshConfig.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $project 'Mappings.psm1') -Force
$root=Join-Path $PSScriptRoot ('host-management-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert($value,[string]$why){if(-not $value){throw $why}}
try{
    $config=Join-Path $root 'config'
    $maps=Join-Path $root 'mappings.json'
    $source="Host unrelated`n HostName example.test`n Port 443`nHost PyramidKV-plugin`n HostName 36.140.239.91`n User root`n Port 32067`n RemoteForward 18080 localhost:7890`n"
    [IO.File]::WriteAllText($config,$source)
    $doc=Read-SshDocument -Path $config
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Add -Alias 'New-GPU' -User root -Port 32123 -WorkspaceName 'MyServer' -MappingsPath $maps
    Assert $result.Success 'Host add should succeed.'
    Assert ($result.ConfigChanged -and $result.MappingsSaved) 'Both files should be saved.'
    Assert ([IO.File]::ReadAllText($result.ConfigBackupPath) -ceq $source) 'Config backup must preserve exact prior content.'
    Assert ((Get-CoderMappings -Path $maps)['New-GPU'] -ceq 'MyServer') 'New mapping not saved.'
    Assert ([IO.File]::ReadAllText($config).Contains("Host unrelated`n HostName example.test`n Port 443")) 'Unrelated host changed.'
    'PASS: add host and binding with config backup and unrelated entries preserved'

    $doc=Read-SshDocument -Path $config
    $selected=@(Get-TargetHosts -Document $doc|Where-Object Alias -eq 'New-GPU')[0]
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Edit -Id $selected.Id -Alias 'Renamed-GPU' -User ubuntu -Port 32124 -WorkspaceName 'AnotherServer' -MappingsPath $maps
    Assert $result.Success 'Rename/edit should succeed.'
    $bindings=Get-CoderMappings -Path $maps
    Assert (-not $bindings.ContainsKey('New-GPU') -and $bindings['Renamed-GPU'] -ceq 'AnotherServer') 'Rename must move binding.'
    Assert ($bindings.ContainsKey('PyramidKV-plugin')) 'Other mappings must survive.'
    'PASS: rename updates matching binding and preserves other mappings'

    $doc=Read-SshDocument -Path $config
    $selected=@(Get-TargetHosts -Document $doc|Where-Object Alias -eq 'Renamed-GPU')[0]
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Edit -Id $selected.Id -Alias 'Renamed-GPU' -User ubuntu -Port 32124 -WorkspaceName '' -MappingsPath $maps
    Assert ($result.Success -and -not $result.ConfigChanged) 'Unbind should not rewrite unchanged config.'
    Assert (-not (Get-CoderMappings -Path $maps).ContainsKey('Renamed-GPU')) 'Blank workspace must unbind.'
    'PASS: empty workspace unbinds without rewriting unchanged SSH config'

    $doc=Read-SshDocument -Path $config
    $selected=@(Get-TargetHosts -Document $doc|Where-Object Alias -eq 'Renamed-GPU')[0]
    $before=$doc.Text
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash ('0'*64) -Action Delete -Id $selected.Id -MappingsPath $maps
    Assert (-not $result.Success) 'Stale snapshot must block deletion.'
    Assert ([IO.File]::ReadAllText($config) -ceq $before) 'Stale delete mutated config.'
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Delete -Id $selected.Id -MappingsPath $maps
    Assert $result.Success 'Delete should succeed.'
    Assert (-not [IO.File]::ReadAllText($config).Contains('Renamed-GPU')) 'Deleted local block still exists.'
    Assert ([IO.File]::ReadAllText($result.ConfigBackupPath) -ceq $before) 'Deleted host must remain in backup.'
    'PASS: local deletion checks snapshot and keeps recoverable backup'

    $doc=Read-SshDocument -Path $config
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Add -Alias 'InvalidWorkspace' -User root -Port 32125 -WorkspaceName "bad`nname" -MappingsPath $maps
    Assert (-not $result.Success -and [IO.File]::ReadAllText($config) -ceq $doc.Text) 'Invalid mapping must fail before SSH save.'
    'PASS: malformed workspace binding is rejected before config mutation'

    $blocked=Join-Path $root 'file-not-folder'
    [IO.File]::WriteAllText($blocked,'fixture')
    $result=Invoke-HostManagementChange -ConfigPath $config -ExpectedHash $doc.Hash -Action Add -Alias 'Partial-GPU' -User root -Port 32126 -WorkspaceName 'Workspace' -MappingsPath (Join-Path $blocked 'maps.json')
    Assert (-not $result.Success -and $result.ConfigChanged -and -not $result.MappingsSaved) 'Partial save must be accurately reported.'
    Assert ([IO.File]::Exists($result.ConfigBackupPath)) 'Partial save must retain config backup.'
    'PASS: mapping write failure reports config partial success and backup'
}finally{
    $resolved=[IO.Path]::GetFullPath($root)
    $allowed=[IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
