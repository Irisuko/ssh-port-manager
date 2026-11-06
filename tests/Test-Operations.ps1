$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$appRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'Operations.psm1'))) {
    throw 'FAIL: Invoke-PortChanges is not implemented.'
}
Import-Module (Join-Path $appRoot 'Operations.psm1') -Force
Import-Module (Join-Path $appRoot 'SshConfig.psm1') -Force

$script:passed = 0
$runsRoot = Join-Path $PSScriptRoot '.runs'
$testRoot = Join-Path $runsRoot ([Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$keygen = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\OpenSSH\ssh-keygen.exe'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw ('FAIL: ' + $Message + ' expected <' + $Expected + '> actual <' + $Actual + '>') }
}
function Pass([string]$Name) { $script:passed++; Write-Output ('PASS: ' + $Name) }
function New-Fixture([string]$Name, [string]$KnownHostsText = '') {
    $dir = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $config = Join-Path $dir 'config'
    $known = Join-Path $dir 'known_hosts'
    $text = "# keep this comment`r`nHost alpha`r`n  HostName 36.140.239.91`r`n  User root`r`n  Port 32041`r`nHost beta`r`n  HostName 36.140.239.91`r`n  Port 32081`r`nHost other`r`n  HostName 192.0.2.20`r`n  Port 2222`r`n"
    [IO.File]::WriteAllText($config, $text, $utf8)
    if ($KnownHostsText) { [IO.File]::WriteAllText($known, $KnownHostsText, $utf8) }
    $doc = Read-SshDocument -Path $config
    $targets = @(Get-TargetHosts -Document $doc)
    return [PSCustomObject]@{ Config = $config; Known = $known; Text = $text; Document = $doc; Targets = $targets }
}
function New-Request($Fixture, $Updates) {
    return [PSCustomObject]@{ ConfigPath = $Fixture.Config; KnownHostsPath = $Fixture.Known; ExpectedHash = $Fixture.Document.Hash; Updates = @($Updates) }
}
function Assert-Untouched($Fixture, [string]$BeforeKnown) {
    Assert-Equal ([IO.File]::ReadAllText($Fixture.Config)) $Fixture.Text 'config must not be mutated on validation failure'
    if ($BeforeKnown) { Assert-Equal ([IO.File]::ReadAllText($Fixture.Known)) $BeforeKnown 'known_hosts must not be mutated on validation failure' }
}

try {
    $keyPath = Join-Path $testRoot 'fixture_key'
    & $keygen -q -t ed25519 -N '""' -f $keyPath
    Assert-Equal $LASTEXITCODE 0 'create disposable test key'
    $publicKey = ([IO.File]::ReadAllText($keyPath + '.pub').Trim() -split '\s+')[0..1] -join ' '
    $knownText = "[36.140.239.91]:32091 $publicKey`n[36.140.239.91]:32041 $publicKey`n[192.0.2.20]:2222 $publicKey`n"

    $f = New-Fixture 'success' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True $r.Success ('normal update succeeds: ' + $r.Error + ' ' + ($r.Results | ConvertTo-Json -Depth 4 -Compress))
    Assert-True $r.ConfigChanged 'config changed flag'
    Assert-Equal ([IO.File]::ReadAllText($f.Config)) ($f.Text.Replace('Port 32041', 'Port 32091')) 'only selected port changes'
    Assert-Equal ([IO.File]::ReadAllLines($f.Known) -join "`n") ("[36.140.239.91]:32041 $publicKey`n[192.0.2.20]:2222 $publicKey") 'only requested new endpoint is removed'
    Assert-Equal ([IO.File]::ReadAllText($r.BackupPath)) $f.Text 'config backup contains original'
    Assert-Equal ([IO.File]::ReadAllText($r.KnownHostsBackupPath)) $knownText 'known_hosts backup contains original'
    Assert-Equal @($r.Results).Count 1 'one command result'
    Assert-Equal $r.Results[0].Endpoint '[36.140.239.91]:32091' 'new port endpoint'
    Pass 'real ssh-keygen removes exact endpoint and preserves other rows'

    $f = New-Fixture "space ' and 中文" $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True $r.Success ('paths with spaces and Unicode succeed: ' + $r.Error)
    Assert-Equal @([IO.File]::ReadAllLines($f.Known)).Count 2 'quoted native path reaches expected file'
    Pass 'spaces, apostrophes, and Unicode in file paths are supported'

    $f = New-Fixture 'hashed' $knownText
    $ErrorActionPreference = 'Continue'
    & $keygen -H -f $f.Known 2>$null | Out-Null
    $hashExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert-Equal $hashExitCode 0 'hash fixture entries'
    $before = [IO.File]::ReadAllText($f.Known)
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True $r.Success 'hashed record operation succeeds'
    Assert-Equal @([IO.File]::ReadAllLines($f.Known)).Count 2 'hashed requested endpoint removed'
    Assert-True (-not ([IO.File]::ReadAllText($f.Known).Contains('[36.140.239.91]'))) 'remaining entries stay hashed'
    Assert-Equal ([IO.File]::ReadAllText($r.KnownHostsBackupPath)) $before 'hashed backup unchanged'
    Pass 'hashed known_hosts entries are removed with real ssh-keygen'

    $f = New-Fixture 'blank' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @())
    Assert-True $r.Success 'empty selection is successful no-op'
    Assert-True (-not $r.ConfigChanged) 'empty selection does not change config'
    Assert-Equal @($r.Results).Count 0 'empty selection does not run commands'
    Assert-Untouched $f $knownText
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $f.Config)).Count 2 'empty selection creates no backups'
    Pass 'blank selection leaves all files alone'

    foreach ($badPort in @('0', '65536', '-1', 'abc', '32; echo bad', '32091.0', '  ', '１')) {
        $f = New-Fixture ('invalid-' + [Guid]::NewGuid().ToString('N')) $knownText
        $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = $badPort }))
        Assert-True (-not $r.Success) ('invalid port rejected: ' + $badPort)
        Assert-Untouched $f $knownText
    }
    Pass 'invalid and injection-shaped ports fail before any mutation'

    $f = New-Fixture 'duplicate' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }, @{ Id = $f.Targets[0].Id; Port = '32092' }))
    Assert-True (-not $r.Success) 'duplicate ID rejected'
    Assert-Untouched $f $knownText
    Pass 'duplicate selections fail without changes'

    $f = New-Fixture 'wrong-id' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = 'does-not-exist'; Port = '32091' }))
    Assert-True (-not $r.Success) 'unknown/non-target ID rejected'
    Assert-Untouched $f $knownText
    Pass 'non-target selection fails without changes'

    $f = New-Fixture 'stale' $knownText
    $staleRequest = New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' })
    [IO.File]::AppendAllText($f.Config, '# external edit', $utf8)
    $staleText = [IO.File]::ReadAllText($f.Config)
    $r = Invoke-PortChanges -Request $staleRequest
    Assert-True (-not $r.Success) 'stale snapshot rejected'
    Assert-Equal ([IO.File]::ReadAllText($f.Config)) $staleText 'external edit preserved'
    Assert-Equal ([IO.File]::ReadAllText($f.Known)) $knownText 'stale snapshot leaves host keys alone'
    Pass 'external changes reject stale request'

    $f = New-Fixture 'wrong-known-path' $knownText
    $request = New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' })
    $request.KnownHostsPath = Join-Path $testRoot 'different-known_hosts'
    $r = Invoke-PortChanges -Request $request
    Assert-True (-not $r.Success) 'foreign known_hosts path rejected'
    Assert-Untouched $f $knownText
    Pass 'known_hosts path is tied to selected config directory'

    $f = New-Fixture 'dedup' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }, @{ Id = $f.Targets[1].Id; Port = '32091' }))
    Assert-True $r.Success 'two selected hosts update'
    Assert-Equal @($r.Results).Count 1 'identical endpoints are cleared once'
    Assert-Equal @(Get-TargetHosts -Document (Read-SshDocument -Path $f.Config) | Where-Object Port -eq 32091).Count 2 'both selected blocks updated'
    Pass 'same endpoint is deduplicated after both config blocks update'

    $f = New-Fixture 'no-known-hosts'
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True $r.Success 'missing known_hosts needs no cleanup'
    Assert-True $r.ConfigChanged 'missing known_hosts still updates config'
    Assert-True (-not (Test-Path -LiteralPath $f.Known)) 'missing known_hosts is not created'
    Pass 'missing known_hosts is an explicit successful no-op'

    $f = New-Fixture 'no-match' ("[192.0.2.20]:2222 $publicKey`n")
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True $r.Success 'absent key is idempotent success'
    Pass 'absent key is successful and idempotent'

    $f = New-Fixture 'unchanged-port' $knownText
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32041' }))
    Assert-True $r.Success 'same port still clears host key'
    Assert-True (-not $r.ConfigChanged) 'same port avoids unnecessary config write'
    Assert-True (-not ([IO.File]::ReadAllText($f.Known).Contains('[36.140.239.91]:32041'))) 'same port key removed'
    Pass 'entering current port clears its host key'

    $f = New-Fixture 'partial-failure' ("bad invalid line`n[36.140.239.91]:32091 $publicKey`n")
    $r = Invoke-PortChanges -Request (New-Request $f @(@{ Id = $f.Targets[0].Id; Port = '32091' }))
    Assert-True (-not $r.Success) 'malformed known_hosts reports command failure'
    Assert-True $r.ConfigChanged 'failure accurately reports config already changed'
    Assert-True ([IO.File]::ReadAllText($f.Config).Contains('Port 32091')) 'config update occurred before cleanup failure'
    Assert-True (Test-Path -LiteralPath $r.BackupPath) 'partial failure keeps recovery backup'
    Assert-True (-not $r.Results[0].Success) 'failed command marked failed'
    Assert-True (-not [string]::IsNullOrWhiteSpace($r.Error)) 'partial failure carries an error'
    Pass 'ssh-keygen failure reports partial completion and backups'

    $parts=$publicKey -split ' '
    $trusted=@([pscustomobject]@{Algorithm=$parts[0];Key=$parts[1]})
    $f=New-Fixture 'install-trusted-key' $knownText
    $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='32091';AddHostKeys=$true;HostKeys=$trusted}))
    Assert-True $r.Success ('trusted key install succeeds: '+$r.Error)
    Assert-True $r.Results[0].KeyAdded 'successful key addition is explicit'
    Assert-Equal $r.Results[0].AddedKeys 1 'exactly one trusted key added'
    Assert-True (-not $r.Results[0].KeyPending) 'installed keys are not pending'
    Assert-Equal @([IO.File]::ReadAllLines($f.Known) | Where-Object { $_ -eq "[36.140.239.91]:32091 $publicKey" }).Count 1 'new endpoint public key installed once'
    Assert-True ([IO.File]::ReadAllText($f.Known).Contains('[192.0.2.20]:2222')) 'unrelated endpoint retained after addition'
    $found=@(& $keygen -F '[36.140.239.91]:32091' -f $f.Known)
    Assert-Equal $LASTEXITCODE 0 'real OpenSSH recognizes installed host key'
    Assert-True (($found -join "`n").Contains($publicKey)) 'OpenSSH finds exact trusted key'
    $again=Read-SshDocument -Path $f.Config
    $request=New-Request $f @(@{Id=$f.Targets[0].Id;Port='32091';AddHostKeys=$true;HostKeys=$trusted})
    $request.ExpectedHash=$again.Hash
    $r=Invoke-PortChanges -Request $request
    Assert-True $r.Success 'repeated install succeeds'
    Assert-Equal @([IO.File]::ReadAllLines($f.Known) | Where-Object { $_ -eq "[36.140.239.91]:32091 $publicKey" }).Count 1 'repeated cleanup and add does not duplicate host key'
    Pass 'trusted new host keys install after cleanup, preserve unrelated entries and work in real OpenSSH'

    $defaultKnownText="36.140.239.91 $publicKey`n[36.140.239.91]:22 $publicKey`n[36.140.239.91]:32091 $publicKey`n[192.0.2.20]:2222 $publicKey`n"
    foreach ($hashDefaultKeys in @($false,$true)) {
        $f=New-Fixture ('default-port-'+$hashDefaultKeys) $defaultKnownText
        if ($hashDefaultKeys) {
            $ErrorActionPreference='Continue'
            & $keygen -H -f $f.Known 2>$null | Out-Null
            $hashExitCode=$LASTEXITCODE
            $ErrorActionPreference='Stop'
            Assert-Equal $hashExitCode 0 'hash default-port fixture entries'
        }
        $beforeKnown=[IO.File]::ReadAllText($f.Known)
        $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='22';AddHostKeys=$true;HostKeys=$trusted}))
        Assert-True ($r.Success -and $r.Results[0].KeyAdded -and -not $r.Results[0].KeyPending) 'default port installs verified keys successfully'
        Assert-Equal $r.Results[0].Endpoint '[36.140.239.91]:22' 'default port keeps stable UI result endpoint'
        Assert-Equal ([IO.File]::ReadAllText($r.KnownHostsBackupPath)) $beforeKnown 'default port backs up both original key forms before cleanup'
        Assert-Equal @([IO.File]::ReadAllLines($f.Known)).Count 3 'both old default-port forms are replaced by one canonical entry'
        Assert-Equal @([IO.File]::ReadAllLines($f.Known) | Where-Object { $_ -ceq "36.140.239.91 $publicKey" }).Count 1 'default port installs canonical bare-host entry exactly once'
        $found=@(& $keygen -F '36.140.239.91' -f $f.Known)
        Assert-Equal $LASTEXITCODE 0 'real OpenSSH recognizes canonical default-port key'
        Assert-True (($found -join "`n").Contains($publicKey)) 'canonical OpenSSH lookup finds verified public key'
        $null=& $keygen -F '[36.140.239.91]:22' -f $f.Known
        Assert-Equal $LASTEXITCODE 1 'obsolete bracketed default-port key is removed'
        $null=& $keygen -F '[36.140.239.91]:32091' -f $f.Known
        Assert-Equal $LASTEXITCODE 0 'nondefault key on the same IP is preserved'
    }
    Pass 'default port rotates plain and hashed host keys into the canonical OpenSSH bare-host name'

    $f=New-Fixture 'default-port-deferred' $defaultKnownText
    $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='22';AddHostKeys=$false;HostKeys=@()}))
    Assert-True ($r.Success -and $r.Results[0].KeyPending -and -not $r.Results[0].KeyAdded) 'default-port deferred cleanup stays explicitly pending'
    Assert-Equal ([IO.File]::ReadAllLines($f.Known) -join "`n") ("[36.140.239.91]:32091 $publicKey`n[192.0.2.20]:2222 $publicKey") 'default-port deferred cleanup removes both old forms without installing keys'
    Pass 'default-port deferred cleanup removes bare and bracketed keys while preserving other ports'

    $f=New-Fixture 'default-port-cleanup-failure' ("bad invalid line`n"+$defaultKnownText)
    $beforeKnown=[IO.File]::ReadAllText($f.Known)
    $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='22';AddHostKeys=$true;HostKeys=$trusted}))
    Assert-True (-not $r.Success -and -not $r.Results[0].KeyAdded -and $r.Results[0].AddedKeys -eq 0) 'failed default-port cleanup cannot report new keys installed'
    Assert-True $r.ConfigChanged 'default-port failure accurately reports config already changed'
    Assert-Equal ([IO.File]::ReadAllText($f.Known)) $beforeKnown 'malformed known_hosts never receives new keys after cleanup fails'
    Assert-Equal ([IO.File]::ReadAllText($r.KnownHostsBackupPath)) $beforeKnown 'default-port cleanup failure retains original backup'
    Pass 'default-port cleanup failures block new-key installation and preserve recovery backup'

    $f=New-Fixture 'create-known-hosts'
    $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='32091';AddHostKeys=$true;HostKeys=$trusted}))
    Assert-True ($r.Success -and $r.Results[0].KeyAdded) 'key addition creates absent known_hosts'
    Assert-Equal ([IO.File]::ReadAllText($f.Known).Trim()) "[36.140.239.91]:32091 $publicKey" 'new known_hosts content exact'
    Pass 'missing known_hosts is created only when verified keys are supplied'

    $f=New-Fixture 'deferred-key-addition' $knownText
    $r=Invoke-PortChanges -Request (New-Request $f @(@{Id=$f.Targets[0].Id;Port='32091';AddHostKeys=$false;HostKeys=@()}))
    Assert-True ($r.Success -and $r.Results[0].KeyPending -and -not $r.Results[0].KeyAdded) 'deferred mode updates config and clears old key while explicitly pending new key'
    Assert-True (-not ([IO.File]::ReadAllText($f.Known).Contains('[36.140.239.91]:32091'))) 'deferred mode does not invent host keys'
    Pass 'not-ready sync completes local update and cleanup with key addition marked pending'

    foreach ($bad in @(@{Id='1';Port='32091';AddHostKeys=$true;HostKeys=@()},@{Id='1';Port='32091';AddHostKeys=$true;HostKeys=@([pscustomobject]@{Algorithm='ssh-ed25519';Key="bad`n[evil]:22"})},@{Id='1';Port='32091';AddHostKeys='true';HostKeys=$trusted},@{Id='1';Port='32091';AddHostKeys=$false;HostKeys=$trusted})) {
        $f=New-Fixture ('invalid-hostkey-'+[guid]::NewGuid().ToString('N')) $knownText
        $r=Invoke-PortChanges -Request (New-Request $f @($bad))
        Assert-True (-not $r.Success) 'invalid host key requests must fail'
        Assert-Untouched $f $knownText
    }
    Pass 'missing, malformed, injected or contradictory host keys fail before any local mutation'

    Write-Output ('Operations tests passed: ' + $script:passed)
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedRoot = [IO.Path]::GetFullPath($runsRoot) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
