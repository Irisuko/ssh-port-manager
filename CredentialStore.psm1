Set-StrictMode -Version 2.0

function Get-CoderCredentialPath {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SshPortManager\coder-credential.xml'
}

function Read-CoderCredential {
    [CmdletBinding()]
    param([string]$Path = (Get-CoderCredentialPath))
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $credential = Import-Clixml -LiteralPath $Path -ErrorAction Stop
        if ($credential -isnot [pscredential] -or [string]::IsNullOrWhiteSpace($credential.UserName) -or $credential.Password.Length -eq 0) {
            throw 'Invalid saved credential.'
        }
        return $credential
    } catch {
        throw '无法读取已保存的登录信息。请在登录设置中重新保存；加密信息只能由原 Windows 用户在本机读取。'
    }
}

function Save-CoderCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscredential]$Credential, [string]$Path = (Get-CoderCredentialPath))
    if ([string]::IsNullOrWhiteSpace($Credential.UserName) -or $Credential.Password.Length -eq 0) {
        throw '请填写登录账号和密码。'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $temporaryPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        # Export-Clixml protects SecureString with Windows DPAPI CurrentUser.
        $Credential | Export-Clixml -LiteralPath $temporaryPath -Encoding UTF8 -ErrorAction Stop
        # Windows PowerShell 5.1 converts $null to an empty string for this overload.
        if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($temporaryPath, $fullPath, [NullString]::Value) }
        else { [IO.File]::Move($temporaryPath, $fullPath) }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

Export-ModuleMember -Function Get-CoderCredentialPath,Read-CoderCredential,Save-CoderCredential
