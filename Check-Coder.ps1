# Read-only connection check: this command never starts a stopped workspace.
param([string[]]$Alias)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Coder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CredentialStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mappings.psm1') -Force
if ($null -eq $Alias -or $Alias.Count -eq 0) { $Alias = @((Get-CoderMappings).Keys) }
$credential = Read-CoderCredential
if ($null -eq $credential) { throw 'Save Coder credentials in the application first.' }
foreach ($name in $Alias) {
    $result = Invoke-CoderWorkspace -Alias $name -Credential $credential -RequireAlreadyRunning -TimeoutSeconds 60
    [pscustomobject]@{ Alias=$name; Workspace=$result.WorkspaceName; Port=$result.Port; Status=$result.Status; Started=$result.Started }
}
$credential = $null
