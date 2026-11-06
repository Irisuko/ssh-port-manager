$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SshConfig.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw 'FAIL: SshConfig.psm1 implementation is missing.' }
Import-Module $modulePath -Force
$script:Passed = 0
$fixtureRoot = Join-Path $PSScriptRoot ('fixtures-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "FAIL: $Name`nExpected: <$Expected>`nActual: <$Actual>" }
}
function Assert-True([bool]$Value, [string]$Name) { if (-not $Value) { throw "FAIL: $Name" } }
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $didThrow = $false
    try { & $Action | Out-Null } catch { $didThrow = $true }
    Assert-True $didThrow $Name
}
function Write-Fixture([string]$Name, [string]$Text, [Text.Encoding]$Encoding = (New-Object Text.UTF8Encoding($false))) {
    $path = Join-Path $fixtureRoot $Name
    [IO.File]::WriteAllText($path, $Text, $Encoding)
    return $path
}
function Pass([string]$Name) { $script:Passed++; Write-Output "PASS: $Name" }
try {
    $source = "# keep`r`nInclude other.conf`r`nHost first`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port  32041 # old`r`n    RemoteForward 127.0.0.1:18080 127.0.0.1:7890`r`n`r`nHost second`r`n`tHostName=`"36.140.239.91`"`r`n`tPORT = 32081`r`nHost unrelated`r`n    HostName other.example`r`n    Port 443`r`n"
    $path = Write-Fixture 'config' $source
    $doc = Read-SshDocument -Path $path
    $targets = @(Get-TargetHosts -Document $doc)
    Assert-Equal $targets.Count 2 'find both target hosts'
    Assert-Equal $targets[0].Alias 'first' 'first alias'
    Assert-Equal $targets[0].Port 32041 'first current port'
    Assert-Equal $targets[0].User 'root' 'first user'
    Assert-Equal $targets[1].Port 32081 'equals and upper-case directive'
    $updated = New-PortUpdate -Document $doc -Updates @([pscustomobject]@{Id=$targets[0].Id;Port='32091'})
    Assert-Equal $updated ($source.Replace('Port  32041 # old','Port  32091 # old')) 'update only selected value, preserve all other bytes'
    Assert-Equal (New-PortUpdate -Document $doc -Updates @()) $source 'empty changes preserve source'
    Pass 'multiple hosts; selected edit preserves comments, whitespace and unrelated configuration'

    $source2 = "Host first second`n`tHostName 36.140.239.91 # comment`n`tHostName 9.9.9.9`n`tPort `"32041`" # first wins`n`tPort 32042`nMatch user root`n    HostName 36.140.239.91`n    Port 1`nHost third`n    HostName 9.9.9.9`n    HostName 36.140.239.91"
    $doc2 = Read-SshDocument -Path (Write-Fixture 'duplicates' $source2)
    $targets2 = @(Get-TargetHosts -Document $doc2)
    Assert-Equal $targets2.Count 1 'Match blocks and second HostName excluded'
    Assert-Equal $targets2[0].Alias 'first second' 'multiple aliases retained'
    Assert-Equal $targets2[0].Port 32041 'first Port wins'
    $updated2 = New-PortUpdate -Document $doc2 -Updates @([pscustomobject]@{Id=$targets2[0].Id;Port=2222})
    Assert-True ($updated2.Contains('Port "2222" # first wins')) 'quoted Port syntax retained'
    Assert-True ($updated2.Contains("`tPort 2222`nMatch")) 'duplicate port updated consistently'
    Assert-True ($updated2.EndsWith('    HostName 36.140.239.91')) 'no trailing newline preserved'
    Pass 'first-value semantics, multi-alias block, Match boundary, duplicate ports, EOF preservation'

    $source3 = "Host new`r`n    Include settings.conf`r`n    HostName 36.140.239.91"
    $doc3 = Read-SshDocument -Path (Write-Fixture 'missing-port' $source3)
    $targets3 = @(Get-TargetHosts -Document $doc3)
    Assert-Equal $targets3[0].Port 22 'missing Port defaults to 22'
    Assert-True (-not $targets3[0].HasExplicitPort) 'missing Port marked'
    Assert-Equal (New-PortUpdate -Document $doc3 -Updates @([pscustomobject]@{Id=$targets3[0].Id;Port=65535})) "Host new`r`n    Port 65535`r`n    Include settings.conf`r`n    HostName 36.140.239.91" 'insert Port before Includes'
    Pass 'missing Port insertion before Include with original newline style'

    foreach ($bad in @('0','65536','22;whoami','-1','1.5','+22','1e3',' 22 ','abc',"22`n",([char]0xff12).ToString())) {
        Assert-Throws { New-PortUpdate -Document $doc -Updates @([pscustomobject]@{Id=$targets[0].Id;Port=$bad}) } "reject invalid port $bad"
    }
    Assert-Throws { New-PortUpdate -Document $doc -Updates @([pscustomobject]@{Id='9999';Port=22}) } 'reject unknown ID'
    Assert-Throws { New-PortUpdate -Document $doc -Updates @([pscustomobject]@{Id=$targets[0].Id;Port=22},[pscustomobject]@{Id=$targets[0].Id;Port=23}) } 'reject duplicate IDs'
    Pass 'strict port range and syntax; unknown and duplicate update IDs'

    $save = Save-SshDocument -Document $doc -Text $updated -ExpectedHash $doc.Hash
    Assert-True $save.Changed 'save reports change'
    Assert-Equal ([IO.File]::ReadAllText($path)) $updated 'saved updated config'
    Assert-Equal ([IO.File]::ReadAllText($save.BackupPath)) $source 'backup contains exact original text'
    $docAfter = Read-SshDocument -Path $path
    $noChange = Save-SshDocument -Document $docAfter -Text $docAfter.Text -ExpectedHash $docAfter.Hash
    Assert-True (-not $noChange.Changed) 'same text skips writes'
    Assert-True ([string]::IsNullOrEmpty($noChange.BackupPath)) 'same text creates no backup'
    Assert-Throws { Save-SshDocument -Document $doc -Text $updated -ExpectedHash $doc.Hash } 'stale document cannot overwrite current config'
    Pass 'atomic save, exact backup, no-op save and stale snapshot rejection'

    foreach ($encoding in @((New-Object Text.UTF8Encoding($true)), [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
        $unicodeSource = '# ' + [char]0x4e2d + [char]0x6587 + "`nHost unicode`n  HostName 36.140.239.91`n  Port 22`n"
        $unicodePath = Write-Fixture ('unicode-' + $encoding.CodePage) $unicodeSource $encoding
        $beforeBytes = [IO.File]::ReadAllBytes($unicodePath)
        $unicodeDoc = Read-SshDocument -Path $unicodePath
        Assert-Equal $unicodeDoc.Text $unicodeSource 'decode non-ASCII source'
        $unicodeTarget = @(Get-TargetHosts -Document $unicodeDoc)[0]
        $unicodeUpdated = New-PortUpdate -Document $unicodeDoc -Updates @([pscustomobject]@{Id=$unicodeTarget.Id;Port=32091})
        $unicodeSave = Save-SshDocument -Document $unicodeDoc -Text $unicodeUpdated -ExpectedHash $unicodeDoc.Hash
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($unicodeSave.BackupPath))) ([Convert]::ToBase64String($beforeBytes)) 'backup keeps exact original bytes'
        $expectedBytes = $encoding.GetPreamble() + $encoding.GetBytes($unicodeSource.Replace('Port 22','Port 32091'))
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($unicodePath))) ([Convert]::ToBase64String($expectedBytes)) 'save retains original BOM and encoding'
    }
    Pass 'UTF-8 BOM, UTF-16 LE/BE, non-ASCII comments and exact byte backups'

    $emptyDoc = Read-SshDocument -Path (Write-Fixture 'empty' '')
    Assert-Equal @(Get-TargetHosts -Document $emptyDoc).Count 0 'empty config contains no targets'
    Assert-Throws { Read-SshDocument -Path (Join-Path $fixtureRoot 'missing') } 'missing file gives error'
    $badPath = Join-Path $fixtureRoot 'invalid-utf8'
    [IO.File]::WriteAllBytes($badPath, [byte[]]@(0xff,0x90,0x91))
    Assert-Throws { Read-SshDocument -Path $badPath } 'unsupported encoding rejected without replacement'
    Pass 'empty config, missing file and unsupported bytes'

    $wildcardSource = "# leading global comment`nServerAliveInterval 30`nHost *`n    User default-user`n    Port 22`n    HostName wrong.example`n"
    $wildcardDoc = Read-SshDocument -Path (Write-Fixture 'wildcard-before-add' $wildcardSource)
    $wildcardAdded = New-SshHostChange -Document $wildcardDoc -Action Add -Alias 'New-GPU' -User root -Port 32123
    $effectivePath = Write-Fixture 'wildcard-effective' $wildcardAdded
    $sshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    $effective = @(& $sshExe -F $effectivePath -G New-GPU)
    Assert-Equal $LASTEXITCODE 0 'ssh -G accepts generated fixture without connecting'
    Assert-True ($effective -contains 'user root') 'new explicit user overrides existing Host wildcard defaults'
    Assert-True ($effective -contains 'port 32123') 'new explicit port overrides existing Host wildcard defaults'
    Assert-True ($effective -contains 'hostname 36.140.239.91') 'new fixed IP overrides existing Host wildcard HostName'
    Assert-True ($effective -contains 'serveraliveinterval 30') 'leading global directives retain their scope'
    Assert-Equal $wildcardAdded "# leading global comment`nServerAliveInterval 30`nHost New-GPU`n    HostName 36.140.239.91`n    User root`n    Port 32123`n`nHost *`n    User default-user`n    Port 22`n    HostName wrong.example`n" 'insert new block before first Host and retain exact surrounding source'
    $matchSource = "# global`r`nMatch all`r`n  User fallback`r`nHost later`r`n  HostName 192.0.2.2"
    $matchDoc = Read-SshDocument -Path (Write-Fixture 'match-before-add' $matchSource)
    Assert-Equal (New-SshHostChange -Document $matchDoc -Action Add -Alias 'early' -Port 22) "# global`r`nHost early`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 22`r`n`r`nMatch all`r`n  User fallback`r`nHost later`r`n  HostName 192.0.2.2" 'insert before first Match even when a later Host exists'
    Pass 'CRUD add precedes Host/Match defaults; actual OpenSSH effective values verified on fixtures'

    foreach ($globalSetting in @(@('HostName','wrong.example'), @('User','default-user'), @('Port','22'))) {
        $globalConflictSource = $globalSetting[0] + ' ' + $globalSetting[1] + "`nHost *`n    ServerAliveInterval 60`n"
        $globalConflictDoc = Read-SshDocument -Path (Write-Fixture ('global-conflict-' + $globalSetting[0]) $globalConflictSource)
        Assert-Throws { New-SshHostChange -Document $globalConflictDoc -Action Add -Alias 'New-GPU' -User root -Port 32123 } ('conflicting leading global ' + $globalSetting[0] + ' rejected')
        Assert-Equal ([IO.File]::ReadAllText($globalConflictDoc.Path)) $globalConflictSource 'global conflict rejection leaves file untouched'
    }
    $equalGlobals = "HostName `"36.140.239.91`"`nUser root`nPort=32123`nHost *`n    User fallback`n    Port 22`n"
    $equalGlobalDoc = Read-SshDocument -Path (Write-Fixture 'equal-global-source' $equalGlobals)
    $equalGlobalAdded = New-SshHostChange -Document $equalGlobalDoc -Action Add -Alias 'New-GPU' -User root -Port 32123
    $equalGlobalPath = Write-Fixture 'equal-global-effective' $equalGlobalAdded
    $equalEffective = @(& $sshExe -F $equalGlobalPath -G New-GPU)
    Assert-Equal $LASTEXITCODE 0 'matching leading globals remain valid OpenSSH configuration'
    Assert-True ($equalEffective -contains 'user root') 'matching global user accepted'
    Assert-True ($equalEffective -contains 'port 32123') 'matching global port accepted'
    Assert-True ($equalEffective -contains 'hostname 36.140.239.91') 'matching global HostName accepted'
    Pass 'CRUD add rejects conflicting leading direct global options and accepts matching options'

    $crudSource = "# existing config`nHost other`n  HostName 192.0.2.8`n  Port 2222"
    $crudPath = Write-Fixture 'crud' $crudSource
    $crudDoc = Read-SshDocument -Path $crudPath
    $added = New-SshHostChange -Document $crudDoc -Action Add -Alias 'gpu-new' -User 'ubuntu' -Port 32091
    Assert-Equal $added "# existing config`nHost gpu-new`n    HostName 36.140.239.91`n    User ubuntu`n    Port 32091`n`nHost other`n  HostName 192.0.2.8`n  Port 2222" 'insert before existing Host and preserve missing final newline'
    Assert-Equal ([IO.File]::ReadAllText($crudPath)) $crudSource 'CRUD text operations never write files'
    $addedDefaultUser = New-SshHostChange -Document $emptyDoc -Action Add -Alias 'gpu-default' -Port 22
    Assert-Equal $addedDefaultUser "Host gpu-default`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 22`r`n" 'add empty document defaults omitted user to root'
    $globalOnlyDoc = Read-SshDocument -Path (Write-Fixture 'global-only' '# no final newline')
    Assert-Equal (New-SshHostChange -Document $globalOnlyDoc -Action Add -Alias 'gpu-first' -Port 22) "# no final newline`r`n`r`nHost gpu-first`r`n    HostName 36.140.239.91`r`n    User root`r`n    Port 22`r`n" 'global-only file with no newline is separated before first Host'
    $addSave = Save-SshDocument -Document $crudDoc -Text $added -ExpectedHash $crudDoc.Hash
    Assert-Equal ([IO.File]::ReadAllText($addSave.BackupPath)) $crudSource 'CRUD saves use existing exact backup workflow'
    Pass 'CRUD add preserves existing bytes and missing final newline; text-only generation and backup save'

    $editSource = "# global`r`nHost original # keep alias comment`r`n`tHostName 36.140.239.91`r`n`tUser=`"root`" # account`r`n`tUser root`r`n`tPort  32041 # connection`r`n`tPort 32042`r`n`tRemoteForward 127.0.0.1:18080 127.0.0.1:7890`r`n`tServerAliveInterval 60`r`n`r`nHost elsewhere`r`n  HostName example.com`r`n  Port 443"
    $editDoc = Read-SshDocument -Path (Write-Fixture 'crud-edit' $editSource)
    $editTarget = @(Get-TargetHosts -Document $editDoc)[0]
    $edited = New-SshHostChange -Document $editDoc -Action Edit -Id $editTarget.Id -Alias 'renamed' -User 'dev.user' -Port 32555
    $editExpected = $editSource.Replace('Host original #', 'Host renamed #').Replace('User="root" #', 'User="dev.user" #').Replace("`tUser root", "`tUser dev.user").Replace('Port  32041 #', 'Port  32555 #').Replace('Port 32042', 'Port 32555')
    Assert-Equal $edited $editExpected 'edit preserves comments, quoted formatting, forwards, other hosts and no final newline'
    Assert-Equal (New-SshHostChange -Document $editDoc -Action Edit -Id $editTarget.Id) $editSource 'omitted edit fields leave source unchanged'
    Assert-Equal (New-SshHostChange -Document $editDoc -Action Edit -Id $editTarget.Id -Alias 'ORIGINAL') ($editSource.Replace('Host original #','Host ORIGINAL #')) 'same alias case change allowed'
    $missingFields = New-SshHostChange -Document $doc3 -Action Edit -Id $targets3[0].Id -User 'root' -Port 32091
    Assert-Equal $missingFields "Host new`r`n    User root`r`n    Port 32091`r`n    Include settings.conf`r`n    HostName 36.140.239.91" 'missing User and Port inserted before Include'
    Pass 'CRUD edit keeps unrelated directives and formatting; omitted values and missing directives'

    $deleteSource = "# keep global`nHost remove-me`n  HostName 36.140.239.91`n  User root`n  Port 22`n# trailing block comment belongs to removed block`n`nMatch user root`n  Port 9999`nHost keep-me`n  HostName 192.0.2.8`n  Port 443`n"
    $deleteDoc = Read-SshDocument -Path (Write-Fixture 'crud-delete' $deleteSource)
    $deleteTarget = @(Get-TargetHosts -Document $deleteDoc)[0]
    Assert-Equal (New-SshHostChange -Document $deleteDoc -Action Delete -Id $deleteTarget.Id) "# keep global`nMatch user root`n  Port 9999`nHost keep-me`n  HostName 192.0.2.8`n  Port 443`n" 'delete removes selected block and its trailing comments up to Match boundary only'
    Assert-Throws { New-SshHostChange -Document $deleteDoc -Action Delete -Id '9' } 'delete non-target block rejected'
    Assert-Throws { New-SshHostChange -Document $deleteDoc -Action Edit -Id '9' -Port 22 } 'edit non-target block rejected'
    Assert-Throws { New-SshHostChange -Document $deleteDoc -Action Delete -Id '9999' } 'delete unknown ID rejected'
    Assert-Throws { New-SshHostChange -Document $doc2 -Action Edit -Id $targets2[0].Id -Alias 'safe' } 'multi-alias edit rejected'
    Assert-Throws { New-SshHostChange -Document $doc2 -Action Delete -Id $targets2[0].Id } 'multi-alias delete rejected'
    $wildDoc = Read-SshDocument -Path (Write-Fixture 'crud-wildcard' "Host gpu-*`n  HostName 36.140.239.91`n  Port 22`n")
    Assert-Throws { New-SshHostChange -Document $wildDoc -Action Delete -Id '0' } 'wildcard deletion rejected'
    Pass 'CRUD deletion bounded by Host/Match; reject other hosts, unknown IDs and broad aliases'

    $duplicateSource = "Host target`n HostName 36.140.239.91`n Port 22`nHost Elsewhere other-alias`n HostName example.com`nHost `"QuotedAlias`"`n HostName 192.0.2.2`n"
    $duplicateDoc = Read-SshDocument -Path (Write-Fixture 'crud-duplicate' $duplicateSource)
    foreach ($duplicateAlias in @('TARGET','elsewhere','OTHER-ALIAS','quotedalias')) {
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Add -Alias $duplicateAlias -User root -Port 22 } "duplicate alias $duplicateAlias rejected"
    }
    Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Edit -Id '0' -Alias 'other-alias' } 'rename collision with non-target multi-alias block rejected'
    foreach ($badAlias in @('', 'two hosts','gpu*','!gpu','gpu#comment','gpu;whoami',([char]0x4e2d).ToString())) {
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Add -Alias $badAlias -User root -Port 22 } "invalid alias $badAlias rejected"
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Edit -Id '0' -Alias $badAlias } "invalid edit alias $badAlias rejected"
    }
    foreach ($badUser in @('', 'two users','root#comment','root;whoami',('a' * 65))) {
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Add -Alias 'unused' -User $badUser -Port 22 } "invalid user $badUser rejected"
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Edit -Id '0' -User $badUser } "invalid edit user $badUser rejected"
    }
    foreach ($badPort in @('','0','65536','22;whoami','1.5',"22`n")) {
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Add -Alias 'unused' -User root -Port $badPort } "invalid add port $badPort rejected"
        Assert-Throws { New-SshHostChange -Document $duplicateDoc -Action Edit -Id '0' -Port $badPort } "invalid edit port $badPort rejected"
    }
    Assert-Equal ([IO.File]::ReadAllText($duplicateDoc.Path)) $duplicateSource 'validation errors never change stored configuration'
    Pass 'CRUD alias uniqueness across all blocks; strict alias, user and port validation'
    Write-Output "All $script:Passed SSH configuration test groups passed."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
