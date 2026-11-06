Set-StrictMode -Version 2.0

function Read-HostKeyWireValue([byte[]]$Bytes, [ref]$Offset) {
    $start = [int]$Offset.Value
    if ($start -lt 0 -or $start + 4 -gt $Bytes.Length) { throw '服务器公钥格式不完整。' }
    $length = ([long]$Bytes[$start] * 16777216) + ([long]$Bytes[$start + 1] * 65536) + ([long]$Bytes[$start + 2] * 256) + $Bytes[$start + 3]
    $start += 4
    if ($length -gt 8192 -or $length -gt ($Bytes.Length - $start)) { throw '服务器公钥字段长度无效。' }
    $value = New-Object byte[] ([int]$length)
    [Array]::Copy($Bytes, $start, $value, 0, [int]$length)
    $Offset.Value = $start + [int]$length
    return ,$value
}

function ConvertTo-ValidatedHostKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Keys, [switch]$AllowEmpty)
    if ($null -eq $Keys -or $Keys.Count -eq 0) {
        if ($AllowEmpty) { return }
        throw '尚未取得服务器主机公钥，无法添加新密钥。'
    }
    if ($Keys.Count -gt 16) { throw '服务器公钥数量超出限制。' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $Keys) {
        if ($null -eq $entry) { throw '服务器公钥项目无效。' }
        $algorithm = $null
        $key = $null
        if ($entry -is [Collections.IDictionary]) { $algorithm=$entry['Algorithm']; $key=$entry['Key'] }
        else {
            if ($null -ne $entry.PSObject.Properties['Algorithm']) { $algorithm=$entry.Algorithm }
            if ($null -ne $entry.PSObject.Properties['Key']) { $key=$entry.Key }
        }
        if ($algorithm -isnot [string] -or $key -isnot [string] -or
            @('ssh-ed25519','ssh-rsa','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521') -cnotcontains $algorithm -or
            $key.Length -gt 16384 -or $key -cnotmatch '\A[A-Za-z0-9+/]+={0,2}\z') {
            throw '服务器公钥类型或编码无效。'
        }
        try { $bytes = [Convert]::FromBase64String($key) } catch { throw '服务器公钥 Base64 编码无效。' }
        if ([Convert]::ToBase64String($bytes) -cne $key) { throw '服务器公钥不是规范的 Base64 编码。' }
        $offset = 0
        $wireAlgorithm = [Text.Encoding]::ASCII.GetString((Read-HostKeyWireValue $bytes ([ref]$offset)))
        if ($wireAlgorithm -cne $algorithm) { throw '服务器公钥类型与密钥内容不一致。' }
        switch -CaseSensitive ($algorithm) {
            'ssh-ed25519' {
                $publicValue = Read-HostKeyWireValue $bytes ([ref]$offset)
                if ($publicValue.Length -ne 32) { throw 'Ed25519 主机公钥长度无效。' }
            }
            'ssh-rsa' {
                $exponent = Read-HostKeyWireValue $bytes ([ref]$offset)
                $modulus = Read-HostKeyWireValue $bytes ([ref]$offset)
                if ($exponent.Length -lt 1 -or $exponent.Length -gt 8 -or $modulus.Length -lt 128 -or $modulus.Length -gt 8192 -or
                    ($exponent[0] -band 128) -ne 0 -or ($modulus[0] -band 128) -ne 0 -or
                    @($exponent | Where-Object { $_ -ne 0 }).Count -eq 0 -or @($modulus | Where-Object { $_ -ne 0 }).Count -eq 0) {
                    throw 'RSA 主机公钥参数无效。'
                }
            }
            default {
                $curve = [Text.Encoding]::ASCII.GetString((Read-HostKeyWireValue $bytes ([ref]$offset)))
                $point = Read-HostKeyWireValue $bytes ([ref]$offset)
                $curveName = $algorithm.Substring('ecdsa-sha2-'.Length)
                $pointLengths = @{nistp256=65;nistp384=97;nistp521=133}
                if ($curve -cne $curveName -or $point.Length -ne $pointLengths[$curveName] -or $point[0] -ne 4) { throw 'ECDSA 主机公钥参数无效。' }
            }
        }
        if ($offset -ne $bytes.Length) { throw '服务器公钥包含多余数据。' }
        $identity = $algorithm + ' ' + $key
        if ($seen.Add($identity)) {
            [pscustomobject]@{Algorithm=$algorithm;Key=$key}
        }
    }
}

Export-ModuleMember -Function ConvertTo-ValidatedHostKeys
