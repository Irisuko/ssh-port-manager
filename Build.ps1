[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot 'dist\SshPortManager.exe'
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw 'Run this build script using Windows PowerShell 5.1 (powershell.exe).'
}
$compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) {
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$automation = [System.Management.Automation.PSObject].Assembly.Location
$output = [IO.Path]::GetFullPath($OutputPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
$payload = @(
    'App.ps1', 'App.xaml', 'Apply-Changes.ps1', 'Check-Coder.ps1',
    'Coder.psm1', 'CoderJob.psm1', 'CredentialStore.psm1', 'HostManagement.psm1',
    'HostManager.ps1', 'HostManager.xaml', 'Mappings.psm1', 'Operations.psm1',
    'SshConfig.psm1', 'Start-Coder.ps1', 'CoderTerminal.psm1',
    'PreparationJob.psm1', 'Start-Prepare.ps1', 'HostKeys.psm1', 'VsCode.psm1'
)
$arguments = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', "/reference:$automation", '/reference:System.Windows.Forms.dll', "/out:$output")
foreach ($name in $payload) {
    $file = Join-Path $PSScriptRoot $name
    if (-not [IO.File]::Exists($file)) { throw ('Missing application payload: ' + $name) }
    $arguments += ('/resource:' + $file + ',SshPortManager.Runtime.' + $name)
}
$icon = Join-Path $PSScriptRoot 'Assets\SshPortManager.ico'
if ([IO.File]::Exists($icon)) { $arguments += ('/win32icon:' + $icon) }
$arguments += @((Join-Path $PSScriptRoot 'Launcher.cs'), (Join-Path $PSScriptRoot 'AssemblyInfo.cs'))
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Write-Output ('Built: ' + $output)
