$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'HostKeys.psm1') -Force
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Wire([byte[]]$Data) { return ,([byte[]]@((($Data.Length -shr 24) -band 255),(($Data.Length -shr 16) -band 255),(($Data.Length -shr 8) -band 255),($Data.Length -band 255)) + $Data) }
function Key([string]$Type,[byte[]]$Tail) { return [pscustomobject]@{Algorithm=$Type;Key=[Convert]::ToBase64String([byte[]]((Wire ([Text.Encoding]::ASCII.GetBytes($Type))) + $Tail))} }
function Reject($Keys) { $caught=$false; try { $null=ConvertTo-ValidatedHostKeys -Keys $Keys } catch { $caught=$true }; Assert $caught 'Invalid key unexpectedly accepted.' }
$ed=Key 'ssh-ed25519' (Wire ([byte[]](1..32)))
$rsa=Key 'ssh-rsa' ([byte[]]((Wire ([byte[]]@(1,0,1))) + (Wire ([byte[]](@(0,128) + (1..127))))))
$ec=Key 'ecdsa-sha2-nistp256' ([byte[]]((Wire ([Text.Encoding]::ASCII.GetBytes('nistp256'))) + (Wire ([byte[]](@(4)+(1..64))))))
$validated=@(ConvertTo-ValidatedHostKeys -Keys @($ed,$rsa,$ec,$ed))
Assert ($validated.Count -eq 3) 'Supported SSH wire keys must validate and duplicates collapse.'
Assert (@(ConvertTo-ValidatedHostKeys -Keys @() -AllowEmpty).Count -eq 0) 'Explicit empty deferred keys must be allowed.'
Reject @()
Reject @([pscustomobject]@{Algorithm='ssh-ed25519';Key=$ed.Key+"`nmalicious"})
Reject @([pscustomobject]@{Algorithm='ssh-rsa';Key=$ed.Key})
Reject @([pscustomobject]@{Algorithm='ssh-ed25519';Key='not+base64'})
Reject @((Key 'ssh-ed25519' (Wire ([byte[]](1..31)))))
Reject @([pscustomobject]@{Algorithm='ssh-ed25519';Key=[Convert]::ToBase64String([byte[]]([Convert]::FromBase64String($ed.Key)+[byte]0))})
Reject @((Key 'ecdsa-sha2-nistp256' ([byte[]]((Wire ([Text.Encoding]::ASCII.GetBytes('nistp384'))) + (Wire ([byte[]](@(4)+(1..64))))))))
Reject @([pscustomobject]@{Algorithm='ssh-ed25519';Key=[Convert]::ToBase64String([byte[]]@(255,255,255,255))})
Write-Output 'PASS: SSH host public key wire validation, canonical encoding, type/length checks, deduplication and injection rejection.'
