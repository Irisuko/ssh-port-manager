$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'VsCode.psm1') -Force
$module = Get-Module VsCode
$testRoot = Join-Path $PSScriptRoot ('.runs\vscode-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Pass([string]$Message) { $script:passed++; Write-Output ('PASS: ' + $Message) }
try {
    $installFolder = Join-Path $testRoot "space and ' Unicode 中文"
    [void][IO.Directory]::CreateDirectory($installFolder)
    $exe = Join-Path $installFolder 'Code.exe'
    [IO.File]::WriteAllBytes($exe, [byte[]]@(0))
    $calls = [Collections.Generic.List[object]]::new()
    $resolver = { $exe }.GetNewClosure()
    $starter = { param($StartInfo) $calls.Add($StartInfo); return $true }.GetNewClosure()
    $result = Open-SshInVSCode -Alias 'PyramidKV-plugin' -Resolver $resolver -ProcessStarter $starter
    Assert ($result.Launched -and $result.Path -ceq $exe -and $null -eq $result.Error) 'Valid launch must return the resolved executable and success.'
    Assert ($calls.Count -eq 1 -and $calls[0].FileName -ceq $exe) 'Executable path must be handed directly to the process boundary.'
    Assert ($calls[0].Arguments -ceq '--new-window --folder-uri "vscode-remote://ssh-remote+PyramidKV-plugin/root"') 'Launch must open the exact SSH alias and default root folder.'
    Assert (-not $calls[0].UseShellExecute -and $calls[0].WindowStyle -eq [Diagnostics.ProcessWindowStyle]::Normal) 'Launch must be direct and explicitly visible.'
    Pass 'exact Remote SSH folder URI and direct executable launch with spaces, apostrophes and Unicode'

    $calls.Clear()
    $result = Open-SshInVSCode -Alias 'gpu.test_1' -RemotePath '/root/space 中文/#file?"a%/$x' -Resolver $resolver -ProcessStarter $starter
    Assert $result.Launched 'A valid absolute path with reserved characters should be encoded.'
    $arguments = $calls[0].Arguments
    Assert ($arguments.Contains('/root/space%20%E4%B8%AD%E6%96%87/%23file%3F%22a%25/%24x')) 'URI path segments must be percent encoded.'
    Assert (([regex]::Matches($arguments, '"')).Count -eq 2) 'Remote path must not inject additional command-line quotes.'
    Pass 'remote path is URI escaped without argument or shell interpolation'

    foreach ($alias in @('', '-bad', 'a b', 'a;cmd', 'a"b', 'a/b', 'a@host', "a`nnext", '主机', ('a' * 129))) {
        $calls.Clear()
        $result = Open-SshInVSCode -Alias $alias -Resolver $resolver -ProcessStarter $starter
        Assert (-not $result.Launched -and $calls.Count -eq 0 -and $result.Error) 'Invalid aliases must fail before process launch.'
    }
    foreach ($path in @('', 'relative/path', "root`nnext", "/root`0bad", ('/' + ('a' * 4096)))) {
        $calls.Clear()
        $result = Open-SshInVSCode -Alias 'Valid' -RemotePath $path -Resolver $resolver -ProcessStarter $starter
        Assert (-not $result.Launched -and $calls.Count -eq 0) 'Invalid remote paths must never reach process launch.'
    }
    Pass 'strict aliases and absolute bounded remote paths reject injection-shaped input'

    $calls.Clear()
    $result = Open-SshInVSCode -Alias 'Valid' -Resolver { $null } -ProcessStarter $starter
    Assert (-not $result.Launched -and $calls.Count -eq 0 -and $result.Error.Contains('VS Code')) 'Missing installation must return actionable failure without launching.'
    $result = Open-SshInVSCode -Alias 'Valid' -Resolver { 'powershell.exe' } -ProcessStarter $starter
    Assert (-not $result.Launched -and $calls.Count -eq 0) 'Resolver must not substitute a relative executable command.'
    $otherExe = Join-Path $installFolder 'Other.exe'
    [IO.File]::WriteAllBytes($otherExe, [byte[]]@(0))
    $result = Open-SshInVSCode -Alias 'Valid' -Resolver { $otherExe }.GetNewClosure() -ProcessStarter $starter
    Assert (-not $result.Launched -and $calls.Count -eq 0) 'Resolver must not substitute an unrelated executable.'
    Pass 'missing or invalid VS Code discovery is a safe non-launch result'

    $bin = Join-Path $installFolder 'bin'
    [void][IO.Directory]::CreateDirectory($bin)
    $shim = Join-Path $bin 'code.cmd'
    [IO.File]::WriteAllText($shim, 'DO NOT EXECUTE THIS FIXTURE')
    $found = & $module { param($Candidates) Resolve-VsCodeExecutable -CandidatePaths $Candidates } @($shim)
    Assert ($found -ceq $exe) 'Code command shim should resolve to its installation executable without executing the shim.'
    $found = & $module { param($Candidates) Resolve-VsCodeExecutable -CandidatePaths $Candidates } @('C:\missing\Code.exe', ('"' + $exe + '"'))
    Assert ($found -ceq $exe) 'Discovery should ignore missing paths and support quoted App Paths values.'
    Pass 'discovery safely resolves command shim and quoted registered executable paths'

    $result = Open-SshInVSCode -Alias 'Valid' -Resolver $resolver -ProcessStarter { param($StartInfo) return $false }
    Assert (-not $result.Launched -and $result.Error) 'Process failure must not report a launch.'
    $result = Open-SshInVSCode -Alias 'Valid' -Resolver $resolver -ProcessStarter { throw 'fixture-sensitive-process-detail' }
    Assert (-not $result.Launched -and -not $result.Error.Contains('fixture-sensitive-process-detail')) 'Unexpected process diagnostics must not leak into UI result.'
    Pass 'process failure is explicit and sanitized'
    Write-Output ('VS Code tests passed: ' + $passed + ' groups; no real app launch, SSH access or network.')
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.runs')).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
